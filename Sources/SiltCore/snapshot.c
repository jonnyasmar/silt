// Snapshots: a compacted, LZ4-compressed copy of a finished tree, so the next
// launch can show it instantly and only catch up on what changed since.
//
// Saving walks the live tree breadth-first and writes each folder's children
// as one contiguous run, so the loaded tree has no garbage from refreshes.
// Names are laid out exactly as the chunked arena expects, so every offset in
// the file is usable as-is after loading. Both directions stream through a
// small buffer: saving holds one compacted copy at most, and loading
// decompresses straight into the tree's own chunks.

#include "internal.h"

#include <compression.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SNAP_MAGIC "SILTSNP3"
#define SNAP_VERSION 3u // 3: runs with spare room, streamed payload
#define NAME_CHUNK (1u << SILT_NAME_SHIFT)
#define ENTRY_CHUNK (1u << SILT_ENTRY_SHIFT)
#define DIR_CHUNK (1u << SILT_DIR_SHIFT)
#define STREAM_BUFFER (1u << 20)

typedef struct snap_header {
  char magic[8];
  uint32_t version;
  uint32_t entry_size;
  uint32_t dir_size;
  uint32_t entry_count;
  uint32_t dir_count;
  uint32_t name_bytes;
  uint64_t raw_bytes;        // uncompressed payload size
  uint64_t compressed_bytes; // payload size on disk
  uint64_t checksum;         // of the uncompressed payload
  silt_snapshot_meta meta;
} snap_header;

// A fast word-wise checksum, to catch a damaged file that still decompresses.
// Splitting the input at multiples of 8 bytes doesn't change the result.
static uint64_t checksum(uint64_t h, const void *p, size_t len) {
  const uint8_t *b = p;
  size_t words = len / 8;
  for (size_t i = 0; i < words; i++) {
    uint64_t w;
    memcpy(&w, b + i * 8, 8);
    h = (h ^ w) * 0x9E3779B97F4A7C15ull;
    h ^= h >> 29;
  }
  for (size_t i = words * 8; i < len; i++) h = (h ^ b[i]) * 0x100000001B3ull;
  return h;
}

#define CHECKSUM_SEED 0x5117C0DEull

// A buffer sized to an upper bound up front. Large allocations are only
// backed by memory as they're written, so the bound costs nothing.
typedef struct outbuf {
  uint8_t *p;
  size_t n, cap;
} outbuf;

// NULL if the bound turns out to be too small (the save is abandoned).
static void *take(outbuf *b, size_t extra) {
  if (b->n + extra > b->cap) return NULL;
  void *at = b->p + b->n;
  b->n += extra;
  return at;
}

// Appends a name where the chunked arena would put it. Returns its offset,
// or SILT_NONE if the buffer is full.
static uint32_t put_name(outbuf *names, const uint8_t *s, uint16_t len) {
  size_t off = names->n;
  if ((off & SILT_NAME_MASK) + len > NAME_CHUNK) {
    size_t pad = NAME_CHUNK - (off & SILT_NAME_MASK);
    void *at = take(names, pad);
    if (!at) return SILT_NONE;
    memset(at, 0, pad);
    off = names->n;
  }
  void *at = take(names, len);
  if (!at) return SILT_NONE;
  memcpy(at, s, len);
  return (uint32_t)off;
}

// Compresses `len` bytes into the stream, writing output as it fills.
static bool encode(compression_stream *z, FILE *f, uint8_t *out, const void *src,
                   size_t len, bool last, uint64_t *written) {
  z->src_ptr = src;
  z->src_size = len;
  for (;;) {
    compression_status st = compression_stream_process(z, last ? COMPRESSION_STREAM_FINALIZE : 0);
    if (st == COMPRESSION_STATUS_ERROR) return false;
    const size_t produced = STREAM_BUFFER - z->dst_size;
    const bool done = last ? st == COMPRESSION_STATUS_END : z->src_size == 0;
    if (produced && (z->dst_size == 0 || done)) {
      if (fwrite(out, 1, produced, f) != produced) return false;
      *written += produced;
      z->dst_ptr = out;
      z->dst_size = STREAM_BUFFER;
    }
    if (done) return true;
  }
}

