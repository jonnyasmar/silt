// silt-bench: scans a path with SiltCore and reports throughput.
//   silt-bench <path> [threads]
// With SILT_WATCH=<seconds>, it then follows FSEvents under <path> the way
// the app does (each changed folder re-listed) and reports memory every 10 s.
// SILT_THROTTLE=1 applies the app's pacing for big, busy folders.
#include <silt.h>

#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static silt_tree *tree;
static silt_scanner *scanner;
static bool throttle;
static uint64_t events, refreshes, deferred;

// Per-folder pacing, mirroring the app: a folder is re-listed at most every
// (children × 40 µs), capped at 5 s.
#define PACE_SLOTS 4096
static struct pace { uint32_t dir; double last, due; } paces[PACE_SLOTS];

static volatile bool sampling;
static volatile uint64_t peak;

static uint64_t footprint(void);

static void *sampler(void *arg) {
  while (sampling) {
    uint64_t f = footprint();
    if (f > peak) peak = f;
    usleep(2000);
  }
  return NULL;
}

static double now_s(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

static uint64_t footprint(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS) return 0;
  return info.phys_footprint;
}

static void report(const char *label) {
  silt_memory m;
  silt_tree_memory_stats(tree, &m);
  silt_progress p;
  silt_scanner_progress(scanner, &p);
  printf("%-8s footprint=%5.0f MB  entries=%5.0f MB (slots %llu, live %llu, freed chunks %llu)  "
         "names=%4.0f MB  dirs=%3.0f MB  items=%llu  listed=%llu  events=%llu refreshes=%llu deferred=%llu\n",
         label, footprint() / 1e6, m.entry_bytes / 1e6, (unsigned long long)m.entry_slots,
         (unsigned long long)m.live_slots, (unsigned long long)m.chunks_freed, m.name_bytes / 1e6,
         m.dir_bytes / 1e6, (unsigned long long)p.files, (unsigned long long)p.listed,
         (unsigned long long)events, (unsigned long long)refreshes, (unsigned long long)deferred);
  fflush(stdout);
}

// Nearest folder at or above `path` that the tree has listed.
static uint32_t nearest_dir(char *path) {
  size_t len = strlen(path);
  while (len > 1 && path[len - 1] == '/') path[--len] = 0;
  for (;;) {
    uint32_t e = silt_lookup(tree, path);
    if (e != SILT_NONE && silt_entry_at(tree, e)->kind == SILT_KIND_DIR) return silt_entry_at(tree, e)->aux;
    char *slash = strrchr(path, '/');
    if (!slash || slash == path) return SILT_NONE;
    *slash = 0;
  }
}

static void refresh(uint32_t dir, uint32_t count) {
  if (throttle) {
    double gap = count * 40e-6;
    if (gap > 5) gap = 5;
    if (gap >= 0.1) {
      struct pace *p = &paces[(dir * 2654435761u) % PACE_SLOTS];
      double t = now_s();
      if (p->dir == dir && t - p->last < gap) {
        if (p->due == 0) {
          p->due = p->last + gap;
          deferred++;
        }
        return;
      }
      *p = (struct pace){dir, t, 0};
    }
  }
  refreshes++;
  silt_scanner_refresh(scanner, dir, false);
}

static void flush_due(void) {
  double t = now_s();
  for (int i = 0; i < PACE_SLOTS; i++) {
    if (paces[i].due && paces[i].due <= t) {
      paces[i].last = t;
      paces[i].due = 0;
      refreshes++;
      silt_scanner_refresh(scanner, paces[i].dir, false);
    }
  }
}

