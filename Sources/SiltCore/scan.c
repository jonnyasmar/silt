// The scanner: worker threads draining two LIFO stacks of directory
// listings, one for urgent work (a scan, or a refresh someone is waiting on)
// and one for background work (keeping a finished scan current). Each
// listing is one getattrlistbulk() pass that parses every entry into a
// thread-local batch, then a single short critical section that appends the
// batch to the tree and pushes the size delta up the ancestor chain. Parents
// therefore show correct partial totals at every moment of the scan, which
// is what lets the UI render it live.
//
// Threads start as work arrives and exit after a few idle seconds, so an
// idle scanner costs nothing. How many urgent listings run at once adapts to
// what the storage gives back for the CPU spent (see "Controller");
// background listings run at most two at a time, at utility priority. Both
// classes' priority and ceilings can be changed, and the scanner paused, at
// any time (silt_scanner_set_pace).
//
// Every queued folder has exactly one work item: in a stack, or in a
// worker's hands. `pending` counts rely on it (one listing per queued
// folder). So a folder's state and its item always change together: whoever
// marks a folder QUEUED, or makes its pending listing URGENT, pushes or
// moves its item before letting go of the tree lock.
//
// Lock order: the queue mutex may be taken while holding the tree lock,
// never the other way around. Nothing slow (starting a thread) happens under
// the queue mutex while the tree lock is held.

#include "internal.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/qos.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/vnode.h>
#include <time.h>
#include <unistd.h>

#define BULK_BUFFER (256 * 1024)
#define PATH_BUFFER 4096
#define BACKGROUND_LIMIT 2u         // background listings running at once, by default
#define IDLE_EXIT_NS 5000000000ull // a worker idle this long exits

typedef struct work {
  uint32_t dir;
  bool deep;
  bool urgent;
} work;

typedef struct stack {
  work *items;
  uint32_t count, cap;
} stack;

// Where each background item sits in its stack, by dir id, so an upgrade to
// urgent finds it without a search. Open addressing, linear probing.
typedef struct dirmap {
  uint32_t *keys; // SILT_NONE: empty
  uint32_t *vals;
  uint32_t cap;   // a power of two, or 0
  uint32_t count;
} dirmap;

// One per thread that can exist. Fields change under the queue mutex, except
// `urgent` on a busy worker, which changes only with both locks held: the
// worker reads its own under either.
typedef struct worker {
  pthread_cond_t wake;
  bool used;    // a live thread owns this slot
  bool waiting; // on the idle list
  bool woken;   // taken off it because there's work
  bool busy;    // holds an item
  bool urgent;  // ...counted as urgent
  uint32_t dir; // ...for this folder
} worker;

// MARK: Controller
//
// Chooses how many urgent listings run at once. More threads list faster
// until the storage (or the file system's own locks) saturates; past that
// point they mostly burn kernel CPU contending with each other. The
// controller finds the knee by paired probing: it runs short windows at the
// current limit L and at an alternative, in the order L, alt, alt, L, so
// that a workload drifting steadily (big folders, then small ones) affects
// both sides equally. It compares throughput (cost units per second) and
// CPU per unit, measured on the workers' own CPU clocks:
// - it grows to L + 2 when that's at least CTL_GAIN faster and each extra
//   unit costs at most CTL_K times the CPU of an average one, and both
//   halves of the probe agree (if only they disagree, it probes again, up
//   to CTL_RETRIES times);
// - otherwise it tries L - 1, and shrinks after CTL_SHRINK_WINS probes in a
//   row where L - 1 kept up;
// - otherwise it holds for CTL_HOLD_NS, then probes again.
// On cold or network storage, CPU per unit stays flat while throughput
// rises, so the same rule keeps growing there. Background listings don't
// count, and a window where urgent work ran dry is thrown away.

// Cost units: an entry is 1. Opening, reading and committing a folder, and
// looking up a partial clone's private size, cost about this many entries'
// worth of CPU. Fitted by least squares on per-listing thread CPU over a
// ~/dev scan (1.3M entries, 136k folders) at a limit of 4: 36 us a folder,
// 12 us an entry, 57 us a partial clone.
#define UNIT_FOLDER 3
#define UNIT_PARTIAL 5

#define CTL_START 4u
#define CTL_FLOOR 2u
#define CTL_STEP 2u
#define CTL_SETTLE_NS 15000000ull  // after a change, before measuring
#define CTL_WINDOW_NS 100000000ull // one measurement window
#define CTL_HOLD_NS 2000000000ull  // between probes once settled
#define CTL_GAIN 0.08
// Tuned on ~/dev: between 6 and 10 threads each extra unit cost ~2.9 times
// an average one while wall time kept falling; past 10 it stopped falling.
#define CTL_K 3.5
#define CTL_RETRIES 2u
#define CTL_SHRINK_TOL 0.02 // L - 1 "kept up" within this much
#define CTL_SHRINK_WINS 2u

enum { CTL_IDLE, CTL_HOLD, CTL_PROBE };

typedef struct controller {
  bool fixed;             // pinned by silt_scanner_fix_limit
  uint32_t pinned;        // ...at this, as far as the pace's ceiling allows
  uint32_t base;          // the settled limit
  uint32_t lo, hi;        // its bounds
  int phase;
  bool down;              // probing base - 1 rather than base + 2
  uint32_t alt;           // the limit compared with base
  int step;               // window within the probe: base, alt, alt, base
  uint32_t wins;          // down-probes in a row where alt kept up
  uint32_t retries;       // up-probes in a row that were worth it but noisy
  uint64_t since;         // when this window's limit took effect
  uint64_t measure_from;  // when its measurement began; 0 while settling
  uint64_t hold_until;
  bool starved;           // urgent work ran out during the window
  double rate[4], cpu[4]; // per window: units per second, CPU cores
  // Credited by workers without the queue mutex.
  uint64_t units;
  uint64_t cpu_ns;
  bool measuring;
} controller;

// MARK: Batches

