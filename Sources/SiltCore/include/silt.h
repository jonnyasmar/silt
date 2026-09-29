// SiltCore — the scanning engine and in-memory file tree behind Silt.
//
// The tree is a flat store designed for tens of millions of entries: every
// entry is 24 bytes, every directory adds 48 more, and names live in a shared
// byte arena. A directory's children always occupy one contiguous run of
// entry indices, so listing a folder is a pointer walk.
//
// Refreshes update a run in place where they can: surviving entries keep
// their index, new ones take spare room at the end of the run, and vanished
// ones stay behind flagged REMOVED. Only when the room runs out does the
// folder get a new run. Indices are never reused, and memory under runs that
// no longer belong to any folder is returned to the system; reading such an
// index is still safe and yields a REMOVED entry. Structural mutation
// (scans, refreshes, removals) happens under the tree lock; readers that may
// race a live scan take the same lock around short batches of reads.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SILT_NONE 0xFFFFFFFFu

enum {
  SILT_KIND_FILE = 0,
  SILT_KIND_DIR = 1,
  SILT_KIND_SYMLINK = 2,
  SILT_KIND_OTHER = 3,
};

enum {
  SILT_FLAG_HARDLINK = 1 << 0, // another link to an inode already counted
  SILT_FLAG_DENIED = 1 << 1,   // directory could not be read
  SILT_FLAG_MOUNT = 1 << 2,    // a different volume is mounted here
  SILT_FLAG_DATALESS = 1 << 3, // cloud placeholder, no local data
  SILT_FLAG_HIDDEN = 1 << 4,   // dot-file or UF_HIDDEN
  SILT_FLAG_REMOVED = 1 << 5,  // deleted by the user; awaiting refresh
  SILT_FLAG_CLONE = 1 << 6,    // APFS clone: shares blocks with other files
};

enum {
  SILT_DIR_QUEUED = 1 << 0,     // a listing of this directory is pending
  SILT_DIR_DETACHED = 1 << 1,   // no longer reachable from the root
  SILT_DIR_LISTED = 1 << 2,     // listed at least once
  SILT_DIR_DEEP = 1 << 3,       // the pending listing must revalidate the subtree
  SILT_DIR_INCOMPLETE = 1 << 4, // the last listing stopped early on an error
  SILT_DIR_ACTIVE = 1 << 5,     // this directory is being listed now
  SILT_DIR_DIRTY = 1 << 6,      // list it once more after the active listing
};

typedef struct silt_entry {
  // Bytes on disk this entry accounts for; directories: whole subtree.
  // Blocks shared by hard links or APFS clones are split between the files
  // sharing them, so totals match what the volume actually stores.
  int64_t size;
  uint32_t parent;   // dir id of the containing directory
  uint32_t name;     // offset into the name arena
  uint32_t aux;      // files: mtime (unix seconds); directories: dir id
  uint16_t name_len; // bytes, not NUL-terminated
  uint8_t kind;
  uint8_t flags;
} silt_entry;

typedef struct silt_dir {
  uint64_t file_id; // inode, so a refresh only reuses the same folder
  uint32_t entry;   // index of this directory's own entry
  uint32_t first;   // index of the first child entry
  uint32_t count;   // number of child entries (including removed ones)
  uint32_t cap;     // slots reserved for the run: `count` plus room to grow
  uint32_t items;   // descendants, files and folders
  uint32_t newest;  // newest file mtime anywhere in the subtree
  uint32_t pending; // folders in this subtree (self included) not yet listed
  uint32_t state;
  uint32_t version; // changes whenever entries join or leave the run
  uint32_t listed_at; // unix seconds this folder was last read; 0 if never
} silt_dir;

