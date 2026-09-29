// Parking: a tree nobody is looking at gives its memory back. Its storage
// goes to a file exactly as it is, so every entry index and dir id means the
// same thing after unparking; meanwhile the tree is an empty shell whose
// chunks all point at shared read-only ones, so a stray read sees a removed
// entry or an empty folder instead of faulting.

#include "internal.h"

#include <compression.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PARK_MAGIC "SILTPRK1"
#define ENTRY_CHUNK (1u << SILT_ENTRY_SHIFT)
#define DIR_CHUNK (1u << SILT_DIR_SHIFT)
#define NAME_CHUNK (1u << SILT_NAME_SHIFT)
#define PARK_BUFFER (1u << 20)
#define CHECKSUM_SEED 0x9A4C0DEull

typedef struct park_header {
  char magic[8];
  uint32_t entry_size, dir_size;
  uint32_t entry_count, dir_count, name_used;
  uint32_t entry_chunks, dir_chunks, name_chunks;
  uint64_t checksum;         // of the freed-chunk map and the payload
  uint64_t compressed_bytes; // payload size on disk
} park_header;

typedef struct segment {
  void *p;
  size_t len;
} segment;

static uint32_t chunks_for(uint64_t n, uint64_t per) { return (uint32_t)((n + per - 1) / per); }

// The storage in file order (entry chunks that aren't freed, then folders,
// then names), over the given chunk tables. Returns the segment count.
static size_t layout(const silt_tree *t, const uint8_t *freed, void **entries, void **dirs, void **names,
                     uint32_t ec, uint32_t dc, uint32_t nc, segment *out) {
  size_t n = 0;
  for (uint32_t c = 0; c < ec; c++) {
    if (freed[c]) continue;
    uint64_t left = (uint64_t)t->entry_count - (uint64_t)c * ENTRY_CHUNK;
    out[n++] = (segment){entries[c], (size_t)(left < ENTRY_CHUNK ? left : ENTRY_CHUNK) * sizeof(silt_entry)};
  }
  for (uint32_t c = 0; c < dc; c++) {
    uint64_t left = (uint64_t)t->dir_count - (uint64_t)c * DIR_CHUNK;
    out[n++] = (segment){dirs[c], (size_t)(left < DIR_CHUNK ? left : DIR_CHUNK) * sizeof(silt_dir)};
  }
  for (uint32_t c = 0; c < nc; c++) {
    uint64_t left = (uint64_t)t->name_used - (uint64_t)c * NAME_CHUNK;
    out[n++] = (segment){names[c], (size_t)(left < NAME_CHUNK ? left : NAME_CHUNK)};
  }
  return n;
}

bool silt_tree_is_parked(silt_tree *t) {
  silt_tree_lock(t);
  bool parked = silt_int(t)->parked;
  silt_tree_unlock(t);
  return parked;
}

