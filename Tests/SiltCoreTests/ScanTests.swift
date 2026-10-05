import Foundation
import SiltCore
import Testing

/// Builds a scratch tree, scans it, and checks the engine's accounting.
final class Fixture {
    let root: URL
    let tree: UnsafeMutablePointer<silt_tree>
    let scanner: OpaquePointer

    init(_ layout: [String: Int]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("silt-test-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, size) in layout { try Fixture.write(root.appendingPathComponent(path), size: size) }
        tree = silt_tree_create(root.path)
        scanner = silt_scanner_start(tree, 4)
        silt_scanner_wait_idle(scanner)
    }

    deinit {
        silt_scanner_destroy(scanner)
        silt_tree_destroy(tree)
        try? FileManager.default.removeItem(at: root)
    }

    static func write(_ url: URL, size: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: size).write(to: url)
    }

    func entry(_ rel: String) -> silt_entry? {
        silt_tree_lock(tree)
        defer { silt_tree_unlock(tree) }
        let i = silt_lookup(tree, rel.isEmpty ? root.path : root.appendingPathComponent(rel).path)
        return i == 0xFFFF_FFFF ? nil : silt_entry_at(tree, i).pointee
    }

    func dir(_ rel: String) -> silt_dir? {
        guard let e = entry(rel), e.kind == UInt8(SILT_KIND_DIR) else { return nil }
        silt_tree_lock(tree)
        defer { silt_tree_unlock(tree) }
        return silt_dir_at(tree, e.aux).pointee
    }

    func size(_ rel: String) -> Int64 { entry(rel)?.size ?? -1 }

    /// Sum of allocated sizes as the file system reports them.
    func expected(_ rel: String) -> Int64 {
        let url = rel.isEmpty ? root : root.appendingPathComponent(rel)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    func refresh(_ rel: String, deep: Bool = false) {
        guard let e = entry(rel) else { return }
        silt_scanner_refresh(scanner, e.aux, deep)
        silt_scanner_wait_idle(scanner)
    }
}

@Test func scanTotalsMatchFileSystem() throws {
    let f = try Fixture([
        "a/one.bin": 100_000, "a/two.bin": 5_000, "a/deep/x/y/z.bin": 250_000,
        "b/three.bin": 1_000_000, ".hidden": 12_000, "empty/.keep": 0,
    ])
    #expect(f.size("") == f.expected(""))
    #expect(f.size("a") == f.expected("a"))
    #expect(f.size("a/deep") == f.expected("a/deep"))
    #expect(f.dir("")?.pending == 0)
    #expect(f.dir("")?.items == 12) // 6 folders + 6 files
    #expect(f.entry(".hidden")!.flags & UInt8(SILT_FLAG_HIDDEN) != 0)
}

@Test func shallowRefreshKeepsSubtreesAndTracksChanges() throws {
    let f = try Fixture(["a/sub/big.bin": 400_000, "a/small.bin": 1_000])
    let subBefore = f.entry("a/sub")!.aux
    try Fixture.write(f.root.appendingPathComponent("a/new.bin"), size: 300_000)
    f.refresh("a")
    #expect(f.entry("a/sub")!.aux == subBefore) // same folder, same dir id
    #expect(f.size("a") == f.expected("a"))
    #expect(f.size("") == f.expected(""))
    #expect(f.dir("")?.pending == 0)
}

@Test func inPlaceRefreshUpdatesSizes() throws {
    let f = try Fixture(["a/grow.bin": 10_000, "a/other.bin": 10_000])
    let before = f.dir("a")!.first
    try Fixture.write(f.root.appendingPathComponent("a/grow.bin"), size: 900_000)
    f.refresh("a")
    #expect(f.dir("a")!.first == before) // updated without a new run
    #expect(f.size("a") == f.expected("a"))
    #expect(f.size("") == f.expected(""))
}

@Test func recreatedFolderIsNotReused() throws {
    let f = try Fixture(["p/cache/old.bin": 500_000])
    let oldDir = f.entry("p/cache")!.aux
    try FileManager.default.removeItem(at: f.root.appendingPathComponent("p/cache"))
    try Fixture.write(f.root.appendingPathComponent("p/cache/new.bin"), size: 20_000)
    f.refresh("p")
    #expect(f.entry("p/cache")!.aux != oldDir)
    #expect(f.entry("p/cache/old.bin") == nil)
    #expect(f.size("p") == f.expected("p"))
    #expect(f.dir("")?.pending == 0)
}

@Test func deepRefreshRescansEverything() throws {
    let f = try Fixture(["d/x/1.bin": 50_000, "d/y/2.bin": 70_000])
    try Fixture.write(f.root.appendingPathComponent("d/x/3.bin"), size: 80_000)
    f.refresh("d") // shallow: x reused, its new file is not seen yet
    #expect(f.size("d/x") < f.expected("d/x"))
    f.refresh("d", deep: true)
    #expect(f.size("d/x") == f.expected("d/x"))
    #expect(f.size("") == f.expected(""))
    #expect(f.dir("")?.pending == 0)
}

@Test func removeSubtractsImmediately() throws {
    let f = try Fixture(["r/keep.bin": 10_000, "r/gone/a.bin": 600_000])
    let total = f.size("")
    let gone = f.size("r/gone")
    silt_tree_lock(f.tree)
    let idx = silt_lookup(f.tree, f.root.appendingPathComponent("r/gone").path)
    silt_tree_unlock(f.tree)
    silt_tree_remove(f.tree, idx)
    #expect(f.size("") == total - gone)
    silt_tree_lock(f.tree)
    #expect(!silt_is_live(f.tree, idx))
    silt_tree_unlock(f.tree)
    // The folder still exists on disk, so a refresh brings it back.
    f.refresh("r")
    #expect(f.size("") == total)
}

@Test func staleIndicesAreNotLive() throws {
    let f = try Fixture(["s/a.bin": 1_000, "s/b.bin": 2_000])
    silt_tree_lock(f.tree)
    let old = silt_lookup(f.tree, f.root.appendingPathComponent("s/a.bin").path)
    silt_tree_unlock(f.tree)
    try Fixture.write(f.root.appendingPathComponent("s/c.bin"), size: 3_000)
    f.refresh("s")
    silt_tree_lock(f.tree)
    #expect(!silt_is_live(f.tree, old)) // the folder got a new run
    let now = silt_lookup(f.tree, f.root.appendingPathComponent("s/a.bin").path)
    #expect(silt_is_live(f.tree, now))
    silt_tree_unlock(f.tree)
}

@Test func guardedFoldersAreNotOpened() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("silt-guard-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    try Fixture.write(root.appendingPathComponent("Containers/app/data.bin"), size: 100_000)
    let tree = silt_tree_create(root.path)!
    silt_tree_guard(tree, root.appendingPathComponent("Containers").path)
    let scanner = silt_scanner_start(tree, 2)!
    silt_scanner_wait_idle(scanner)
    silt_tree_lock(tree)
    let i = silt_lookup(tree, root.appendingPathComponent("Containers/app").path)
    let e = silt_entry_at(tree, i).pointee
    silt_tree_unlock(tree)
    #expect(e.flags & UInt8(SILT_FLAG_DENIED) != 0)
    #expect(e.size == 0)
    silt_scanner_destroy(scanner)
    silt_tree_destroy(tree)
}

@Test func pathAndLookupRoundTrip() throws {
    let f = try Fixture(["x/y/z.txt": 10])
    silt_tree_lock(f.tree)
    let i = silt_lookup(f.tree, f.root.appendingPathComponent("x/y/z.txt").path)
    var buf = [CChar](repeating: 0, count: 4096)
    _ = silt_path(f.tree, i, &buf, 4096)
    silt_tree_unlock(f.tree)
    #expect(String(cString: buf) == f.root.appendingPathComponent("x/y/z.txt").path)
}

@Test func queriesFindLargestAndNamedFolders() throws {
    let f = try Fixture([
        "proj/node_modules/pkg/index.js": 300_000, "proj/src/app.js": 1_000,
        "proj/node_modules/.bin/x": 1_000, "other/node_modules/y.js": 50_000, "big.mov": 2_000_000,
    ])
    var top = [UInt32](repeating: 0, count: 3)
    let n = silt_top_files(f.tree, 0, &top, 3)
    #expect(n == 3)
    silt_tree_lock(f.tree)
    #expect(silt_entry_at(f.tree, top[0]).pointee.size >= silt_entry_at(f.tree, top[1]).pointee.size)
    silt_tree_unlock(f.tree)

    let names = [strdup("node_modules")]
    defer { names.forEach { free($0) } }
    var out = [UInt32](repeating: 0, count: 10)
    var which = [UInt32](repeating: 0, count: 10)
    let found = names.map { UnsafePointer($0) }.withUnsafeBufferPointer {
        silt_find_dirs(f.tree, 0, $0.baseAddress!, 1, &out, &which, 10)
    }
    #expect(found == 2) // nested matches are not descended into
}

@Test func snapshotRoundTripCompactsAndStaysRefreshable() throws {
    let f = try Fixture(["a/one.bin": 100_000, "a/deep/two.bin": 50_000, "b/gone/x.bin": 300_000, "c.txt": 10])
    // Churn the tree first so the snapshot has garbage to drop.
    try Fixture.write(f.root.appendingPathComponent("a/new.bin"), size: 20_000)
    f.refresh("a")
    silt_tree_lock(f.tree)
    let gone = silt_lookup(f.tree, f.root.appendingPathComponent("b/gone").path)
    silt_tree_unlock(f.tree)
    silt_tree_remove(f.tree, gone)
    let before = f.size("")

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silt-\(UUID().uuidString).snap").path
    defer { unlink(file) }
    var meta = silt_snapshot_meta()
    meta.event_id = 12345
    meta.flags = 1
    #expect(silt_tree_save(f.tree, file, &meta))

    var loadedMeta = silt_snapshot_meta()
    let t = try #require(silt_tree_load(file, &loadedMeta))
    defer { silt_tree_destroy(t) }
    #expect(loadedMeta.event_id == 12345 && loadedMeta.flags == 1)
    silt_tree_lock(t)
    #expect(silt_entry_at(t, 0).pointee.size == before)
    #expect(t.pointee.entry_count < f.tree.pointee.entry_count) // garbage dropped
    #expect(silt_lookup(t, f.root.appendingPathComponent("b/gone").path) == 0xFFFF_FFFF)
    let deep = silt_lookup(t, f.root.appendingPathComponent("a/deep/two.bin").path)
    #expect(deep != 0xFFFF_FFFF && silt_is_live(t, deep))
    let a = silt_entry_at(t, silt_lookup(t, f.root.appendingPathComponent("a").path)).pointee
    silt_tree_unlock(t)

    // A restored tree takes refreshes like a scanned one.
    try Fixture.write(f.root.appendingPathComponent("a/later.bin"), size: 400_000)
    let s = silt_scanner_start_idle(t, 2)!
    silt_scanner_refresh(s, a.aux, false)
    silt_scanner_wait_idle(s)
    silt_tree_lock(t)
    let aAfter = silt_entry_at(t, silt_lookup(t, f.root.appendingPathComponent("a").path)).pointee
    #expect(aAfter.size == f.expected("a"))
    #expect(silt_dir_at(t, 0).pointee.pending == 0)
    silt_tree_unlock(t)
    silt_scanner_destroy(s)
}

@Test func damagedSnapshotIsRejected() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silt-bad.snap").path
    defer { unlink(file) }
    try Data("not a snapshot at all".utf8).write(to: URL(fileURLWithPath: file))
    #expect(silt_tree_load(file, nil) == nil)
    #expect(!silt_snapshot_peek(file, nil))
}