#define SILT_ENTRY_SHIFT 16
#define SILT_ENTRY_MASK ((1u << SILT_ENTRY_SHIFT) - 1)
#define SILT_ENTRY_CHUNKS (1u << 16)
#define SILT_DIR_SHIFT 14
#define SILT_DIR_MASK ((1u << SILT_DIR_SHIFT) - 1)
#define SILT_DIR_CHUNKS (1u << 18)
#define SILT_NAME_SHIFT 22
#define SILT_NAME_MASK ((1u << SILT_NAME_SHIFT) - 1)
#define SILT_NAME_CHUNKS (1u << 10)

typedef struct silt_tree {
  silt_entry **entries; // SILT_ENTRY_CHUNKS chunk pointers
  silt_dir **dirs;      // SILT_DIR_CHUNKS chunk pointers
  uint8_t **names;      // SILT_NAME_CHUNKS chunk pointers
  uint32_t entry_count;
  uint32_t dir_count;
  uint32_t name_used;
  uint32_t reserved;
  uint64_t generation; // bumped on every mutation
  void *internal;
} silt_tree;

static inline silt_entry *silt_entry_at(const silt_tree *t, uint32_t i) {
  return &t->entries[i >> SILT_ENTRY_SHIFT][i & SILT_ENTRY_MASK];
}

static inline silt_dir *silt_dir_at(const silt_tree *t, uint32_t d) {
  return &t->dirs[d >> SILT_DIR_SHIFT][d & SILT_DIR_MASK];
}

static inline const uint8_t *silt_name_ptr(const silt_tree *t, uint32_t off) {
  return &t->names[off >> SILT_NAME_SHIFT][off & SILT_NAME_MASK];
}

// MARK: Tree lifecycle

// `root_path` is the absolute path the tree describes; it becomes the name of
// entry 0 / dir 0.
silt_tree *silt_tree_create(const char *root_path);
void silt_tree_destroy(silt_tree *t);

// Folders directly inside `parent_path` are recorded but not opened; they're
// flagged DENIED instead. Used to avoid macOS privacy prompts (other apps'
// containers) when the app lacks Full Disk Access. Call before scanning.
void silt_tree_guard(silt_tree *t, const char *parent_path);

void silt_tree_lock(silt_tree *t);
void silt_tree_unlock(silt_tree *t);

// Mutation counter, safe to read without the tree lock.
uint64_t silt_tree_generation(const silt_tree *t);

// Lock held. A value that changes whenever anything in `dir`'s subtree
// changes: its run, or any descendant's size, items, newest, pending, or
// flags. Equal stamps mean nothing under `dir` changed. Not persisted.
uint32_t silt_dir_stamp(const silt_tree *t, uint32_t dir);

typedef struct silt_memory {
  uint64_t entry_slots;  // entry indices handed out so far (never reused)
  uint64_t live_slots;   // slots held by current runs, spare room included
  uint64_t entry_bytes;  // entry storage currently allocated
  uint64_t dir_bytes;    // directory records
  uint64_t name_bytes;   // name arena in use
  uint64_t chunks_freed; // entry chunks returned to the system
} silt_memory;

// Where the tree's memory is going. Takes the lock.
void silt_tree_memory_stats(silt_tree *t, silt_memory *out);

// MARK: Reading (hold the lock while a scan or refresh may be running)

// Writes the absolute path of `entry` into `buf` (NUL-terminated). Returns the
// length, or 0 if it did not fit.
size_t silt_path(const silt_tree *t, uint32_t entry, char *buf, size_t cap);

// Fills `out` with the first `cap` live (non-removed) children of `dir` in
// sorted order. Returns the number written. `key`: 0 size desc, 1 name asc,
// 2 items desc, 3 modified desc.
uint32_t silt_children_sorted(const silt_tree *t, uint32_t dir, int key,
                              uint32_t *out, uint32_t cap);

// The same, but called WITHOUT the lock: it takes the lock only to copy what
// it sorts by, and sorts after releasing it. The caller guarantees the tree
// isn't being parked meanwhile (names must stay mapped).
uint32_t silt_children_sorted_unlocked(silt_tree *t, uint32_t dir, int key,
                                       uint32_t *out, uint32_t cap);

