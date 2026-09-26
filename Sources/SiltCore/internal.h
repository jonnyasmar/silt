#pragma once

#include "silt.h"

#include <os/lock.h>

#define SILT_MAX_GUARDS 16

typedef struct silt_internal {
  os_unfair_lock lock;
  uint64_t dirs_listed;
  uint64_t denied;
  char *guards[SILT_MAX_GUARDS];
  uint32_t guard_count;
} silt_internal;

bool tree_is_guarded(const silt_tree *t, const char *path);

static inline silt_internal *silt_int(const silt_tree *t) {
  return (silt_internal *)t->internal;
}

// All of these require the tree lock.
void tree_reserve_entries(silt_tree *t, uint32_t n);
uint32_t tree_new_dir(silt_tree *t, uint32_t entry, uint64_t file_id,
                      uint32_t pending, uint32_t state);
// Copies `len` bytes of names into the arena. If they fit contiguously the
// base offset is returned and *contiguous is set; otherwise callers place
// names one at a time with tree_put_name.
uint32_t tree_put_names(silt_tree *t, const uint8_t *buf, uint32_t len,
                        bool *contiguous);
uint32_t tree_put_name(silt_tree *t, const uint8_t *name, uint32_t len);
// Adds deltas to `dir` and every ancestor.
void tree_propagate(silt_tree *t, uint32_t dir, int64_t size, int64_t items,
                    uint32_t newest, int64_t pending);
bool tree_dir_live(const silt_tree *t, uint32_t dir);
// Recomputes `newest` exactly for `dir` from its children, then for each
// ancestor. Used when a refresh may have lowered it.
void tree_recompute_newest(silt_tree *t, uint32_t dir);