private func allocated(_ path: String) -> Int64 {
    var st = stat()
    return lstat(path, &st) == 0 ? Int64(st.st_blocks) * 512 : -1
}

@Test func clonesCountTheirSharedBlocksOnce() throws {
    let f = try Fixture(["c/original.bin": 5_000_000])
    let dir = f.root.appendingPathComponent("c")
    let original = dir.appendingPathComponent("original.bin").path
    #expect(clonefile(original, dir.appendingPathComponent("clone1.bin").path, 0) == 0)
    #expect(clonefile(original, dir.appendingPathComponent("clone2.bin").path, 0) == 0)
    f.refresh("c")
    let one = allocated(original)
    // Three files, one copy of the data on disk.
    #expect(f.size("c") == one / 3 * 3)
    let e = try #require(f.entry("c/clone1.bin"))
    #expect(e.flags & UInt8(SILT_FLAG_CLONE) != 0)
    #expect(e.size == one / 3)
}

@Test func partialClonesCountTheirOwnBlocksPlusAShare() throws {
    let f = try Fixture(["p/base.bin": 4_000_000])
    let dir = f.root.appendingPathComponent("p")
    let base = dir.appendingPathComponent("base.bin").path
    let copy = dir.appendingPathComponent("edited.bin").path
    #expect(clonefile(base, copy, 0) == 0)
    // Overwrite the first megabyte of the clone: those blocks become its own.
    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: copy))
    try h.write(contentsOf: Data(repeating: 9, count: 1_000_000))
    try h.close()
    f.refresh("p")
    let total = f.size("p")
    // Between "all shared" (one copy) and "nothing shared" (two copies).
    #expect(total > allocated(base) && total < allocated(base) + allocated(copy))
}

