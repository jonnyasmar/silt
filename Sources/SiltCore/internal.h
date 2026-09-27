#pragma once

#include "silt.h"

#include <os/lock.h>

#define SILT_MAX_GUARDS 16
#define TREE_BUMP(t) ((void)__atomic_add_fetch(&(t)->generation, 1, __ATOMIC_RELEASE))

typedef struct silt_internal {
  os_unfair_lock lock;
  uint64_t dirs_listed;
  uint64_t entries_listed;
  uint64_t denied;
  char *guards[SILT_MAX_GUARDS];
  uint32_t guard_count;
  // Per entry chunk: slots that belong to a current run (spare room
  // included). A chunk behind the append point with none left is freed.
  uint32_t *chunk_live;
  uint64_t chunks_freed;
  bool parked; // storage is in a park file; every chunk is a shared stand-in
} silt_internal;

bool tree_is_guarded(const silt_tree *t, const char *path);

static inline silt_internal *silt_int(const silt_tree *t) {
  return (silt_internal *)t->internal;
}

// All of these require the tree lock.
void tree_reserve_entries(silt_tree *t, uint32_t n);
// Run bookkeeping: `claim` when slots [first, first + cap) start belonging to
// a folder, `release` when they stop. Released chunks may be freed.
void tree_claim_run(silt_tree *t, uint32_t first, uint32_t cap);
void tree_release_run(silt_tree *t, uint32_t first, uint32_t cap);
// Moves the append point to `count`, freeing chunks left behind empty.
void tree_set_entry_count(silt_tree *t, uint32_t count);
// Detaches `dir` and every folder beneath it, releasing their runs. Pending
// counts are the caller's business (the subtree's total is `dir`'s pending).
void tree_detach(silt_tree *t, uint32_t dir);
// Rebuilds chunk accounting from the runs (after loading a snapshot).
void tree_reset_accounting(silt_tree *t);
// Storage for entry, folder and name chunks (fixed sizes per kind).
void *tree_chunk_alloc(size_t bytes);
void tree_chunk_free(void *p, size_t bytes);
// The shared, read-only chunk that freed chunks point at.
silt_entry *tree_dead_chunk(void);
// Shared, read-only, all-zero stand-ins for a parked tree's folder and name
// chunks.
silt_dir *tree_zero_dir_chunk(void);
uint8_t *tree_zero_name_chunk(void);
// A fast word-wise checksum. Splitting the input at multiples of 8 bytes
// doesn't change the result.
uint64_t tree_checksum(uint64_t h, const void *p, size_t len);
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
