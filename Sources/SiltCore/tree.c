#include "internal.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <mach/vm_statistics.h>
#include <sys/mman.h>

#define ENTRY_CHUNK (1u << SILT_ENTRY_SHIFT)
#define DIR_CHUNK (1u << SILT_DIR_SHIFT)
#define NAME_CHUNK (1u << SILT_NAME_SHIFT)

static void *xcalloc(size_t n, size_t size) {
  void *p = calloc(n, size);
  if (!p) abort();
  return p;
}

#define FOLD1(c) (uint8_t)((c) >= 'A' && (c) <= 'Z' ? (c) + 32 : (c))
#define FOLD4(c) FOLD1(c), FOLD1((c) + 1), FOLD1((c) + 2), FOLD1((c) + 3)
#define FOLD16(c) FOLD4(c), FOLD4((c) + 4), FOLD4((c) + 8), FOLD4((c) + 12)
#define FOLD64(c) FOLD16(c), FOLD16((c) + 16), FOLD16((c) + 32), FOLD16((c) + 48)
const uint8_t silt_ascii_fold[256] = {FOLD64(0), FOLD64(64), FOLD64(128), FOLD64(192)};

// MARK: Freed chunks

// Every freed entry chunk points here: one read-only chunk of REMOVED
// entries, so a stale index anywhere reads as "gone" instead of faulting.
static silt_entry *dead_chunk;
static pthread_once_t dead_once = PTHREAD_ONCE_INIT;

static void make_dead_chunk(void) {
  size_t bytes = (size_t)ENTRY_CHUNK * sizeof(silt_entry);
  void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (p == MAP_FAILED) abort();
  silt_entry *e = p;
  for (uint32_t i = 0; i < ENTRY_CHUNK; i++) {
    e[i] = (silt_entry){
        .size = 0,
        .parent = SILT_NONE,
        .name = 0,
        .aux = 0,
        .name_len = 0,
        .kind = SILT_KIND_FILE,
        .flags = SILT_FLAG_REMOVED,
    };
  }
  if (mprotect(p, bytes, PROT_READ) != 0) abort();
  dead_chunk = e;
}

// Chunks come straight from the kernel, so freeing one really returns it:
// malloc keeps freed blocks this size around, still counted against the app.
#define CHUNK_TAG VM_MAKE_TAG(240) // shows as "Memory Tag 240" in vmmap

void *tree_chunk_alloc(size_t bytes) {
  void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, CHUNK_TAG, 0);
  if (p == MAP_FAILED) abort();
  return p;
}

void tree_chunk_free(void *p, size_t bytes) {
  if (p) munmap(p, bytes);
}

silt_entry *tree_dead_chunk(void) {
  pthread_once(&dead_once, make_dead_chunk);
  return dead_chunk;
}

// Zero pages cost nothing until touched, and these are never written.
static silt_dir *zero_dirs;
static uint8_t *zero_names;
static pthread_once_t zero_once = PTHREAD_ONCE_INIT;

static void make_zero_chunks(void) {
  void *d = mmap(NULL, (size_t)DIR_CHUNK * sizeof(silt_dir), PROT_READ, MAP_PRIVATE | MAP_ANON, -1, 0);
  void *n = mmap(NULL, NAME_CHUNK, PROT_READ, MAP_PRIVATE | MAP_ANON, -1, 0);
  if (d == MAP_FAILED || n == MAP_FAILED) abort();
  zero_dirs = d;
  zero_names = n;
}

silt_dir *tree_zero_dir_chunk(void) {
  pthread_once(&zero_once, make_zero_chunks);
  return zero_dirs;
}

uint8_t *tree_zero_name_chunk(void) {
  pthread_once(&zero_once, make_zero_chunks);
  return zero_names;
}