@Test func deepRefreshKeepsFolderIdentity() throws {
    let f = try Fixture(["d/x/y/1.bin": 50_000, "d/z/2.bin": 70_000])
    let xBefore = f.entry("d/x")!.aux
    let yBefore = f.entry("d/x/y")!.aux
    try Fixture.write(f.root.appendingPathComponent("d/x/y/3.bin"), size: 80_000)
    f.refresh("d", deep: true)
    #expect(f.entry("d/x")!.aux == xBefore) // same folders, revalidated in place
    #expect(f.entry("d/x/y")!.aux == yBefore)
    #expect(f.size("d") == f.expected("d"))
    #expect(f.dir("")?.pending == 0)
}

@Test func refreshWhileListingActiveQueuesOneFollowUp() throws {
    let f = try Fixture(["busy/seed.bin": 4_096])
    let busy = f.root.appendingPathComponent("busy")
    // Keep the listing active long enough to request a refresh mid-pass.
    for i in 0..<20_000 {
        let path = busy.appendingPathComponent("empty-\(i)").path
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        #expect(fd >= 0)
        if fd >= 0 { close(fd) }
    }
    try Fixture.write(busy.appendingPathComponent("latest.bin"), size: 700_000)

    var before = silt_progress()
    silt_scanner_progress(f.scanner, &before)
    let dir = try #require(f.entry("busy")).aux
    silt_scanner_refresh(f.scanner, dir, false)

    // A worker counts as active a moment before it marks the folder, so wait
    // for the folder itself.
    var listing = false
    let deadline = Date().addingTimeInterval(5)
    repeat {
        silt_tree_lock(f.tree)
        listing = silt_dir_at(f.tree, dir).pointee.state & UInt32(SILT_DIR_ACTIVE) != 0
        silt_tree_unlock(f.tree)
    } while !listing && Date() < deadline
    #expect(listing)
    silt_scanner_refresh(f.scanner, dir, false)
    silt_scanner_wait_idle(f.scanner)

    var after = silt_progress()
    silt_scanner_progress(f.scanner, &after)
    #expect(after.dirs == before.dirs + 2)
    #expect(f.dir("")?.pending == 0)
    #expect(f.size("busy") == f.expected("busy"))
}

@Test func cloneCandidatesIgnoreAccountedSizeThreshold() throws {
    let f = try Fixture(["c/original.bin": 5_000_000])
    let dir = f.root.appendingPathComponent("c")
    let original = dir.appendingPathComponent("original.bin").path
    let clone = dir.appendingPathComponent("clone.bin").path
    #expect(clonefile(original, clone, 0) == 0)
    f.refresh("c")

    let threshold: Int64 = 4_000_000
    let entry = try #require(f.entry("c/clone.bin"))
    #expect(entry.flags & UInt8(SILT_FLAG_CLONE) != 0)
    #expect(entry.size < threshold)
    let skip = [strdup("not-present")]
    defer { skip.forEach { free($0) } }
    var out = [UInt32](repeating: 0, count: 8)
    let n = skip.map { UnsafePointer($0) }.withUnsafeBufferPointer {
        silt_files_at_least(f.tree, 0, threshold, $0.baseAddress!, 1, false, &out, 8)
    }
    silt_tree_lock(f.tree)
    let names = (0..<Int(n)).map { i -> String in
        let e = silt_entry_at(f.tree, out[i]).pointee
        return String(decoding: UnsafeBufferPointer(start: silt_name_ptr(f.tree, e.name),
                                                     count: Int(e.name_len)), as: UTF8.self)
    }
    silt_tree_unlock(f.tree)
    #expect(names.contains("clone.bin"))
}

@Test func generationIncreasesAcrossRefresh() throws {
    let f = try Fixture(["g/file.bin": 10_000])
    let before = silt_tree_generation(f.tree)
    try Fixture.write(f.root.appendingPathComponent("g/file.bin"), size: 500_000)
    f.refresh("g")
    #expect(silt_tree_generation(f.tree) > before)
}

@Test func largeFileQuerySkipsManagedFoldersAndBundles() throws {
    let f = try Fixture([
        "photos/a.jpg": 2_000_000, "photos/b.jpg": 50_000,
        "proj/node_modules/pkg/blob.bin": 3_000_000,
        "Tool.app/Contents/Resources/big.dat": 4_000_000,
        "docs/c.pdf": 1_500_000,
    ])
    let skip = [strdup("node_modules")]
    defer { skip.forEach { free($0) } }
    var out = [UInt32](repeating: 0, count: 16)
    let n = skip.map { UnsafePointer($0) }.withUnsafeBufferPointer {
        silt_files_at_least(f.tree, 0, 1_000_000, $0.baseAddress!, 1, true, &out, 16)
    }
    silt_tree_lock(f.tree)
    let names = (0..<Int(n)).map { i -> String in
        let e = silt_entry_at(f.tree, out[i]).pointee
        return String(decoding: UnsafeBufferPointer(start: silt_name_ptr(f.tree, e.name), count: Int(e.name_len)), as: UTF8.self)
    }.sorted()
    silt_tree_unlock(f.tree)
    #expect(names == ["a.jpg", "c.pdf"])
}

// MARK: In-place relisting and memory

extension Fixture {
    func index(_ rel: String) -> UInt32 {
        silt_tree_lock(tree)
        defer { silt_tree_unlock(tree) }
        return silt_lookup(tree, root.appendingPathComponent(rel).path)
    }

    func live(_ index: UInt32) -> Bool {
        silt_tree_lock(tree)
        defer { silt_tree_unlock(tree) }
        return silt_is_live(tree, index)
    }

    var memory: silt_memory {
        var m = silt_memory()
        silt_tree_memory_stats(tree, &m)
        return m
    }

    func touch(_ rel: String, count: Int, prefix: String) {
        let dir = root.appendingPathComponent(rel)
        for i in 0..<count {
            let fd = open(dir.appendingPathComponent("\(prefix)-\(i)").path, O_CREAT | O_WRONLY, S_IRUSR | S_IWUSR)
            if fd >= 0 { close(fd) }
        }
    }

    func remove(_ rel: String, count: Int, prefix: String) {
        let dir = root.appendingPathComponent(rel)
        for i in 0..<count { unlink(dir.appendingPathComponent("\(prefix)-\(i)").path) }
    }
}

@Test func survivorsKeepTheirIndexWhenAFolderChanges() throws {
    let f = try Fixture(["w/a.bin": 10_000, "w/b.bin": 20_000, "w/sub/x.bin": 30_000])
    // The first change moves the folder to a run with room to spare...
    try Fixture.write(f.root.appendingPathComponent("w/c.bin"), size: 40_000)
    f.refresh("w")
    let a = f.index("w/a.bin"), b = f.index("w/b.bin"), sub = f.entry("w/sub")!.aux
    let run = f.dir("w")!
    #expect(run.cap > run.count)
    // ...so later ones happen in place: survivors keep their index.
    try Fixture.write(f.root.appendingPathComponent("w/a.bin"), size: 90_000)
    unlink(f.root.appendingPathComponent("w/b.bin").path)
    try Fixture.write(f.root.appendingPathComponent("w/d.bin"), size: 5_000)
    f.refresh("w")
    let after = f.dir("w")!
    #expect(after.first == run.first)
    #expect(after.version != run.version)
    #expect(f.index("w/a.bin") == a && f.live(a))
    #expect(!f.live(b))
    #expect(f.entry("w/b.bin") == nil)
    #expect(f.live(f.index("w/d.bin")))
    #expect(f.entry("w/sub")!.aux == sub)
    #expect(f.size("w") == f.expected("w"))
    #expect(f.size("") == f.expected(""))
    #expect(f.dir("w")!.items == 5) // a, c, d, sub, sub/x
    #expect(f.dir("")?.pending == 0)
}

