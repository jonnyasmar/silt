// The scanner: a fixed pool of worker threads draining a LIFO queue of
// directory listings. Each listing is one getattrlistbulk() pass that parses
// every entry into a thread-local batch, then a single short critical section
// that appends the batch to the tree and pushes the size delta up the
// ancestor chain. Parents therefore show correct partial totals at every
// moment of the scan, which is what lets the UI render it live.
//
// Lock order: the queue mutex and the tree lock are never held together.

#include "internal.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <time.h>
#include <unistd.h>

#define BULK_BUFFER (256 * 1024)

typedef struct work {
  char *path;
  uint32_t dir;
  bool deep;
} work;

typedef struct batch {
  silt_entry *ents;
  uint64_t *ids;  // per entry: inode
  uint8_t *walk;  // per entry: 1 if it is a folder to descend into
  uint32_t n, cap;
  uint8_t *names;
  uint32_t nlen, ncap;
  uint32_t *new_dirs; // batch index of each new folder to descend into
  uint32_t *new_ids;  // ...and the dir id it was given
  uint32_t nnew, newcap;
  work *out;
  uint32_t nout, outcap;
  char *buf;
} batch;

struct silt_scanner {
  silt_tree *tree;
  pthread_mutex_t qlock;
  pthread_cond_t qcond;
  pthread_cond_t idle_cond;
  work *q;
  uint32_t qcount, qcap;
  uint32_t active;
  bool shutdown;
  bool cancelled;
  int nthreads;
  pthread_t *threads;
  uint64_t scan_start;
  uint64_t scan_end;
};

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static void *xrealloc(void *p, size_t size) {
  void *q = realloc(p, size);
  if (!q) abort();
  return q;
}

#define GROW(ptr, count, cap, extra)                                           \
  do {                                                                         \
    if ((count) + (extra) > (cap)) {                                           \
      uint32_t c_ = (cap) ? (cap) : 64;                                        \
      while ((count) + (extra) > c_) c_ *= 2;                                  \
      (ptr) = xrealloc((ptr), (size_t)c_ * sizeof(*(ptr)));                    \
      (cap) = c_;                                                              \
    }                                                                          \
  } while (0)

// MARK: Listing

static struct attrlist bulk_attrs = {
    .bitmapcount = ATTR_BIT_MAP_COUNT,
    .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR |
                  ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS |
                  ATTR_CMN_FILEID,
    .dirattr = ATTR_DIR_MOUNTSTATUS,
    .fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE,
};

static void batch_grow(batch *b) {
  if (b->n < b->cap) return;
  uint32_t cap = b->cap ? b->cap * 2 : 256;
  b->ents = xrealloc(b->ents, cap * sizeof *b->ents);
  b->ids = xrealloc(b->ids, cap * sizeof *b->ids);
  b->walk = xrealloc(b->walk, cap);
  b->cap = cap;
}

