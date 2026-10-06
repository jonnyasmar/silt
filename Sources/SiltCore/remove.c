// Deleting a folder with a count of what's gone so far, for progress.
#include <errno.h>
#include <removefile.h>

#include "silt.h"

static int counted(removefile_state_t state, const char *path, void *context) {
  (void)state;
  (void)path;
  __atomic_fetch_add((uint64_t *)context, 1, __ATOMIC_RELAXED);
  return REMOVEFILE_PROCEED;
}

int silt_remove_tree(const char *path, uint64_t *done) {
  removefile_state_t state = removefile_state_alloc();
  if (!state) return ENOMEM;
  removefile_state_set(state, REMOVEFILE_STATE_STATUS_CALLBACK, (void *)counted);
  removefile_state_set(state, REMOVEFILE_STATE_STATUS_CONTEXT, done);
  int r = removefile(path, state, REMOVEFILE_RECURSIVE);
  int err = r == 0 ? 0 : (errno ? errno : EIO);
  removefile_state_free(state);
  return err;
}

uint64_t silt_load_count(const uint64_t *count) { return __atomic_load_n(count, __ATOMIC_RELAXED); }