@Test func aFileBecomingAFolderIsANewEntry() throws {
    let f = try Fixture(["m/thing": 10_000, "m/other.bin": 1_000])
    try Fixture.write(f.root.appendingPathComponent("m/extra.bin"), size: 1_000)
    f.refresh("m") // now it has spare room
    let old = f.index("m/thing")
    unlink(f.root.appendingPathComponent("m/thing").path)
    try Fixture.write(f.root.appendingPathComponent("m/thing/inside.bin"), size: 70_000)
    f.refresh("m")
    #expect(!f.live(old))
    #expect(f.entry("m/thing")?.kind == UInt8(SILT_KIND_DIR))
    #expect(f.size("m/thing") == f.expected("m/thing"))
    #expect(f.size("m") == f.expected("m"))
    #expect(f.dir("")?.pending == 0)
}

@Test func deepRefreshInPlaceRevalidatesSurvivors() throws {
    let f = try Fixture(["q/keep/x.bin": 10_000, "q/y.bin": 1_000])
    try Fixture.write(f.root.appendingPathComponent("q/z.bin"), size: 1_000)
    f.refresh("q") // spare room from here on
    try Fixture.write(f.root.appendingPathComponent("q/keep/new.bin"), size: 60_000)
    try Fixture.write(f.root.appendingPathComponent("q/w.bin"), size: 2_000)
    let keep = f.entry("q/keep")!.aux
    f.refresh("q", deep: true)
    #expect(f.entry("q/keep")!.aux == keep)
    #expect(f.size("q/keep") == f.expected("q/keep"))
    #expect(f.size("") == f.expected(""))
    #expect(f.dir("")?.pending == 0)
}

@Test func vanishedFolderGivesBackItsSubtree() throws {
    var layout: [String: Int] = ["v/keep.bin": 1_000]
    for i in 0..<400 { layout["v/big/f\(i)"] = 10 }
    let f = try Fixture(layout)
    let before = f.memory.live_slots
    try FileManager.default.removeItem(at: f.root.appendingPathComponent("v/big"))
    f.refresh("v")
    let after = f.memory
    // Its 400 entries' run is released; the parent's new run takes a little.
    #expect(after.live_slots + 380 <= before)
    #expect(f.size("") == f.expected(""))
    #expect(f.dir("")?.pending == 0)
}

@Test func churnKeepsMemoryFlatAndFreesChunks() throws {
    let f = try Fixture(["hot/seed.bin": 1_000])
    f.touch("hot", count: 8_000, prefix: "base")
    f.refresh("hot")
    // Each round replaces more files than the spare room holds, so the folder
    // keeps moving to fresh runs; the old ones must be given back.
    var stale: UInt32 = 0
    for round in 0..<14 {
        f.touch("hot", count: 5_000, prefix: "r\(round)")
        if round > 0 { f.remove("hot", count: 5_000, prefix: "r\(round - 1)") }
        f.refresh("hot")
        if round == 5 { stale = f.index("hot/r5-0") }
    }
    let m = f.memory
    #expect(m.chunks_freed > 0)
    // What stays allocated is on the order of the folder, not of the churn.
    #expect(m.live_slots < 40_000)
    #expect(m.entry_bytes <= 4 * 65_536 * 24)
    #expect(f.dir("hot")!.items == 13_001)
    #expect(f.size("") == f.expected(""))

    // A stale index into a freed chunk reads as removed and never faults.
    #expect(stale >= 65_536)
    silt_tree_lock(f.tree)
    let e = silt_entry_at(f.tree, stale).pointee
    var buf = [CChar](repeating: 0, count: 4096)
    let len = silt_path(f.tree, stale, &buf, 4096)
    #expect(!silt_is_live(f.tree, stale))
    silt_tree_unlock(f.tree)
    #expect(e.flags & UInt8(SILT_FLAG_REMOVED) != 0)
    #expect(e.name_len == 0 && len == 0) // its chunk is gone
}

@Test func smallChurnStaysInPlace() throws {
    let f = try Fixture(["t/seed.bin": 1_000])
    f.touch("t", count: 2_000, prefix: "keep")
    try Fixture.write(f.root.appendingPathComponent("t/x.tmp"), size: 1_000)
    f.refresh("t")
    let first = f.dir("t")!.first
    let slots = f.memory.entry_slots
    let names = f.memory.name_bytes
    // Temp files come and go; the folder's run absorbs them.
    for i in 0..<40 {
        try Fixture.write(f.root.appendingPathComponent("t/tmp-\(i)"), size: 100)
        if i > 0 { unlink(f.root.appendingPathComponent("t/tmp-\(i - 1)").path) }
        f.refresh("t")
    }
    #expect(f.dir("t")!.first == first)
    #expect(f.memory.entry_slots == slots)
    #expect(f.memory.name_bytes - names < 40 * 8) // only the newcomers' names
    #expect(f.size("t") == f.expected("t"))
    #expect(f.dir("")?.pending == 0)
}

@Test func snapshotAfterInPlaceChangesIsCompact() throws {
    let f = try Fixture(["s/a.bin": 1_000, "s/sub/b.bin": 2_000])
    try Fixture.write(f.root.appendingPathComponent("s/c.bin"), size: 3_000)
    f.refresh("s")
    unlink(f.root.appendingPathComponent("s/a.bin").path)
    try Fixture.write(f.root.appendingPathComponent("s/d.bin"), size: 4_000)
    f.refresh("s") // leaves a hole and uses spare room
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silt-\(UUID().uuidString).snap").path
    defer { unlink(file) }
    var meta = silt_snapshot_meta()
    #expect(silt_tree_save(f.tree, file, &meta))
    let t = try #require(silt_tree_load(file, &meta))
    defer { silt_tree_destroy(t) }
    silt_tree_lock(t)
    #expect(silt_entry_at(t, 0).pointee.size == f.size(""))
    let s = silt_lookup(t, f.root.appendingPathComponent("s").path)
    let d = silt_dir_at(t, silt_entry_at(t, s).pointee.aux).pointee
    #expect(d.count == 3 && d.cap == 3) // sub, c, d: the hole and the spare room are gone
    silt_tree_unlock(t)
    var m = silt_memory()
    silt_tree_memory_stats(t, &m)
    #expect(m.live_slots == m.entry_slots)
}