// Parses one getattrlistbulk() buffer into the batch. Returns the number of
// entries that reported their own error.
static uint32_t parse(batch *b, const char *buf, int count) {
  uint32_t errors = 0;
  const char *p = buf;
  for (int i = 0; i < count; i++) {
    uint32_t len;
    memcpy(&len, p, 4);
    const char *f = p + 4;
    p += len;

    attribute_set_t ret;
    memcpy(&ret, f, sizeof ret);
    f += sizeof ret;

    uint32_t err = 0;
    if (ret.commonattr & ATTR_CMN_ERROR) {
      memcpy(&err, f, 4);
      f += 4;
    }
    if (!(ret.commonattr & ATTR_CMN_NAME)) continue;
    attrreference_t ref;
    memcpy(&ref, f, sizeof ref);
    const char *name = f + ref.attr_dataoffset;
    uint32_t name_len = ref.attr_length ? ref.attr_length - 1 : 0;
    f += sizeof ref;
    if (name_len == 0 || name_len > 0xFFFF) continue;

    uint32_t type = VNON;
    if (ret.commonattr & ATTR_CMN_OBJTYPE) {
      memcpy(&type, f, 4);
      f += 4;
    }
    struct timespec mtime = {0, 0};
    if (ret.commonattr & ATTR_CMN_MODTIME) {
      memcpy(&mtime, f, sizeof mtime);
      f += sizeof mtime;
    }
    uint32_t bsd_flags = 0;
    if (ret.commonattr & ATTR_CMN_FLAGS) {
      memcpy(&bsd_flags, f, 4);
      f += 4;
    }
    uint64_t file_id = 0;
    if (ret.commonattr & ATTR_CMN_FILEID) {
      memcpy(&file_id, f, 8);
      f += 8;
    }

    silt_entry e = {
        .size = 0,
        .parent = 0,
        .name = b->nlen,
        .aux = 0,
        .name_len = (uint16_t)name_len,
        .kind = SILT_KIND_OTHER,
        .flags = 0,
    };
    uint8_t walk = 0;
    if (name[0] == '.' || (bsd_flags & UF_HIDDEN)) e.flags |= SILT_FLAG_HIDDEN;
    if (bsd_flags & SF_DATALESS) e.flags |= SILT_FLAG_DATALESS;
    if (err) {
      e.flags |= SILT_FLAG_DENIED;
      errors++;
    }

    if (type == VDIR) {
      e.kind = SILT_KIND_DIR;
      uint32_t mount = 0;
      if (ret.dirattr & ATTR_DIR_MOUNTSTATUS) {
        memcpy(&mount, f, 4);
        f += 4;
      }
      if (mount & (DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER))
        e.flags |= SILT_FLAG_MOUNT;
      else if (err == 0)
        walk = 1;
    } else {
      e.kind = type == VREG   ? SILT_KIND_FILE
               : type == VLNK ? SILT_KIND_SYMLINK
                              : SILT_KIND_OTHER;
      uint32_t links = 1;
      if (ret.fileattr & ATTR_FILE_LINKCOUNT) {
        memcpy(&links, f, 4);
        f += 4;
      }
      int64_t alloc = 0;
      if (ret.fileattr & ATTR_FILE_ALLOCSIZE) {
        memcpy(&alloc, f, 8);
        f += 8;
      }
      // Hard links split their blocks evenly, so totals are exact when every
      // link is inside the scan and the answer never depends on scan order.
      if (links > 1 && e.kind == SILT_KIND_FILE) {
        e.flags |= SILT_FLAG_HARDLINK;
        alloc /= links;
      }
      e.size = alloc;
      e.aux = mtime.tv_sec > 0 ? (uint32_t)mtime.tv_sec : 0;
    }

    batch_grow(b);
    GROW(b->names, b->nlen, b->ncap, name_len);
    memcpy(b->names + b->nlen, name, name_len);
    b->nlen += name_len;
    b->walk[b->n] = walk;
    b->ids[b->n] = file_id;
    b->ents[b->n++] = e;
  }
  return errors;
}

typedef struct listing {
  int open_error; // errno from open(), 0 if the folder opened
  int read_error; // errno that ended the listing early, 0 if it completed
} listing;

static listing list_dir(batch *b, const char *path, bool root) {
  listing r = {0, 0};
  int flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC;
  if (!root) flags |= O_NOFOLLOW;
  int fd = open(path, flags);
  if (fd < 0) {
    r.open_error = errno;
    return r;
  }
  for (;;) {
    int n = getattrlistbulk(fd, &bulk_attrs, b->buf, BULK_BUFFER, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      r.read_error = errno;
      break;
    }
    if (n == 0) break;
    parse(b, b->buf, n);
  }
  close(fd);
  return r;
}

// MARK: Commit

#define SLOT_EMPTY SILT_NONE
#define SLOT_CLAIMED (SILT_NONE - 1)

static uint32_t hash_name(const uint8_t *s, uint32_t len) {
  uint32_t h = 2166136261u;
  for (uint32_t i = 0; i < len; i++) h = (h ^ s[i]) * 16777619u;
  return h;
}

static bool same_name(const silt_tree *t, const silt_entry *o,
                      const uint8_t *name, uint16_t len) {
  return o->name_len == len && memcmp(silt_name_ptr(t, o->name), name, len) == 0;
}