static void on_events(ConstFSEventStreamRef stream, void *info, size_t n, void *paths,
                      const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
  char **list = paths;
  for (size_t i = 0; i < n; i++) {
    events++;
    char path[4096];
    strlcpy(path, list[i], sizeof path);
    silt_tree_lock(tree);
    uint32_t dir = nearest_dir(path);
    uint32_t count = dir == SILT_NONE ? 0 : silt_dir_at(tree, dir)->count;
    silt_tree_unlock(tree);
    if (dir != SILT_NONE) refresh(dir, count);
  }
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: silt-bench <path> [threads]\n");
    return 2;
  }
  int threads = argc > 2 ? atoi(argv[2]) : 16;
  tree = silt_tree_create(argv[1]);
  scanner = silt_scanner_start(tree, threads);
  silt_scanner_wait_idle(scanner);
  silt_progress p;
  silt_scanner_progress(scanner, &p);
  silt_memory m;
  silt_tree_memory_stats(tree, &m);
  printf("threads=%d  time=%.3fs  entries=%llu  dirs=%llu  denied=%llu  "
         "size=%.2f GB  rate=%.2fM entries/s  tree=%.0f MB\n",
         threads, p.elapsed, (unsigned long long)p.files,
         (unsigned long long)p.dirs, (unsigned long long)p.denied,
         (double)p.bytes / 1e9, (double)p.files / p.elapsed / 1e6,
         (m.entry_bytes + m.dir_bytes + m.name_bytes) / 1e6);
  if (getenv("SILT_TOP")) {
    uint32_t top[10];
    uint32_t n = silt_top_files(tree, 0, top, 10);
    char path[4096];
    for (uint32_t i = 0; i < n; i++) {
      silt_path(tree, top[i], path, sizeof path);
      printf("  %8.2f GB  %s\n", (double)silt_entry_at(tree, top[i])->size / 1e9, path);
    }
  }
  const char *snap = getenv("SILT_SNAP");
  if (snap) {
    // Save and reload a snapshot, reporting time and the footprint peak of
    // each step above the starting point (a sampler thread watches).
    silt_snapshot_meta meta = {0};
    uint64_t base = footprint();
    sampling = true;
    pthread_t th;
    pthread_create(&th, NULL, sampler, NULL);
    double t0 = now_s();
    bool saved = silt_tree_save(tree, snap, &meta);
    double t1 = now_s();
    uint64_t save_peak = peak;
    peak = footprint();
    silt_tree *loaded = saved ? silt_tree_load(snap, &meta) : NULL;
    double t2 = now_s();
    uint64_t load_peak = peak, loaded_fp = footprint();
    sampling = false;
    pthread_join(th, NULL);
    struct stat st;
    stat(snap, &st);
    printf("snapshot %.0f MB: save %.2fs (peak +%.0f MB), load %.2fs (peak +%.0f MB, loaded tree +%.0f MB)\n",
           st.st_size / 1e6, t1 - t0, (save_peak - base) / 1e6, t2 - t1, (load_peak - base) / 1e6,
           (loaded_fp - base) / 1e6);
    if (loaded) silt_tree_destroy(loaded);
    unlink(snap);
  }
  const char *park = getenv("SILT_PARK");
  if (park) {
    // Park and unpark, reporting time, file size and footprint.
    silt_scanner_destroy(scanner);
    scanner = NULL;
    malloc_zone_pressure_relief(NULL, 0);
    uint64_t f0 = footprint();
    double t0 = now_s();
    bool ok = silt_tree_park(tree, park);
    double t1 = now_s();
    malloc_zone_pressure_relief(NULL, 0);
    uint64_t f1 = footprint();
    if (getenv("SILT_VMMAP")) {
      char cmd[128];
      snprintf(cmd, sizeof cmd, "vmmap --summary %d | grep -E 'MALLOC_(LARGE|SMALL|MEDIUM)|Physical footprint'", getpid());
      system(cmd);
    }
    struct stat st;
    stat(park, &st);
    bool back = ok && silt_tree_unpark(tree, park);
    double t2 = now_s();
    uint64_t f2 = footprint();
    printf("park: ok=%d in %.2fs, file %.0f MB, footprint %.0f -> %.0f MB; unpark ok=%d in %.2fs, footprint %.0f MB\n",
           ok, t1 - t0, st.st_size / 1e6, f0 / 1e6, f1 / 1e6, back, t2 - t1, f2 / 1e6);
    unlink(park);
    scanner = silt_scanner_start_idle(tree, threads);
  }
  const char *watch = getenv("SILT_WATCH");
  if (watch) {
    throttle = getenv("SILT_THROTTLE") != NULL;
    const char *root = argv[1];
    CFStringRef cfroot = CFStringCreateWithCString(NULL, root, kCFStringEncodingUTF8);
    CFArrayRef roots = CFArrayCreate(NULL, (const void **)&cfroot, 1, &kCFTypeArrayCallBacks);
    FSEventStreamRef stream = FSEventStreamCreate(NULL, on_events, NULL, roots, kFSEventStreamEventIdSinceNow, 0.4,
                                                  kFSEventStreamCreateFlagWatchRoot);
    dispatch_queue_t q = dispatch_queue_create("bench.fsevents", DISPATCH_QUEUE_SERIAL);
    FSEventStreamSetDispatchQueue(stream, q);
    FSEventStreamStart(stream);
    report("start");
    double end = now_s() + atof(watch), next = now_s() + 10;
    while (now_s() < end) {
      usleep(100000);
      dispatch_sync(q, ^{ flush_due(); });
      if (now_s() >= next) {
        next += 10;
        char label[16];
        snprintf(label, sizeof label, "%4.0fs", atof(watch) - (end - now_s()));
        report(label);
      }
    }
    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    silt_scanner_wait_idle(scanner);
    report("end");
  }
  silt_scanner_destroy(scanner);
  silt_tree_destroy(tree);
  return 0;
}