// Resolves an absolute path to an entry index, or SILT_NONE. Only walks
// directories that have been listed.
uint32_t silt_lookup(const silt_tree *t, const char *path);

// True if `entry` is still reachable from the root. An entry stands for a
// name in a folder: a file deleted and recreated under the same name between
// two listings keeps its entry (folders are also matched by inode). Anything
// acting on a file should check it on disk, as the app does.
bool silt_is_live(const silt_tree *t, uint32_t entry);

// MARK: Scanning

typedef struct silt_scanner silt_scanner;

typedef struct silt_progress {
  uint64_t files;
  uint64_t dirs;
  uint64_t bytes;
  uint64_t denied;
  uint64_t listed;  // entries listed so far, across scans and refreshes
  uint32_t queued;  // listings waiting or running
  uint32_t active;  // listings running right now
  bool idle;        // nothing queued or running
  double elapsed;   // seconds since the most recent full scan began
  double finished;  // seconds the most recent full scan took (0 while running)
  uint32_t urgent_queued; // urgent listings waiting or running
  uint32_t limit;         // listings allowed to run at once right now
  uint32_t threads;       // worker threads alive
} silt_progress;

// Starts a pool of `threads` workers bound to `t` and queues a full scan of the
// root. The scanner stays alive afterwards to serve refreshes.
//
// Threading: progress/refresh may be called from any thread, but never
// concurrently with silt_scanner_destroy, and the tree must outlive the
// scanner. Cancellation is terminal: it is meant to precede destroy.
silt_scanner *silt_scanner_start(silt_tree *t, int threads);
void silt_scanner_progress(silt_scanner *s, silt_progress *out);
// Stops workers after their current listing; queued work is discarded.
void silt_scanner_cancel(silt_scanner *s);
// Blocks until the queue drains (or the scanner is cancelled).
void silt_scanner_wait_idle(silt_scanner *s);
// Cancels, joins workers, and frees the scanner. The tree remains valid.
void silt_scanner_destroy(silt_scanner *s);

// Re-lists `dir`. Subfolders that still exist (same name and inode) keep
// their scanned contents; new ones are scanned. With `deep`, every surviving
// subfolder is re-listed too, recursively, but in place: sizes and identities
// stay put until each folder's fresh listing replaces them, so a rescan never
// empties the tree. Duplicate requests coalesce; a deep request upgrades a
// pending shallow one.
void silt_scanner_refresh(silt_scanner *s, uint32_t dir, bool deep);

#define SILT_REFRESH_DEEP 1u
#define SILT_REFRESH_URGENT 2u // someone is waiting on it: scan-class priority

// Like silt_scanner_refresh, with flags. Without SILT_REFRESH_URGENT the
// listing (and everything it queues beneath it) runs as background work.
void silt_scanner_refresh_ex(silt_scanner *s, uint32_t dir, uint32_t flags);

// Marks `entry` removed and subtracts it from every ancestor immediately, so
// the UI reflects a deletion before the file system reports it. The next
// refresh of its parent drops it for good.
void silt_tree_remove(silt_tree *t, uint32_t entry);

// Like silt_scanner_start, but queues nothing: for a tree restored from a
// snapshot, which only needs refreshes.
silt_scanner *silt_scanner_start_idle(silt_tree *t, int threads);

// MARK: Snapshots

typedef struct silt_snapshot_meta {
  uint64_t event_id;       // FSEvents id the snapshot is current as of
  uint8_t volume_uuid[16]; // FSEvents database the id belongs to
  double saved_at;         // unix seconds
  uint32_t flags;          // caller-defined (e.g. whether FDA was granted)
} silt_snapshot_meta;

// Writes a compacted copy of the tree (live entries only) to `path`
// atomically. Takes the lock. Returns false on I/O error, or if a scan is
// still pending anywhere in the tree. Folders whose last listing stopped
// early keep SILT_DIR_INCOMPLETE; list them again after loading.
bool silt_tree_save(silt_tree *t, const char *path, const silt_snapshot_meta *meta);