bool silt_tree_save(silt_tree *t, const char *path, const silt_snapshot_meta *meta) {
  outbuf entries = {0}, dirs = {0}, names = {0};
  uint32_t *queue = NULL; // pairs: old dir id, new dir id
  size_t qhead = 0, qtail = 0, qcap = 0;

  silt_tree_lock(t);
  const silt_entry *root = silt_entry_at(t, 0);
  const silt_dir *root_dir = silt_dir_at(t, root->aux);
  if (root_dir->pending != 0) {
    silt_tree_unlock(t);
    return false;
  }
  // Live entries are exactly the root's descendants plus the root.
  entries.cap = ((size_t)root_dir->items + 1) * sizeof(silt_entry);
  dirs.cap = (size_t)t->dir_count * sizeof(silt_dir);
  names.cap = (size_t)t->name_used + ((size_t)t->name_used / NAME_CHUNK + 1) * 0x10000;
  entries.p = malloc(entries.cap);
  dirs.p = malloc(dirs.cap);
  names.p = malloc(names.cap);
  if (!entries.p || !dirs.p || !names.p) abort();

  silt_entry *r = take(&entries, sizeof *r);
  *r = *root;
  r->parent = SILT_NONE;
  r->aux = 0;
  r->flags &= (uint8_t)~SILT_FLAG_REMOVED;
  r->name = put_name(&names, silt_name_ptr(t, root->name), root->name_len);
  silt_dir *rd = take(&dirs, sizeof *rd); // the bounds always fit the root
  *rd = *root_dir;
  rd->entry = 0;
  rd->state &= SILT_DIR_LISTED | SILT_DIR_INCOMPLETE;

#define PUSH(a, b)                                                             \
  do {                                                                         \
    if (qtail + 2 > qcap) {                                                    \
      qcap = qcap ? qcap * 2 : 4096;                                           \
      queue = realloc(queue, qcap * sizeof *queue);                            \
      if (!queue) abort();                                                     \
    }                                                                          \
    queue[qtail++] = (a);                                                      \
    queue[qtail++] = (b);                                                      \
  } while (0)

  bool incomplete = (root_dir->state & SILT_DIR_INCOMPLETE) != 0;
  PUSH(root->aux, 0);
  while (qhead < qtail && !incomplete) {
    uint32_t old_id = queue[qhead++], new_id = queue[qhead++];
    const silt_dir *od = silt_dir_at(t, old_id);
    uint32_t first = (uint32_t)(entries.n / sizeof(silt_entry));
    uint32_t count = 0;
    for (uint32_t i = od->first, end = od->first + od->count; i < end; i++) {
      const silt_entry *e = silt_entry_at(t, i);
      if (e->flags & SILT_FLAG_REMOVED) continue;
      silt_entry *ne = take(&entries, sizeof *ne);
      uint32_t name = ne ? put_name(&names, silt_name_ptr(t, e->name), e->name_len) : SILT_NONE;
      if (name == SILT_NONE) {
        incomplete = true; // counts disagree with the tree: don't persist it
        break;
      }
      *ne = *e;
      ne->parent = new_id;
      ne->name = name;
      if (e->kind == SILT_KIND_DIR) {
        // A listing that failed partway may be missing changes whose events
        // were already consumed: never persist it.
        if (silt_dir_at(t, e->aux)->state & SILT_DIR_INCOMPLETE) incomplete = true;
        uint32_t child_new = (uint32_t)(dirs.n / sizeof(silt_dir));
        silt_dir *nd = take(&dirs, sizeof *nd);
        if (!nd) {
          incomplete = true;
          break;
        }
        *nd = *silt_dir_at(t, e->aux);
        nd->entry = first + count;
        nd->first = 0;
        nd->count = 0;
        nd->cap = 0;
        nd->state &= SILT_DIR_LISTED | SILT_DIR_INCOMPLETE;
        ne->aux = child_new;
        PUSH(e->aux, child_new);
      }
      count++;
    }
    silt_dir *nd = (silt_dir *)(dirs.p + (size_t)new_id * sizeof(silt_dir));
    nd->first = first;
    nd->count = count;
    nd->cap = count; // compacted: no spare room
    nd->version = 0;
    nd->reserved = 0;
  }
#undef PUSH
  silt_tree_unlock(t);
  free(queue);

  bool ok = !incomplete;
  snap_header h;
  memset(&h, 0, sizeof h);
  memcpy(h.magic, SNAP_MAGIC, 8);
  h.version = SNAP_VERSION;
  h.entry_size = sizeof(silt_entry);
  h.dir_size = sizeof(silt_dir);
  h.entry_count = (uint32_t)(entries.n / sizeof(silt_entry));
  h.dir_count = (uint32_t)(dirs.n / sizeof(silt_dir));
  h.name_bytes = (uint32_t)names.n;
  h.raw_bytes = entries.n + dirs.n + names.n;
  h.checksum = checksum(checksum(checksum(CHECKSUM_SEED, entries.p, entries.n), dirs.p, dirs.n), names.p, names.n);
  h.meta = *meta;

  // Write beside the target, then rename over it. A unique temporary per
  // save, so concurrent savers never share a file.
  size_t plen = strlen(path);
  char *tmp = malloc(plen + 16);
  if (!tmp) abort();
  snprintf(tmp, plen + 16, "%s.XXXXXX", path);
  FILE *f = NULL;
  if (ok) {
    int fd = mkstemp(tmp);
    f = fd >= 0 ? fdopen(fd, "wb") : NULL;
    if (!f && fd >= 0) close(fd);
    ok = f && fwrite(&h, sizeof h, 1, f) == 1; // compressed size patched below
  }
  uint8_t *out = ok ? malloc(STREAM_BUFFER) : NULL;
  compression_stream z;
  bool stream = false;
  if (ok && out && compression_stream_init(&z, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZ4) == COMPRESSION_STATUS_OK) {
    stream = true;
    z.dst_ptr = out;
    z.dst_size = STREAM_BUFFER;
    uint64_t written = 0;
    ok = encode(&z, f, out, entries.p, entries.n, false, &written) &&
         encode(&z, f, out, dirs.p, dirs.n, false, &written) &&
         encode(&z, f, out, names.p, names.n, true, &written);
    h.compressed_bytes = written;
    ok = ok && fseek(f, 0, SEEK_SET) == 0 && fwrite(&h, sizeof h, 1, f) == 1;
  } else {
    ok = false;
  }
  if (stream) compression_stream_destroy(&z);
  free(out);
  free(entries.p);
  free(dirs.p);
  free(names.p);
  if (f) ok = (fclose(f) == 0) && ok;
  if (f && ok) ok = rename(tmp, path) == 0;
  if (f && !ok) unlink(tmp);
  free(tmp);
  return ok;
}

