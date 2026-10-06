// What removing a file or folder would free, measured on disk at the time:
// the tree can lag behind (paused updates, a scan catching up), and space
// promised from a stale listing is space nobody gets back.
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <time.h>
#include <unistd.h>

#include "silt.h"

typedef struct measurer {
  const int64_t *cutoffs;
  uint32_t k;
  int64_t *buckets;
  silt_measure *out;
  uint64_t deadline_ns; // 0: none
  bool extended;        // the volume answers ATTR_CMN_EXTENDED requests
  const uint64_t *open; // sorted inodes held open by running apps
  uint32_t open_count;
  uint32_t depth;
} measurer;

static bool is_open(const measurer *m, uint64_t ino) {
  uint32_t lo = 0, hi = m->open_count;
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    if (m->open[mid] < ino) lo = mid + 1;
    else hi = mid;
  }
  return lo < m->open_count && m->open[lo] == ino;
}

static uint32_t bucket_at(const measurer *m, int64_t t) {
  uint32_t lo = 0, hi = m->k; // first cutoff after t
  while (lo < hi) {
    uint32_t mid = (lo + hi) / 2;
    if (m->cutoffs[mid] <= t) lo = mid + 1;
    else hi = mid;
  }
  return lo;
}

// A file: born or last written at `t` (whichever is earlier: a file born
// before a snapshot may share blocks with it whatever its mtime), `alloc`
// bytes, shared with other files if hard-linked or a clone. Unknown times
// count as before every snapshot.
static void count_file(measurer *m, bool known, int64_t t, int64_t alloc, bool shared, uint64_t ino) {
  m->out->total += alloc;
  m->out->files++;
  if (ino && is_open(m, ino)) {
    m->out->in_use += alloc;
    return;
  }
  if (shared) {
    m->out->shared += alloc;
    return;
  }
  m->buckets[known ? bucket_at(m, t) : 0] += alloc;
}

static bool past_deadline(const measurer *m) {
  return m->deadline_ns && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > m->deadline_ns;
}

static struct attrlist attrs(bool extended) {
  struct attrlist al = {
      .bitmapcount = ATTR_BIT_MAP_COUNT,
      .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE |
                    ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_FILEID,
      .dirattr = ATTR_DIR_MOUNTSTATUS,
      .fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE,
  };
  if (extended) al.forkattr = ATTR_CMNEXT_EXT_FLAGS;
  return al;
}

