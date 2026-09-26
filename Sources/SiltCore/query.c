// Whole-tree queries. Each is a single depth-first pass over live entries under
// the tree lock, keeping the largest `cap` results in a min-heap.

#include "internal.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

// MARK: Top-N heap

typedef struct heap {
  const silt_tree *t;
  uint32_t *idx;
  uint32_t *tag;
  uint32_t n, cap;
} heap;

static inline int64_t hsize(const heap *h, uint32_t k) {
  return silt_entry_at(h->t, h->idx[k])->size;
}

static void hswap(heap *h, uint32_t a, uint32_t b) {
  uint32_t x = h->idx[a];
  h->idx[a] = h->idx[b];
  h->idx[b] = x;
  if (h->tag) {
    x = h->tag[a];
    h->tag[a] = h->tag[b];
    h->tag[b] = x;
  }
}

static void sift_down(heap *h, uint32_t k) {
  for (;;) {
    uint32_t l = 2 * k + 1, r = l + 1, m = k;
    if (l < h->n && hsize(h, l) < hsize(h, m)) m = l;
    if (r < h->n && hsize(h, r) < hsize(h, m)) m = r;
    if (m == k) return;
    hswap(h, k, m);
    k = m;
  }
}

static void heap_offer(heap *h, uint32_t entry, uint32_t tag) {
  if (h->cap == 0) return;
  int64_t size = silt_entry_at(h->t, entry)->size;
  if (h->n < h->cap) {
    uint32_t k = h->n++;
    h->idx[k] = entry;
    if (h->tag) h->tag[k] = tag;
    while (k > 0) {
      uint32_t p = (k - 1) / 2;
      if (hsize(h, p) <= hsize(h, k)) break;
      hswap(h, p, k);
      k = p;
    }
  } else if (size > hsize(h, 0)) {
    h->idx[0] = entry;
    if (h->tag) h->tag[0] = tag;
    sift_down(h, 0);
  }
}

// Pops everything so the output ends up largest-first.
static uint32_t heap_finish(heap *h) {
  uint32_t n = h->n;
  while (h->n > 1) {
    hswap(h, 0, h->n - 1);
    h->n--;
    sift_down(h, 0);
  }
  h->n = 0;
  return n;
}

// MARK: Depth-first walk

typedef struct walker {
  uint32_t *stack;
  uint32_t n, cap;
} walker;

static void wpush(walker *w, uint32_t dir) {
  if (w->n == w->cap) {
    w->cap = w->cap ? w->cap * 2 : 1024;
    w->stack = realloc(w->stack, w->cap * sizeof *w->stack);
    if (!w->stack) abort();
  }
  w->stack[w->n++] = dir;
}

// Calls `visit` for every live entry under `root_dir`. `visit` returns true to
// descend into a folder.
#define WALK(t, root_dir, e, index, body)                                      \
  do {                                                                         \
    walker w_ = {0};                                                           \
    wpush(&w_, (root_dir));                                                    \
    while (w_.n) {                                                             \
      const silt_dir *d_ = silt_dir_at((t), w_.stack[--w_.n]);                 \
      for (uint32_t index = d_->first, end_ = d_->first + d_->count;           \
           index < end_; index++) {                                            \
        const silt_entry *e = silt_entry_at((t), index);                       \
        if (e->flags & SILT_FLAG_REMOVED) continue;                            \
        bool descend_ = e->kind == SILT_KIND_DIR;                              \
        body;                                                                  \
        if (descend_) wpush(&w_, e->aux);                                      \
      }                                                                        \
    }                                                                          \
    free(w_.stack);                                                            \
  } while (0)

uint32_t silt_top_files(silt_tree *t, uint32_t dir, uint32_t *out,
                        uint32_t cap) {
  heap h = {.t = t, .idx = out, .tag = NULL, .n = 0, .cap = cap};
  silt_tree_lock(t);
  WALK(t, dir, e, i, {
    if (e->kind != SILT_KIND_DIR && e->size > 0) heap_offer(&h, i, 0);
  });
  uint32_t n = heap_finish(&h);
  silt_tree_unlock(t);
  return n;
}

static bool contains_ci(const uint8_t *hay, uint32_t hlen, const uint8_t *nee,
                        uint32_t nlen) {
  if (nlen == 0) return true;
  if (nlen > hlen) return false;
  uint8_t first = nee[0];
  for (uint32_t i = 0; i + nlen <= hlen; i++) {
    if ((uint8_t)tolower(hay[i]) != first) continue;
    uint32_t k = 1;
    while (k < nlen && (uint8_t)tolower(hay[i + k]) == nee[k]) k++;
    if (k == nlen) return true;
  }
  return false;
}

uint32_t silt_search(silt_tree *t, uint32_t dir, const char *needle,
                     uint32_t *out, uint32_t cap) {
  size_t nlen = strlen(needle);
  if (nlen == 0 || nlen > 1024) return 0;
  uint8_t lower[1024];
  for (size_t i = 0; i < nlen; i++) lower[i] = (uint8_t)tolower(needle[i]);

  heap h = {.t = t, .idx = out, .tag = NULL, .n = 0, .cap = cap};
  silt_tree_lock(t);
  WALK(t, dir, e, i, {
    if (contains_ci(silt_name_ptr(t, e->name), e->name_len, lower,
                    (uint32_t)nlen))
      heap_offer(&h, i, 0);
  });
  uint32_t n = heap_finish(&h);
  silt_tree_unlock(t);
  return n;
}