// Fast path for a refresh where nothing was added, removed, or renamed: update
// sizes and times in place, so the old run stays the live one and nothing new
// is allocated. Returns false if the listing doesn't qualify. Lock held.
static bool commit_in_place(silt_tree *t, uint32_t dir_id, batch *b,
                            int64_t *total, int64_t *items, uint32_t *newest) {
  const silt_dir *d = silt_dir_at(t, dir_id);
  if (d->count != b->n) return false;
  for (uint32_t k = 0; k < b->n; k++) {
    const silt_entry *o = silt_entry_at(t, d->first + k);
    const silt_entry *e = &b->ents[k];
    if (o->kind != e->kind || (o->flags & SILT_FLAG_REMOVED) ||
        !same_name(t, o, b->names + e->name, e->name_len))
      return false;
    if (o->kind == SILT_KIND_DIR) {
      const silt_dir *od = silt_dir_at(t, o->aux);
      bool was_blocked = o->flags & (SILT_FLAG_DENIED | SILT_FLAG_MOUNT);
      bool now_blocked = e->flags & (SILT_FLAG_DENIED | SILT_FLAG_MOUNT);
      if (od->file_id != b->ids[k] || was_blocked != now_blocked) return false;
    }
  }
  *total = 0;
  *items = b->n;
  *newest = 0;
  for (uint32_t k = 0; k < b->n; k++) {
    silt_entry *o = silt_entry_at(t, d->first + k);
    const silt_entry *e = &b->ents[k];
    if (o->kind == SILT_KIND_DIR) {
      const silt_dir *od = silt_dir_at(t, o->aux);
      o->flags = (uint8_t)((e->flags & ~SILT_FLAG_DENIED) |
                           (o->flags & SILT_FLAG_DENIED));
      *items += od->items;
      if (od->newest > *newest) *newest = od->newest;
    } else {
      o->size = e->size;
      o->aux = e->aux;
      o->flags = e->flags;
      if (e->aux > *newest) *newest = e->aux;
    }
    *total += o->size;
  }
  return true;
}