typedef struct batch {
  silt_entry *ents;
  uint64_t *ids;   // per entry: inode
  uint8_t *walk;   // per entry: 1 if it is a folder to descend into
  uint32_t *match; // per entry: the old entry it updates, or SILT_NONE
  uint32_t *reuse; // per newcomer: a name offset the folder already holds
  uint32_t n, cap;
  uint8_t *names;
  uint32_t nlen, ncap;
  uint32_t *new_ids;  // folders to list next
  uint8_t *new_deep;  // ...and whether to revalidate beneath them
  uint32_t nnew, newcap;
  uint32_t *promote;  // folders whose pending listing just became urgent
  uint32_t npromote, promotecap;
  // Partial APFS clones: their private size is fetched after the listing.
  struct partial { uint32_t index; uint32_t links; int64_t alloc; } *partials;
  uint32_t npartial, partialcap;
  bool urgent; // the class of the listing being committed
  bool followup;
  bool followup_deep;
  bool followup_urgent;
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
  pthread_cond_t idle_cond; // silt_scanner_wait_idle
  pthread_cond_t gone_cond; // destroy, waiting for the last thread
  stack urgent, background;
  dirmap where; // background items by dir id
  uint32_t urgent_active, background_active;
  uint32_t max;      // threads at most
  uint32_t limit;    // urgent listings allowed at once
  uint32_t alive;    // threads started and not yet exited
  uint32_t starting; // ...of which not yet looking for work
  uint32_t woken;    // ...of which woken for work and not yet running
  uint32_t returning; // ...of which done with an item, not yet back for more
  worker *workers;   // `max` slots
  uint32_t *idle;    // slots waiting for work, most recently idle last
  uint32_t nidle;
  pthread_t reaped;  // the last thread to exit, still to be joined
  bool has_reaped;
  uint64_t idle_ns;
  bool shutdown;
  bool cancelled;
  uint64_t scan_start;
  uint64_t scan_end;
  controller ctl;
  // Pace (silt_scanner_set_pace). The QoS values are read by workers without
  // the mutex; the rest changes and is read under it.
  silt_qos urgent_qos, background_qos;
  uint32_t background_max; // background listings allowed at once
  bool paused;             // start no listing
};

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static uint64_t thread_cpu_ns(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }

// Working buffers that can grow big (the queues, a huge folder's batch) come
// straight from the kernel above a threshold, so freeing them really gives
// the memory back: malloc keeps large freed blocks, still counted against
// the app. Callers pass the size they asked for before.
#define BIG_BUFFER (16u << 10)

static void buf_free(void *p, size_t bytes) {
  if (!p) return;
  if (bytes < BIG_BUFFER) free(p);
  else tree_chunk_free(p, bytes);
}

static void *buf_alloc(size_t bytes) {
  void *p = bytes < BIG_BUFFER ? malloc(bytes ? bytes : 1) : tree_chunk_alloc(bytes);
  if (!p) abort();
  return p;
}

static void *buf_resize(void *p, size_t old_bytes, size_t new_bytes) {
  if (new_bytes < BIG_BUFFER && old_bytes < BIG_BUFFER) {
    void *q = realloc(p, new_bytes);
    if (!q) abort();
    return q;
  }
  void *q = buf_alloc(new_bytes);
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
  buf_free(b->new_ids, (size_t)b->newcap * sizeof *b->new_ids);
  buf_free(b->new_deep, b->newcap);
  buf_free(b->promote, (size_t)b->promotecap * sizeof *b->promote);
  buf_free(b->partials, (size_t)b->partialcap * sizeof *b->partials);
  buf_free(b->map, (size_t)b->mapcap * sizeof *b->map);
  buf_free(b->hit, b->hitcap);
}

