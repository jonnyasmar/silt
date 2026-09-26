// Snapshots: a compacted, LZ4-compressed copy of a finished tree, so the next
// launch can show it instantly and only catch up on what changed since.
//
// Saving walks the live tree breadth-first and writes each folder's children
// as one contiguous run, so the loaded tree has no garbage from refreshes.
// Names are laid out exactly as the chunked arena expects, so every offset in
// the file is usable as-is after loading.

#include "internal.h"

#include <compression.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SNAP_MAGIC "SILTSNP2"
#define SNAP_VERSION 2u // 2: clone-aware sizes
#define NAME_CHUNK (1u << SILT_NAME_SHIFT)
#define ENTRY_CHUNK (1u << SILT_ENTRY_SHIFT)
#define DIR_CHUNK (1u << SILT_DIR_SHIFT)

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
  silt_snapshot_meta meta;
} snap_header;

typedef struct growbuf {
  uint8_t *p;
  size_t n, cap;
} growbuf;

static void *grow(growbuf *b, size_t extra) {
  if (b->n + extra > b->cap) {
    size_t cap = b->cap ? b->cap : 1 << 20;
    while (b->n + extra > cap) cap *= 2;
    b->p = realloc(b->p, cap);
    if (!b->p) abort();
    b->cap = cap;
  }
  void *at = b->p + b->n;
  b->n += extra;
  return at;
}

// Appends a name where the chunked arena would put it. Returns its offset.
static uint32_t put_name(growbuf *names, const uint8_t *s, uint16_t len) {
  size_t off = names->n;
  if ((off & SILT_NAME_MASK) + len > NAME_CHUNK) {
    size_t pad = NAME_CHUNK - (off & SILT_NAME_MASK);
    memset(grow(names, pad), 0, pad);
    off = names->n;
  }
  memcpy(grow(names, len), s, len);
  return (uint32_t)off;
}

bool silt_tree_save(silt_tree *t, const char *path, const silt_snapshot_meta *meta) {
  growbuf entries = {0}, dirs = {0}, names = {0};
  uint32_t *queue = NULL; // pairs: old dir id, new dir id
  size_t qhead = 0, qtail = 0, qcap = 0;

  silt_tree_lock(t);
  const silt_entry *root = silt_entry_at(t, 0);
  if (silt_dir_at(t, root->aux)->pending != 0) {
    silt_tree_unlock(t);
    return false;
  }

  silt_entry *r = grow(&entries, sizeof *r);
  *r = *root;
  r->parent = SILT_NONE;
  r->aux = 0;
  r->flags &= (uint8_t)~SILT_FLAG_REMOVED;
  r->name = put_name(&names, silt_name_ptr(t, root->name), root->name_len);
  silt_dir *rd = grow(&dirs, sizeof *rd);
  *rd = *silt_dir_at(t, root->aux);
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

  bool incomplete = (silt_dir_at(t, root->aux)->state & SILT_DIR_INCOMPLETE) != 0;
  PUSH(root->aux, 0);
  while (qhead < qtail && !incomplete) {
    uint32_t old_id = queue[qhead++], new_id = queue[qhead++];
    const silt_dir *od = silt_dir_at(t, old_id);
    uint32_t first = (uint32_t)(entries.n / sizeof(silt_entry));
    uint32_t count = 0;
    for (uint32_t i = od->first, end = od->first + od->count; i < end; i++) {
      const silt_entry *e = silt_entry_at(t, i);
      if (e->flags & SILT_FLAG_REMOVED) continue;
      silt_entry *ne = grow(&entries, sizeof *ne);
      *ne = *e;
      ne->parent = new_id;
      ne->name = put_name(&names, silt_name_ptr(t, e->name), e->name_len);
      if (e->kind == SILT_KIND_DIR) {
        // A listing that failed partway may be missing changes whose events
        // were already consumed: never persist it.
        if (silt_dir_at(t, e->aux)->state & SILT_DIR_INCOMPLETE) incomplete = true;
        uint32_t child_new = (uint32_t)(dirs.n / sizeof(silt_dir));
        silt_dir *nd = grow(&dirs, sizeof *nd);
        *nd = *silt_dir_at(t, e->aux);
        nd->entry = first + count;
        nd->first = 0;
        nd->count = 0;
        nd->state &= SILT_DIR_LISTED | SILT_DIR_INCOMPLETE;
        ne->aux = child_new;
        PUSH(e->aux, child_new);
      }
      count++;
    }
    silt_dir *nd = (silt_dir *)(dirs.p + (size_t)new_id * sizeof(silt_dir));
    nd->first = first;
    nd->count = count;
  }
#undef PUSH
  silt_tree_unlock(t);
  free(queue);
  if (incomplete) {
    free(entries.p);
    free(dirs.p);
    free(names.p);
    return false;
  }

  // One payload: entries, then dirs, then names.
  size_t raw = entries.n + dirs.n + names.n;
  uint8_t *payload = malloc(raw ? raw : 1);
  if (!payload) abort();
  memcpy(payload, entries.p, entries.n);
  memcpy(payload + entries.n, dirs.p, dirs.n);
  memcpy(payload + entries.n + dirs.n, names.p, names.n);

  snap_header h;
  memset(&h, 0, sizeof h);
  memcpy(h.magic, SNAP_MAGIC, 8);
  h.version = SNAP_VERSION;
  h.entry_size = sizeof(silt_entry);
  h.dir_size = sizeof(silt_dir);
  h.entry_count = (uint32_t)(entries.n / sizeof(silt_entry));
  h.dir_count = (uint32_t)(dirs.n / sizeof(silt_dir));
  h.name_bytes = (uint32_t)names.n;
  h.raw_bytes = raw;
  h.meta = *meta;
  free(entries.p);
  free(dirs.p);
  free(names.p);

  size_t cap = raw + raw / 16 + 4096;
  uint8_t *packed = malloc(cap);
  if (!packed) abort();
  size_t packed_n = compression_encode_buffer(packed, cap, payload, raw, NULL, COMPRESSION_LZ4);
  free(payload);
  if (packed_n == 0 && raw > 0) {
    free(packed);
    return false;
  }
  h.compressed_bytes = packed_n;

  // Write beside the target, then rename over it.
  // A unique temporary per save, so concurrent savers never share a file.
  size_t plen = strlen(path);
  char *tmp = malloc(plen + 16);
  if (!tmp) abort();
  snprintf(tmp, plen + 16, "%s.XXXXXX", path);
  int fd = mkstemp(tmp);
  FILE *f = fd >= 0 ? fdopen(fd, "wb") : NULL;
  if (!f && fd >= 0) close(fd);
  bool ok = f && fwrite(&h, sizeof h, 1, f) == 1 && fwrite(packed, 1, packed_n, f) == packed_n;
  if (f) ok = (fclose(f) == 0) && ok;
  free(packed);
  if (ok) ok = rename(tmp, path) == 0;
  if (!ok) unlink(tmp);
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
    if (i > 0 && e->parent >= nd) return false;
    if (e->kind == SILT_KIND_DIR && (e->aux >= nd || silt_dir_at(t, e->aux)->entry != i)) return false;
  }
  uint64_t covered = 1; // the root has no parent run
  for (uint32_t d = 0; d < nd; d++) {
    const silt_dir *x = silt_dir_at(t, d);
    if (x->entry >= ne || silt_entry_at(t, x->entry)->kind != SILT_KIND_DIR ||
        silt_entry_at(t, x->entry)->aux != d)
      return false;
    if ((uint64_t)x->first + x->count > ne || x->pending != 0) return false;
    for (uint32_t i = x->first, end = x->first + x->count; i < end; i++) {
      if (i == 0 || silt_entry_at(t, i)->parent != d) return false;
    }
    covered += x->count;
  }
  // Compacted: every entry belongs to exactly one run (so no cycles either).
  return covered == ne;
}

