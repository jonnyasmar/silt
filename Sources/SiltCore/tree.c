#include "internal.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define ENTRY_CHUNK (1u << SILT_ENTRY_SHIFT)
#define DIR_CHUNK (1u << SILT_DIR_SHIFT)
#define NAME_CHUNK (1u << SILT_NAME_SHIFT)

static void *xcalloc(size_t n, size_t size) {
  void *p = calloc(n, size);
  if (!p) abort();
  return p;
}

static void *xmalloc(size_t size) {
  void *p = malloc(size);
  if (!p) abort();
  return p;
}

silt_tree *silt_tree_create(const char *root_path) {
  silt_tree *t = xcalloc(1, sizeof *t);
  t->entries = xcalloc(SILT_ENTRY_CHUNKS, sizeof *t->entries);
  t->dirs = xcalloc(SILT_DIR_CHUNKS, sizeof *t->dirs);
  t->names = xcalloc(SILT_NAME_CHUNKS, sizeof *t->names);
  silt_internal *in = xcalloc(1, sizeof *in);
  in->lock = OS_UNFAIR_LOCK_INIT;
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
  for (uint32_t i = 0; i < SILT_ENTRY_CHUNKS && t->entries[i]; i++)
    free(t->entries[i]);
  for (uint32_t i = 0; i < SILT_DIR_CHUNKS && t->dirs[i]; i++) free(t->dirs[i]);
  for (uint32_t i = 0; i < SILT_NAME_CHUNKS && t->names[i]; i++)
    free(t->names[i]);
  free(t->entries);
  free(t->dirs);
  free(t->names);
  free(t->internal);
  free(t);
}

void silt_tree_lock(silt_tree *t) { os_unfair_lock_lock(&silt_int(t)->lock); }
void silt_tree_unlock(silt_tree *t) {
  os_unfair_lock_unlock(&silt_int(t)->lock);
}

uint64_t silt_tree_generation(const silt_tree *t) {
  return __atomic_load_n(&t->generation, __ATOMIC_ACQUIRE);
}

// MARK: Internal mutation

void tree_reserve_entries(silt_tree *t, uint32_t n) {
  uint64_t need = (uint64_t)t->entry_count + n;
  if (need >= SILT_NONE) abort();
  uint32_t last = need == 0 ? 0 : (uint32_t)((need - 1) >> SILT_ENTRY_SHIFT);
  for (uint32_t c = t->entry_count >> SILT_ENTRY_SHIFT; c <= last; c++) {
    if (!t->entries[c]) t->entries[c] = xmalloc(ENTRY_CHUNK * sizeof(silt_entry));
  }
}

uint32_t tree_new_dir(silt_tree *t, uint32_t entry, uint64_t file_id,
                      uint32_t pending, uint32_t state) {
  uint32_t id = t->dir_count;
  if (id == SILT_NONE) abort();
  uint32_t c = id >> SILT_DIR_SHIFT;
  if (!t->dirs[c]) t->dirs[c] = xmalloc(DIR_CHUNK * sizeof(silt_dir));
  *silt_dir_at(t, id) = (silt_dir){
      .file_id = file_id,
      .entry = entry,
      .first = 0,
      .count = 0,
      .items = 0,
      .newest = 0,
      .pending = pending,
      .state = state,
  };
  t->dir_count = id + 1;
  return id;
}

static uint32_t name_reserve(silt_tree *t, uint32_t len) {
  uint32_t off = t->name_used;
  uint32_t within = off & SILT_NAME_MASK;
  if (within + len > NAME_CHUNK) {
    off = (off & ~SILT_NAME_MASK) + NAME_CHUNK; // start the next chunk
    within = 0;
  }
  uint32_t c = off >> SILT_NAME_SHIFT;
  if (c >= SILT_NAME_CHUNKS) abort();
  if (!t->names[c]) t->names[c] = xmalloc(NAME_CHUNK);
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

void tree_propagate(silt_tree *t, uint32_t dir, int64_t size, int64_t items,
                    uint32_t newest, int64_t pending) {
  while (dir != SILT_NONE) {
    silt_dir *d = silt_dir_at(t, dir);
    silt_entry *e = silt_entry_at(t, d->entry);
    e->size += size;
    d->items = (uint32_t)((int64_t)d->items + items);
    if (newest > d->newest) d->newest = newest;
    d->pending = (uint32_t)((int64_t)d->pending + pending);
    dir = e->parent;
  }
}

void tree_recompute_newest(silt_tree *t, uint32_t dir) {
  while (dir != SILT_NONE) {
    silt_dir *d = silt_dir_at(t, dir);
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

static int name_cmp(const silt_tree *t, const silt_entry *a,
                    const silt_entry *b) {
  size_t n = a->name_len < b->name_len ? a->name_len : b->name_len;
  int c = strncasecmp((const char *)silt_name_ptr(t, a->name),
                      (const char *)silt_name_ptr(t, b->name), n);
  if (c) return c;
  return (int)a->name_len - (int)b->name_len;
}

static uint32_t sort_items(const silt_tree *t, const silt_entry *e) {
  if (e->kind != SILT_KIND_DIR) return 0;
  return silt_dir_at(t, e->aux)->items;
}

static uint32_t sort_mtime(const silt_tree *t, const silt_entry *e) {
  if (e->kind != SILT_KIND_DIR) return e->aux;
  return silt_dir_at(t, e->aux)->newest;
}

typedef struct {
  const silt_tree *t;
  int key;
} sort_ctx;

static int child_cmp(void *ctx, const void *pa, const void *pb) {
  const sort_ctx *c = ctx;
  const silt_entry *a = silt_entry_at(c->t, *(const uint32_t *)pa);
  const silt_entry *b = silt_entry_at(c->t, *(const uint32_t *)pb);
  switch (c->key) {
  case 0:
    if (a->size != b->size) return a->size > b->size ? -1 : 1;
    break;
  case 2: {
    uint32_t x = sort_items(c->t, a), y = sort_items(c->t, b);
    if (x != y) return x > y ? -1 : 1;
    if (a->size != b->size) return a->size > b->size ? -1 : 1;
    break;
  }
  case 3: {
    uint32_t x = sort_mtime(c->t, a), y = sort_mtime(c->t, b);
    if (x != y) return x > y ? -1 : 1;
    break;
  }
  default:
    break;
  }
  return name_cmp(c->t, a, b);
}

uint32_t silt_children_sorted(const silt_tree *t, uint32_t dir, int key,
                              uint32_t *out, uint32_t cap) {
  if (dir >= t->dir_count || cap == 0) return 0;
  const silt_dir *d = silt_dir_at(t, dir);
  // Sort every live child, then keep the first `cap`.
  uint32_t *all = cap >= d->count ? out : malloc(d->count * sizeof *all);
  if (!all) abort();
  uint32_t n = 0;
  for (uint32_t i = d->first, end = d->first + d->count; i < end; i++) {
    if (silt_entry_at(t, i)->flags & SILT_FLAG_REMOVED) continue;
    all[n++] = i;
  }
  sort_ctx ctx = {t, key};
  qsort_r(all, n, sizeof *all, &ctx, child_cmp);
  if (all != out) {
    if (n > cap) n = cap;
    memcpy(out, all, n * sizeof *out);
    free(all);
  }
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
    d->state |= SILT_DIR_DETACHED;
  }
  e->flags |= SILT_FLAG_REMOVED;
  tree_propagate(t, e->parent, -e->size, -items, 0, -pending);
  TREE_BUMP(t);
  silt_tree_unlock(t);
}