@Test func removingTheNewestItemUpdatesLastChanged() throws {
    let f = try Fixture(["r/old.bin": 1_000, "r/new.bin": 1_000])
    let old = Date(timeIntervalSince1970: 1_700_000_000), new = Date(timeIntervalSince1970: 1_800_000_000)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: f.root.appendingPathComponent("r/old.bin").path)
    try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: f.root.appendingPathComponent("r/new.bin").path)
    f.refresh("r")
    #expect(f.dir("r")?.newest == 1_800_000_000)
    silt_tree_remove(f.tree, f.index("r/new.bin"))
    #expect(f.dir("r")?.newest == 1_700_000_000)
    #expect(f.dir("")?.newest == 1_700_000_000)
}

@Test func filesThatComeBackReuseTheirNames() throws {
    var layout: [String: Int] = [:]
    for i in 0..<40 { layout["n/keep-\(i)"] = 10 }
    let f = try Fixture(layout)
    let a = f.root.appendingPathComponent("n/a-fairly-long-file-name-that-keeps-coming-back.tmp")
    let b = f.root.appendingPathComponent("n/b-fairly-long-file-name-that-keeps-coming-back.tmp")
    try Fixture.write(a, size: 10)
    f.refresh("n") // the folder now has spare room
    let names = f.memory.name_bytes
    // A save pattern: the same file renamed back and forth between two names.
    for i in 0..<20 {
        try FileManager.default.moveItem(at: i % 2 == 0 ? a : b, to: i % 2 == 0 ? b : a)
        f.refresh("n")
    }
    // Each name is stored at most once per run it lives in, not per change.
    #expect(f.memory.name_bytes - names < 4 * 60)
    #expect(f.size("n") == f.expected("n"))
    #expect(f.dir("n")!.items == 41)
}

// MARK: Parking

@Test func parkingRoundTripsExactly() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-park-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<300 { try Fixture.write(root.appendingPathComponent("d\(i % 7)/f\(i).bin"), size: 1_000 + i) }
    let t = silt_tree_create(root.path)!
    defer { silt_tree_destroy(t) }
    var s = silt_scanner_start(t, 4)!
    silt_scanner_wait_idle(s)
    // Churn a folder so there are tombstones, spare room and new names.
    try Fixture.write(root.appendingPathComponent("d0/extra.bin"), size: 5_000)
    unlink(root.appendingPathComponent("d0/f0.bin").path)
    silt_tree_lock(t)
    let d0 = silt_entry_at(t, silt_lookup(t, root.appendingPathComponent("d0").path)).pointee.aux
    silt_tree_unlock(t)
    silt_scanner_refresh(s, d0, false)
    silt_scanner_wait_idle(s)
    silt_scanner_destroy(s)

    func snapshot() -> (UInt32, Int64, UInt32, UInt32) {
        silt_tree_lock(t)
        defer { silt_tree_unlock(t) }
        let i = silt_lookup(t, root.appendingPathComponent("d3/f10.bin").path)
        return (t.pointee.entry_count, silt_entry_at(t, 0).pointee.size, i, silt_dir_at(t, d0).pointee.version)
    }
    let before = snapshot()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silt-\(UUID().uuidString).park").path
    defer { unlink(file) }
    #expect(silt_tree_park(t, file))
    #expect(silt_tree_is_parked(t))
    var m = silt_memory()
    silt_tree_memory_stats(t, &m)
    #expect(m.entry_bytes == 0 && m.dir_bytes == 0)
    // Reads are safe and see nothing.
    silt_tree_lock(t)
    #expect(silt_lookup(t, root.appendingPathComponent("d3/f10.bin").path) == 0xFFFF_FFFF)
    #expect(!silt_is_live(t, before.2))
    silt_tree_unlock(t)
    var none = [UInt32](repeating: 0, count: 10)
    #expect(silt_top_files(t, 0, &none, 10) == 0)

    #expect(silt_tree_unpark(t, file))
    #expect(!silt_tree_is_parked(t))
    let after = snapshot()
    #expect(after == before) // same indices, same totals
    silt_tree_lock(t)
    #expect(silt_is_live(t, before.2))
    silt_tree_unlock(t)

    // And it takes refreshes again.
    try Fixture.write(root.appendingPathComponent("d0/later.bin"), size: 70_000)
    s = silt_scanner_start_idle(t, 2)!
    silt_scanner_refresh(s, d0, false)
    silt_scanner_wait_idle(s)
    silt_scanner_destroy(s)
    silt_tree_lock(t)
    #expect(silt_lookup(t, root.appendingPathComponent("d0/later.bin").path) != 0xFFFF_FFFF)
    #expect(silt_dir_at(t, 0).pointee.pending == 0)
    silt_tree_unlock(t)
}

@Test func damagedParkFileLeavesTheTreeParked() throws {
    let f = try Fixture(["a/b.bin": 10_000, "c.bin": 2_000]) // its scanner is idle: nothing will touch the tree
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silt-\(UUID().uuidString).park").path
    defer { unlink(file) }
    #expect(silt_tree_park(f.tree, file))
    // Flip a byte in the payload.
    let h = try FileHandle(forUpdating: URL(fileURLWithPath: file))
    let end = try h.seekToEnd()
    try h.seek(toOffset: end - 3)
    let byte = try h.read(upToCount: 1)!
    try h.seek(toOffset: end - 3)
    h.write(Data([byte[0] ^ 0x5A]))
    try h.close()
    #expect(!silt_tree_unpark(f.tree, file))
    #expect(silt_tree_is_parked(f.tree))
    #expect(!silt_tree_unpark(f.tree, file + ".missing"))
}

/// A folder that opens but can't be searched (read without execute, like
/// some of macOS's own) is locked, not half-read, so the tree still saves.
@Test func unsearchableFolderIsLockedAndTheTreeStillSaves() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-test-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    let locked = root.appendingPathComponent("locked")
    try Fixture.write(locked.appendingPathComponent("inside.bin"), size: 1_000)
    try Fixture.write(root.appendingPathComponent("open.bin"), size: 1_000)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: root)
    }
    let tree = silt_tree_create(root.path)!
    let scanner = silt_scanner_start(tree, 2)!
    silt_scanner_wait_idle(scanner)
    defer {
        silt_scanner_destroy(scanner)
        silt_tree_destroy(tree)
    }

    silt_tree_lock(tree)
    let e = silt_entry_at(tree, silt_lookup(tree, locked.path)).pointee
    let d = silt_dir_at(tree, e.aux).pointee
    silt_tree_unlock(tree)
    #expect(e.flags & UInt8(SILT_FLAG_DENIED) != 0)
    #expect(d.state & UInt32(SILT_DIR_INCOMPLETE) == 0)

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silt-\(UUID().uuidString).snap").path
    defer { unlink(file) }
    var meta = silt_snapshot_meta()
    #expect(silt_tree_save(tree, file, &meta))
}