#define MAX_ENTRIES (SILT_ENTRY_CHUNKS / 2 * (uint64_t)ENTRY_CHUNK)
#define MAX_DIRS (SILT_DIR_CHUNKS / 2 * (uint64_t)DIR_CHUNK)
#define MAX_NAMES (SILT_NAME_CHUNKS / 2 * (uint64_t)NAME_CHUNK)

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
  uint8_t *packed = malloc(h.compressed_bytes ? h.compressed_bytes : 1);
  uint8_t *raw = malloc(h.raw_bytes);
  bool ok = packed && raw && fread(packed, 1, h.compressed_bytes, f) == h.compressed_bytes;
  fclose(f);
  if (ok) {
    size_t n = compression_decode_buffer(raw, h.raw_bytes, packed, h.compressed_bytes, NULL, COMPRESSION_LZ4);
    ok = n == h.raw_bytes;
  }
  free(packed);
  if (!ok) {
    free(raw);
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
    free(raw);
    return NULL;
  }
  in->lock = OS_UNFAIR_LOCK_INIT;
  t->internal = in;

  bool alloc_ok = true;
  const uint8_t *p = raw;
  for (uint64_t i = 0, c = 0; alloc_ok && i < h.entry_count; i += ENTRY_CHUNK, c++) {
    uint64_t n = h.entry_count - i < ENTRY_CHUNK ? h.entry_count - i : ENTRY_CHUNK;
    t->entries[c] = malloc(ENTRY_CHUNK * sizeof(silt_entry));
    if (!(alloc_ok = t->entries[c] != NULL)) break;
    memcpy(t->entries[c], p, n * sizeof(silt_entry));
    p += n * sizeof(silt_entry);
  }
  for (uint64_t i = 0, c = 0; alloc_ok && i < h.dir_count; i += DIR_CHUNK, c++) {
    uint64_t n = h.dir_count - i < DIR_CHUNK ? h.dir_count - i : DIR_CHUNK;
    t->dirs[c] = malloc(DIR_CHUNK * sizeof(silt_dir));
    if (!(alloc_ok = t->dirs[c] != NULL)) break;
    memcpy(t->dirs[c], p, n * sizeof(silt_dir));
    p += n * sizeof(silt_dir);
  }
  for (uint64_t off = 0, c = 0; alloc_ok && off < h.name_bytes; off += NAME_CHUNK, c++) {
    uint64_t n = h.name_bytes - off < NAME_CHUNK ? h.name_bytes - off : NAME_CHUNK;
    t->names[c] = malloc(NAME_CHUNK);
    if (!(alloc_ok = t->names[c] != NULL)) break;
    memcpy(t->names[c], p, n);
    p += n;
  }
  free(raw);

  t->entry_count = h.entry_count;
  t->dir_count = h.dir_count;
  t->name_used = h.name_bytes;
  TREE_BUMP(t);
  if (!alloc_ok || !validate(t)) {
    silt_tree_destroy(t);
    return NULL;
  }
  if (meta) *meta = h.meta;
  return t;
}