// Measures the folder open at `fd` (closed here) and everything under it.
static void walk(measurer *m, int fd) {
  enum { BUF = 128 * 1024 };
  char *buf = malloc(BUF);
  char **subdirs = NULL;
  size_t nsub = 0, capsub = 0;
  if (!buf) {
    close(fd);
    m->out->complete = false;
    return;
  }
  for (;;) {
    if (past_deadline(m)) {
      m->out->complete = false;
      break;
    }
    struct attrlist al = attrs(m->extended);
    int n = getattrlistbulk(fd, &al, buf, BUF, m->extended ? FSOPT_ATTR_CMN_EXTENDED : 0);
    if (n < 0 && m->extended && errno == EINVAL) {
      m->extended = false; // a volume without them (exFAT and the like)
      continue;
    }
    if (n < 0) {
      m->out->unreadable++;
      m->out->complete = false;
      break;
    }
    if (n == 0) break;
    const char *p = buf;
    for (int i = 0; i < n; i++) {
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
      f += sizeof ref;
      uint32_t type = VNON;
      if (ret.commonattr & ATTR_CMN_OBJTYPE) {
        memcpy(&type, f, 4);
        f += 4;
      }
      struct timespec born = {0, 0}, written = {0, 0};
      bool has_born = (ret.commonattr & ATTR_CMN_CRTIME) != 0;
      bool has_written = (ret.commonattr & ATTR_CMN_MODTIME) != 0;
      if (has_born) {
        memcpy(&born, f, sizeof born);
        f += sizeof born;
      }
      if (has_written) {
        memcpy(&written, f, sizeof written);
        f += sizeof written;
      }
      uint64_t ino = 0;
      if (ret.commonattr & ATTR_CMN_FILEID) {
        memcpy(&ino, f, 8);
        f += 8;
      }
      if (err) {
        if (type == VDIR) m->out->unreadable++;
        m->out->complete = false;
        continue;
      }
      if (type == VDIR) {
        uint32_t mount = 0;
        if (ret.dirattr & ATTR_DIR_MOUNTSTATUS) memcpy(&mount, f, 4);
        if (mount & (DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER)) continue; // another volume
        if (nsub == capsub) {
          capsub = capsub ? capsub * 2 : 64;
          char **grown = realloc(subdirs, capsub * sizeof *subdirs);
          if (!grown) {
            m->out->complete = false;
            continue;
          }
          subdirs = grown;
        }
        subdirs[nsub++] = strdup(name);
        continue;
      }
      uint32_t links = 1;
      int64_t alloc = 0;
      if (ret.fileattr & ATTR_FILE_LINKCOUNT) {
        memcpy(&links, f, 4);
        f += 4;
      }
      if (ret.fileattr & ATTR_FILE_ALLOCSIZE) {
        memcpy(&alloc, f, 8);
        f += 8;
      }
      uint64_t ext = 0;
      if (ret.forkattr & ATTR_CMNEXT_EXT_FLAGS) memcpy(&ext, f, 8);
      int64_t t = has_born && (!has_written || born.tv_sec < written.tv_sec) ? born.tv_sec : written.tv_sec;
      count_file(m, has_born || has_written, t, alloc,
                 type == VREG && (links > 1 || (ext & EF_MAY_SHARE_BLOCKS)), ino);
    }
  }
  free(buf);
  for (size_t i = 0; i < nsub; i++) {
    if (past_deadline(m) || m->depth >= 200) { // each level holds a descriptor
      m->out->complete = false;
    } else {
      int child = openat(fd, subdirs[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
      m->depth++;
      if (child >= 0) walk(m, child);
      else {
        m->out->unreadable++;
        m->out->complete = false;
      }
      m->depth--;
    }
    free(subdirs[i]);
  }
  free(subdirs);
  close(fd);
}

bool silt_measure_path(const char *path, const int64_t *cutoffs, uint32_t k, int64_t *buckets,
                       const uint64_t *open_inodes, uint32_t open_count, double deadline_seconds,
                       silt_measure *out) {
  memset(out, 0, sizeof *out);
  memset(buckets, 0, (size_t)(k + 1) * sizeof *buckets);
  out->complete = true;
  measurer m = {.cutoffs = cutoffs, .k = k, .buckets = buckets, .out = out, .extended = true,
                .open = open_inodes, .open_count = open_count};
  if (deadline_seconds > 0)
    m.deadline_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + (uint64_t)(deadline_seconds * 1e9);
  struct stat st;
  if (lstat(path, &st) != 0) return false;
  if (S_ISDIR(st.st_mode)) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) return false;
    walk(&m, fd);
    return true;
  }
  // One file (or link): the same facts lstat and getattrlist give.
  struct attrlist al = {.bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = ATTR_CMN_RETURNED_ATTRS,
                        .forkattr = ATTR_CMNEXT_EXT_FLAGS};
  struct __attribute__((packed)) {
    uint32_t len;
    attribute_set_t ret;
    uint64_t ext;
  } info = {0};
  uint64_t ext = 0;
  if (getattrlist(path, &al, &info, sizeof info, FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED) == 0 &&
      (info.ret.forkattr & ATTR_CMNEXT_EXT_FLAGS))
    ext = info.ext;
  int64_t t = st.st_birthtimespec.tv_sec < st.st_mtimespec.tv_sec ? st.st_birthtimespec.tv_sec
                                                                    : st.st_mtimespec.tv_sec;
  count_file(&m, true, t, (int64_t)st.st_blocks * 512,
             S_ISREG(st.st_mode) && (st.st_nlink > 1 || (ext & EF_MAY_SHARE_BLOCKS)), st.st_ino);
  return true;
}