bool silt_tree_park(silt_tree *t, const char *path) {
  silt_tree_lock(t);
  silt_internal *in = silt_int(t);
  if (in->parked) {
    silt_tree_unlock(t);
    return true;
  }
  silt_entry *dead = tree_dead_chunk();
  const uint32_t ec = chunks_for(t->entry_count, ENTRY_CHUNK);
  const uint32_t dc = chunks_for(t->dir_count, DIR_CHUNK);
  const uint32_t nc = chunks_for(t->name_used, NAME_CHUNK);
  uint8_t *freed = malloc(ec ? ec : 1);
  segment *segs = malloc(((size_t)ec + dc + nc + 1) * sizeof *segs);
  uint8_t *out = malloc(PARK_BUFFER);
  size_t plen = strlen(path);
  char *tmp = malloc(plen + 16);
  if (!freed || !segs || !out || !tmp) abort();
  for (uint32_t c = 0; c < ec; c++) freed[c] = t->entries[c] == dead;
  size_t nseg = layout(t, freed, (void **)t->entries, (void **)t->dirs, (void **)t->names, ec, dc, nc, segs);

  park_header h;
  memset(&h, 0, sizeof h);
  memcpy(h.magic, PARK_MAGIC, 8);
  h.entry_size = sizeof(silt_entry);
  h.dir_size = sizeof(silt_dir);
  h.entry_count = t->entry_count;
  h.dir_count = t->dir_count;
  h.name_used = t->name_used;
  h.entry_chunks = ec;
  h.dir_chunks = dc;
  h.name_chunks = nc;
  h.checksum = tree_checksum(CHECKSUM_SEED, freed, ec);
  for (size_t k = 0; k < nseg; k++) h.checksum = tree_checksum(h.checksum, segs[k].p, segs[k].len);

  snprintf(tmp, plen + 16, "%s.XXXXXX", path);
  int fd = mkstemp(tmp);
  FILE *f = fd >= 0 ? fdopen(fd, "wb") : NULL;
  if (!f && fd >= 0) close(fd);
  bool ok = f && fwrite(&h, sizeof h, 1, f) == 1 && fwrite(freed, 1, ec, f) == ec;

  compression_stream z;
  bool stream = ok && compression_stream_init(&z, COMPRESSION_STREAM_ENCODE, COMPRESSION_LZ4) == COMPRESSION_STATUS_OK;
  ok = stream;
  if (ok) {
    z.dst_ptr = out;
    z.dst_size = PARK_BUFFER;
    z.src_size = 0;
    size_t k = 0;
    for (bool done = false; ok && !done;) {
      if (z.src_size == 0 && k < nseg) {
        z.src_ptr = segs[k].p;
        z.src_size = segs[k].len;
        k++;
      }
      const bool last = k == nseg; // the final segment is loaded
      compression_status st = compression_stream_process(&z, last ? COMPRESSION_STREAM_FINALIZE : 0);
      if (st == COMPRESSION_STATUS_ERROR) {
        ok = false;
        break;
      }
      done = st == COMPRESSION_STATUS_END;
      size_t produced = PARK_BUFFER - z.dst_size;
      if (produced && (z.dst_size == 0 || done)) {
        ok = fwrite(out, 1, produced, f) == produced;
        h.compressed_bytes += produced;
        z.dst_ptr = out;
        z.dst_size = PARK_BUFFER;
      }
    }
    compression_stream_destroy(&z);
  }
  if (ok) ok = fseek(f, 0, SEEK_SET) == 0 && fwrite(&h, sizeof h, 1, f) == 1;
  if (f) ok = (fclose(f) == 0) && ok;
  if (f && ok) ok = rename(tmp, path) == 0;
  if (f && !ok) unlink(tmp);

  if (ok) {
    // Hand the memory back; the shared chunks answer reads meanwhile.
    for (uint32_t c = 0; c < SILT_ENTRY_CHUNKS && t->entries[c]; c++) {
      if (t->entries[c] != dead) tree_chunk_free(t->entries[c], ENTRY_CHUNK * sizeof(silt_entry));
      t->entries[c] = c < ec ? dead : NULL;
    }
    silt_dir *zd = tree_zero_dir_chunk();
    for (uint32_t c = 0; c < SILT_DIR_CHUNKS && t->dirs[c]; c++) {
      tree_chunk_free(t->dirs[c], DIR_CHUNK * sizeof(silt_dir));
      t->dirs[c] = c < dc ? zd : NULL;
    }
    uint8_t *zn = tree_zero_name_chunk();
    for (uint32_t c = 0; c < SILT_NAME_CHUNKS && t->names[c]; c++) {
      tree_chunk_free(t->names[c], NAME_CHUNK);
      t->names[c] = c < nc ? zn : NULL;
    }
    // Stamps aren't worth keeping: unparking hands out fresh ones.
    tree_stamp_release(t);
    in->parked = true;
  }
  silt_tree_unlock(t);
  free(freed);
  free(segs);
  free(out);
  free(tmp);
  return ok;
}