// Every invariant the rest of the engine relies on, checked before anyone
// walks the tree. Cheap next to decompression (one pass over each array).
static bool validate(const silt_tree *t) {
  const uint32_t ne = t->entry_count, nd = t->dir_count;
  const silt_entry *root = silt_entry_at(t, 0);
  if (root->kind != SILT_KIND_DIR || root->aux != 0 || root->parent != SILT_NONE) return false;
  for (uint32_t i = 0; i < ne; i++) {
    const silt_entry *e = silt_entry_at(t, i);
    uint64_t end = (uint64_t)e->name + e->name_len;
    if (e->name_len == 0 || end > t->name_used ||
        (e->name >> SILT_NAME_SHIFT) != ((end - 1) >> SILT_NAME_SHIFT))
      return false; // out of range, or straddling an arena chunk
    if (e->kind > SILT_KIND_OTHER) return false;
    if (e->flags & SILT_FLAG_REMOVED) return false;
    if (i > 0 && e->parent >= nd) return false;
    if (e->kind == SILT_KIND_DIR && (e->aux >= nd || silt_dir_at(t, e->aux)->entry != i)) return false;
  }
  uint64_t covered = 1; // the root has no parent run
  for (uint32_t d = 0; d < nd; d++) {
    const silt_dir *x = silt_dir_at(t, d);
    if (x->entry >= ne || silt_entry_at(t, x->entry)->kind != SILT_KIND_DIR ||
        silt_entry_at(t, x->entry)->aux != d)
      return false;
    if ((uint64_t)x->first + x->count > ne || x->cap != x->count || x->pending != 0 ||
        (x->state & ~(uint32_t)(SILT_DIR_LISTED | SILT_DIR_INCOMPLETE)))
      return false;
    for (uint32_t i = x->first, end = x->first + x->count; i < end; i++) {
      if (i == 0 || silt_entry_at(t, i)->parent != d) return false;
    }
    covered += x->count;
  }
  // Compacted: every entry belongs to exactly one run.
  if (covered != ne) return false;
  // And every folder hangs off the root exactly once: no cycles, no islands.
  uint8_t *seen = calloc(nd, 1);
  uint32_t *stack = malloc((size_t)nd * sizeof *stack);
  bool ok = seen && stack;
  uint32_t n = 0, visited = 0;
  if (ok) {
    seen[0] = 1;
    stack[n++] = 0;
    visited = 1;
  }
  while (ok && n) {
    const silt_dir *x = silt_dir_at(t, stack[--n]);
    for (uint32_t i = x->first, end = x->first + x->count; ok && i < end; i++) {
      const silt_entry *e = silt_entry_at(t, i);
      if (e->kind != SILT_KIND_DIR) continue;
      if (seen[e->aux]) {
        ok = false;
        break;
      }
      seen[e->aux] = 1;
      visited++;
      stack[n++] = e->aux;
    }
  }
  free(seen);
  free(stack);
  return ok && visited == nd;
}