/// A listing that stopped early is saved as such, for the loader to redo,
/// rather than keeping the whole tree from being saved.
@Test func incompleteFolderIsSavedAndStaysFlagged() throws {
    let f = try Fixture(["a/one.bin": 1_000, "b/two.bin": 1_000])
    let a = try #require(f.entry("a")).aux
    silt_tree_lock(f.tree)
    silt_dir_at(f.tree, a).pointee.state |= UInt32(SILT_DIR_INCOMPLETE)
    silt_tree_unlock(f.tree)

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silt-\(UUID().uuidString).snap").path
    defer { unlink(file) }
    var meta = silt_snapshot_meta()
    #expect(silt_tree_save(f.tree, file, &meta))
    let t = try #require(silt_tree_load(file, nil))
    defer { silt_tree_destroy(t) }
    silt_tree_lock(t)
    let la = silt_dir_at(t, silt_entry_at(t, silt_lookup(t, f.root.appendingPathComponent("a").path)).pointee.aux).pointee
    let lb = silt_dir_at(t, silt_entry_at(t, silt_lookup(t, f.root.appendingPathComponent("b").path)).pointee.aux).pointee
    silt_tree_unlock(t)
    #expect(la.state & UInt32(SILT_DIR_INCOMPLETE) != 0)
    #expect(lb.state & UInt32(SILT_DIR_INCOMPLETE) == 0)
}

/// Every folder remembers when it was last read, across a save and load.
@Test func foldersRememberWhenTheyWereListed() throws {
    let start = UInt32(Date().timeIntervalSince1970)
    let f = try Fixture(["a/one.bin": 1_000, "a/deep/two.bin": 1_000])
    let end = UInt32(Date().timeIntervalSince1970)
    for rel in ["", "a", "a/deep"] {
        let at = try #require(f.dir(rel)).listed_at
        #expect(at >= start && at <= end)
    }
    let deep = try #require(f.dir("a/deep")).listed_at

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silt-\(UUID().uuidString).snap").path
    defer { unlink(file) }
    var meta = silt_snapshot_meta()
    meta.saved_at = 1_234_567
    #expect(silt_tree_save(f.tree, file, &meta))
    var peeked = silt_snapshot_meta()
    #expect(silt_snapshot_peek(file, &peeked) && peeked.saved_at == 1_234_567)
    let t = try #require(silt_tree_load(file, nil))
    defer { silt_tree_destroy(t) }
    silt_tree_lock(t)
    let loaded = silt_dir_at(t, silt_entry_at(t, silt_lookup(t, f.root.appendingPathComponent("a/deep").path)).pointee.aux).pointee
    silt_tree_unlock(t)
    #expect(loaded.listed_at == deep)
}

// MARK: Work classes and the worker pool

/// Raw handles to hand to other threads. The engine's own locking makes the
/// calls these tests make from several threads safe.
private struct Handles: @unchecked Sendable {
    let tree: UnsafeMutablePointer<silt_tree>
    let scanner: OpaquePointer
}

private let busyStates = UInt32(SILT_DIR_QUEUED | SILT_DIR_ACTIVE | SILT_DIR_DIRTY | SILT_DIR_DEEP | SILT_DIR_URGENT)

extension Fixture {
    fileprivate var handles: Handles { Handles(tree: tree, scanner: scanner) }

    var progress: silt_progress {
        var p = silt_progress()
        silt_scanner_progress(scanner, &p)
        return p
    }

    /// Dir ids of every folder still reachable from the root.
    func liveDirs() -> [UInt32] {
        silt_tree_lock(tree)
        defer { silt_tree_unlock(tree) }
        return (0..<tree.pointee.dir_count).filter { d in
            let entry = silt_dir_at(tree, d).pointee.entry
            return silt_is_live(tree, entry) && silt_entry_at(tree, entry).pointee.aux == d
        }
    }

    func stamp(_ rel: String) -> UInt32 {
        guard let e = entry(rel) else { return 0 }
        silt_tree_lock(tree)
        defer { silt_tree_unlock(tree) }
        return silt_dir_stamp(tree, e.aux)
    }

    /// Waits (a few seconds at most) for `condition` on the scanner's progress.
    func waitFor(_ condition: (silt_progress) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition(progress) { return true }
            usleep(10_000)
        }
        return condition(progress)
    }
}

/// Urgent, background, deep and shallow refreshes from several threads at
/// once, while the folders change underneath: afterwards nothing may be left
/// queued, running or marked, and every count must add up.
@Test func mixedRefreshClassesLeaveNothingQueued() throws {
    var layout: [String: Int] = [:]
    for a in 0..<6 {
        for b in 0..<5 {
            for c in 0..<4 { layout["d\(a)/e\(b)/f\(c)/x.bin"] = 1_000 + a * 100 + b * 10 + c }
            layout["d\(a)/e\(b)/y.bin"] = 2_000
        }
    }
    let f = try Fixture(layout)
    let h = f.handles
    let dirs = f.liveDirs()
    let root = f.root
    #expect(dirs.count > 150)

    DispatchQueue.concurrentPerform(iterations: 4) { worker in
        if worker == 3 {
            // Churn: files and folders come and go while refreshes run.
            for i in 0..<60 {
                let dir = root.appendingPathComponent("d\(i % 6)/e\(i % 5)")
                try? Fixture.write(dir.appendingPathComponent("new\(i)/z.bin"), size: 3_000)
                if i >= 10 {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent("d\((i - 10) % 6)/e\((i - 10) % 5)/new\(i - 10)"))
                }
                unlink(root.appendingPathComponent("d\(i % 6)/e\(i % 5)/y.bin").path)
                usleep(1_000)
            }
            return
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<600 {
            let dir = dirs.randomElement(using: &rng)!
            let flags = UInt32.random(in: 0...3, using: &rng) // DEEP and URGENT in every combination
            silt_scanner_refresh_ex(h.scanner, dir, flags)
            if Int.random(in: 0..<20, using: &rng) == 0 { usleep(500) }
        }
    }
    silt_scanner_wait_idle(f.scanner)

    let p = f.progress
    #expect(p.idle && p.queued == 0 && p.urgent_queued == 0 && p.active == 0)
    silt_tree_lock(f.tree)
    #expect(silt_dir_at(f.tree, 0).pointee.pending == 0)
    var stuck: [UInt32] = []
    for d in 0..<f.tree.pointee.dir_count where silt_dir_at(f.tree, d).pointee.state & busyStates != 0 {
        stuck.append(d)
    }
    silt_tree_unlock(f.tree)
    #expect(stuck.isEmpty, "folders left queued, active, dirty, deep or urgent: \(stuck)")
    for d in f.liveDirs() {
        silt_tree_lock(f.tree)
        let pending = silt_dir_at(f.tree, d).pointee.pending
        silt_tree_unlock(f.tree)
        #expect(pending == 0)
    }

    // One more thorough pass settles whatever the churn left unseen; then
    // every total matches the disk.
    silt_scanner_refresh_ex(f.scanner, 0, UInt32(SILT_REFRESH_DEEP | SILT_REFRESH_URGENT))
    silt_scanner_wait_idle(f.scanner)
    #expect(f.size("") == f.expected(""))
    #expect(f.dir("")?.pending == 0)
}