bool silt_tree_unpark(silt_tree *t, const char *path) {
  silt_tree_lock(t);
  silt_internal *in = silt_int(t);
  if (!in->parked) {
    silt_tree_unlock(t);
    return true;
  }
  silt_entry *dead = tree_dead_chunk();
  const uint32_t ec = chunks_for(t->entry_count, ENTRY_CHUNK);
  const uint32_t dc = chunks_for(t->dir_count, DIR_CHUNK);
  const uint32_t nc = chunks_for(t->name_used, NAME_CHUNK);
  FILE *f = fopen(path, "rb");
  park_header h;
  bool ok = f && fread(&h, sizeof h, 1, f) == 1 && memcmp(h.magic, PARK_MAGIC, 8) == 0 &&
            h.entry_size == sizeof(silt_entry) && h.dir_size == sizeof(silt_dir) &&
            h.entry_count == t->entry_count && h.dir_count == t->dir_count && h.name_used == t->name_used &&
            h.entry_chunks == ec && h.dir_chunks == dc && h.name_chunks == nc;

  uint8_t *freed = malloc(ec ? ec : 1);
  void **entries = calloc(ec ? ec : 1, sizeof *entries);
  void **dirs = calloc(dc ? dc : 1, sizeof *dirs);
  void **names = calloc(nc ? nc : 1, sizeof *names);
  segment *segs = malloc(((size_t)ec + dc + nc + 1) * sizeof *segs);
  uint8_t *input = malloc(PARK_BUFFER);
  if (!freed || !entries || !dirs || !names || !segs || !input) abort();
  ok = ok && fread(freed, 1, ec, f) == ec;
  for (uint32_t c = 0; ok && c < ec; c++) {
    entries[c] = freed[c] ? (void *)dead : tree_chunk_alloc(ENTRY_CHUNK * sizeof(silt_entry));
    ok = entries[c] != NULL;
  }
  for (uint32_t c = 0; ok && c < dc; c++) ok = (dirs[c] = tree_chunk_alloc(DIR_CHUNK * sizeof(silt_dir))) != NULL;
  for (uint32_t c = 0; ok && c < nc; c++) ok = (names[c] = tree_chunk_alloc(NAME_CHUNK)) != NULL;
  size_t nseg = ok ? layout(t, freed, entries, dirs, names, ec, dc, nc, segs) : 0;

  compression_stream z;
  const bool stream = ok && compression_stream_init(&z, COMPRESSION_STREAM_DECODE, COMPRESSION_LZ4) == COMPRESSION_STATUS_OK;
  ok = stream;
  uint64_t unread = h.compressed_bytes;
  size_t k = 0;
  uint8_t beyond[16]; // anything decoded past the payload lands here: an error
  if (ok) {
    z.src_ptr = input;
    z.src_size = 0;
    z.dst_ptr = nseg ? segs[0].p : beyond;
    z.dst_size = nseg ? segs[0].len : sizeof beyond;
  }
  for (bool ended = false; ok && !ended;) {
    if (z.src_size == 0 && unread > 0) {
      size_t want = unread < PARK_BUFFER ? (size_t)unread : PARK_BUFFER;
      if (fread(input, 1, want, f) != want) {
        ok = false;
        break;
      }
      unread -= want;
      z.src_ptr = input;
      z.src_size = want;
    }
    const size_t aimed = z.dst_size, fed = z.src_size;
    compression_status st = compression_stream_process(&z, unread == 0 ? COMPRESSION_STREAM_FINALIZE : 0);
    if (st == COMPRESSION_STATUS_ERROR) {
      ok = false;
      break;
    }
    const size_t produced = aimed - z.dst_size;
    if (k == nseg && produced) ok = false; // more than the payload
    while (ok && k < nseg && z.dst_size == 0) {
      if (++k < nseg) {
        z.dst_ptr = segs[k].p;
        z.dst_size = segs[k].len;
      } else {
        z.dst_ptr = beyond;
        z.dst_size = sizeof beyond;
      }
    }
    if (st == COMPRESSION_STATUS_END) {
      ended = true;
      ok = ok && k == nseg;
    } else if (produced == 0 && z.src_size == fed && unread == 0) {
      ok = false; // no progress left to make: the payload is short
    }
  }
  if (stream) compression_stream_destroy(&z);
  if (f) fclose(f);
  if (ok) {
    uint64_t sum = tree_checksum(CHECKSUM_SEED, freed, ec);
    for (size_t s = 0; s < nseg; s++) sum = tree_checksum(sum, segs[s].p, segs[s].len);
    ok = sum == h.checksum;
  }
  if (ok) {
    for (uint32_t c = 0; c < ec; c++) t->entries[c] = entries[c];
    for (uint32_t c = 0; c < dc; c++) t->dirs[c] = dirs[c];
    for (uint32_t c = 0; c < nc; c++) t->names[c] = names[c];
    in->parked = false;
    // Every folder gets a stamp nobody saw before parking, so views that
    // remember stamps redo their work once.
    tree_stamp_all(t);
    TREE_BUMP(t);
  } else {
    for (uint32_t c = 0; c < ec; c++)
      if (entries[c] != dead) tree_chunk_free(entries[c], ENTRY_CHUNK * sizeof(silt_entry));
    for (uint32_t c = 0; c < dc; c++) tree_chunk_free(dirs[c], DIR_CHUNK * sizeof(silt_dir));
    for (uint32_t c = 0; c < nc; c++) tree_chunk_free(names[c], NAME_CHUNK);
  }
  silt_tree_unlock(t);
  free(freed);
  free(entries);
  free(dirs);
  free(names);
  free(segs);
  free(input);
  return ok;
}
