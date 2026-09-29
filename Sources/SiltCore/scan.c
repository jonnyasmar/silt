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
  uint64_t *ids;   // per entry: inode
  uint8_t *walk;   // per entry: 1 if it is a folder to descend into
  uint32_t *match; // per entry: the old entry it updates, or SILT_NONE
  uint32_t *reuse; // per newcomer: a name offset the folder already holds
  uint32_t n, cap;
  uint8_t *names;
  uint32_t nlen, ncap;
  uint32_t *new_dirs; // batch index of each folder to list next
  uint32_t *new_ids;  // ...its dir id
  uint8_t *new_deep;  // ...and whether to revalidate beneath it
  uint32_t nnew, newcap;
  // Partial APFS clones: their private size is fetched after the listing.
  struct partial { uint32_t index; uint32_t links; int64_t alloc; } *partials;
  uint32_t npartial, partialcap;
  work *out;
  uint32_t nout, outcap;
  bool followup;
  bool followup_deep;
  char *buf;
  // A relisting's view of the old run: its entries by name, and which of
  // them the new listing still has.
  uint32_t *map;
  uint32_t mapcap, mask;
  uint8_t *hit;
  uint32_t hitcap;
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

// Working buffers that can grow big (the queue, a huge folder's batch) come
// straight from the kernel above a threshold, so freeing them really gives
// the memory back: malloc keeps large freed blocks, still counted against
// the app. Callers pass the size they asked for before.
#define BIG_BUFFER (64u << 10)

static void buf_free(void *p, size_t bytes) {
  if (!p) return;
  if (bytes < BIG_BUFFER) free(p);
  else tree_chunk_free(p, bytes);
}

static void *buf_resize(void *p, size_t old_bytes, size_t new_bytes) {
  if (new_bytes < BIG_BUFFER && old_bytes < BIG_BUFFER) {
    void *q = realloc(p, new_bytes);
    if (!q) abort();
    return q;
  }
  void *q = new_bytes < BIG_BUFFER ? malloc(new_bytes) : tree_chunk_alloc(new_bytes);
  if (!q) abort();
  if (p) {
    memcpy(q, p, old_bytes < new_bytes ? old_bytes : new_bytes);
    buf_free(p, old_bytes);
  }
  return q;
}