/// An urgent request counts from the moment it returns, even when it only
/// upgrades background work already queued or running, and it stops
/// counting only once everything it covers is listed.
@Test func urgentWorkCountsUntilItIsDone() throws {
    var layout: [String: Int] = [:]
    for a in 0..<8 { for b in 0..<8 { layout["p\(a)/q\(b)/r.bin"] = 4_096 } }
    let f = try Fixture(layout)
    silt_scanner_refresh_ex(f.scanner, 0, UInt32(SILT_REFRESH_DEEP)) // background
    silt_scanner_refresh_ex(f.scanner, 0, UInt32(SILT_REFRESH_DEEP | SILT_REFRESH_URGENT))
    #expect(f.progress.urgent_queued > 0)
    #expect(f.waitFor { $0.urgent_queued == 0 })
    // Urgent work drained: the whole deep refresh is done, background or not.
    #expect(f.dir("")?.pending == 0)
    silt_scanner_wait_idle(f.scanner)
    #expect(f.size("") == f.expected(""))
}

/// Idle workers exit, all the way down to none, and work that arrives later
/// still gets done.
@Test func idlePoolShrinksToZeroAndComesBack() throws {
    let f = try Fixture(["a/one.bin": 10_000, "b/two.bin": 20_000])
    silt_scanner_set_idle_timeout(f.scanner, 0.05)
    #expect(f.waitFor { $0.threads == 0 })
    try Fixture.write(f.root.appendingPathComponent("a/three.bin"), size: 300_000)
    let a = try #require(f.entry("a")).aux
    silt_scanner_refresh_ex(f.scanner, a, UInt32(SILT_REFRESH_URGENT))
    silt_scanner_wait_idle(f.scanner)
    #expect(f.size("a") == f.expected("a"))
    #expect(f.size("") == f.expected(""))
    try Fixture.write(f.root.appendingPathComponent("b/four.bin"), size: 40_000)
    let b = try #require(f.entry("b")).aux
    silt_scanner_refresh(f.scanner, b, false) // background, from an empty pool
    silt_scanner_wait_idle(f.scanner)
    #expect(f.size("b") == f.expected("b"))
    #expect(f.waitFor { $0.threads == 0 })
}

/// Destroying a scanner while its threads start, work and exit on their own
/// never loses one (thread sanitizer runs cover the joins).
@Test func destroyRacesThreadsExiting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-pool-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<40 { try Fixture.write(root.appendingPathComponent("d\(i % 8)/f\(i).bin"), size: 1_000) }
    for round in 0..<30 {
        let t = silt_tree_create(root.path)!
        let s = silt_scanner_start(t, Int32(1 + round % 6))!
        silt_scanner_set_idle_timeout(s, 0.0005 * Double(round % 4))
        if round % 3 == 0 { silt_scanner_wait_idle(s) }
        if round % 5 == 0 { usleep(2_000) }
        silt_scanner_refresh_ex(s, 0, UInt32(round % 2 == 0 ? SILT_REFRESH_URGENT : 0))
        silt_scanner_destroy(s)
        silt_tree_destroy(t)
    }
}

/// Reading progress never waits for the tree lock, so a long query can't
/// stall whoever polls it.
@Test func progressDoesNotWaitForTheTreeLock() throws {
    let f = try Fixture(["a/one.bin": 10_000])
    let h = f.handles
    let locked = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0)
    let unlocked = DispatchSemaphore(value: 0)
    let holder = Thread {
        silt_tree_lock(h.tree)
        locked.signal()
        release.wait()
        silt_tree_unlock(h.tree)
        unlocked.signal()
    }
    holder.start()
    locked.wait()
    DispatchQueue.global().async {
        var p = silt_progress()
        silt_scanner_progress(h.scanner, &p)
        read.signal()
    }
    let answered = read.wait(timeout: .now() + 3) == .success
    release.signal()
    if !answered { read.wait() }
    unlocked.wait() // the fixture frees the tree when this returns
    #expect(answered)
    #expect(f.progress.files == 2) // a and a/one.bin
}

// MARK: Stamps

@Test func stampsMoveForAncestorsButNotSiblings() throws {
    let f = try Fixture(["a/x/f.bin": 10_000, "a/y.bin": 1_000, "b/g.bin": 5_000, "b/c/h.bin": 1_000])
    let before = ["", "a", "a/x", "b", "b/c"].map { f.stamp($0) }
    #expect(before.allSatisfy { $0 != 0 })
    #expect(["", "a", "a/x", "b", "b/c"].map { f.stamp($0) } == before) // reading doesn't move them

    try Fixture.write(f.root.appendingPathComponent("a/x/f.bin"), size: 900_000)
    f.refresh("a/x")
    let after = ["", "a", "a/x", "b", "b/c"].map { f.stamp($0) }
    #expect(after[0] != before[0] && after[1] != before[1] && after[2] != before[2])
    #expect(after[3] == before[3] && after[4] == before[4])

    // Removal moves the chain above it, too.
    silt_tree_remove(f.tree, f.index("b/c/h.bin"))
    let removed = ["", "a", "a/x", "b", "b/c"].map { f.stamp($0) }
    #expect(removed[0] != after[0] && removed[3] != after[3] && removed[4] != after[4])
    #expect(removed[1] == after[1] && removed[2] == after[2])

    silt_tree_lock(f.tree)
    #expect(silt_dir_stamp(f.tree, f.tree.pointee.dir_count) == 0)
    silt_tree_unlock(f.tree)
}

@Test func stampsAreNewAfterLoadAndUnpark() throws {
    let f = try Fixture(["a/one.bin": 1_000, "a/deep/two.bin": 1_000, "b/three.bin": 1_000])
    func all(_ t: UnsafeMutablePointer<silt_tree>) -> [UInt32] {
        silt_tree_lock(t)
        defer { silt_tree_unlock(t) }
        return (0..<t.pointee.dir_count).map { silt_dir_stamp(t, $0) }
    }
    var seen = Set(all(f.tree))

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("silt-\(UUID().uuidString).snap").path
    defer { unlink(file) }
    var meta = silt_snapshot_meta()
    #expect(silt_tree_save(f.tree, file, &meta))
    let loaded = try #require(silt_tree_load(file, nil))
    defer { silt_tree_destroy(loaded) }
    let fresh = all(loaded)
    #expect(fresh.allSatisfy { $0 != 0 && !seen.contains($0) })
    seen.formUnion(fresh)

    // The loaded tree has no scanner, so it can park.
    let park = FileManager.default.temporaryDirectory.appendingPathComponent("silt-\(UUID().uuidString).park").path
    defer { unlink(park) }
    #expect(silt_tree_park(loaded, park))
    #expect(all(loaded).allSatisfy { $0 == 0 })
    #expect(silt_tree_unpark(loaded, park))
    #expect(all(loaded).allSatisfy { $0 != 0 && !seen.contains($0) })
}