uint64_t tree_checksum(uint64_t h, const void *p, size_t len) {
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

silt_tree *silt_tree_create(const char *root_path) {
  silt_tree *t = xcalloc(1, sizeof *t);
  t->entries = xcalloc(SILT_ENTRY_CHUNKS, sizeof *t->entries);
  t->dirs = xcalloc(SILT_DIR_CHUNKS, sizeof *t->dirs);
  t->names = xcalloc(SILT_NAME_CHUNKS, sizeof *t->names);
  silt_internal *in = xcalloc(1, sizeof *in);
  in->lock = OS_UNFAIR_LOCK_INIT;
  in->chunk_live = xcalloc(SILT_ENTRY_CHUNKS, sizeof *in->chunk_live);
  in->stamps = xcalloc(SILT_DIR_CHUNKS, sizeof *in->stamps);
  t->internal = in;

  size_t len = strlen(root_path);
  // Keep "/" as is, but drop a trailing slash from anything longer.
  while (len > 1 && root_path[len - 1] == '/') len--;
  if (len > 0xFFFF) len = 0xFFFF;

  tree_reserve_entries(t, 1);
  uint32_t name = tree_put_name(t, (const uint8_t *)root_path, (uint32_t)len);
  uint32_t dir = tree_new_dir(t, 0, 0, 1, SILT_DIR_QUEUED);
  *silt_entry_at(t, 0) = (silt_entry){
      .size = 0,
      .parent = SILT_NONE,
      .name = name,
      .aux = dir,
      .name_len = (uint16_t)len,
      .kind = SILT_KIND_DIR,
      .flags = 0,
  };
  t->entry_count = 1;
  tree_claim_run(t, 0, 1); // the root's own entry belongs to no run
  in->stamp_now = 0;
  return t;
}

void silt_tree_guard(silt_tree *t, const char *parent_path) {
  silt_internal *in = silt_int(t);
  if (in->guard_count < SILT_MAX_GUARDS)
    in->guards[in->guard_count++] = strdup(parent_path);
}

bool tree_is_guarded(const silt_tree *t, const char *path) {
  const silt_internal *in = silt_int(t);
  for (uint32_t i = 0; i < in->guard_count; i++)
    if (strcmp(in->guards[i], path) == 0) return true;
  return false;
}

void silt_tree_destroy(silt_tree *t) {
  if (!t) return;
  for (uint32_t i = 0; i < silt_int(t)->guard_count; i++)
    free(silt_int(t)->guards[i]);
  silt_entry *dead = tree_dead_chunk();
  silt_dir *zd = tree_zero_dir_chunk();
  uint8_t *zn = tree_zero_name_chunk();
  for (uint32_t i = 0; i < SILT_ENTRY_CHUNKS && t->entries[i]; i++)
    if (t->entries[i] != dead) tree_chunk_free(t->entries[i], ENTRY_CHUNK * sizeof(silt_entry));
  for (uint32_t i = 0; i < SILT_DIR_CHUNKS && t->dirs[i]; i++)
    if (t->dirs[i] != zd) tree_chunk_free(t->dirs[i], DIR_CHUNK * sizeof(silt_dir));
  for (uint32_t i = 0; i < SILT_NAME_CHUNKS && t->names[i]; i++)
    if (t->names[i] != zn) tree_chunk_free(t->names[i], NAME_CHUNK);
  if (silt_int(t)->stamps) tree_stamp_release(t);
  free(t->entries);
  free(t->dirs);
  free(t->names);
  free(silt_int(t)->chunk_live);
  free(silt_int(t)->stamps);
  free(t->internal);
  free(t);
}

void silt_tree_lock(silt_tree *t) { os_unfair_lock_lock(&silt_int(t)->lock); }
void silt_tree_unlock(silt_tree *t) {
  // Whatever changed in this hold is one batch: the next change gets a new
  // stamp, so anyone who read a stamp meanwhile sees it move.
  silt_int(t)->stamp_now = 0;
  os_unfair_lock_unlock(&silt_int(t)->lock);
}

uint64_t silt_tree_generation(const silt_tree *t) {
  return __atomic_load_n(&t->generation, __ATOMIC_ACQUIRE);
}

void tree_publish(silt_tree *t) {
  silt_internal *in = silt_int(t);
  __atomic_store_n(&in->root_size, silt_entry_at(t, 0)->size, __ATOMIC_RELAXED);
  __atomic_store_n(&in->root_items, silt_dir_at(t, 0)->items, __ATOMIC_RELAXED);
  __atomic_add_fetch(&t->generation, 1, __ATOMIC_RELEASE);
}

// MARK: Stamps

#define STAMP_CHUNK_BYTES ((size_t)DIR_CHUNK * sizeof(uint32_t))

// One counter for the whole process: a value handed out once is never handed
// out again (until it wraps, after 2^32 change batches), whichever tree asks.
static uint32_t stamp_counter;

static uint32_t stamp_fresh(void) {
  uint32_t v;
  do v = __atomic_add_fetch(&stamp_counter, 1, __ATOMIC_RELAXED);
  while (v == 0); // 0 means "no stamp"
  return v;
}

// The stamp for changes made in this lock hold.
static uint32_t stamp_current(silt_tree *t) {
  silt_internal *in = silt_int(t);
  if (in->stamp_now == 0) in->stamp_now = stamp_fresh();
  return in->stamp_now;
}

static uint32_t *stamp_slot(silt_tree *t, uint32_t dir) {
  return &silt_int(t)->stamps[dir >> SILT_DIR_SHIFT][dir & SILT_DIR_MASK];
}

void tree_stamp_one(silt_tree *t, uint32_t dir) {
  if (dir < t->dir_count) *stamp_slot(t, dir) = stamp_current(t);
}

void tree_touch(silt_tree *t, uint32_t dir) {
  const uint32_t now = stamp_current(t);
  while (dir != SILT_NONE && dir < t->dir_count) {
    *stamp_slot(t, dir) = now;
    dir = silt_entry_at(t, silt_dir_at(t, dir)->entry)->parent;
  }
}

void tree_stamp_all(silt_tree *t) {
  silt_internal *in = silt_int(t);
  const uint32_t now = stamp_current(t);
  const uint32_t chunks = (t->dir_count + DIR_CHUNK - 1) / DIR_CHUNK;
  for (uint32_t c = 0; c < chunks; c++) {
    if (!in->stamps[c]) in->stamps[c] = tree_chunk_alloc(STAMP_CHUNK_BYTES);
    for (uint32_t i = 0; i < DIR_CHUNK; i++) in->stamps[c][i] = now;
  }
}

void tree_stamp_release(silt_tree *t) {
  silt_internal *in = silt_int(t);
  for (uint32_t c = 0; c < SILT_DIR_CHUNKS && in->stamps[c]; c++) {
    tree_chunk_free(in->stamps[c], STAMP_CHUNK_BYTES);
    in->stamps[c] = NULL;
  }
}

uint32_t silt_dir_stamp(const silt_tree *t, uint32_t dir) {
  const silt_internal *in = silt_int(t);
  if (in->parked || dir >= t->dir_count) return 0;
  return in->stamps[dir >> SILT_DIR_SHIFT][dir & SILT_DIR_MASK];
}

// MARK: Internal mutation

void tree_reserve_entries(silt_tree *t, uint32_t n) {
  uint64_t need = (uint64_t)t->entry_count + n;
  if (need >= SILT_NONE) abort();
  uint32_t last = need == 0 ? 0 : (uint32_t)((need - 1) >> SILT_ENTRY_SHIFT);
  for (uint32_t c = t->entry_count >> SILT_ENTRY_SHIFT; c <= last; c++) {
    if (!t->entries[c]) t->entries[c] = tree_chunk_alloc(ENTRY_CHUNK * sizeof(silt_entry));
  }
}

uint32_t tree_new_dir(silt_tree *t, uint32_t entry, uint64_t file_id,
                      uint32_t pending, uint32_t state) {
  uint32_t id = t->dir_count;
  if (id == SILT_NONE) abort();
  uint32_t c = id >> SILT_DIR_SHIFT;
  if (!t->dirs[c]) t->dirs[c] = tree_chunk_alloc(DIR_CHUNK * sizeof(silt_dir));
  silt_internal *in = silt_int(t);
  if (!in->stamps[c]) in->stamps[c] = tree_chunk_alloc(STAMP_CHUNK_BYTES);
  // A new folder's stamp differs from the 0 anyone got by asking early. Its
  // ancestors move when the listing that found it commits.
  in->stamps[c][id & SILT_DIR_MASK] = stamp_current(t);
  *silt_dir_at(t, id) = (silt_dir){
      .file_id = file_id,
      .entry = entry,
      .first = 0,
      .count = 0,
      .cap = 0,
      .items = 0,
      .newest = 0,
      .pending = pending,
      .state = state,
      .version = 0,
      .listed_at = 0,
  };
  t->dir_count = id + 1;
  return id;
}

// MARK: Run accounting

static void maybe_free_chunk(silt_tree *t, uint32_t c) {
  silt_internal *in = silt_int(t);
  // The chunk holding the append point may still be written.
  if (in->chunk_live[c] != 0 || c >= (t->entry_count >> SILT_ENTRY_SHIFT)) return;
  silt_entry *dead = tree_dead_chunk();
  if (!t->entries[c] || t->entries[c] == dead) return;
  tree_chunk_free(t->entries[c], ENTRY_CHUNK * sizeof(silt_entry));
  t->entries[c] = dead;
  in->chunks_freed++;
}

// Adds `delta` (+1 claim, -1 release) per slot to each chunk the range spans.
static void account(silt_tree *t, uint32_t first, uint32_t cap, int delta) {
  uint32_t *live = silt_int(t)->chunk_live;
  uint64_t i = first, end = (uint64_t)first + cap;
  while (i < end) {
    uint32_t c = (uint32_t)(i >> SILT_ENTRY_SHIFT);
    uint64_t chunk_end = ((uint64_t)c + 1) << SILT_ENTRY_SHIFT;
    uint32_t n = (uint32_t)((end < chunk_end ? end : chunk_end) - i);
    if (delta > 0) {
      live[c] += n;
    } else {
      if (live[c] < n) abort(); // released more than was claimed
      live[c] -= n;
      if (live[c] == 0) maybe_free_chunk(t, c);
    }
    i += n;
  }
}

void tree_claim_run(silt_tree *t, uint32_t first, uint32_t cap) {
  if (cap) account(t, first, cap, 1);
}

void tree_release_run(silt_tree *t, uint32_t first, uint32_t cap) {
  if (cap) account(t, first, cap, -1);
}

void tree_set_entry_count(silt_tree *t, uint32_t count) {
  uint32_t from = t->entry_count >> SILT_ENTRY_SHIFT;
  t->entry_count = count;
  uint32_t to = count >> SILT_ENTRY_SHIFT;
  for (uint32_t c = from; c < to; c++) maybe_free_chunk(t, c);
}

void tree_detach(silt_tree *t, uint32_t dir) {
  uint32_t *stack = NULL;
  uint32_t n = 0, cap = 0;
#define DPUSH(x)                                                               \
  do {                                                                         \
    if (n == cap) {                                                            \
      cap = cap ? cap * 2 : 64;                                                \
      stack = realloc(stack, cap * sizeof *stack);                             \
      if (!stack) abort();                                                     \
    }                                                                          \
    stack[n++] = (x);                                                          \
  } while (0)
  DPUSH(dir);
  while (n) {
    const uint32_t id = stack[--n];
    silt_dir *d = silt_dir_at(t, id);
    if (d->state & SILT_DIR_DETACHED) continue;
    d->state |= SILT_DIR_DETACHED;
    tree_stamp_one(t, id); // the caller's propagate moves the ancestors'
    // Folders beneath go too; removed ones were detached when removed.
    for (uint32_t i = d->first, end = d->first + d->count; i < end; i++) {
      const silt_entry *e = silt_entry_at(t, i);
      if (e->kind != SILT_KIND_DIR || (e->flags & SILT_FLAG_REMOVED)) continue;
      if (silt_dir_at(t, e->aux)->entry == i) DPUSH(e->aux);
    }
    tree_release_run(t, d->first, d->cap);
    d->cap = 0;
  }
#undef DPUSH
  free(stack);
}

void tree_reset_accounting(silt_tree *t) {
  silt_internal *in = silt_int(t);
  if (!in->chunk_live) in->chunk_live = xcalloc(SILT_ENTRY_CHUNKS, sizeof *in->chunk_live);
  else memset(in->chunk_live, 0, SILT_ENTRY_CHUNKS * sizeof *in->chunk_live);
  tree_claim_run(t, 0, 1);
  for (uint32_t d = 0; d < t->dir_count; d++) {
    const silt_dir *x = silt_dir_at(t, d);
    if (!(x->state & SILT_DIR_DETACHED)) tree_claim_run(t, x->first, x->cap);
  }
}

void silt_tree_memory_stats(silt_tree *t, silt_memory *out) {
  silt_tree_lock(t);
  const silt_internal *in = silt_int(t);
  silt_entry *dead = tree_dead_chunk();
  memset(out, 0, sizeof *out);
  out->entry_slots = t->entry_count;
  for (uint32_t c = 0; c < SILT_ENTRY_CHUNKS && t->entries[c]; c++) {
    out->live_slots += in->chunk_live[c];
    if (t->entries[c] != dead) out->entry_bytes += (uint64_t)ENTRY_CHUNK * sizeof(silt_entry);
  }
  silt_dir *zd = tree_zero_dir_chunk();
  for (uint32_t c = 0; c < SILT_DIR_CHUNKS && t->dirs[c]; c++)
    if (t->dirs[c] != zd) out->dir_bytes += (uint64_t)DIR_CHUNK * sizeof(silt_dir);
  out->name_bytes = in->parked ? 0 : t->name_used;
  out->chunks_freed = in->chunks_freed;
  silt_tree_unlock(t);
}

// MARK: Names

static uint32_t name_reserve(silt_tree *t, uint32_t len) {
  uint32_t off = t->name_used;
  uint32_t within = off & SILT_NAME_MASK;
  if (within + len > NAME_CHUNK) {
    off = (off & ~SILT_NAME_MASK) + NAME_CHUNK; // start the next chunk
    within = 0;
  }
  uint32_t c = off >> SILT_NAME_SHIFT;
  if (c >= SILT_NAME_CHUNKS) abort();
  if (!t->names[c]) t->names[c] = tree_chunk_alloc(NAME_CHUNK);
  t->name_used = off + len;
  return off;
}

uint32_t tree_put_name(silt_tree *t, const uint8_t *name, uint32_t len) {
  uint32_t off = name_reserve(t, len);
  memcpy((uint8_t *)silt_name_ptr(t, off), name, len);
  return off;
}

uint32_t tree_put_names(silt_tree *t, const uint8_t *buf, uint32_t len,
                        bool *contiguous) {
  if (len > NAME_CHUNK) {
    *contiguous = false;
    return 0;
  }
  *contiguous = true;
  return tree_put_name(t, buf, len);
}

// Every commit ends here, even one whose deltas are all zero: its folder's
// run changed, so the stamps up the chain move regardless.
void tree_propagate(silt_tree *t, uint32_t dir, int64_t size, int64_t items,
                    uint32_t newest, int64_t pending) {
  const uint32_t now = stamp_current(t);
  while (dir != SILT_NONE) {
    silt_dir *d = silt_dir_at(t, dir);
    silt_entry *e = silt_entry_at(t, d->entry);
    e->size += size;
    d->items = (uint32_t)((int64_t)d->items + items);
    if (newest > d->newest) d->newest = newest;
    d->pending = (uint32_t)((int64_t)d->pending + pending);
    *stamp_slot(t, dir) = now;
    dir = e->parent;
  }
}

void tree_recompute_newest(silt_tree *t, uint32_t dir) {
  const uint32_t now = stamp_current(t);
  while (dir != SILT_NONE) {
    silt_dir *d = silt_dir_at(t, dir);
    *stamp_slot(t, dir) = now;
    uint32_t newest = 0;
    for (uint32_t i = d->first, end = d->first + d->count; i < end; i++) {
      const silt_entry *e = silt_entry_at(t, i);
      if (e->flags & SILT_FLAG_REMOVED) continue;
      uint32_t m = e->kind == SILT_KIND_DIR ? silt_dir_at(t, e->aux)->newest
                                            : e->aux;
      if (m > newest) newest = m;
    }
    d->newest = newest;
    dir = silt_entry_at(t, d->entry)->parent;
  }
}

bool tree_dir_live(const silt_tree *t, uint32_t dir) {
  if (dir >= t->dir_count) return false;
  while (dir != SILT_NONE) {
    const silt_dir *d = silt_dir_at(t, dir);
    if (d->state & SILT_DIR_DETACHED) return false;
    const silt_entry *e = silt_entry_at(t, d->entry);
    if (e->flags & SILT_FLAG_REMOVED) return false;
    dir = e->parent;
  }
  return true;
}

// MARK: Reading

bool silt_is_live(const silt_tree *t, uint32_t entry) {
  if (entry >= t->entry_count) return false;
  uint32_t i = entry;
  for (;;) {
    const silt_entry *e = silt_entry_at(t, i);
    if (e->flags & SILT_FLAG_REMOVED) return false;
    if (e->kind == SILT_KIND_DIR) {
      const silt_dir *d = silt_dir_at(t, e->aux);
      if (d->entry != i || (d->state & SILT_DIR_DETACHED)) return false;
    }
    if (e->parent == SILT_NONE) return i == 0;
    const silt_dir *p = silt_dir_at(t, e->parent);
    if (i < p->first || i >= p->first + p->count) return false;
    i = p->entry;
  }
}

size_t silt_path(const silt_tree *t, uint32_t entry, char *buf, size_t cap) {
  if (entry >= t->entry_count || cap == 0) return 0;
  // Collect the chain first, then write it root-first.
  uint32_t chain[512];
  uint32_t depth = 0;
  uint32_t i = entry;
  for (;;) {
    if (depth == 512) return 0;
    chain[depth++] = i;
    const silt_entry *e = silt_entry_at(t, i);
    if (e->parent == SILT_NONE) break;
    i = silt_dir_at(t, e->parent)->entry;
  }
  size_t len = 0;
  for (uint32_t k = depth; k-- > 0;) {
    const silt_entry *e = silt_entry_at(t, chain[k]);
    bool root = k == depth - 1;
    if (!root && !(len == 1 && buf[0] == '/')) {
      if (len + 1 >= cap) return 0;
      buf[len++] = '/';
    }
    if (len + e->name_len >= cap) return 0;
    memcpy(buf + len, silt_name_ptr(t, e->name), e->name_len);
    len += e->name_len;
  }
  buf[len] = 0;
  return len;
}

// MARK: Sorting children
//
// Each child becomes a record of plain integers, compared without looking
// anything up: the sort keys, then the first 16 bytes of the name, case
// folded and packed big-endian so integer order is name order. Only records
// that tie on all of that (names sharing a 16-byte prefix, which is rare
// even in folders where most names start alike, like com.apple.*) compare
// the rest of their names. The order is the same as a case-insensitive name
// comparison: folded bytes first, then the shorter name first.

typedef struct sort_rec {
  uint64_t k1, k2;       // sort keys, ascending (descending ones are inverted)
  uint64_t name0, name1; // folded name bytes 0-7 and 8-15, zero-padded
  uint32_t index;  // entry index
  uint32_t name;   // name offset in the arena
  uint16_t len;    // name length
} sort_rec;

// Inverts a size so that ascending order is largest first.
static inline uint64_t size_desc(int64_t size) { return (uint64_t)INT64_MAX - (uint64_t)size; }

// Fills in a record's keys from its entry. Lock held.
static void sort_keys(const silt_tree *t, int key, uint32_t i, sort_rec *r) {
  const silt_entry *e = silt_entry_at(t, i);
  const bool dir = e->kind == SILT_KIND_DIR;
  r->index = i;
  r->name = e->name;
  r->len = e->name_len;
  r->k2 = 0;
  switch (key) {
  case 0:
    r->k1 = size_desc(e->size);
    break;
  case 2:
    r->k1 = UINT32_MAX - (dir ? silt_dir_at(t, e->aux)->items : 0);
    r->k2 = size_desc(e->size);
    break;
  case 3:
    r->k1 = UINT32_MAX - (dir ? silt_dir_at(t, e->aux)->newest : e->aux);
    break;
  default:
    r->k1 = 0;
    break;
  }
}

// Names never move or change once written, so this is safe without the lock
// as long as the tree isn't parked.
static void sort_name(const silt_tree *t, sort_rec *r) {
  const uint8_t *s = silt_name_ptr(t, r->name);
  uint64_t v = 0, w = 0;
  for (uint32_t k = 0; k < 8; k++) v = (v << 8) | (k < r->len ? silt_ascii_fold[s[k]] : 0);
  for (uint32_t k = 8; k < 16; k++) w = (w << 8) | (k < r->len ? silt_ascii_fold[s[k]] : 0);
  r->name0 = v;
  r->name1 = w;
}

static inline int rec_cmp(const silt_tree *t, const sort_rec *a, const sort_rec *b) {
  if (a->k1 != b->k1) return a->k1 < b->k1 ? -1 : 1;
  if (a->k2 != b->k2) return a->k2 < b->k2 ? -1 : 1;
  if (a->name0 != b->name0) return a->name0 < b->name0 ? -1 : 1;
  if (a->name1 != b->name1) return a->name1 < b->name1 ? -1 : 1;
  // Equal first 16 bytes: the rest of the names decide, then their lengths.
  const uint32_t n = a->len < b->len ? a->len : b->len;
  if (n > 16) {
    const uint8_t *x = silt_name_ptr(t, a->name), *y = silt_name_ptr(t, b->name);
    for (uint32_t k = 16; k < n; k++) {
      uint8_t p = silt_ascii_fold[x[k]], q = silt_ascii_fold[y[k]];
      if (p != q) return p < q ? -1 : 1;
    }
  }
  if (a->len != b->len) return a->len < b->len ? -1 : 1;
  return a->index < b->index ? -1 : a->index > b->index;
}

static inline void rec_swap(sort_rec *a, sort_rec *b) {
  sort_rec x = *a;
  *a = *b;
  *b = x;
}

static void rec_sift(const silt_tree *t, sort_rec *r, size_t k, size_t n) {
  for (;;) {
    size_t c = 2 * k + 1;
    if (c >= n) return;
    if (c + 1 < n && rec_cmp(t, &r[c], &r[c + 1]) < 0) c++;
    if (rec_cmp(t, &r[k], &r[c]) >= 0) return;
    rec_swap(&r[k], &r[c]);
    k = c;
  }
}

// Introsort: quicksort with a median-of-three pivot, heapsort if it
// degenerates, insertion sort for short ranges. In place, so a huge folder
// needs no second buffer.
static void rec_sort(const silt_tree *t, sort_rec *r, size_t n, int depth) {
  while (n > 16) {
    if (depth-- == 0) {
      for (size_t k = n / 2; k-- > 0;) rec_sift(t, r, k, n);
      for (size_t k = n; k-- > 1;) {
        rec_swap(&r[0], &r[k]);
        rec_sift(t, r, 0, k);
      }
      return;
    }
    size_t mid = n / 2;
    if (rec_cmp(t, &r[mid], &r[0]) < 0) rec_swap(&r[mid], &r[0]);
    if (rec_cmp(t, &r[n - 1], &r[0]) < 0) rec_swap(&r[n - 1], &r[0]);
    if (rec_cmp(t, &r[n - 1], &r[mid]) < 0) rec_swap(&r[n - 1], &r[mid]);
    // The pivot waits at n - 2; r[0] and r[n - 1] already bound the scans.
    rec_swap(&r[mid], &r[n - 2]);
    const sort_rec pivot = r[n - 2];
    size_t i = 0, j = n - 2;
    for (;;) {
      while (rec_cmp(t, &r[++i], &pivot) < 0) {}
      while (rec_cmp(t, &pivot, &r[--j]) < 0) {}
      if (i >= j) break;
      rec_swap(&r[i], &r[j]);
    }
    rec_swap(&r[i], &r[n - 2]);
    // Recurse into the smaller side, loop on the larger.
    if (i < n - i - 1) {
      rec_sort(t, r, i, depth);
      r += i + 1;
      n -= i + 1;
    } else {
      rec_sort(t, r + i + 1, n - i - 1, depth);
      n = i;
    }
  }
  for (size_t k = 1; k < n; k++) {
    sort_rec x = r[k];
    size_t j = k;
    while (j > 0 && rec_cmp(t, &x, &r[j - 1]) < 0) {
      r[j] = r[j - 1];
      j--;
    }
    r[j] = x;
  }
}

// Record buffers for big folders come straight from the kernel, so they
// really go back when the sort is done.
#define SORT_MMAP_BYTES (256u << 10)

static sort_rec *recs_alloc(size_t n) {
  size_t bytes = n * sizeof(sort_rec);
  sort_rec *r = bytes >= SORT_MMAP_BYTES ? tree_chunk_alloc(bytes) : malloc(bytes ? bytes : 1);
  if (!r) abort();
  return r;
}

static void recs_free(sort_rec *r, size_t n) {
  size_t bytes = n * sizeof(sort_rec);
  if (bytes >= SORT_MMAP_BYTES) tree_chunk_free(r, bytes);
  else free(r);
}

// Copies the live children of `dir` into records (keys only). Lock held.
// Returns the count; *out_recs must be freed with recs_free(*, *cap_out).
static uint32_t collect_children(const silt_tree *t, uint32_t dir, int key, sort_rec **out_recs,
                                 size_t *cap_out) {
  const silt_dir *d = silt_dir_at(t, dir);
  sort_rec *r = recs_alloc(d->count);
  uint32_t n = 0;
  for (uint32_t i = d->first, end = d->first + d->count; i < end; i++) {
    if (silt_entry_at(t, i)->flags & SILT_FLAG_REMOVED) continue;
    sort_keys(t, key, i, &r[n++]);
  }
  *out_recs = r;
  *cap_out = d->count;
  return n;
}

static uint32_t finish_sort(const silt_tree *t, sort_rec *r, uint32_t n, uint32_t *out, uint32_t cap) {
  for (uint32_t k = 0; k < n; k++) sort_name(t, &r[k]);
  int depth = 2;
  for (uint32_t m = n; m > 1; m >>= 1) depth += 2;
  rec_sort(t, r, n, depth);
  if (n > cap) n = cap;
  for (uint32_t k = 0; k < n; k++) out[k] = r[k].index;
  return n;
}

uint32_t silt_children_sorted(const silt_tree *t, uint32_t dir, int key,
                              uint32_t *out, uint32_t cap) {
  if (dir >= t->dir_count || cap == 0) return 0;
  sort_rec *r;
  size_t rcap;
  uint32_t n = collect_children(t, dir, key, &r, &rcap);
  n = finish_sort(t, r, n, out, cap);
  recs_free(r, rcap);
  return n;
}

uint32_t silt_children_sorted_unlocked(silt_tree *t, uint32_t dir, int key,
                                       uint32_t *out, uint32_t cap) {
  if (cap == 0) return 0;
  silt_tree_lock(t);
  if (dir >= t->dir_count) {
    silt_tree_unlock(t);
    return 0;
  }
  sort_rec *r;
  size_t rcap;
  uint32_t n = collect_children(t, dir, key, &r, &rcap);
  silt_tree_unlock(t);
  // Everything from here reads only the records and the name arena.
  n = finish_sort(t, r, n, out, cap);
  recs_free(r, rcap);
  return n;
}

static uint32_t find_child(const silt_tree *t, uint32_t dir, const char *name,
                           size_t len) {
  if (dir >= t->dir_count) return SILT_NONE;
  const silt_dir *d = silt_dir_at(t, dir);
  for (uint32_t i = d->first, end = d->first + d->count; i < end; i++) {
    const silt_entry *e = silt_entry_at(t, i);
    if (e->name_len == len && !(e->flags & SILT_FLAG_REMOVED) &&
        memcmp(silt_name_ptr(t, e->name), name, len) == 0)
      return i;
  }
  return SILT_NONE;
}

uint32_t silt_lookup(const silt_tree *t, const char *path) {
  const silt_entry *root = silt_entry_at(t, 0);
  size_t rlen = root->name_len;
  const char *rname = (const char *)silt_name_ptr(t, root->name);
  size_t plen = strlen(path);
  while (plen > 1 && path[plen - 1] == '/') plen--;
  if (plen < rlen || memcmp(path, rname, rlen) != 0) return SILT_NONE;
  const char *p = path + rlen;
  const char *end = path + plen;
  if (p < end && *p != '/' && !(rlen == 1 && rname[0] == '/')) return SILT_NONE;

  uint32_t cur = 0;
  while (p < end) {
    while (p < end && *p == '/') p++;
    if (p >= end) break;
    const char *s = p;
    while (p < end && *p != '/') p++;
    const silt_entry *e = silt_entry_at(t, cur);
    if (e->kind != SILT_KIND_DIR) return SILT_NONE;
    uint32_t next = find_child(t, e->aux, s, (size_t)(p - s));
    if (next == SILT_NONE) return SILT_NONE;
    cur = next;
  }
  return cur;
}

// MARK: Removal

void silt_tree_remove(silt_tree *t, uint32_t entry) {
  silt_tree_lock(t);
  if (entry == 0 || !silt_is_live(t, entry)) {
    silt_tree_unlock(t);
    return;
  }
  silt_entry *e = silt_entry_at(t, entry);
  int64_t items = 1;
  int64_t pending = 0;
  if (e->kind == SILT_KIND_DIR) {
    silt_dir *d = silt_dir_at(t, e->aux);
    items += d->items;
    pending = d->pending;
    tree_detach(t, e->aux);
  }
  e->flags |= SILT_FLAG_REMOVED;
  silt_dir_at(t, e->parent)->version++;
  tree_propagate(t, e->parent, -e->size, -items, 0, -pending);
  tree_recompute_newest(t, e->parent); // it may have been the newest thing here
  TREE_BUMP(t);
  silt_tree_unlock(t);
}
