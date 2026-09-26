# Silt

A fast, live disk-space explorer for macOS. It's a drillable file tree in the
spirit of WinDirStat: it fills in while it scans and stays current as files
change.

## Build and run

```sh
scripts/build-app.sh            # build/Silt.app
scripts/build-app.sh --install  # also copy to /Applications and launch
swift test                      # engine tests
```

Requires macOS 15+ and Xcode 26. You can also launch the binary with a folder
to scan it straight away (`Silt.app/Contents/MacOS/Silt ~/dev`), or drop a
folder on the window or the Dock icon.

For a complete picture, give Silt **Full Disk Access** (System Settings →
Privacy & Security). Without it, Silt skips other apps' containers rather
than trigger a privacy prompt for each one, and marks them as locked.

## Using it

| | |
|---|---|
| Show in Finder | ⌘R, double-click a file, or the hover button |
| Focus into a folder / open a file | ⌘↓ |
| Enclosing folder | ⌘↑ |
| Quick Look | Space |
| Copy path | ⌥⌘C |
| Mark for Cleanup | M (or the hover button) |
| Review & clean up | ⌘↩ |
| Move to Trash | ⌘⌫ |
| Delete immediately | ⌥⌘⌫ (asks first) |
| Files · Largest · Duplicates · Reclaim · Types | ⌘1 – ⌘5 (or the toolbar) |
| Rescan in place | ⇧⌘R |
| Rescan from scratch | ⌥⇧⌘R |

Other features:

- **Cleanup basket.** Mark anything with M, from Reclaim ("Mark All Safe"), or
  from Duplicates ("Mark All Extras"). A bar above the status line keeps a
  running, deduplicated total, and the capacity meter shows the marked share
  hatched. The review sheet gives every item a safety verdict (and warns
  about anything Silt would keep), can pull in everything Safe to clear, and
  lets you choose between Trash and deleting now. Only Trash is on the Return
  key. A mark remembers the exact file it was made on: if that file is
  replaced by another with the same name, the mark is dropped, not carried
  over. Marks survive a relaunch.
- **Undo and follow-through.** "Moved to the Trash" toasts have Undo, which
  puts everything back. The status bar remembers what's still waiting in the
  Trash and offers to empty it.
- **What changed.** Silt compares against the last scan (or the moment this
  one finished) and shows the folders that grew or shrank most: a status-bar
  chip ("+2.8 GB since yesterday") opens the list, and changed folders carry a
  "+1.2 GB" tag in the tree.
- **Guidance.** Rows for known things get a tag (Dependencies, Build output,
  Cache, Installer…). The inspector explains what the selection is, whether
  it's safe to remove, the exact reinstall command its lockfile implies, and
  how long its project has sat untouched.
- **Duplicates** finds files with identical contents. It compares size, then a
  sampled hash, then a full SHA-256, and skips dependency and build folders
  unless you ask. Results stream in, largest first. APFS clones already share
  their blocks, so they aren't counted as waste. Before anything is marked,
  every copy is re-checked against the exact file that was compared.
- **Reclaim** finds known caches, build output (node_modules, Rust target
  folders wherever they live, SwiftPM `.build`, DerivedData…), orphaned build
  output whose project is gone, installers, model weights, and large files
  untouched for a year. Build output in projects you haven't touched for
  three months gets its own group at the top. It works from the scan, with no
  extra disk reads.
- **File Types** breaks space down by kind and extension.
- **Largest Files** folds copies (same name and size in several places) into
  one row, so duplicates stand out.
- **Search** matches names anywhere in the scan, largest first.

## How it's fast

- **SiltCore** (C) lists directories with `getattrlistbulk` across a pool of
  threads. Each listing is one syscall pass plus one short critical section
  that appends the entries and pushes size deltas up the ancestor chain. So
  every folder's total is correct-so-far at every instant, and the UI shows it
  live.
- The tree is flat, chunked, and append-only: 24 bytes per entry, 40 per
  folder, and names in a shared arena. About 1.2M entries fit in ~55 MB.
- After the scan, an FSEvents stream re-lists only the folders that changed.
  Unchanged listings are updated in place.
- **Instant relaunch.** A settled scan is saved as a compacted, LZ4-compressed
  snapshot (about 26 MB for 1.2M items) in
  `~/Library/Caches/com.jonnyasmar.silt/Snapshots`. Reopening the same
  location shows it immediately, then FSEvents replays everything that changed
  since, so only those folders are re-listed. Removable and network volumes
  always rescan, and ⇧⌘R forces a fresh scan.
- **Rescans happen in place.** Every folder keeps its size and identity while
  its fresh listing replaces it, so the tree stays usable. The status bar
  shows a percentage, and folders still being re-checked show a hatched bar.
- The UI is an `NSOutlineView` whose rows are created lazily. A 12 Hz tick
  refreshes only the visible cells and re-sorts expanded folders, animating
  the moves.

Measured on `~/dev` (1.23M items, 88 GB) on an M3 Max under heavy load: Silt
scans in 5–9 s; `du -sk` took 71 s.

## Sizes, precisely

Sizes are **bytes on disk, counted once**. Blocks shared by several hard links
or APFS clones are split between the files sharing them. Full clones count
`size ÷ clone count`; a partial clone counts its own blocks plus half of what
it shares. On a volume full of cloned cargo target folders, Silt reports
1,143 GB against 1,157 GB used according to `df` (the rest is APFS metadata and
snapshots). The inspector shows a clone's full size alongside its share.
