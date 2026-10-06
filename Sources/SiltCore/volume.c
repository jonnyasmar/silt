// Local APFS snapshots of a volume, with their exact creation times.
#include <fcntl.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/snapshot.h>
#include <unistd.h>

#include "silt.h"

int silt_volume_snapshots(const char *mount, silt_volume_snapshot *out, int cap) {
  int fd = open(mount, O_RDONLY | O_DIRECTORY);
  if (fd < 0) return -1;
  // Without RETURNED_ATTRS the call refuses (EINVAL).
  struct attrlist al = {.bitmapcount = ATTR_BIT_MAP_COUNT,
                        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_CRTIME};
  char buf[16384];
  int count = 0;
  for (;;) {
    int n = fs_snapshot_list(fd, &al, buf, sizeof buf, 0);
    if (n < 0) {
      close(fd);
      return -1;
    }
    if (n == 0) break;
    const char *p = buf;
    for (int i = 0; i < n; i++) {
      uint32_t len;
      memcpy(&len, p, 4);
      attribute_set_t ret;
      memcpy(&ret, p + 4, sizeof ret);
      const char *q = p + 4 + sizeof ret;
      attrreference_t ref;
      memcpy(&ref, q, sizeof ref);
      struct timespec created = {0};
      if (ret.commonattr & ATTR_CMN_CRTIME) memcpy(&created, q + sizeof ref, sizeof created);
      if (count < cap && (ret.commonattr & ATTR_CMN_NAME) && ref.attr_length > 0) {
        size_t nlen = ref.attr_length - 1; // includes the NUL
        if (nlen >= sizeof out[count].name) nlen = sizeof out[count].name - 1;
        memcpy(out[count].name, q + ref.attr_dataoffset, nlen);
        out[count].name[nlen] = 0;
        out[count].created = created.tv_sec;
        count++;
      }
      p += len;
    }
  }
  close(fd);
  return count;
}