// Installs the batch as the new contents of `w->dir`. Lock held.
static void commit(silt_scanner *s, const work *w, batch *b, listing r) {
  silt_tree *t = s->tree;
  silt_internal *in = silt_int(t);
  b->nnew = 0;
  if (w->dir >= t->dir_count) return;
  silt_dir *d = silt_dir_at(t, w->dir);
  const bool deep = w->deep || (d->state & SILT_DIR_DEEP);
  d->state &= ~SILT_DIR_DEEP;
  if (!tree_dir_live(t, w->dir)) return; // its pending was already dropped

  const bool relisted = (d->state & SILT_DIR_LISTED) != 0;
  const uint32_t dir_entry = d->entry;
  silt_entry *de = silt_entry_at(t, dir_entry);
  const uint32_t old_first = d->first, old_count = d->count;
  const uint32_t old_newest = d->newest;
  const bool incomplete = r.read_error != 0;
  const bool denied = r.open_error == EACCES || r.open_error == EPERM ||
                      (b->n == 0 && (r.read_error == EACCES || r.read_error == EPERM));

  int64_t total = 0, items = 0;
  uint32_t newest = 0;
  int64_t pending_delta = -1; // this listing is done

  if (relisted && (incomplete || (r.open_error && !denied && r.open_error != ENOENT &&
                                  r.open_error != ENOTDIR))) {
    // A refresh that failed partway (I/O error, stale handle): keep what we
    // had rather than replace it with a truncated listing.
    d->state |= SILT_DIR_INCOMPLETE;
    tree_propagate(t, w->dir, 0, 0, 0, pending_delta);
    t->generation++;
    return;
  }

  if (tree_is_guarded(t, w->path)) {
    for (uint32_t i = 0; i < b->n; i++) {
      if (b->walk[i]) {
        b->walk[i] = 0;
        b->ents[i].flags |= SILT_FLAG_DENIED;
      }
    }
  }

  if (relisted && !deep && !denied &&
      commit_in_place(t, w->dir, b, &total, &items, &newest)) {
    goto finish;
  }

  {
    const uint32_t n = b->n;
    // Old folders by name, so a shallow refresh keeps their scanned subtrees.
    uint32_t *map = NULL;
    uint32_t mask = 0;
    if (relisted && !deep && old_count > 0) {
      uint32_t size = 16;
      while (size < old_count * 2) size *= 2;
      mask = size - 1;
      map = malloc(size * sizeof *map);
      if (!map) abort();
      memset(map, 0xFF, size * sizeof *map);
      for (uint32_t i = old_first; i < old_first + old_count; i++) {
        const silt_entry *e = silt_entry_at(t, i);
        if (e->kind != SILT_KIND_DIR || (e->flags & SILT_FLAG_REMOVED)) continue;
        uint32_t h = hash_name(silt_name_ptr(t, e->name), e->name_len) & mask;
        while (map[h] != SLOT_EMPTY) h = (h + 1) & mask;
        map[h] = i;
      }
    }

    tree_reserve_entries(t, n);
    const uint32_t base = t->entry_count;
    bool contiguous = false;
    uint32_t name_base = tree_put_names(t, b->names, b->nlen, &contiguous);
    items = n;

    if (n > b->newcap) {
      b->newcap = n;
      b->new_dirs = xrealloc(b->new_dirs, n * sizeof *b->new_dirs);
      b->new_ids = xrealloc(b->new_ids, n * sizeof *b->new_ids);
    }
    for (uint32_t i = 0; i < n; i++) {
      silt_entry e = b->ents[i];
      const uint8_t *local_name = b->names + e.name;
      e.name = contiguous ? name_base + e.name
                          : tree_put_name(t, local_name, e.name_len);
      e.parent = w->dir;

      if (e.kind == SILT_KIND_DIR) {
        uint32_t reused = SILT_NONE;
        if (map) {
          uint32_t h = hash_name(local_name, e.name_len) & mask;
          for (; map[h] != SLOT_EMPTY; h = (h + 1) & mask) {
            if (map[h] == SLOT_CLAIMED) continue;
            const silt_entry *o = silt_entry_at(t, map[h]);
            if (same_name(t, o, local_name, e.name_len)) {
              const silt_dir *od = silt_dir_at(t, o->aux);
              // Same name is not enough: it must be the same folder, and one
              // we could actually read last time.
              if (od->file_id == b->ids[i] &&
                  !(o->flags & (SILT_FLAG_DENIED | SILT_FLAG_MOUNT)) &&
                  !(e.flags & SILT_FLAG_MOUNT))
                reused = map[h];
              map[h] = SLOT_CLAIMED; // keeps probe chains intact
              break;
            }
          }
        }
        if (reused != SILT_NONE) {
          const silt_entry *o = silt_entry_at(t, reused);
          silt_dir *od = silt_dir_at(t, o->aux);
          e.size = o->size;
          e.aux = o->aux;
          od->entry = base + i;
          items += od->items;
          if (od->newest > newest) newest = od->newest;
        } else {
          bool walk = b->walk[i];
          e.aux = tree_new_dir(t, base + i, b->ids[i], walk ? 1 : 0,
                               walk ? SILT_DIR_QUEUED : SILT_DIR_LISTED);
          if (walk) {
            b->new_dirs[b->nnew] = i;
            b->new_ids[b->nnew++] = e.aux;
            pending_delta++;
          }
        }
      } else if (e.aux > newest) {
        newest = e.aux;
      }
      total += e.size;
      *silt_entry_at(t, base + i) = e;
    }

    // Folders that disappeared (or every folder, on a deep rescan) drop out.
    if (relisted) {
      for (uint32_t i = old_first; i < old_first + old_count; i++) {
        const silt_entry *e = silt_entry_at(t, i);
        if (e->kind != SILT_KIND_DIR || (e->flags & SILT_FLAG_REMOVED)) continue;
        silt_dir *od = silt_dir_at(t, e->aux);
        if (od->entry != i) continue; // reused above, now lives in the new run
        od->state |= SILT_DIR_DETACHED;
        pending_delta -= od->pending;
      }
    }
    free(map);

    t->entry_count = base + n;
    d = silt_dir_at(t, w->dir);
    d->first = base;
    d->count = n;
  }

finish:
  d->state |= SILT_DIR_LISTED;
  if (incomplete) d->state |= SILT_DIR_INCOMPLETE;
  else d->state &= ~SILT_DIR_INCOMPLETE;
  de->flags = (uint8_t)((de->flags & ~SILT_FLAG_DENIED) |
                        (denied || incomplete ? SILT_FLAG_DENIED : 0));
  if (denied && !relisted) in->denied++;
  in->dirs_listed++;

  int64_t size_delta = total - de->size;
  int64_t items_delta = items - (int64_t)d->items;
  d->newest = newest;
  tree_propagate(t, w->dir, size_delta, items_delta, newest, pending_delta);
  if (relisted && newest < old_newest) tree_recompute_newest(t, de->parent);
  t->generation++;
}