// The checksum of a loaded tree's payload, chunk by chunk in file order.
static uint64_t loaded_checksum(const silt_tree *t, const snap_header *h) {
  uint64_t sum = CHECKSUM_SEED;
  const struct { void *const *chunks; size_t chunk_bytes; uint64_t total; } parts[3] = {
      {(void *const *)t->entries, ENTRY_CHUNK * sizeof(silt_entry), (uint64_t)h->entry_count * sizeof(silt_entry)},
      {(void *const *)t->dirs, DIR_CHUNK * sizeof(silt_dir), (uint64_t)h->dir_count * sizeof(silt_dir)},
      {(void *const *)t->names, NAME_CHUNK, h->name_bytes},
  };
  for (int k = 0; k < 3; k++) {
    for (uint64_t done = 0, c = 0; done < parts[k].total; c++) {
      uint64_t len = parts[k].total - done < parts[k].chunk_bytes ? parts[k].total - done : parts[k].chunk_bytes;
      sum = checksum(sum, parts[k].chunks[c], (size_t)len);
      done += len;
    }
  }
  return sum;
}

#define MAX_ENTRIES (SILT_ENTRY_CHUNKS / 2 * (uint64_t)ENTRY_CHUNK)
#define MAX_DIRS (SILT_DIR_CHUNKS / 2 * (uint64_t)DIR_CHUNK)
#define MAX_NAMES (SILT_NAME_CHUNKS / 2 * (uint64_t)NAME_CHUNK)

// Where the decompressed payload goes next: a run of chunks per section.
typedef struct sink {
  void **chunks;
  size_t chunk_bytes; // capacity of one chunk
  uint64_t total;     // bytes this section holds
  uint64_t done;
} sink;

// Points the stream at the next free stretch of the current section,
// allocating its chunk if needed. Returns false when out of memory.
static bool aim(compression_stream *z, sink *s) {
  size_t c = (size_t)(s->done / s->chunk_bytes);
  size_t off = (size_t)(s->done % s->chunk_bytes);
  if (!s->chunks[c]) {
    s->chunks[c] = malloc(s->chunk_bytes);
    if (!s->chunks[c]) return false;
  }
  uint64_t left = s->total - s->done;
  size_t room = s->chunk_bytes - off;
  z->dst_ptr = (uint8_t *)s->chunks[c] + off;
  z->dst_size = left < room ? (size_t)left : room;
  return true;
}