// MARK: Queries and sorting

@Test func findNamedMatchesWholeNamesIgnoringASCIICase() throws {
    let f = try Fixture([
        "proj/Target/a.bin": 5_000, "other/target/b.bin": 1_000, "targets/c.bin": 1_000,
        "xtarget/d.bin": 1_000, "proj/.rustc_info.json": 100, "lib/TARGET": 0,
    ])
    let names = [strdup("target"), strdup(".rustc_info.json")]
    defer { names.forEach { free($0) } }
    var out = [UInt32](repeating: 0, count: 16)
    var which = [UInt32](repeating: 0, count: 16)
    let n = names.map { UnsafePointer($0) }.withUnsafeBufferPointer {
        silt_find_named(f.tree, 0, $0.baseAddress!, 2, &out, &which, 16)
    }
    silt_tree_lock(f.tree)
    let found = (0..<Int(n)).map { i -> (String, UInt32) in
        var buf = [CChar](repeating: 0, count: 4096)
        _ = silt_path(f.tree, out[i], &buf, 4096)
        return (String(cString: buf).replacingOccurrences(of: f.root.path + "/", with: ""), which[i])
    }
    silt_tree_unlock(f.tree)
    #expect(Set(found.map { $0.0 }) == ["proj/Target", "other/target", "lib/TARGET", "proj/.rustc_info.json"])
    #expect(found.first { $0.0 == "proj/.rustc_info.json" }?.1 == 1)
    #expect(found.filter { $0.1 == 0 }.count == 3)
    #expect(found.first?.0 == "proj/Target") // largest first
}

/// The integer-key sort orders children exactly like a straightforward
/// comparison would: the key, then the name ignoring ASCII case (shorter
/// first on a tie), with or without the lock.
@Test func childrenSortLikeTheReferenceOrder() throws {
    var layout: [String: Int] = [:]
    let stems = ["alpha", "Alpha", "ALPHABET", "alphabet-soup", "alphabet-Soup-2", "beta", "b", "B2",
                 "libserde-0123456789.rlib", "libserde-0123456789.d", "libserde-0123", "LIBSERDE-99",
                 "zeta", "Zulu", "ümlaut", "émile", "_under", "123", "1234567890123"]
    for (i, stem) in stems.enumerated() {
        layout["s/\(stem)"] = [0, 4_096, 4_096, 8_192, 0][i % 5]
        layout["s/dir\(i % 4)-\(stem)/f.bin"] = 1_000 * (i % 3)
    }
    for i in 0..<300 { layout["s/bulk-\(i % 7)-\(i)"] = (i % 11) * 4_096 }
    let f = try Fixture(layout)
    let s = try #require(f.entry("s")).aux

    silt_tree_lock(f.tree)
    let d = silt_dir_at(f.tree, s).pointee
    struct Child { let index: UInt32; let size: Int64; let items: UInt32; let newest: UInt32; let name: [UInt8] }
    let children = (d.first..<d.first + d.count).compactMap { i -> Child? in
        let e = silt_entry_at(f.tree, i).pointee
        if e.flags & UInt8(SILT_FLAG_REMOVED) != 0 { return nil }
        let isDir = e.kind == UInt8(SILT_KIND_DIR)
        let dd = isDir ? silt_dir_at(f.tree, e.aux).pointee : nil
        let name = Array(UnsafeBufferPointer(start: silt_name_ptr(f.tree, e.name), count: Int(e.name_len)))
        return Child(index: i, size: e.size, items: dd?.items ?? 0, newest: dd?.newest ?? e.aux, name: name)
    }
    silt_tree_unlock(f.tree)

    func fold(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
    func nameLess(_ a: Child, _ b: Child) -> Bool {
        for (x, y) in zip(a.name, b.name) where fold(x) != fold(y) { return fold(x) < fold(y) }
        if a.name.count != b.name.count { return a.name.count < b.name.count }
        return a.index < b.index
    }
    let reference: [Int32: (Child, Child) -> Bool] = [
        0: { $0.size != $1.size ? $0.size > $1.size : nameLess($0, $1) },
        1: nameLess,
        2: { $0.items != $1.items ? $0.items > $1.items : $0.size != $1.size ? $0.size > $1.size : nameLess($0, $1) },
        3: { $0.newest != $1.newest ? $0.newest > $1.newest : nameLess($0, $1) },
    ]
    for key in Int32(0)...3 {
        let want = children.sorted(by: reference[key]!).map(\.index)
        var locked = [UInt32](repeating: 0, count: children.count)
        silt_tree_lock(f.tree)
        let n = silt_children_sorted(f.tree, s, key, &locked, UInt32(locked.count))
        silt_tree_unlock(f.tree)
        var unlocked = [UInt32](repeating: 0, count: children.count + 8)
        let m = silt_children_sorted_unlocked(f.tree, s, key, &unlocked, UInt32(unlocked.count))
        #expect(Int(n) == want.count && Array(locked.prefix(Int(n))) == want, "key \(key)")
        #expect(Int(m) == want.count && Array(unlocked.prefix(Int(m))) == want, "key \(key), unlocked")
        // A smaller cap keeps the first ones.
        var top = [UInt32](repeating: 0, count: 5)
        #expect(silt_children_sorted_unlocked(f.tree, s, key, &top, 5) == 5 && top == Array(want.prefix(5)))
    }
}

@Test func extensionStatsGrowPastTheirFirstTable() throws {
    var layout: [String: Int] = ["e/a.JPG": 4_096, "e/b.jpg": 4_096, "e/c.png": 8_192, "e/noext": 4_096]
    for i in 0..<700 { layout["many/f\(i).x\(i)"] = 4_096 }
    let f = try Fixture(layout)
    var out = [silt_ext_stat](repeating: silt_ext_stat(), count: 1_000)
    let n = Int(silt_ext_stats(f.tree, 0, &out, 1_000))
    let byName = Dictionary(uniqueKeysWithValues: out.prefix(n).map { stat -> (String, silt_ext_stat) in
        var s = stat
        let name = withUnsafeBytes(of: &s.ext) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return (name, stat)
    })
    #expect(n == 703) // jpg, png, none, and 700 distinct
    #expect(byName["jpg"]?.count == 2)
    #expect(byName["png"]?.count == 1)
    #expect(byName[""]?.count == 1)
    #expect(byName["x699"]?.count == 1)
    #expect(zip(out.prefix(n), out.prefix(n).dropFirst()).allSatisfy { $0.bytes >= $1.bytes })
}
