// silt-bench: scans a path with SiltCore and reports throughput.
//   silt-bench <path> [threads]
#include <silt.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: silt-bench <path> [threads]\n");
    return 2;
  }
  int threads = argc > 2 ? atoi(argv[2]) : 16;
  silt_tree *t = silt_tree_create(argv[1]);
  silt_scanner *s = silt_scanner_start(t, threads);
  silt_scanner_wait_idle(s);
  silt_progress p;
  silt_scanner_progress(s, &p);
  double mem = (double)t->entry_count * sizeof(silt_entry) +
               (double)t->dir_count * sizeof(silt_dir) + (double)t->name_used;
  printf("threads=%d  time=%.3fs  entries=%llu  dirs=%llu  denied=%llu  "
         "size=%.2f GB  rate=%.2fM entries/s  tree=%.0f MB\n",
         threads, p.elapsed, (unsigned long long)p.files,
         (unsigned long long)p.dirs, (unsigned long long)p.denied,
         (double)p.bytes / 1e9, (double)p.files / p.elapsed / 1e6, mem / 1e6);
  if (getenv("SILT_TOP")) {
    uint32_t top[10];
    uint32_t n = silt_top_files(t, 0, top, 10);
    char path[4096];
    for (uint32_t i = 0; i < n; i++) {
      silt_path(t, top[i], path, sizeof path);
      printf("  %8.2f GB  %s\n", (double)silt_entry_at(t, top[i])->size / 1e9, path);
    }
  }
  silt_scanner_destroy(s);
  silt_tree_destroy(t);
  return 0;
}
