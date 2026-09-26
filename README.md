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
| Move to Trash | ⌘⌫ |
| Delete immediately | ⌥⌘⌫ (asks first) |
| Files · Largest · Reclaim · Types | ⌘1 – ⌘4 |
| Rescan | ⇧⌘R |

Other features:

- **Reclaim** finds known caches, build output (node_modules, Rust `target`,
  SwiftPM `.build`, DerivedData…), installers, model weights, and large files
  untouched for a year. It works from the scan, with no extra disk reads.
- **File Types** breaks space down by kind and extension.
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
- The UI is an `NSOutlineView` whose rows are created lazily. A 12 Hz tick
  refreshes only the visible cells and re-sorts expanded folders, animating
  the moves.

Measured on `~/dev` (1.23M items, 88 GB) on an M3 Max under heavy load: Silt
scans in 5–9 s; `du -sk` took 71 s.

## Sizes, precisely

Sizes are **allocated bytes on disk**. A file with several hard links is split
evenly across its links. APFS clones share blocks but each copy reports its
full allocation, so totals can overstate what deleting a clone would free.