// MARK: Workers

static void enqueue_locked(silt_scanner *s, work w) {
  GROW(s->q, s->qcount, s->qcap, 1);
  s->q[s->qcount++] = w;
}

static void process(silt_scanner *s, const work *w, batch *b) {
  b->n = 0;
  b->nlen = 0;
  b->nout = 0;
  // From here on, a change to this folder must queue a fresh listing rather
  // than fold into this one, which may already have read past it.
  silt_tree_lock(s->tree);
  if (w->dir < s->tree->dir_count) silt_dir_at(s->tree, w->dir)->state &= ~SILT_DIR_QUEUED;
  silt_tree_unlock(s->tree);
  listing r = list_dir(b, w->path, w->dir == 0);

  silt_tree_lock(s->tree);
  commit(s, w, b, r);
  silt_tree_unlock(s->tree);

  // Build child paths outside the lock.
  size_t plen = strlen(w->path);
  bool slash = !(plen == 1 && w->path[0] == '/');
  GROW(b->out, 0, b->outcap, b->nnew);
  for (uint32_t k = 0; k < b->nnew; k++) {
    const silt_entry *e = &b->ents[b->new_dirs[k]];
    size_t len = plen + (slash ? 1 : 0) + e->name_len;
    char *path = malloc(len + 1);
    if (!path) abort();
    memcpy(path, w->path, plen);
    size_t o = plen;
    if (slash) path[o++] = '/';
    memcpy(path + o, b->names + e->name, e->name_len);
    path[len] = 0;
    b->out[b->nout++] = (work){.path = path, .dir = b->new_ids[k], .deep = false};
  }
}

static void *worker_main(void *arg) {
  silt_scanner *s = arg;
  batch b;
  memset(&b, 0, sizeof b);
  b.buf = malloc(BULK_BUFFER);
  if (!b.buf) abort();

  pthread_mutex_lock(&s->qlock);
  for (;;) {
    while (s->qcount == 0 && !s->shutdown)
      pthread_cond_wait(&s->qcond, &s->qlock);
    if (s->shutdown) break;
    work w = s->q[--s->qcount];
    s->active++;
    pthread_mutex_unlock(&s->qlock);

    process(s, &w, &b);
    free(w.path);

    pthread_mutex_lock(&s->qlock);
    s->active--;
    if (!s->cancelled) {
      for (uint32_t k = 0; k < b.nout; k++) enqueue_locked(s, b.out[k]);
      if (b.nout > 1) pthread_cond_broadcast(&s->qcond);
    } else {
      for (uint32_t k = 0; k < b.nout; k++) free(b.out[k].path);
    }
    if (s->qcount == 0 && s->active == 0) {
      if (s->scan_end == 0) s->scan_end = now_ns();
      pthread_cond_broadcast(&s->idle_cond);
    }
  }
  pthread_mutex_unlock(&s->qlock);

  free(b.ents);
  free(b.ids);
  free(b.walk);
  free(b.names);
  free(b.new_dirs);
  free(b.new_ids);
  free(b.out);
  free(b.buf);
  return NULL;
}

// MARK: Public API

static silt_scanner *scanner_create(silt_tree *t, int threads, bool scan_root);

silt_scanner *silt_scanner_start(silt_tree *t, int threads) {
  return scanner_create(t, threads, true);
}

silt_scanner *silt_scanner_start_idle(silt_tree *t, int threads) {
  return scanner_create(t, threads, false);
}