uint32_t silt_find_dirs(silt_tree *t, uint32_t dir, const char *const *names,
                        uint32_t name_count, uint32_t *out, uint32_t *which,
                        uint32_t cap) {
  uint32_t lens[64];
  if (name_count > 64) name_count = 64;
  for (uint32_t k = 0; k < name_count; k++) lens[k] = (uint32_t)strlen(names[k]);

  heap h = {.t = t, .idx = out, .tag = which, .n = 0, .cap = cap};
  silt_tree_lock(t);
  WALK(t, dir, e, i, {
    if (e->kind == SILT_KIND_DIR) {
      const uint8_t *nm = silt_name_ptr(t, e->name);
      for (uint32_t k = 0; k < name_count; k++) {
        if (lens[k] == e->name_len && memcmp(nm, names[k], lens[k]) == 0) {
          if (e->size > 0) heap_offer(&h, i, k);
          descend_ = false;
          break;
        }
      }
    }
  });
  uint32_t n = heap_finish(&h);
  silt_tree_unlock(t);
  return n;
}

uint32_t silt_stale_files(silt_tree *t, uint32_t dir, int64_t min_size,
                          uint32_t before, uint32_t *out, uint32_t cap) {
  heap h = {.t = t, .idx = out, .tag = NULL, .n = 0, .cap = cap};
  silt_tree_lock(t);
  WALK(t, dir, e, i, {
    if (e->kind == SILT_KIND_FILE && e->size >= min_size && e->aux > 0 &&
        e->aux < before)
      heap_offer(&h, i, 0);
  });
  uint32_t n = heap_finish(&h);
  silt_tree_unlock(t);
  return n;
}

// MARK: Extensions

// Lowercased extension of `e` into `ext` (up to 15 bytes). Returns its length.
static uint32_t entry_ext(const silt_tree *t, const silt_entry *e, char *ext) {
  const uint8_t *nm = silt_name_ptr(t, e->name);
  uint32_t lo = e->name_len > 16 ? e->name_len - 16 : 0;
  for (uint32_t k = e->name_len - 1; k > lo && k > 0; k--) {
    if (nm[k] != '.') continue;
    uint32_t len = e->name_len - k - 1;
    for (uint32_t c = 0; c < len; c++) ext[c] = (char)tolower(nm[k + 1 + c]);
    ext[len] = 0;
    return len;
  }
  ext[0] = 0;
  return 0;
}

uint32_t silt_find_files(silt_tree *t, uint32_t dir, const char *const *exts,
                         uint32_t ext_count, uint32_t *out, uint32_t *which,
                         uint32_t cap) {
  heap h = {.t = t, .idx = out, .tag = which, .n = 0, .cap = cap};
  silt_tree_lock(t);
  WALK(t, dir, e, i, {
    if (e->kind == SILT_KIND_FILE && e->size > 0) {
      char ext[16];
      if (entry_ext(t, e, ext)) {
        for (uint32_t k = 0; k < ext_count; k++) {
          if (strcmp(ext, exts[k]) == 0) {
            heap_offer(&h, i, k);
            break;
          }
        }
      }
    }
  });
  uint32_t n = heap_finish(&h);
  silt_tree_unlock(t);
  return n;
}

typedef struct ext_slot {
  char ext[16];
  uint64_t bytes;
  uint64_t count;
  bool used;
} ext_slot;

static int ext_cmp(const void *a, const void *b) {
  const silt_ext_stat *x = a, *y = b;
  if (x->bytes != y->bytes) return x->bytes > y->bytes ? -1 : 1;
  return strcmp(x->ext, y->ext);
}

uint32_t silt_ext_stats(silt_tree *t, uint32_t dir, silt_ext_stat *out,
                        uint32_t cap) {
  const uint32_t size = 1u << 16, limit = size / 2;
  uint32_t used = 0;
  ext_slot *slots = calloc(size, sizeof *slots);
  if (!slots) abort();
  uint64_t rest_bytes = 0, rest_count = 0; // extensions past `limit`

  silt_tree_lock(t);
  WALK(t, dir, e, i, {
    if (e->kind == SILT_KIND_FILE && e->size > 0) {
      char ext[16] = {0};
      uint32_t len = entry_ext(t, e, ext);
      uint32_t hsh = 2166136261u;
      for (uint32_t c = 0; c < len; c++)
        hsh = (hsh ^ (uint8_t)ext[c]) * 16777619u;
      uint32_t s = hsh & (size - 1);
      while (slots[s].used && strcmp(slots[s].ext, ext) != 0)
        s = (s + 1) & (size - 1);
      if (!slots[s].used && used >= limit) {
        rest_bytes += (uint64_t)e->size;
        rest_count++;
      } else {
        if (!slots[s].used) {
          memcpy(slots[s].ext, ext, sizeof ext);
          slots[s].used = true;
          used++;
        }
        slots[s].bytes += (uint64_t)e->size;
        slots[s].count++;
      }
    }
  });
  silt_tree_unlock(t);

  silt_ext_stat *all = malloc((used + 1) * sizeof *all);
  if (!all) abort();
  uint32_t n = 0;
  for (uint32_t s = 0; s < size; s++) {
    if (!slots[s].used) continue;
    memcpy(all[n].ext, slots[s].ext, sizeof all[n].ext);
    all[n].bytes = slots[s].bytes;
    all[n].count = slots[s].count;
    n++;
  }
  if (rest_count) {
    memset(all[n].ext, 0, sizeof all[n].ext);
    all[n].ext[0] = '*';
    all[n].bytes = rest_bytes;
    all[n].count = rest_count;
    n++;
  }
  free(slots);
  qsort(all, n, sizeof *all, ext_cmp);
  if (n > cap) n = cap;
  memcpy(out, all, n * sizeof *all);
  free(all);
  return n;
}
