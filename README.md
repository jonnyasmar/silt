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

## Releasing

`scripts/release.sh` builds `build/Silt-<version>.dmg`: a universal (arm64 +
x86_64) app signed with Developer ID and the hardened runtime, inside a signed
drag-to-install disk image. Set the version in `Resources/Info.plist` first.

Notarizing needs credentials stored once (an app-specific password, kept in
your keychain):

```sh
xcrun notarytool store-credentials silt-notary --apple-id <Apple ID email> --team-id Z4PL6853AL
NOTARY_PROFILE=silt-notary scripts/release.sh
```

That notarizes and staples both the app and the disk image, and only runs on
a clean working tree. An App Store Connect API key works too (`NOTARY_KEY_P8`,
`NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`), and `SILT_RELEASE_IDENTITY` picks another
Developer ID identity. Without credentials the image is signed but not
notarized: Gatekeeper blocks it on other Macs, so don't hand it out. The
background comes from `swift scripts/make-dmg-background.swift`, and the
window layout from `scripts/dmg/layout.json`.

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
  over. Marks survive a relaunch. Silt never deletes system or home folder
  locations, or a volume mounted inside the scan.
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
  every copy is re-checked against the exact file that was compared. Cleanup
  never removes the last copy: a marked copy goes only while another copy
  stays, unchanged since the search, and a copy edited since is left alone.
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
- **The pool sizes itself.** Past a point, more threads mostly buy the kernel
  more contention, not more speed. So the pool starts small and grows only
  while an extra pair of threads makes listing faster without making each
  item much more expensive. Threads leave after 5 s with nothing to do, so a
  settled scan holds none. Refreshes the app starts on its own (FSEvents) run
  as background work, at utility priority, two at a time. Listing never
  updates access times.
- The tree is flat and chunked: 24 bytes per entry, 48 per folder, and names
  in a shared arena. About 1.2M entries fit in ~55 MB.
- After the scan, an FSEvents stream re-lists only the folders that changed,
  and a re-listing updates the folder where it is: files that are still there
  keep their slot and name, new ones take spare room at the end, and vanished
  ones are marked removed. A folder only moves when it outgrows that room,
  and memory no folder uses any more goes back to the system. On a drive with
  cargo builds running, memory stays flat where it used to grow by
  ~200 MB a minute.
- Big folders that change constantly (build output, browser caches) are
  re-listed at a pace that scales with their size, a 60,000-file folder at
  most every 2.4 s; small folders update immediately. Whole-tree views
  (Largest, Types, the inspector's breakdown) skip folders where nothing
  changed and otherwise refresh at a pace set by what their last pass cost.
- **Instant relaunch.** A settled scan is saved as a compacted, LZ4-compressed
  snapshot (about 26 MB for 1.2M items) in
  `~/Library/Caches/com.jonnyasmar.silt/Snapshots`, when the scan settles, at
  quit, and at most every 30 minutes. Loading streams straight into the tree.
  Reopening the same
  location shows it immediately, then FSEvents replays everything that changed
  since, so only those folders are re-listed. Removable and network volumes
  always rescan, and ⇧⌘R forces a fresh scan.
- **One copy of everything.** A location or folder inside a scan that's
  already open (Home inside Macintosh HD, a project inside `~/dev`) is shown
  from that scan, instantly, rather than scanned again. If the smaller one
  was scanned first, it folds into the bigger one when that finishes; marks
  and open folders carry over. Each view keeps its own place.
- **Hidden scans park.** A location that's been out of sight for two minutes
  (or any hidden one, when macOS runs short of memory) writes its tree to
  `~/Library/Caches/com.jonnyasmar.silt/Parked` exactly as it is and frees
  it: Storage (7.6M items) goes from ~520 MB to ~26 MB, and comes back in
  about half a second when shown again, then catches up on what changed.
  While parked it doesn't even listen for changes: waking replays them from
  FSEvents history. Marks, open folders, Reclaim results and duplicates
  survive.
- Tree chunks and big working buffers come straight from the kernel, so
  memory the engine frees really goes back to the system.
- **Rescans happen in place.** Every folder keeps its size and identity while
  its fresh listing replaces it, so the tree stays usable. The status bar
  shows a percentage, and folders still being re-checked show a hatched bar.
- **Nothing runs on a timer when nothing's happening.** While a scan runs, a
  12 Hz tick refreshes the visible cells. Afterwards Silt wakes only when files
  change or a chore is due. Locations nobody can see (hidden windows, other
  locations) do no UI work, and Reclaim and the capacity meter update only
  on screen.
- The UI is an `NSOutlineView` whose rows are created lazily. Open folders
  re-sort only when something inside them changed, and a re-listed folder's
  rows are updated in place rather than reloaded.

Measured on `~/dev` (1.3M items) on an M3 Max, with other work loading the
machine (load average 24–92). This is the release app, launched hidden, in
the same session as the build before the performance round:

| | Before | Now |
|---|---|---|
| Full scan: CPU time | 101 s | 29 s |
| Full scan: wall time | 11.3 s | 8.9 s |
| Settled memory | 215 MB | 172 MB |
| Settled CPU on a changing disk | 1.9 s a minute | 0.1 s a minute |
| Settled CPU on a quiet folder | 1.8 % of a core | ~0.03 % |
| Threads when settled | 32–35 | 4–7 |

`du -sk` took 71 s on the same folder.

## Sizes, precisely

Sizes are **bytes on disk, counted once**. Blocks shared by several hard links
or APFS clones are split between the files sharing them. Full clones count
`size ÷ clone count`; a partial clone counts its own blocks plus half of what
it shares. On a volume full of cloned cargo target folders, Silt reports
1,143 GB against 1,157 GB used according to `df` (the rest is APFS metadata and
snapshots). The inspector shows a clone's full size alongside its share.

For whole volumes, the difference between what the volume says is in use and
what the scan found appears as **System & hidden space**. Expand it (or
select it) to see what it's made of: purgeable space (local Time Machine
snapshots and caches macOS frees by itself), the other volumes sharing the
disk (swap, Preboot, Recovery), and data only macOS can read.