static silt_scanner *scanner_create(silt_tree *t, int threads, bool scan_root) {
  // Never pull iCloud placeholders down just because we looked at them.
  setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                 IOPOL_MATERIALIZE_DATALESS_FILES_OFF);

  silt_scanner *s = calloc(1, sizeof *s);
  if (!s) abort();
  s->tree = t;
  pthread_mutex_init(&s->qlock, NULL);
  pthread_cond_init(&s->qcond, NULL);
  pthread_cond_init(&s->idle_cond, NULL);
  s->nthreads = threads < 1 ? 1 : threads;
  s->threads = calloc((size_t)s->nthreads, sizeof *s->threads);
  if (!s->threads) abort();

  s->scan_start = now_ns();
  if (scan_root) {
    char path[4096];
    silt_tree_lock(t);
    silt_path(t, 0, path, sizeof path);
    silt_tree_unlock(t);
    enqueue_locked(s, (work){.path = strdup(path), .dir = 0, .deep = false});
  } else {
    s->scan_end = s->scan_start;
  }

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INITIATED, 0);
  for (int i = 0; i < s->nthreads; i++)
    pthread_create(&s->threads[i], &attr, worker_main, s);
  pthread_attr_destroy(&attr);
  return s;
}

void silt_scanner_progress(silt_scanner *s, silt_progress *out) {
  silt_tree *t = s->tree;
  silt_tree_lock(t);
  const silt_entry *root = silt_entry_at(t, 0);
  const silt_dir *rd = silt_dir_at(t, root->aux);
  out->bytes = (uint64_t)root->size;
  out->dirs = silt_int(t)->dirs_listed;
  out->files = rd->items;
  out->denied = silt_int(t)->denied;
  silt_tree_unlock(t);

  pthread_mutex_lock(&s->qlock);
  out->queued = s->qcount + s->active;
  out->active = s->active;
  out->idle = s->qcount == 0 && s->active == 0;
  uint64_t end = s->scan_end ? s->scan_end : now_ns();
  out->elapsed = (double)(end - s->scan_start) / 1e9;
  out->finished = s->scan_end ? out->elapsed : 0;
  pthread_mutex_unlock(&s->qlock);
}

void silt_scanner_cancel(silt_scanner *s) {
  pthread_mutex_lock(&s->qlock);
  s->cancelled = true;
  for (uint32_t i = 0; i < s->qcount; i++) free(s->q[i].path);
  s->qcount = 0;
  if (s->active == 0) pthread_cond_broadcast(&s->idle_cond);
  pthread_mutex_unlock(&s->qlock);
}

void silt_scanner_wait_idle(silt_scanner *s) {
  pthread_mutex_lock(&s->qlock);
  while (s->qcount > 0 || s->active > 0)
    pthread_cond_wait(&s->idle_cond, &s->qlock);
  pthread_mutex_unlock(&s->qlock);
}

void silt_scanner_destroy(silt_scanner *s) {
  if (!s) return;
  silt_scanner_cancel(s);
  pthread_mutex_lock(&s->qlock);
  s->shutdown = true;
  pthread_cond_broadcast(&s->qcond);
  pthread_mutex_unlock(&s->qlock);
  for (int i = 0; i < s->nthreads; i++) pthread_join(s->threads[i], NULL);
  free(s->threads);
  free(s->q);
  pthread_mutex_destroy(&s->qlock);
  pthread_cond_destroy(&s->qcond);
  pthread_cond_destroy(&s->idle_cond);
  free(s);
}

void silt_scanner_refresh(silt_scanner *s, uint32_t dir, bool deep) {
  pthread_mutex_lock(&s->qlock);
  bool cancelled = s->cancelled;
  pthread_mutex_unlock(&s->qlock);
  if (cancelled) return;

  silt_tree *t = s->tree;
  char path[4096];
  silt_tree_lock(t);
  if (!tree_dir_live(t, dir)) {
    silt_tree_unlock(t);
    return;
  }
  silt_dir *d = silt_dir_at(t, dir);
  const silt_entry *e = silt_entry_at(t, d->entry);
  if (d->state & SILT_DIR_QUEUED) {
    if (deep) d->state |= SILT_DIR_DEEP; // upgrade the pending listing
    silt_tree_unlock(t);
    return;
  }
  if ((e->flags & SILT_FLAG_MOUNT) || silt_path(t, d->entry, path, sizeof path) == 0) {
    silt_tree_unlock(t);
    return;
  }
  d->state |= SILT_DIR_QUEUED;
  tree_propagate(t, dir, 0, 0, 0, 1);
  t->generation++;
  silt_tree_unlock(t);

  pthread_mutex_lock(&s->qlock);
  enqueue_locked(s, (work){.path = strdup(path), .dir = dir, .deep = deep});
  pthread_cond_signal(&s->qcond);
  pthread_mutex_unlock(&s->qlock);
}