// After listing a big folder, give its buffers back rather than keep them
// for the life of the worker: with dozens of workers, each holding on to the
// largest folder it ever saw adds up. The bulk read buffer stays until the
// thread exits.
#define TRIM_ENTRIES 8192u
static void batch_trim(batch *b) {
  if (b->cap <= TRIM_ENTRIES && b->ncap <= TRIM_ENTRIES * 64 && b->newcap <= TRIM_ENTRIES &&
      b->mapcap <= TRIM_ENTRIES * 4 && b->hitcap <= TRIM_ENTRIES && b->promotecap <= TRIM_ENTRIES &&
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

// What an urgent listing costs, for the controller: the worker's own CPU
// clock and the cost units done, credited as the listing goes (a huge
// folder shouldn't land in one window all at once).
typedef struct meter {
  controller *ctl;
  bool on;
  uint64_t cpu;   // thread CPU at the last credit
  uint64_t units; // done since then
} meter;

#define METER_CREDIT 4096u // credit a long listing every this many units

static void meter_start(meter *m, controller *ctl, bool urgent) {
  m->ctl = ctl;
  m->on = urgent && __atomic_load_n(&ctl->measuring, __ATOMIC_RELAXED);
  m->units = 0;
  m->cpu = m->on ? thread_cpu_ns() : 0;
}

static void meter_credit(meter *m) {
  if (!m->on) return;
  const uint64_t cpu = thread_cpu_ns();
  __atomic_add_fetch(&m->ctl->cpu_ns, cpu - m->cpu, __ATOMIC_RELAXED);
  __atomic_add_fetch(&m->ctl->units, m->units, __ATOMIC_RELAXED);
  m->cpu = cpu;
  m->units = 0;
}

typedef struct listing {
  int open_error; // errno from open(), 0 if the folder opened
  int read_error; // errno that ended the listing early, 0 if it completed
} listing;

static listing list_dir(batch *b, const char *path, bool root, meter *m) {
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
    m->units += (uint32_t)n;
    if (m->units >= METER_CREDIT) meter_credit(m);
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
  m->units += (uint64_t)b->npartial * UNIT_PARTIAL;
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

// A folder that isn't walked: unreadable, a mount point, or left out by the
// user. A folder that becomes (or stops being) one is a different entry, so
// its old subtree is dropped (or a new one scanned).
static bool blocked(uint8_t flags) {
  return (flags & (SILT_FLAG_DENIED | SILT_FLAG_MOUNT | SILT_FLAG_EXCLUDED)) != 0;
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

static void n_alloc_new_dirs(batch *b, uint32_t n) {
  if (n <= b->newcap) return;
  b->new_ids = buf_resize(b->new_ids, (size_t)b->newcap * sizeof *b->new_ids, (size_t)n * sizeof *b->new_ids);
  b->new_deep = buf_resize(b->new_deep, b->newcap, n);
  b->newcap = n;
}

// An urgent listing met subfolder `dir` while that folder's own listing was
// still to come (or under way), and it belongs to what someone is waiting
// for: make that listing urgent too. Its item moves to the urgent stack (or
// the worker holding it is recounted) when the commit hands its work over.
// Lock held.
static void upgrade(batch *b, silt_dir *od, uint32_t dir) {
  if (!b->urgent || (od->state & SILT_DIR_URGENT)) return;
  od->state |= SILT_DIR_URGENT;
  GROW(b->promote, b->npromote, b->promotecap, 1);
  b->promote[b->npromote++] = dir;
}

// Queues an in-place re-listing of subfolder `dir` as part of a deep
// refresh, in the class of the listing that found it. Returns the pending
// units added to the parent's chain. Lock held.
static int64_t revalidate(silt_tree *t, batch *b, uint32_t dir) {
  silt_dir *od = silt_dir_at(t, dir);
  if (od->state & SILT_DIR_QUEUED) {
    od->state |= SILT_DIR_DEEP; // already waiting: just make it thorough
    upgrade(b, od, dir);
    return 0;
  }
  if (od->state & SILT_DIR_ACTIVE) {
    od->state |= SILT_DIR_DIRTY | SILT_DIR_DEEP;
    upgrade(b, od, dir);
    return 0;
  }
  od->state |= SILT_DIR_QUEUED | (b->urgent ? SILT_DIR_URGENT : 0);
  od->pending += 1;
  tree_stamp_one(t, dir); // the parent's commit moves the ancestors'
  b->new_ids[b->nnew] = dir;
  b->new_deep[b->nnew++] = 1;
  return 1;
}

// A surviving subfolder met by a shallow listing. One that was never listed
// yet is part of this listing's news (its first listing was queued by an
// earlier one), so an urgent listing takes it along. Lock held.
static void adopt(silt_tree *t, batch *b, uint32_t dir) {
  silt_dir *od = silt_dir_at(t, dir);
  if (!(od->state & SILT_DIR_LISTED) && (od->state & (SILT_DIR_QUEUED | SILT_DIR_ACTIVE)))
    upgrade(b, od, dir);
}

// Queues the first listing of a new subfolder. Lock held.
static void queue_new(batch *b, uint32_t dir) {
  b->new_ids[b->nnew] = dir;
  b->new_deep[b->nnew++] = 0;
}

// The state a new subfolder starts in.
static uint32_t new_dir_state(const batch *b, bool walk) {
  if (!walk) return SILT_DIR_LISTED;
  return SILT_DIR_QUEUED | (b->urgent ? SILT_DIR_URGENT : 0);
}

// Fast path for a refresh where nothing was added, removed, or renamed and
// the order held: update sizes and times in place. Returns false if the
// listing doesn't qualify. Lock held.
static bool commit_in_place(silt_tree *t, uint32_t dir_id, batch *b, bool deep, int64_t *total,
                            int64_t *items, uint32_t *newest, int64_t *pending) {
  const silt_dir *d = silt_dir_at(t, dir_id);
  if (d->count != b->n) return false;
  for (uint32_t k = 0; k < b->n; k++) {
    const silt_entry *o = silt_entry_at(t, d->first + k);
    const silt_entry *e = &b->ents[k];
    if ((o->flags & SILT_FLAG_REMOVED) || !same_name(t, o, b->names + e->name, e->name_len) ||
        !compatible(t, o, e, b->ids[k]))
      return false;
  }
  tree_touch(t, dir_id);
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
      if (deep && !blocked(o->flags)) *pending += revalidate(t, b, o->aux);
      else adopt(t, b, o->aux);
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

// Completes the active unit and emits at most one replacement. Lock held;
// the worker hands the emitted item over before releasing it.
static void finish_listing(silt_tree *t, const work *w, batch *b) {
  if (w->dir >= t->dir_count) return;
  silt_dir *d = silt_dir_at(t, w->dir);
  d->state &= ~SILT_DIR_ACTIVE;
  if (!(d->state & SILT_DIR_DIRTY)) {
    d->state &= ~SILT_DIR_URGENT; // it only upgraded this listing
    return;
  }
  d->state &= ~SILT_DIR_DIRTY;
  if (!tree_dir_live(t, w->dir)) {
    d->state &= ~(SILT_DIR_DEEP | SILT_DIR_URGENT);
    return;
  }
  b->followup = true;
  b->followup_deep = (d->state & SILT_DIR_DEEP) != 0;
  b->followup_urgent = (d->state & SILT_DIR_URGENT) != 0;
  d->state &= ~SILT_DIR_DEEP;
  d->state |= SILT_DIR_QUEUED; // URGENT, if set, now describes the follow-up
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

  tree_touch(t, w->dir);
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
        if (deep && b->walk[k]) out->pending += revalidate(t, b, o->aux);
        else adopt(t, b, o->aux);
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
      ne.aux = tree_new_dir(t, j, b->ids[k], walk ? 1 : 0, new_dir_state(b, walk));
      if (walk) {
        queue_new(b, ne.aux);
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

  tree_touch(t, w->dir);
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
        if (deep && b->walk[i]) out->pending += revalidate(t, b, o->aux);
        else adopt(t, b, o->aux);
      } else {
        bool walk = b->walk[i];
        e.aux = tree_new_dir(t, base + i, b->ids[i], walk ? 1 : 0, new_dir_state(b, walk));
        if (walk) {
          queue_new(b, e.aux);
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
  b->npromote = 0;
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

  n_alloc_new_dirs(b, b->n);
  bool mapped = false;
  if (relisted && !denied) {
    if (commit_in_place(t, w->dir, b, deep, &tl.total, &tl.items, &tl.newest, &tl.pending)) goto finish;
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
  if (denied && !relisted) __atomic_add_fetch(&in->denied, 1, __ATOMIC_RELAXED);
  __atomic_add_fetch(&in->dirs_listed, 1, __ATOMIC_RELAXED);
  __atomic_add_fetch(&in->entries_listed, b->n, __ATOMIC_RELAXED);

  int64_t size_delta = tl.total - de->size;
  int64_t items_delta = tl.items - (int64_t)d->items;
  d->newest = tl.newest;
  tree_propagate(t, w->dir, size_delta, items_delta, tl.newest, tl.pending);
  if (relisted && tl.newest < old_newest) tree_recompute_newest(t, de->parent);
  TREE_BUMP(t);
  finish_listing(t, w, b);
}

// MARK: Queues (queue mutex held)

static inline uint32_t map_hash(uint32_t k, uint32_t mask) { return (k * 2654435761u) & mask; }

static void map_free(dirmap *m) {
  buf_free(m->keys, (size_t)m->cap * sizeof *m->keys);
  buf_free(m->vals, (size_t)m->cap * sizeof *m->vals);
  memset(m, 0, sizeof *m);
}

static void map_put(dirmap *m, uint32_t k, uint32_t v);

static void map_rehash(dirmap *m, uint32_t cap) {
  dirmap old = *m;
  m->keys = buf_alloc((size_t)cap * sizeof *m->keys);
  m->vals = buf_alloc((size_t)cap * sizeof *m->vals);
  memset(m->keys, 0xFF, (size_t)cap * sizeof *m->keys);
  m->cap = cap;
  m->count = 0;
  for (uint32_t i = 0; i < old.cap; i++)
    if (old.keys[i] != SILT_NONE) map_put(m, old.keys[i], old.vals[i]);
  map_free(&old);
}

static void map_put(dirmap *m, uint32_t k, uint32_t v) {
  if ((m->count + 1) * 2 > m->cap) map_rehash(m, m->cap ? m->cap * 2 : 64);
  const uint32_t mask = m->cap - 1;
  uint32_t h = map_hash(k, mask);
  while (m->keys[h] != SILT_NONE && m->keys[h] != k) h = (h + 1) & mask;
  if (m->keys[h] == SILT_NONE) {
    m->keys[h] = k;
    m->count++;
  }
  m->vals[h] = v;
}

static uint32_t map_get(const dirmap *m, uint32_t k) {
  if (!m->cap) return SILT_NONE;
  const uint32_t mask = m->cap - 1;
  for (uint32_t h = map_hash(k, mask); m->keys[h] != SILT_NONE; h = (h + 1) & mask)
    if (m->keys[h] == k) return m->vals[h];
  return SILT_NONE;
}

// Removes `k`, pulling later entries of its cluster back into the hole so
// lookups never need tombstones.
static void map_del(dirmap *m, uint32_t k) {
  if (!m->cap) return;
  const uint32_t mask = m->cap - 1;
  uint32_t h = map_hash(k, mask);
  while (m->keys[h] != k) {
    if (m->keys[h] == SILT_NONE) return;
    h = (h + 1) & mask;
  }
  uint32_t hole = h;
  for (uint32_t j = (hole + 1) & mask; m->keys[j] != SILT_NONE; j = (j + 1) & mask) {
    const uint32_t home = map_hash(m->keys[j], mask);
    if (((j - home) & mask) >= ((j - hole) & mask)) {
      m->keys[hole] = m->keys[j];
      m->vals[hole] = m->vals[j];
      hole = j;
    }
  }
  m->keys[hole] = SILT_NONE;
  m->count--;
}

static inline bool urgent_busy(const silt_scanner *s) {
  return s->urgent.count > 0 || s->urgent_active > 0;
}

static void ctl_burst(silt_scanner *s, uint64_t now);
static void ctl_idle(silt_scanner *s);

static void push_locked(silt_scanner *s, work w) {
  const bool was = urgent_busy(s);
  stack *q = w.urgent ? &s->urgent : &s->background;
  GROW(q->items, q->count, q->cap, 1);
  if (!w.urgent) map_put(&s->where, w.dir, q->count);
  q->items[q->count++] = w;
  if (!was && urgent_busy(s)) ctl_burst(s, now_ns());
}

// The pending listing of `dir` became urgent: move its item to the urgent
// stack, or recount the worker already holding it. Both locks held, so the
// item is exactly where the folder's state says: in a stack, or with a
// worker (popped, or being listed).
static void promote_locked(silt_scanner *s, uint32_t dir) {
  const bool was = urgent_busy(s);
  const uint32_t at = map_get(&s->where, dir);
  if (at != SILT_NONE) {
    stack *q = &s->background;
    work w = q->items[at];
    map_del(&s->where, dir);
    const uint32_t last = --q->count;
    if (at != last) {
      q->items[at] = q->items[last];
      map_put(&s->where, q->items[at].dir, at);
    }
    w.urgent = true;
    push_locked(s, w);
  } else {
    for (uint32_t i = 0; i < s->max; i++) {
      worker *x = &s->workers[i];
      if (x->used && x->busy && x->dir == dir && !x->urgent) {
        x->urgent = true;
        s->background_active--;
        s->urgent_active++;
        break;
      }
    }
  }
  if (!was && urgent_busy(s)) ctl_burst(s, now_ns());
}

static bool pop_locked(silt_scanner *s, worker *me, work *w) {
  if (s->cancelled || s->paused) return false;
  if (s->urgent.count > 0 && s->urgent_active < s->limit) {
    *w = s->urgent.items[--s->urgent.count];
    s->urgent_active++;
    me->urgent = true;
  } else if (s->background.count > 0 && s->background_active < s->background_max) {
    *w = s->background.items[--s->background.count];
    map_del(&s->where, w->dir);
    s->background_active++;
    me->urgent = false;
  } else {
    // A thread was free for urgent work and there was none: this window
    // didn't measure the limit.
    if (s->urgent.count == 0 && s->urgent_active < s->limit) s->ctl.starved = true;
    return false;
  }
  me->busy = true;
  me->dir = w->dir;
  return true;
}

// Listings that could start right now.
static uint32_t runnable_locked(const silt_scanner *s) {
  if (s->paused) return 0;
  uint32_t u = s->limit > s->urgent_active ? s->limit - s->urgent_active : 0;
  uint32_t b = s->background_max > s->background_active ? s->background_max - s->background_active : 0;
  if (u > s->urgent.count) u = s->urgent.count;
  if (b > s->background.count) b = s->background.count;
  return u + b;
}

// Nothing queued or running any more: stop the clock, let waiters go, and
// give back queue memory a big scan left behind.
static void settle_locked(silt_scanner *s, bool urgent_was_busy) {
  if (urgent_was_busy && !urgent_busy(s)) {
    if (s->scan_end == 0) s->scan_end = now_ns();
    ctl_idle(s);
  }
  if (s->urgent.count || s->background.count || s->urgent_active || s->background_active) return;
  if ((size_t)s->urgent.cap * sizeof(work) >= BIG_BUFFER) {
    buf_free(s->urgent.items, (size_t)s->urgent.cap * sizeof(work));
    s->urgent = (stack){0};
  }
  if ((size_t)s->background.cap * sizeof(work) >= BIG_BUFFER) {
    buf_free(s->background.items, (size_t)s->background.cap * sizeof(work));
    s->background = (stack){0};
  }
  if ((size_t)s->where.cap * sizeof(uint32_t) >= BIG_BUFFER) map_free(&s->where);
  pthread_cond_broadcast(&s->idle_cond);
}

// MARK: Threads (queue mutex held)

static void *worker_main(void *arg);

static bool spawn_locked(silt_scanner *s) {
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INITIATED, 0);
  pthread_t th;
  // Joined by whoever reaps it (see worker_main), not detached: destroy must
  // know every thread is gone before freeing the scanner.
  const bool ok = pthread_create(&th, &attr, worker_main, s) == 0;
  pthread_attr_destroy(&attr);
  if (!ok) {
    // A running thread takes the work when it's done, and the next dispatch
    // tries again. With none running, nobody ever would: the process is out
    // of threads, which it can't recover from (as with memory).
    if (s->alive == 0) abort();
    return false;
  }
  s->alive++;
  s->starting++;
  return true;
}

static void wake_one_locked(silt_scanner *s) {
  worker *x = &s->workers[s->idle[--s->nidle]];
  x->waiting = false;
  x->woken = true;
  s->woken++;
  pthread_cond_signal(&x->wake);
}

static void wake_all_locked(silt_scanner *s) {
  while (s->nidle) wake_one_locked(s);
}

// Makes sure every listing that could start now has a thread coming for it:
// wakes the most recently idle threads first (so the others can time out
// and exit), then starts new ones, up to the maximum. `self`: the caller is
// a worker about to take an item itself. Never called with the tree lock
// held: starting a thread takes a while.
static void dispatch_locked(silt_scanner *s, bool self) {
  if (s->shutdown || s->cancelled) return;
  const uint32_t ready = runnable_locked(s);
  uint32_t have = s->woken + s->starting + s->returning + (self ? 1 : 0);
  while (ready > have && s->nidle > 0) {
    wake_one_locked(s);
    have++;
  }
  while (ready > have && s->alive < s->max && spawn_locked(s)) have++;
}

// MARK: Controller (queue mutex held)

static void ctl_window(silt_scanner *s, uint32_t limit, uint64_t now) {
  controller *c = &s->ctl;
  s->limit = limit;
  c->since = now;
  c->measure_from = 0;
}

static void ctl_hold(silt_scanner *s, uint64_t now) {
  controller *c = &s->ctl;
  c->phase = CTL_HOLD;
  c->hold_until = now + CTL_HOLD_NS;
  c->wins = 0;
  c->retries = 0;
  s->limit = c->base;
  __atomic_store_n(&c->measuring, false, __ATOMIC_RELAXED);
}

static void ctl_probe(silt_scanner *s, bool down, uint64_t now) {
  controller *c = &s->ctl;
  if (!down && c->base >= c->hi) down = true;
  if (down && c->base <= c->lo) {
    ctl_hold(s, now);
    return;
  }
  c->phase = CTL_PROBE;
  c->down = down;
  c->alt = down ? c->base - 1 : (c->base + CTL_STEP < c->hi ? c->base + CTL_STEP : c->hi);
  c->step = 0;
  __atomic_store_n(&c->measuring, true, __ATOMIC_RELAXED);
  ctl_window(s, c->base, now);
}

// Urgent work arrived after none: probe from where the last burst settled.
static void ctl_burst(silt_scanner *s, uint64_t now) {
  if (s->ctl.fixed) return;
  ctl_probe(s, false, now);
}

// Urgent work ran out: the next burst starts over at the settled limit.
static void ctl_idle(silt_scanner *s) {
  controller *c = &s->ctl;
  if (c->fixed) return;
  c->phase = CTL_IDLE;
  c->wins = 0;
  c->retries = 0;
  s->limit = c->base;
  __atomic_store_n(&c->measuring, false, __ATOMIC_RELAXED);
}

// Called after each urgent listing. Moves through the probe's windows and
// decides at the end of each probe.
static void ctl_tick(silt_scanner *s, uint64_t now) {
  controller *c = &s->ctl;
  if (c->fixed) return;
  if (c->phase == CTL_HOLD) {
    if (now >= c->hold_until) ctl_probe(s, false, now);
    return;
  }
  if (c->phase != CTL_PROBE) return;
  if (c->measure_from == 0) {
    // Let listings started under the previous limit drain first.
    if (now - c->since < CTL_SETTLE_NS) return;
    __atomic_exchange_n(&c->units, 0, __ATOMIC_RELAXED);
    __atomic_exchange_n(&c->cpu_ns, 0, __ATOMIC_RELAXED);
    c->measure_from = now;
    c->starved = false;
    return;
  }
  if (now - c->measure_from < CTL_WINDOW_NS) return;
  const uint64_t units = __atomic_exchange_n(&c->units, 0, __ATOMIC_RELAXED);
  const uint64_t cpu = __atomic_exchange_n(&c->cpu_ns, 0, __ATOMIC_RELAXED);
  const double wall = (double)(now - c->measure_from);
  if (c->starved || units == 0) {
    // Too little work to tell limits apart: start this probe over.
    c->step = 0;
    ctl_window(s, c->base, now);
    return;
  }
  c->rate[c->step] = (double)units / wall;
  c->cpu[c->step] = (double)cpu / wall;
  if (++c->step < 4) {
    ctl_window(s, c->step == 3 ? c->base : c->alt, now);
    return;
  }
  const double ra = (c->rate[0] + c->rate[3]) / 2, rb = (c->rate[1] + c->rate[2]) / 2;
  const double ca = (c->cpu[0] + c->cpu[3]) / 2, cb = (c->cpu[1] + c->cpu[2]) / 2;
  if (!c->down) {
    // Faster by enough on average, and in both adjacent pairs: a steady
    // drift adds to one pair's difference what it takes from the other's,
    // while noise (and adjacent windows can differ severalfold on a busy
    // machine) rarely favors the same side twice. And the extra units cost
    // at most K times an average one's CPU: (cb - ca) / (rb - ra) <= K * ca / ra.
    const bool consistent = c->rate[1] > c->rate[0] && c->rate[2] > c->rate[3];
    const bool worth = rb >= ra * (1 + CTL_GAIN) && (cb - ca) * ra <= CTL_K * ca * (rb - ra);
    if (worth && consistent) {
      c->base = c->alt;
      c->retries = 0;
      ctl_probe(s, false, now);
    } else if (worth && c->retries < CTL_RETRIES) {
      c->retries++;
      ctl_probe(s, false, now);
    } else {
      c->retries = 0;
      ctl_probe(s, true, now);
    }
  } else if (rb >= ra * (1 - CTL_SHRINK_TOL) && c->rate[1] >= c->rate[0] * (1 - CTL_SHRINK_TOL) &&
             c->rate[2] >= c->rate[3] * (1 - CTL_SHRINK_TOL)) {
    // One fewer kept up, on average and in both pairs.
    if (++c->wins >= CTL_SHRINK_WINS) {
      c->base = c->alt;
      c->wins = 0;
    }
    ctl_probe(s, true, now);
  } else {
    ctl_hold(s, now);
  }
}

// MARK: Workers

static qos_class_t qos_class(silt_qos q) {
  switch (q) {
  case SILT_QOS_BACKGROUND: return QOS_CLASS_BACKGROUND;
  case SILT_QOS_UTILITY: return QOS_CLASS_UTILITY;
  default: return QOS_CLASS_USER_INITIATED;
  }
}

// Runs the thread at the QoS of the class of the listing it's about to do.
// QoS only: a thread-scoped I/O policy would take the thread out of QoS for
// good (macOS then refuses to raise it again), and utility and background QoS
// lower the I/O tier by themselves.
static void set_class(const silt_scanner *s, qos_class_t *now, bool urgent) {
  const qos_class_t want = qos_class(urgent ? __atomic_load_n(&s->urgent_qos, __ATOMIC_RELAXED)
                                            : __atomic_load_n(&s->background_qos, __ATOMIC_RELAXED));
  if (*now == want) return;
  pthread_set_qos_class_self_np(want, 0);
  *now = want;
}

// Leaves out the folders the user excluded from the listing of `path`: they're
// recorded, flagged, and not walked. Tree lock held.
static void exclude(const silt_tree *t, const char *path, batch *b) {
  const silt_internal *in = silt_int(t);
  for (uint32_t x = 0; x < in->exclude_count; x++) {
    if (strcmp(in->exclude_parent[x], path) != 0) continue;
    const char *name = in->exclude_name[x];
    const size_t len = strlen(name);
    for (uint32_t i = 0; i < b->n; i++) {
      silt_entry *e = &b->ents[i];
      if (e->kind == SILT_KIND_DIR && e->name_len == len && memcmp(b->names + e->name, name, len) == 0) {
        b->walk[i] = 0;
        e->flags |= SILT_FLAG_EXCLUDED;
      }
    }
  }
}

// Finishes an item: hands over the work the listing produced, in the same
// critical section that marked it queued, then stops counting the item.
// Tree lock held; takes the queue mutex.
static void complete(silt_scanner *s, worker *me, const work *w, batch *b) {
  pthread_mutex_lock(&s->qlock);
  const bool was = urgent_busy(s);
  if (!s->cancelled) {
    for (uint32_t k = 0; k < b->nnew; k++)
      push_locked(s, (work){.dir = b->new_ids[k], .deep = b->new_deep[k] != 0, .urgent = b->urgent});
    if (b->followup)
      push_locked(s, (work){.dir = w->dir, .deep = b->followup_deep, .urgent = b->followup_urgent});
    for (uint32_t k = 0; k < b->npromote; k++) promote_locked(s, b->promote[k]);
  }
  if (me->urgent) s->urgent_active--;
  else s->background_active--;
  me->busy = false;
  s->returning++; // coming back for more: don't start a thread in its place
  settle_locked(s, was);
  pthread_mutex_unlock(&s->qlock);
}

// Lists one folder and commits it.
static void process(silt_scanner *s, worker *me, work *w, batch *b, qos_class_t *class_now) {
  silt_tree *t = s->tree;
  char path[PATH_BUFFER];
  size_t plen = 0;
  b->n = 0;
  b->nlen = 0;
  b->nnew = 0;
  b->npromote = 0;
  b->followup = false;
  b->followup_deep = false;
  b->followup_urgent = false;

  silt_tree_lock(t);
  const bool live = tree_dir_live(t, w->dir);
  if (w->dir < t->dir_count) {
    silt_dir *d = silt_dir_at(t, w->dir);
    // From here on, a change to this folder must queue a fresh listing rather
    // than fold into this one, which may already have read past it.
    d->state &= ~SILT_DIR_QUEUED;
    if (d->state & SILT_DIR_DEEP) w->deep = true;
    if (d->state & SILT_DIR_URGENT) w->urgent = true;
    d->state &= ~(SILT_DIR_DEEP | SILT_DIR_URGENT);
    if (live) {
      d->state |= SILT_DIR_ACTIVE;
      // Paths are built here rather than when queued: the tree has every
      // name, and a queued item is just a dir id.
      plen = silt_path(t, d->entry, path, sizeof path);
    }
  }
  if (me->urgent) w->urgent = true;
  if (!live) {
    // Removed while it waited; its pending count went with it.
    b->urgent = w->urgent;
    complete(s, me, w, b);
    silt_tree_unlock(t);
    return;
  }
  silt_tree_unlock(t);

  set_class(s, class_now, w->urgent);
  meter m;
  meter_start(&m, &s->ctl, w->urgent);
  // A path too long to build is one the system couldn't open either.
  listing r = plen ? list_dir(b, path, w->dir == 0, &m) : (listing){ENAMETOOLONG, 0};

  silt_tree_lock(t);
  if (me->urgent) w->urgent = true; // upgraded while it listed
  b->urgent = w->urgent;
  if (plen && tree_is_guarded(t, path)) {
    for (uint32_t i = 0; i < b->n; i++) {
      if (b->walk[i]) {
        b->walk[i] = 0;
        b->ents[i].flags |= SILT_FLAG_DENIED;
      }
    }
  }
  if (plen) exclude(t, path, b);
  commit(s, w, b, r);
  m.units += UNIT_FOLDER;
  meter_credit(&m);
  complete(s, me, w, b);
  silt_tree_unlock(t);
}

static void *worker_main(void *arg) {
  silt_scanner *s = arg;
  batch b;
  memset(&b, 0, sizeof b);
  b.buf = tree_chunk_alloc(BULK_BUFFER);
  qos_class_t class_now = QOS_CLASS_USER_INITIATED; // what spawn_locked started it at

  pthread_mutex_lock(&s->qlock);
  s->starting--;
  uint32_t slot = 0;
  while (s->workers[slot].used) slot++; // alive <= max, so one is free
  worker *me = &s->workers[slot];
  me->used = true;
  me->busy = false;
  uint64_t idle_since = now_ns();
  for (;;) {
    dispatch_locked(s, true);
    work w;
    if (pop_locked(s, me, &w)) {
      pthread_mutex_unlock(&s->qlock);
      process(s, me, &w, &b, &class_now);
      batch_trim(&b);
      pthread_mutex_lock(&s->qlock);
      s->returning--;
      const uint64_t now = now_ns();
      if (w.urgent) ctl_tick(s, now);
      idle_since = now;
      continue;
    }
    if (s->shutdown || s->cancelled) break;
    const uint64_t now = now_ns();
    if (now - idle_since >= s->idle_ns) break;
    // Wait on this thread's own condition, so dispatch wakes exactly the
    // threads it counts on.
    me->waiting = true;
    me->woken = false;
    s->idle[s->nidle++] = slot;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    const uint64_t at = (uint64_t)tv.tv_sec * 1000000000ull + (uint64_t)tv.tv_usec * 1000ull +
                        (idle_since + s->idle_ns - now);
    const struct timespec deadline = {.tv_sec = (time_t)(at / 1000000000ull),
                                      .tv_nsec = (long)(at % 1000000000ull)};
    pthread_cond_timedwait(&me->wake, &s->qlock, &deadline);
    if (me->woken) {
      me->woken = false;
      s->woken--;
    } else if (me->waiting) {
      // Timed out (or woke for nothing): off the idle list, then look again.
      for (uint32_t i = 0; i < s->nidle; i++) {
        if (s->idle[i] == slot) {
          memmove(&s->idle[i], &s->idle[i + 1], (s->nidle - i - 1) * sizeof *s->idle);
          s->nidle--;
          break;
        }
      }
      me->waiting = false;
    }
  }
  // Exit. The previous thread to exit is joined here, this one by the next
  // (or by destroy), so at most one exited thread is ever left unjoined.
  me->used = false;
  const bool join_prev = s->has_reaped;
  const pthread_t prev = s->reaped;
  s->reaped = pthread_self();
  s->has_reaped = true;
  s->alive--;
  if (s->alive == 0) pthread_cond_broadcast(&s->gone_cond);
  pthread_mutex_unlock(&s->qlock);
  if (join_prev) pthread_join(prev, NULL);

  batch_free(&b);
  tree_chunk_free(b.buf, BULK_BUFFER);
  return NULL;
}

// MARK: Public API

static silt_scanner *scanner_create(silt_tree *t, int threads, bool scan_root, const silt_pace *pace);

silt_scanner *silt_scanner_start(silt_tree *t, int threads) {
  return scanner_create(t, threads, true, NULL);
}

silt_scanner *silt_scanner_start_idle(silt_tree *t, int threads) {
  return scanner_create(t, threads, false, NULL);
}

silt_scanner *silt_scanner_start_paced(silt_tree *t, int threads, const silt_pace *pace, bool scan_root) {
  return scanner_create(t, threads, scan_root, pace);
}

static silt_scanner *scanner_create(silt_tree *t, int threads, bool scan_root, const silt_pace *pace) {
  // Never pull iCloud placeholders down just because we looked at them.
  setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                 IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
  // Reading a folder shouldn't write to it: without this, listing one whose
  // access time is older than its modification time (every folder FSEvents
  // sends us back to) updates the access time, a metadata write.
  setiopolicy_np(IOPOL_TYPE_VFS_ATIME_UPDATES, IOPOL_SCOPE_PROCESS, IOPOL_ATIME_UPDATES_OFF);

  silt_scanner *s = calloc(1, sizeof *s);
  if (!s) abort();
  s->tree = t;
  pthread_mutex_init(&s->qlock, NULL);
  pthread_cond_init(&s->idle_cond, NULL);
  pthread_cond_init(&s->gone_cond, NULL);
  s->max = threads < 1 ? 1 : (uint32_t)threads;
  s->workers = calloc(s->max, sizeof *s->workers);
  s->idle = calloc(s->max, sizeof *s->idle);
  if (!s->workers || !s->idle) abort();
  for (uint32_t i = 0; i < s->max; i++) pthread_cond_init(&s->workers[i].wake, NULL);
  s->idle_ns = IDLE_EXIT_NS;

  controller *c = &s->ctl;
  c->hi = s->max;
  c->lo = CTL_FLOOR < s->max ? CTL_FLOOR : s->max;
  c->base = CTL_START < s->max ? CTL_START : s->max;
  c->phase = CTL_IDLE;
  s->limit = c->base;
  const silt_pace start = silt_pace_default();
  s->urgent_qos = start.urgent_qos;
  s->background_qos = start.background_qos;
  s->background_max = start.background_max;
  // Before anything is queued, so the first listing already runs at it.
  if (pace) silt_scanner_set_pace(s, pace);

  s->scan_start = now_ns();
  if (scan_root) {
    silt_tree_lock(t);
    silt_dir *root = silt_dir_at(t, 0);
    if (!(root->state & (SILT_DIR_QUEUED | SILT_DIR_ACTIVE))) {
      // Already scanned once: queue it the way a refresh would.
      root->state |= SILT_DIR_QUEUED;
      tree_propagate(t, 0, 0, 0, 0, 1);
      TREE_BUMP(t);
    }
    root->state |= SILT_DIR_URGENT;
    pthread_mutex_lock(&s->qlock);
    push_locked(s, (work){.dir = 0, .deep = false, .urgent = true});
    pthread_mutex_unlock(&s->qlock);
    silt_tree_unlock(t);
    pthread_mutex_lock(&s->qlock);
    dispatch_locked(s, false);
    pthread_mutex_unlock(&s->qlock);
  } else {
    s->scan_end = s->scan_start;
  }
  return s;
}

void silt_scanner_progress(silt_scanner *s, silt_progress *out) {
  silt_internal *in = silt_int(s->tree);
  out->bytes = (uint64_t)__atomic_load_n(&in->root_size, __ATOMIC_RELAXED);
  out->files = __atomic_load_n(&in->root_items, __ATOMIC_RELAXED);
  out->dirs = __atomic_load_n(&in->dirs_listed, __ATOMIC_RELAXED);
  out->listed = __atomic_load_n(&in->entries_listed, __ATOMIC_RELAXED);
  out->denied = __atomic_load_n(&in->denied, __ATOMIC_RELAXED);

  pthread_mutex_lock(&s->qlock);
  out->active = s->urgent_active + s->background_active;
  out->queued = s->urgent.count + s->background.count + out->active;
  out->urgent_queued = s->urgent.count + s->urgent_active;
  out->limit = s->limit;
  out->threads = s->alive;
  out->paused = s->paused;
  out->idle = out->queued == 0;
  uint64_t end = s->scan_end ? s->scan_end : now_ns();
  out->elapsed = (double)(end - s->scan_start) / 1e9;
  out->finished = s->scan_end ? out->elapsed : 0;
  pthread_mutex_unlock(&s->qlock);
}

void silt_scanner_cancel(silt_scanner *s) {
  pthread_mutex_lock(&s->qlock);
  const bool was = urgent_busy(s);
  s->cancelled = true;
  s->urgent.count = 0;
  s->background.count = 0;
  map_free(&s->where);
  wake_all_locked(s); // idle threads exit
  settle_locked(s, was);
  pthread_mutex_unlock(&s->qlock);
}

void silt_scanner_wait_idle(silt_scanner *s) {
  pthread_mutex_lock(&s->qlock);
  while (s->urgent.count || s->background.count || s->urgent_active || s->background_active)
    pthread_cond_wait(&s->idle_cond, &s->qlock);
  pthread_mutex_unlock(&s->qlock);
}

void silt_scanner_destroy(silt_scanner *s) {
  if (!s) return;
  silt_scanner_cancel(s);
  pthread_mutex_lock(&s->qlock);
  s->shutdown = true;
  wake_all_locked(s);
  while (s->alive > 0) pthread_cond_wait(&s->gone_cond, &s->qlock);
  const bool join_last = s->has_reaped;
  const pthread_t last = s->reaped;
  pthread_mutex_unlock(&s->qlock);
  // Each exiting thread joined the one before it; this is the last.
  if (join_last) pthread_join(last, NULL);

  buf_free(s->urgent.items, (size_t)s->urgent.cap * sizeof(work));
  buf_free(s->background.items, (size_t)s->background.cap * sizeof(work));
  map_free(&s->where);
  for (uint32_t i = 0; i < s->max; i++) pthread_cond_destroy(&s->workers[i].wake);
  free(s->workers);
  free(s->idle);
  pthread_mutex_destroy(&s->qlock);
  pthread_cond_destroy(&s->idle_cond);
  pthread_cond_destroy(&s->gone_cond);
  free(s);
}

void silt_scanner_refresh(silt_scanner *s, uint32_t dir, bool deep) {
  silt_scanner_refresh_ex(s, dir, deep ? SILT_REFRESH_DEEP : 0);
}

void silt_scanner_refresh_ex(silt_scanner *s, uint32_t dir, uint32_t flags) {
  const bool deep = (flags & SILT_REFRESH_DEEP) != 0;
  const bool urgent = (flags & SILT_REFRESH_URGENT) != 0;
  pthread_mutex_lock(&s->qlock);
  bool cancelled = s->cancelled;
  pthread_mutex_unlock(&s->qlock);
  if (cancelled) return;

  silt_tree *t = s->tree;
  char path[PATH_BUFFER];
  silt_tree_lock(t);
  if (!tree_dir_live(t, dir)) {
    silt_tree_unlock(t);
    return;
  }
  silt_dir *d = silt_dir_at(t, dir);
  const silt_entry *e = silt_entry_at(t, d->entry);
  bool push = false, promote = false;
  if (d->state & (SILT_DIR_QUEUED | SILT_DIR_ACTIVE)) {
    // Coalesce: the queued listing will do, or one more after the active
    // one (which may already have read past the change).
    if (d->state & SILT_DIR_ACTIVE) d->state |= SILT_DIR_DIRTY;
    if (deep) d->state |= SILT_DIR_DEEP; // upgrade the pending listing
    if (urgent && !(d->state & SILT_DIR_URGENT)) {
      d->state |= SILT_DIR_URGENT;
      promote = true;
    }
  } else {
    if ((e->flags & (SILT_FLAG_MOUNT | SILT_FLAG_EXCLUDED)) || silt_path(t, d->entry, path, sizeof path) == 0) {
      silt_tree_unlock(t);
      return;
    }
    d->state |= SILT_DIR_QUEUED | (urgent ? SILT_DIR_URGENT : 0);
    tree_propagate(t, dir, 0, 0, 0, 1);
    TREE_BUMP(t);
    push = true;
  }
  if (push || promote) {
    pthread_mutex_lock(&s->qlock);
    if (!s->cancelled) {
      if (push) push_locked(s, (work){.dir = dir, .deep = deep, .urgent = urgent});
      else promote_locked(s, dir);
    }
    pthread_mutex_unlock(&s->qlock);
  }
  silt_tree_unlock(t);
  if (push || promote) {
    pthread_mutex_lock(&s->qlock);
    dispatch_locked(s, false);
    pthread_mutex_unlock(&s->qlock);
  }
}

void silt_scanner_set_idle_timeout(silt_scanner *s, double seconds) {
  pthread_mutex_lock(&s->qlock);
  s->idle_ns = seconds <= 0 ? 0 : (uint64_t)(seconds * 1e9);
  // Idle threads look again at their deadline (they're not being given
  // work, so they aren't marked woken).
  for (uint32_t i = 0; i < s->nidle; i++) pthread_cond_signal(&s->workers[s->idle[i]].wake);
  pthread_mutex_unlock(&s->qlock);
}

void silt_scanner_fix_limit(silt_scanner *s, uint32_t limit) {
  pthread_mutex_lock(&s->qlock);
  controller *c = &s->ctl;
  if (limit > 0) {
    c->fixed = true;
    c->pinned = limit;
    c->phase = CTL_IDLE;
    __atomic_store_n(&c->measuring, false, __ATOMIC_RELAXED);
    s->limit = limit < c->hi ? limit : c->hi;
  } else {
    c->fixed = false;
    if (urgent_busy(s)) ctl_probe(s, false, now_ns());
    else ctl_idle(s);
  }
  dispatch_locked(s, false);
  pthread_mutex_unlock(&s->qlock);
}

silt_pace silt_pace_default(void) {
  return (silt_pace){.urgent_qos = SILT_QOS_USER_INITIATED,
                     .urgent_max = 0,
                     .background_qos = SILT_QOS_UTILITY,
                     .background_max = BACKGROUND_LIMIT,
                     .paused = false};
}

void silt_scanner_set_pace(silt_scanner *s, const silt_pace *pace) {
  pthread_mutex_lock(&s->qlock);
  __atomic_store_n(&s->urgent_qos, pace->urgent_qos, __ATOMIC_RELAXED);
  __atomic_store_n(&s->background_qos, pace->background_qos, __ATOMIC_RELAXED);
  s->background_max = pace->background_max;
  const bool resumed = s->paused && !pace->paused;
  s->paused = pace->paused;

  controller *c = &s->ctl;
  const uint32_t hi = pace->urgent_max && pace->urgent_max < s->max ? pace->urgent_max : s->max;
  const bool ceiling = hi != c->hi;
  if (ceiling) {
    c->hi = hi;
    c->lo = CTL_FLOOR < hi ? CTL_FLOOR : hi;
    if (c->base > c->hi) c->base = c->hi;
    if (c->base < c->lo) c->base = c->lo;
  }
  if (c->fixed) {
    s->limit = c->pinned < c->hi ? c->pinned : c->hi;
  } else if (s->paused) {
    // Nothing to measure while nothing runs; resuming probes afresh.
    ctl_idle(s);
  } else if (ceiling || resumed) {
    if (urgent_busy(s)) ctl_probe(s, false, now_ns());
    else ctl_idle(s);
  }
  dispatch_locked(s, false);
  pthread_mutex_unlock(&s->qlock);
}