// Loads a snapshot. Returns NULL if the file is missing, damaged, or from
// another format version. The tree's root path is stored in the file.
silt_tree *silt_tree_load(const char *path, silt_snapshot_meta *meta);

// Reads only the header: false if the file is missing or not one this build
// can load. Cheap enough to call while drawing.
bool silt_snapshot_peek(const char *path, silt_snapshot_meta *meta);

// MARK: Parking

// Writes the tree's storage to `path` exactly as it is and frees it. Until
// silt_tree_unpark the tree is an empty shell: reads are safe but see nothing
// (every entry removed), and nothing may modify it, so no scanner may be
// running. Takes the lock. Returns false (changing nothing) on I/O error.
bool silt_tree_park(silt_tree *t, const char *path);
// Reads a parked tree back. Every index and dir id means what it did before.
// Returns false, leaving the tree parked, if the file is missing or damaged.
bool silt_tree_unpark(silt_tree *t, const char *path);
bool silt_tree_is_parked(silt_tree *t);

// MARK: Queries (each takes the lock itself; safe during a scan)

// The `cap` largest files under `dir`, largest first. Returns the count.
uint32_t silt_top_files(silt_tree *t, uint32_t dir, uint32_t *out,
                        uint32_t cap);

// The `cap` largest live direct children of `dir`, largest first. Unlike
// silt_children_sorted this never sorts the whole folder.
uint32_t silt_top_children(silt_tree *t, uint32_t dir, uint32_t *out,
                           uint32_t cap);

// Entries under `dir` whose name contains `needle` (ASCII case-insensitive),
// largest first. Returns the count.
uint32_t silt_search(silt_tree *t, uint32_t dir, const char *needle,
                     uint32_t *out, uint32_t cap);

// Entries (files or folders) under `dir` whose name equals one of `names`
// exactly, ignoring ASCII case. `which[i]` receives the index into `names`.
// Largest first. Takes the lock itself. Returns the count.
uint32_t silt_find_named(silt_tree *t, uint32_t dir, const char *const *names,
                         uint32_t count, uint32_t *out, uint32_t *which,
                         uint32_t cap);

// Folders under `dir` whose name matches one of `names`; matched folders are
// not descended into. `which[i]` receives the index into `names`. Largest
// first. Returns the count.
uint32_t silt_find_dirs(silt_tree *t, uint32_t dir, const char *const *names,
                        uint32_t name_count, uint32_t *out, uint32_t *which,
                        uint32_t cap);

// Every file under `dir` of at least `min_size` accounted bytes, plus all
// clone/hard-link candidates whose divided accounting may be below the
// threshold. Skips folders named in `skip` (dependency and build folders,
// bundles). Unordered. Returns the count, at most `cap`.
uint32_t silt_files_at_least(silt_tree *t, uint32_t dir, int64_t min_size,
                             const char *const *skip, uint32_t skip_count,
                             bool skip_packages, uint32_t *out, uint32_t cap);

// Files under `dir` at least `min_size` bytes whose mtime is older than
// `before` (unix seconds). Largest first. Returns the count.
uint32_t silt_stale_files(silt_tree *t, uint32_t dir, int64_t min_size,
                          uint32_t before, uint32_t *out, uint32_t cap);

// Files under `dir` whose lowercased extension is one of `exts` (no dots).
// `which[i]` receives the index into `exts`. Largest first.
uint32_t silt_find_files(silt_tree *t, uint32_t dir, const char *const *exts,
                         uint32_t ext_count, uint32_t *out, uint32_t *which,
                         uint32_t cap);

typedef struct silt_ext_stat {
  char ext[16]; // lowercased, without the dot; "" for none
  uint64_t bytes;
  uint64_t count;
} silt_ext_stat;

// Space by file extension under `dir`, largest first. Returns the count.
uint32_t silt_ext_stats(silt_tree *t, uint32_t dir, silt_ext_stat *out,
                        uint32_t cap);

#ifdef __cplusplus
}
#endif
