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
}
