// Files the user's processes hold open, or have mapped into memory (a
// running app's own binary, a database): deleting one frees nothing until
// it's let go.
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <unistd.h>

#include "silt.h"

// Like PROC_PIDREGIONPATHINFO, but only regions backed by a file: what
// libproc's own proc_listpidspath walks (the public flavor visits every
// region, some 30 times as many). Missing from the public headers; where
// the kernel refuses it, mapped files just go unnoticed.
#define SILT_PIDREGIONPATHINFO2 22

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : x > y;
}

uint32_t silt_open_files(int32_t dev, uint64_t *inodes, uint32_t cap) {
  uint32_t n = 0;
  int count = proc_listallpids(NULL, 0);
  if (count <= 0) return 0;
  pid_t *pids = calloc((size_t)count + 64, sizeof *pids);
  if (!pids) return 0;
  count = proc_listallpids(pids, (int)((count + 64) * sizeof *pids));
  for (int i = 0; i < count && n < cap; i++) {
    pid_t pid = pids[i];
    if (pid <= 0) continue;
    int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) continue; // not ours to look at, or gone
    struct proc_fdinfo *fds = malloc((size_t)bytes);
    if (!fds) continue;
    bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
    int nfds = bytes > 0 ? bytes / (int)sizeof *fds : 0;
    for (int k = 0; k < nfds && n < cap; k++) {
      if (fds[k].proc_fdtype != PROX_FDTYPE_VNODE) continue;
      struct vnode_fdinfo info;
      if (proc_pidfdinfo(pid, fds[k].proc_fd, PROC_PIDFDVNODEINFO, &info, sizeof info) != sizeof info) continue;
      if ((int32_t)info.pvi.vi_stat.vst_dev == dev) inodes[n++] = info.pvi.vi_stat.vst_ino;
    }
    free(fds);
    uint64_t addr = 0;
    for (;;) {
      struct proc_regionwithpathinfo region;
      if (n >= cap || proc_pidinfo(pid, SILT_PIDREGIONPATHINFO2, addr, &region, sizeof region) <= 0) break;
      const struct vinfo_stat *st = &region.prp_vip.vip_vi.vi_stat;
      if ((int32_t)st->vst_dev == dev && st->vst_ino) inodes[n++] = st->vst_ino;
      uint64_t next = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size;
      if (next <= addr) break;
      addr = next;
    }
  }
  free(pids);
  qsort(inodes, n, sizeof *inodes, cmp_u64);
  uint32_t kept = 0; // dedupe
  for (uint32_t i = 0; i < n; i++)
    if (kept == 0 || inodes[kept - 1] != inodes[i]) inodes[kept++] = inodes[i];
  return kept;
}