silt_tree *silt_tree_load(const char *path, silt_snapshot_meta *meta) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  struct stat st;
  snap_header h;
  if (fstat(fileno(f), &st) != 0 || fread(&h, sizeof h, 1, f) != 1 ||
      memcmp(h.magic, SNAP_MAGIC, 8) != 0 || h.version != SNAP_VERSION ||
      h.entry_size != sizeof(silt_entry) || h.dir_size != sizeof(silt_dir) ||
      h.entry_count == 0 || h.dir_count == 0 || h.entry_count > MAX_ENTRIES ||
      h.dir_count > MAX_DIRS || h.name_bytes > MAX_NAMES ||
      h.compressed_bytes != (uint64_t)st.st_size - sizeof h ||
      h.raw_bytes != (uint64_t)h.entry_count * sizeof(silt_entry) +
                         (uint64_t)h.dir_count * sizeof(silt_dir) + h.name_bytes) {
    fclose(f);
    return NULL;
  }

  silt_tree *t = calloc(1, sizeof *t);
  silt_internal *in = calloc(1, sizeof *in);
  if (t) {
    t->entries = calloc(SILT_ENTRY_CHUNKS, sizeof *t->entries);
    t->dirs = calloc(SILT_DIR_CHUNKS, sizeof *t->dirs);
    t->names = calloc(SILT_NAME_CHUNKS, sizeof *t->names);
  }
  if (!t || !in || !t->entries || !t->dirs || !t->names) {
    if (t) {
      free(t->entries);
      free(t->dirs);
      free(t->names);
    }
    free(t);
    free(in);
    fclose(f);
    return NULL;
  }
  in->lock = OS_UNFAIR_LOCK_INIT;
  t->internal = in;

  sink sinks[3] = {
      {(void **)t->entries, ENTRY_CHUNK * sizeof(silt_entry), (uint64_t)h.entry_count * sizeof(silt_entry), 0},
      {(void **)t->dirs, DIR_CHUNK * sizeof(silt_dir), (uint64_t)h.dir_count * sizeof(silt_dir), 0},
      {(void **)t->names, NAME_CHUNK, h.name_bytes, 0},
  };
  uint8_t *input = malloc(STREAM_BUFFER);
  compression_stream z;
  bool ok = input && compression_stream_init(&z, COMPRESSION_STREAM_DECODE, COMPRESSION_LZ4) == COMPRESSION_STATUS_OK;
  const bool stream = ok;
  uint64_t unread = h.compressed_bytes;
  int section = 0;
  while (section < 3 && sinks[section].total == 0) section++;
  if (ok) {
    z.src_ptr = input;
    z.src_size = 0;
    ok = section < 3 && aim(&z, &sinks[section]);
  }
  uint8_t beyond[16]; // anything decoded past the payload lands here: an error
  for (bool ended = false; ok && !ended;) {
    if (z.src_size == 0 && unread > 0) {
      size_t want = unread < STREAM_BUFFER ? (size_t)unread : STREAM_BUFFER;
      if (fread(input, 1, want, f) != want) {
        ok = false;
        break;
      }
      unread -= want;
      z.src_ptr = input;
      z.src_size = want;
    }
    if (section == 3) {
      z.dst_ptr = beyond;
      z.dst_size = sizeof beyond;
    }
    const size_t aimed = z.dst_size, fed = z.src_size;
    compression_status st = compression_stream_process(&z, unread == 0 ? COMPRESSION_STREAM_FINALIZE : 0);
    if (st == COMPRESSION_STATUS_ERROR) {
      ok = false;
      break;
    }
    const size_t produced = aimed - z.dst_size;
    if (section == 3) {
      ok = produced == 0;
    } else {
      sinks[section].done += produced;
      if (z.dst_size == 0) {
        while (section < 3 && sinks[section].done == sinks[section].total) section++;
        if (section < 3) ok = aim(&z, &sinks[section]);
      }
    }
    if (st == COMPRESSION_STATUS_END) {
      ended = true;
      ok = ok && section == 3;
    } else if (produced == 0 && z.src_size == fed && unread == 0) {
      ok = false; // no progress left to make: the payload is short
    }
  }
  if (stream) compression_stream_destroy(&z);
  free(input);
  fclose(f);

  t->entry_count = h.entry_count;
  t->dir_count = h.dir_count;
  t->name_used = h.name_bytes;
  TREE_BUMP(t);
  if (!ok || loaded_checksum(t, &h) != h.checksum || !validate(t)) {
    silt_tree_destroy(t);
    return NULL;
  }
  tree_reset_accounting(t);
  if (meta) *meta = h.meta;
  return t;
}