#define GROW(ptr, count, cap, extra)                                           \
  do {                                                                         \
    if ((count) + (extra) > (cap)) {                                           \
      uint32_t c_ = (cap) ? (cap) : 64;                                        \
      while ((count) + (extra) > c_) c_ *= 2;                                  \
      (ptr) = buf_resize((ptr), (size_t)(cap) * sizeof(*(ptr)),                \
                         (size_t)c_ * sizeof(*(ptr)));                         \
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
    // Clone tracking (APFS). Packed after the file attributes.
    .forkattr = ATTR_CMNEXT_EXT_FLAGS | ATTR_CMNEXT_CLONE_REFCNT,
};

// The same, for file systems that reject extended attributes.
static struct attrlist plain_attrs = {
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
  const size_t was = b->cap;
  b->ents = buf_resize(b->ents, was * sizeof *b->ents, cap * sizeof *b->ents);
  b->ids = buf_resize(b->ids, was * sizeof *b->ids, cap * sizeof *b->ids);
  b->walk = buf_resize(b->walk, was, cap);
  b->match = buf_resize(b->match, was * sizeof *b->match, cap * sizeof *b->match);
  b->reuse = buf_resize(b->reuse, was * sizeof *b->reuse, cap * sizeof *b->reuse);
  b->cap = cap;
}

static void batch_free(batch *b) {
  buf_free(b->ents, (size_t)b->cap * sizeof *b->ents);
  buf_free(b->ids, (size_t)b->cap * sizeof *b->ids);
  buf_free(b->walk, b->cap);
  buf_free(b->match, (size_t)b->cap * sizeof *b->match);
  buf_free(b->reuse, (size_t)b->cap * sizeof *b->reuse);
  buf_free(b->names, b->ncap);
  buf_free(b->new_dirs, (size_t)b->newcap * sizeof *b->new_dirs);
  buf_free(b->new_ids, (size_t)b->newcap * sizeof *b->new_ids);
  buf_free(b->new_deep, b->newcap);
  buf_free(b->partials, (size_t)b->partialcap * sizeof *b->partials);
  buf_free(b->out, (size_t)b->outcap * sizeof *b->out);
  buf_free(b->map, (size_t)b->mapcap * sizeof *b->map);
  buf_free(b->hit, b->hitcap);
}

// After listing a big folder, give its buffers back rather than keep them
// for the life of the worker: with dozens of workers, each holding on to the
// largest folder it ever saw adds up. The bulk read buffer stays.
#define TRIM_ENTRIES 8192u
static void batch_trim(batch *b) {
  if (b->cap <= TRIM_ENTRIES && b->ncap <= TRIM_ENTRIES * 64 && b->newcap <= TRIM_ENTRIES &&
      b->mapcap <= TRIM_ENTRIES * 4 && b->hitcap <= TRIM_ENTRIES && b->outcap <= TRIM_ENTRIES &&
      b->partialcap <= TRIM_ENTRIES)
    return;
  char *buf = b->buf;
  batch_free(b);
  memset(b, 0, sizeof *b);
  b->buf = buf;
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
      uint64_t ext = 0;
      uint32_t clones = 0;
      if (ret.forkattr & ATTR_CMNEXT_EXT_FLAGS) {
        memcpy(&ext, f, 8);
        f += 8;
      }
      if (ret.forkattr & ATTR_CMNEXT_CLONE_REFCNT) {
        memcpy(&clones, f, 4);
        f += 4;
      }
      // APFS clones share blocks, yet each reports its full allocation.
      // Split shared blocks between the files sharing them, like hard links,
      // so a folder of clones counts what the disk actually stores.
      if (ext & EF_MAY_SHARE_BLOCKS && e.kind == SILT_KIND_FILE) {
        e.flags |= SILT_FLAG_CLONE;
        if (ext & EF_SHARES_ALL_BLOCKS) {
          if (clones > 1) alloc /= clones;
        } else {
          GROW(b->partials, b->npartial, b->partialcap, 1);
          b->partials[b->npartial++] = (struct partial){b->n, links, alloc};
        }
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
  b->npartial = 0;
  bool extended = true;
  for (;;) {
    int n = extended ? getattrlistbulk(fd, &bulk_attrs, b->buf, BULK_BUFFER, FSOPT_ATTR_CMN_EXTENDED)
                     : getattrlistbulk(fd, &plain_attrs, b->buf, BULK_BUFFER, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EINVAL && extended && b->n == 0) {
        extended = false; // this file system doesn't do clone attributes
        continue;
      }
      r.read_error = errno;
      break;
    }
    if (n == 0) break;
    parse(b, b->buf, n);
  }
  // A partial clone shares only some blocks: count what's its own, plus half
  // of what it shares. APFS doesn't say how many files share those blocks, so
  // "half" is exact for the common case (a clone and its source) and an
  // overcount when several partial clones share the same extents.
  for (uint32_t k = 0; k < b->npartial; k++) {
    struct partial pc = b->partials[k];
    silt_entry *e = &b->ents[pc.index];
    char name[1024];
    if (e->name_len >= sizeof name) continue;
    memcpy(name, b->names + e->name, e->name_len);
    name[e->name_len] = 0;
    struct attrlist al = {.bitmapcount = ATTR_BIT_MAP_COUNT,
                          .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_FILEID,
                          .forkattr = ATTR_CMNEXT_PRIVATESIZE};
    struct __attribute__((packed)) {
      uint32_t len;
      attribute_set_t ret;
      uint64_t file_id;
      int64_t priv;
    } out;
    memset(&out, 0, sizeof out);
    if (getattrlistat(fd, name, &al, &out, sizeof out, FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW) != 0 ||
        !(out.ret.commonattr & ATTR_CMN_FILEID) ||
        !(out.ret.forkattr & ATTR_CMNEXT_PRIVATESIZE) ||
        out.file_id != b->ids[pc.index])
      continue;
    int64_t priv = out.priv < pc.alloc ? out.priv : pc.alloc;
    int64_t size = priv + (pc.alloc - priv) / 2;
    e->size = pc.links > 1 ? size / pc.links : size;
  }
  close(fd);
  return r;
}

// MARK: Commit

#define SLOT_EMPTY SILT_NONE

static uint32_t hash_name(const uint8_t *s, uint32_t len) {
  uint32_t h = 2166136261u;
  for (uint32_t i = 0; i < len; i++) h = (h ^ s[i]) * 16777619u;
  return h;
}

static bool same_name(const silt_tree *t, const silt_entry *o,
                      const uint8_t *name, uint16_t len) {
  return o->name_len == len && memcmp(silt_name_ptr(t, o->name), name, len) == 0;
}

static bool blocked(uint8_t flags) {
  return (flags & (SILT_FLAG_DENIED | SILT_FLAG_MOUNT)) != 0;
}

// Room a folder gets when it outgrows its run, so the next few arrivals land
// in place instead of moving the whole folder again. Small folders get very
// little: there can be millions of them.
static uint32_t spare_for(uint32_t n) { return n / 4 + 2; }

// Whether old entry `o` can stand for batch entry `e` (inode `id`) in place:
// same kind, and for folders the same folder, just as readable as before.
// Lock held.
static bool compatible(const silt_tree *t, const silt_entry *o,
                       const silt_entry *e, uint64_t id) {
  if (o->kind != e->kind) return false;
  if (o->kind != SILT_KIND_DIR) return true;
  const silt_dir *od = silt_dir_at(t, o->aux);
  return od->file_id == id && blocked(o->flags) == blocked(e->flags);
}

// Indexes the old run by name, removed entries included: their names can be
// reused by files that come back. Lock held.
static void index_old(const silt_tree *t, batch *b, uint32_t first, uint32_t count) {
  uint64_t size = 16;
  while (size < (uint64_t)count * 2) size *= 2;
  if (size > b->mapcap) {
    b->map = buf_resize(b->map, (size_t)b->mapcap * sizeof *b->map, (size_t)size * sizeof *b->map);
    b->mapcap = (uint32_t)size;
  }
  b->mask = (uint32_t)size - 1;
  memset(b->map, 0xFF, (size_t)size * sizeof *b->map);
  for (uint32_t i = first; i < first + count; i++) {
    const silt_entry *e = silt_entry_at(t, i);
    uint32_t h = hash_name(silt_name_ptr(t, e->name), e->name_len) & b->mask;
    while (b->map[h] != SLOT_EMPTY) h = (h + 1) & b->mask;
    b->map[h] = i;
  }
}

typedef struct old_match {
  uint32_t live; // the current entry with this name, or SILT_NONE
  uint32_t name; // an arena offset already holding the name, or SILT_NONE
} old_match;

// What the old run has under this name. Live names are unique within a
// folder; removed entries may repeat one. Lock held; the old run is indexed.
static old_match find_old(const silt_tree *t, const batch *b, const uint8_t *name,
                          uint16_t len) {
  old_match m = {SILT_NONE, SILT_NONE};
  for (uint32_t h = hash_name(name, len) & b->mask; b->map[h] != SLOT_EMPTY;
       h = (h + 1) & b->mask) {
    const silt_entry *o = silt_entry_at(t, b->map[h]);
    if (!same_name(t, o, name, len)) continue;
    m.name = o->name;
    if (!(o->flags & SILT_FLAG_REMOVED)) {
      m.live = b->map[h];
      break;
    }
  }
  return m;
}

// Fast path for a refresh where nothing was added, removed, or renamed and
// the order held: update sizes and times in place. Returns false if the
// listing doesn't qualify. Lock held.
static bool commit_in_place(silt_tree *t, uint32_t dir_id, batch *b,
                            int64_t *total, int64_t *items, uint32_t *newest) {
  const silt_dir *d = silt_dir_at(t, dir_id);
  if (d->count != b->n) return false;
  for (uint32_t k = 0; k < b->n; k++) {
    const silt_entry *o = silt_entry_at(t, d->first + k);
    const silt_entry *e = &b->ents[k];
    if ((o->flags & SILT_FLAG_REMOVED) || !same_name(t, o, b->names + e->name, e->name_len) ||
        !compatible(t, o, e, b->ids[k]))
      return false;
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

static void n_alloc_new_dirs(batch *b, uint32_t n) {
  if (n <= b->newcap) return;
  b->new_dirs = buf_resize(b->new_dirs, (size_t)b->newcap * sizeof *b->new_dirs, (size_t)n * sizeof *b->new_dirs);
  b->new_ids = buf_resize(b->new_ids, (size_t)b->newcap * sizeof *b->new_ids, (size_t)n * sizeof *b->new_ids);
  b->new_deep = buf_resize(b->new_deep, b->newcap, n);
  b->newcap = n;
}

// Queues an in-place re-listing of subfolder `dir` (batch index `i`) as part
// of a deep refresh. Returns the pending units added to the parent's chain.
// Lock held.
static int64_t revalidate(silt_tree *t, batch *b, uint32_t dir, uint32_t i) {
  silt_dir *od = silt_dir_at(t, dir);
  if (od->state & SILT_DIR_QUEUED) {
    od->state |= SILT_DIR_DEEP; // already waiting: just make it thorough
    return 0;
  }
  if (od->state & SILT_DIR_ACTIVE) {
    od->state |= SILT_DIR_DIRTY | SILT_DIR_DEEP;
    return 0;
  }
  od->state |= SILT_DIR_QUEUED;
  od->pending += 1;
  b->new_dirs[b->nnew] = i;
  b->new_ids[b->nnew] = dir;
  b->new_deep[b->nnew++] = 1;
  return 1;
}

// Queues the first listing of a new subfolder (batch index `i`). Lock held.
static void queue_new(batch *b, uint32_t dir, uint32_t i) {
  b->new_dirs[b->nnew] = i;
  b->new_ids[b->nnew] = dir;
  b->new_deep[b->nnew++] = 0;
}

// Completes the active unit and emits at most one replacement. Lock held;
// the worker transfers the emitted item to the queue after releasing it.
static void finish_listing(silt_tree *t, const work *w, batch *b) {
  if (w->dir >= t->dir_count) return;
  silt_dir *d = silt_dir_at(t, w->dir);
  d->state &= ~SILT_DIR_ACTIVE;
  if (!(d->state & SILT_DIR_DIRTY)) return;
  d->state &= ~SILT_DIR_DIRTY;
  if (!tree_dir_live(t, w->dir)) {
    d->state &= ~SILT_DIR_DEEP;
    return;
  }
  b->followup = true;
  b->followup_deep = (d->state & SILT_DIR_DEEP) != 0;
  d->state &= ~SILT_DIR_DEEP;
  d->state |= SILT_DIR_QUEUED;
  tree_propagate(t, w->dir, 0, 0, 0, 1);
}

typedef struct tally {
  int64_t total;   // bytes of the folder's live children
  int64_t items;   // its descendants
  uint32_t newest; // newest mtime among them
  int64_t pending; // change to the folder's pending count
} tally;

// A relisting that fits the folder's run: survivors are updated where they
// are (so their indices stay valid), newcomers take the spare room at the
// end, and the missing are flagged REMOVED. Returns false, changing nothing,
// if the newcomers don't fit or the run would end up mostly holes.
// Lock held; the old run is indexed.
static bool commit_diff(silt_tree *t, const work *w, batch *b, bool deep, tally *out) {
  silt_dir *d = silt_dir_at(t, w->dir);
  const uint32_t first = d->first, count = d->count, n = b->n;
  if (count > b->hitcap) {
    b->hit = buf_resize(b->hit, b->hitcap, count);
    b->hitcap = count;
  }
  memset(b->hit, 0, count);
  uint32_t added = 0;
  for (uint32_t k = 0; k < n; k++) {
    const silt_entry *e = &b->ents[k];
    old_match m = find_old(t, b, b->names + e->name, e->name_len);
    if (m.live != SILT_NONE && compatible(t, silt_entry_at(t, m.live), e, b->ids[k])) {
      b->match[k] = m.live;
      b->hit[m.live - first] = 1;
    } else {
      b->match[k] = SILT_NONE;
      b->reuse[k] = m.name;
      added++;
    }
  }
  const uint64_t after = (uint64_t)count + added;
  if (after > d->cap) return false;
  if (after > 64 && (uint64_t)n * 2 < after) return false; // compact instead

  bool changed = added > 0;
  for (uint32_t i = first; i < first + count; i++) {
    silt_entry *o = silt_entry_at(t, i);
    if ((o->flags & SILT_FLAG_REMOVED) || b->hit[i - first]) continue;
    o->flags |= SILT_FLAG_REMOVED;
    changed = true;
    if (o->kind == SILT_KIND_DIR) {
      silt_dir *od = silt_dir_at(t, o->aux);
      if (od->entry == i && !(od->state & SILT_DIR_DETACHED)) {
        out->pending -= od->pending;
        tree_detach(t, o->aux);
      }
    }
  }

  out->total = 0;
  out->items = n;
  out->newest = 0;
  for (uint32_t k = 0; k < n; k++) {
    const silt_entry *e = &b->ents[k];
    if (b->match[k] != SILT_NONE) {
      silt_entry *o = silt_entry_at(t, b->match[k]);
      if (o->kind == SILT_KIND_DIR) {
        const silt_dir *od = silt_dir_at(t, o->aux);
        o->flags = (uint8_t)((e->flags & ~SILT_FLAG_DENIED) |
                             (o->flags & SILT_FLAG_DENIED));
        out->items += od->items;
        if (od->newest > out->newest) out->newest = od->newest;
        if (deep && b->walk[k]) out->pending += revalidate(t, b, o->aux, k);
      } else {
        o->size = e->size;
        o->aux = e->aux;
        o->flags = e->flags;
        if (e->aux > out->newest) out->newest = e->aux;
      }
      out->total += o->size;
      continue;
    }
    const uint32_t j = first + d->count;
    silt_entry ne = *e;
    ne.name = b->reuse[k] != SILT_NONE ? b->reuse[k] : tree_put_name(t, b->names + e->name, e->name_len);
    ne.parent = w->dir;
    if (ne.kind == SILT_KIND_DIR) {
      const bool walk = b->walk[k];
      ne.aux = tree_new_dir(t, j, b->ids[k], walk ? 1 : 0,
                            walk ? SILT_DIR_QUEUED : SILT_DIR_LISTED);
      if (walk) {
        queue_new(b, ne.aux, k);
        out->pending++;
      }
    } else if (ne.aux > out->newest) {
      out->newest = ne.aux;
    }
    *silt_entry_at(t, j) = ne;
    d->count++;
    out->total += ne.size;
  }
  if (changed) d->version++;
  return true;
}

// Writes the listing as a fresh run. A folder listed before keeps its
// surviving subfolders (and their subtrees), reuses its names, gets spare
// room to grow into, and gives its old run back. `mapped`: the old run is
// indexed. Lock held.
static void commit_new_run(silt_tree *t, const work *w, batch *b, bool relisted,
                           bool mapped, bool deep, tally *out) {
  silt_dir *d = silt_dir_at(t, w->dir);
  const uint32_t n = b->n;
  const uint32_t old_first = d->first, old_count = d->count, old_cap = d->cap;
  const uint32_t cap = relisted && n > 0 ? n + spare_for(n) : n;

  tree_reserve_entries(t, cap);
  const uint32_t base = t->entry_count;
  bool contiguous = false;
  uint32_t name_base = mapped ? 0 : tree_put_names(t, b->names, b->nlen, &contiguous);
  out->total = 0;
  out->items = n;
  out->newest = 0;

  for (uint32_t i = 0; i < n; i++) {
    silt_entry e = b->ents[i];
    const uint8_t *local_name = b->names + e.name;
    const old_match m = mapped ? find_old(t, b, local_name, e.name_len) : (old_match){SILT_NONE, SILT_NONE};
    const silt_entry *o = m.live != SILT_NONE ? silt_entry_at(t, m.live) : NULL;
    // Names never move, so one the folder already had is shared, not copied.
    e.name = m.name != SILT_NONE ? m.name
             : contiguous        ? name_base + e.name
                                 : tree_put_name(t, local_name, e.name_len);
    e.parent = w->dir;

    if (e.kind == SILT_KIND_DIR) {
      if (o && compatible(t, o, &b->ents[i], b->ids[i])) {
        silt_dir *od = silt_dir_at(t, o->aux);
        e.size = o->size;
        e.aux = o->aux;
        e.flags = (uint8_t)((e.flags & ~SILT_FLAG_DENIED) | (o->flags & SILT_FLAG_DENIED));
        od->entry = base + i;
        out->items += od->items;
        if (od->newest > out->newest) out->newest = od->newest;
        if (deep && b->walk[i]) out->pending += revalidate(t, b, o->aux, i);
      } else {
        bool walk = b->walk[i];
        e.aux = tree_new_dir(t, base + i, b->ids[i], walk ? 1 : 0,
                             walk ? SILT_DIR_QUEUED : SILT_DIR_LISTED);
        if (walk) {
          queue_new(b, e.aux, i);
          out->pending++;
        }
      }
    } else if (e.aux > out->newest) {
      out->newest = e.aux;
    }
    out->total += e.size;
    *silt_entry_at(t, base + i) = e;
  }

  if (relisted) {
    // Folders that disappeared drop out, taking their subtrees with them.
    for (uint32_t i = old_first; i < old_first + old_count; i++) {
      const silt_entry *e = silt_entry_at(t, i);
      if (e->kind != SILT_KIND_DIR || (e->flags & SILT_FLAG_REMOVED)) continue;
      silt_dir *od = silt_dir_at(t, e->aux);
      if (od->entry != i || (od->state & SILT_DIR_DETACHED)) continue; // moved to the new run
      out->pending -= od->pending;
      tree_detach(t, e->aux);
    }
    tree_release_run(t, old_first, old_cap);
  }
  tree_claim_run(t, base, cap);
  tree_set_entry_count(t, base + cap);
  d->first = base;
  d->count = n;
  d->cap = cap;
  d->version++;
}

// Installs the batch as the new contents of `w->dir`. Lock held.
static void commit(silt_scanner *s, const work *w, batch *b, listing r) {
  silt_tree *t = s->tree;
  silt_internal *in = silt_int(t);
  b->nnew = 0;
  if (w->dir >= t->dir_count) {
    finish_listing(t, w, b);
    return;
  }
  silt_dir *d = silt_dir_at(t, w->dir);
  const bool deep = w->deep;
  if (!tree_dir_live(t, w->dir)) {
    finish_listing(t, w, b); // its pending was already dropped
    return;
  }

  const bool relisted = (d->state & SILT_DIR_LISTED) != 0;
  const uint32_t dir_entry = d->entry;
  silt_entry *de = silt_entry_at(t, dir_entry);
  const uint32_t old_newest = d->newest;
  const bool denied = r.open_error == EACCES || r.open_error == EPERM ||
                      (b->n == 0 && (r.read_error == EACCES || r.read_error == EPERM));
  // A folder that refuses to be read at all is locked, not half-read: the
  // next listing will find it the same way.
  const bool incomplete = r.read_error != 0 && !denied;

  tally tl = {.total = 0, .items = 0, .newest = 0, .pending = -1}; // this listing is done

  if (relisted && (incomplete || (r.open_error && !denied && r.open_error != ENOENT &&
                                  r.open_error != ENOTDIR))) {
    // A refresh that failed partway (I/O error, stale handle): keep what we
    // had rather than replace it with a truncated listing.
    d->state |= SILT_DIR_INCOMPLETE;
    tree_propagate(t, w->dir, 0, 0, 0, tl.pending);
    TREE_BUMP(t);
    finish_listing(t, w, b);
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

  n_alloc_new_dirs(b, b->n);
  bool mapped = false;
  if (relisted && !denied) {
    if (commit_in_place(t, w->dir, b, &tl.total, &tl.items, &tl.newest)) {
      if (deep) {
        for (uint32_t k = 0; k < d->count; k++) {
          const silt_entry *o = silt_entry_at(t, d->first + k);
          if (o->kind == SILT_KIND_DIR && !blocked(o->flags))
            tl.pending += revalidate(t, b, o->aux, k);
        }
      }
      goto finish;
    }
    if (d->count > 0) {
      index_old(t, b, d->first, d->count);
      mapped = true;
      if (commit_diff(t, w, b, deep, &tl)) goto finish;
    }
  }
  commit_new_run(t, w, b, relisted, mapped, deep, &tl);

finish:
  d = silt_dir_at(t, w->dir);
  d->state |= SILT_DIR_LISTED;
  if (incomplete) d->state |= SILT_DIR_INCOMPLETE;
  else d->state &= ~SILT_DIR_INCOMPLETE;
  d->listed_at = (uint32_t)time(NULL);
  de->flags = (uint8_t)((de->flags & ~SILT_FLAG_DENIED) |
                        (denied || incomplete ? SILT_FLAG_DENIED : 0));
  if (denied && !relisted) in->denied++;
  in->dirs_listed++;
  in->entries_listed += b->n;

  int64_t size_delta = tl.total - de->size;
  int64_t items_delta = tl.items - (int64_t)d->items;
  d->newest = tl.newest;
  tree_propagate(t, w->dir, size_delta, items_delta, tl.newest, tl.pending);
  if (relisted && tl.newest < old_newest) tree_recompute_newest(t, de->parent);
  TREE_BUMP(t);
  finish_listing(t, w, b);
}

// MARK: Workers

static void enqueue_locked(silt_scanner *s, work w) {
  GROW(s->q, s->qcount, s->qcap, 1);
  s->q[s->qcount++] = w;
}

static void process(silt_scanner *s, work *w, batch *b) {
  b->n = 0;
  b->nlen = 0;
  b->nout = 0;
  b->followup = false;
  b->followup_deep = false;
  // From here on, a change to this folder must queue a fresh listing rather
  // than fold into this one, which may already have read past it.
  silt_tree_lock(s->tree);
  if (w->dir < s->tree->dir_count) {
    silt_dir *d = silt_dir_at(s->tree, w->dir);
    d->state &= ~SILT_DIR_QUEUED;
    d->state |= SILT_DIR_ACTIVE;
    if (d->state & SILT_DIR_DEEP) {
      w->deep = true;
      d->state &= ~SILT_DIR_DEEP;
    }
  }
  silt_tree_unlock(s->tree);
  listing r = list_dir(b, w->path, w->dir == 0);

  silt_tree_lock(s->tree);
  commit(s, w, b, r);
  silt_tree_unlock(s->tree);

  // Build child paths outside the lock.
  size_t plen = strlen(w->path);
  bool slash = !(plen == 1 && w->path[0] == '/');
  GROW(b->out, b->nout, b->outcap, b->nnew + (b->followup ? 1 : 0));
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
    b->out[b->nout++] = (work){.path = path, .dir = b->new_ids[k], .deep = b->new_deep[k] != 0};
  }
  if (b->followup)
    b->out[b->nout++] =
        (work){.path = strdup(w->path), .dir = w->dir, .deep = b->followup_deep};
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
    batch_trim(&b); // its work items were just handed over
  }
  pthread_mutex_unlock(&s->qlock);

  batch_free(&b);
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
  out->listed = silt_int(t)->entries_listed;
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
  buf_free(s->q, (size_t)s->qcap * sizeof *s->q);
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
  if (d->state & SILT_DIR_ACTIVE) {
    d->state |= SILT_DIR_DIRTY;
    if (deep) d->state |= SILT_DIR_DEEP;
    silt_tree_unlock(t);
    return;
  }
  if ((e->flags & SILT_FLAG_MOUNT) || silt_path(t, d->entry, path, sizeof path) == 0) {
    silt_tree_unlock(t);
    return;
  }
  d->state |= SILT_DIR_QUEUED;
  tree_propagate(t, dir, 0, 0, 0, 1);
  TREE_BUMP(t);
  silt_tree_unlock(t);

  pthread_mutex_lock(&s->qlock);
  enqueue_locked(s, (work){.path = strdup(path), .dir = dir, .deep = deep});
  pthread_cond_signal(&s->qcond);
  pthread_mutex_unlock(&s->qlock);
}
