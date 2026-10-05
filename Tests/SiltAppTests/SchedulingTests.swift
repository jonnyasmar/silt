import CoreServices
import Foundation
import SiltCore
import Testing
@testable import Silt

/// A scratch folder of small files, left alone for a moment so the events
/// for writing it are over before a session starts watching.
private func scratch(_ prefix: String, files: Int, in folders: Int = 3) async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    for i in 0..<files {
        let url = root.appendingPathComponent("p\(i % folders)/f\(i).bin")
        if i < folders {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 512).write(to: url)
    }
    await settle(1.5)
    return root
}

private func cleanUp(_ root: URL) {
    Snapshots.discard(for: root)
    try? FileManager.default.removeItem(at: root)
}

/// Settled and closed, so it doesn't save once more after cleanup.
private func finish(_ s: Session) async {
    _ = await wait {
        guard s.canPark else { return false }
        s.close()
        return true
    }
}

/// Nothing to follow and nothing due: no timer while hidden, and while on
/// screen only the slow chores (a capacity check every few seconds).
@Test func idleSessionsOnlyWakeForChores() async throws {
    let root = try await scratch("silt-idle", files: 60)
    defer { cleanUp(root) }
    let s = await MainActor.run { Session(url: root, guardPrivateFolders: true, fresh: true) }
    // Settled: live, idle, and the fresh scan saved.
    #expect(await wait { s.phase == .live && s.canPark && Snapshots.savedAt(for: root.path) != nil })
    await settle(1.5) // the last version and quiet bumps

    // On screen: a timer for the next chore, but not the 12 Hz beat of
    // work under way (that would be some 30 ticks here).
    let before = await MainActor.run { s.ticks }
    #expect(await MainActor.run { s.nextTick } != nil)
    await settle(2.5)
    #expect(await MainActor.run { s.ticks } - before <= 1)

    await MainActor.run { s.isOnScreen = false }
    #expect(await wait { s.nextTick == nil })
    let hidden = await MainActor.run { s.ticks }
    await settle(2)
    #expect(await MainActor.run { s.ticks } == hidden)
    #expect(await MainActor.run { s.nextTick } == nil)
    await finish(s)
}

/// A busy folder's refresh held back by its pace happens when the pace
/// allows, set off by its own deadline: nothing else arrives to prompt it,
/// and no other chore is due before then.
@Test func pacedRefreshIsReleasedWithNoFurtherEvents() async throws {
    // 40 µs a child: 50,000 files are listed at most every 2 s. That's past
    // the half second the tick follows a change, and the quiet bump a second
    // later; a settled session's only other chore is its capacity check.
    let files = 50_000
    let pace = Double(files) * 40e-6
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-paced-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    defer { cleanUp(root) }
    let folder = root.appendingPathComponent("busy")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for i in 0..<files {
        let fd = open(folder.appendingPathComponent("f\(i)").path, O_CREAT | O_WRONLY, 0o644)
        if fd >= 0 { close(fd) }
    }
    await settle(1.5)
    let s = await MainActor.run { Session(url: root, guardPrivateFolders: true, fresh: true) }
    #expect(await wait { s.phase == .live && s.canPark })
    await settle(1.5) // the settle save, the last bumps

    // Start just after a capacity check, so the next one is 3 s away.
    let seen = await MainActor.run { s.ticks }
    #expect(await wait { s.ticks > seen })
    let (listed, held, start): (UInt64, Int, TimeInterval) = await MainActor.run {
        let listed = s.tree.progress.listed
        let start = ProcessInfo.processInfo.systemUptime
        let event = FSWatcher.Event(path: folder.path, flags: 0, id: FSEventsGetCurrentEventId())
        s.handle([event]) // listed now, which starts its pace
        s.handle([event]) // too soon: waits for the pace
        return (listed, s.pacedRefreshes, start)
    }
    #expect(held == 1)
    #expect(await wait({ s.pacedRefreshes == 0 }, timeout: 10))
    let released = try #require(await MainActor.run { s.lastPacedRelease }) - start
    #expect(released >= pace - 0.05)
    #expect(released < pace + 0.3) // its own deadline, not a later chore
    // Both listings happen.
    #expect(await wait { s.tree.progress.listed >= listed + UInt64(2 * files) })
    await finish(s)
}

/// After a burst it couldn't keep up with, FSEvents asks for the whole
/// volume to be checked again, and on a busy disk it asks again before a
/// check of a whole disk is through. A request for a folder whose check is
/// under way waits for it to end, then for ten times what it took, instead
/// of starting a second walk over it.
@Test func droppedEventsDontStackWholeLocationChecks() async throws {
    let root = try await scratch("silt-dropped", files: 400, in: 8)
    defer { cleanUp(root) }
    let walk = UInt64(400 + 8) // what one check of it lists
    let s = await MainActor.run { Session(url: root, guardPrivateFolders: true, fresh: true) }
    #expect(await wait { s.phase == .live && s.canPark })
    await settle(1.5)

    let dropped = FSWatcher.Event(
        path: root.path + "/",
        flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped),
        id: FSEventsGetCurrentEventId())
    let (listed, held): (UInt64, Int) = await MainActor.run {
        let listed = s.tree.progress.listed
        s.handle([dropped]) // starts a check of everything
        // Past the old 30 s limit, and the check (as far as the session
        // knows) still going: it's been running a minute.
        s.backdateDeepChecks(by: 60)
        s.handle([dropped])
        return (listed, s.deferredDeepChecks)
    }
    #expect(held == 1)
    #expect(await wait { s.rescanState == nil }) // the first check ends
    #expect(await MainActor.run { s.tree.progress.listed } - listed >= walk)

    // It took a minute, so the next one waits ten more.
    await settle(2)
    #expect(await MainActor.run { s.deferredDeepChecks } == 1)
    let afterOne = await MainActor.run { s.tree.progress.listed }
    #expect(afterOne - listed < 2 * walk)

    // Once that has passed, the deferred check runs.
    await MainActor.run { s.backdateDeepChecks(by: 11 * 60) }
    #expect(await wait { s.deferredDeepChecks == 0 })
    #expect(await wait { s.rescanState == nil && s.tree.progress.listed >= afterOne + walk })
    await finish(s)
}

/// A scan that settles is saved soon after, on screen or not, without
/// anything else happening to prompt it.
@Test(arguments: [true, false])
func settledScanIsSavedWithNoFurtherEvents(onScreen: Bool) async throws {
    let root = try await scratch("silt-settle", files: 40)
    defer { cleanUp(root) }
    let s = await MainActor.run {
        let s = Session(url: root, guardPrivateFolders: true, fresh: true)
        s.isOnScreen = onScreen
        return s
    }
    #expect(await wait { Snapshots.savedAt(for: root.path) != nil })
    let loaded = try #require(Snapshots.load(for: root, fullDiskAccess: false))
    #expect(loaded.replayable)
    silt_tree_destroy(loaded.tree)
    await finish(s)
}

@Test func capacityComparesEveryField() {
    let a = Capacity(total: 100, available: 60, free: 40)
    #expect(a == Capacity(total: 100, available: 60, free: 40))
    #expect(a != Capacity(total: 101, available: 60, free: 40))
    #expect(a != Capacity(total: 100, available: 61, free: 40))
    #expect(a != Capacity(total: 100, available: 60, free: 41))

    // A few kilobytes of churn on a 1 TB disk isn't worth a redraw; what a
    // status bar would show differently is.
    let disk = Capacity(total: 1_000_000_000_000, available: 140_000_000_000, free: 48_000_000_000)
    var churned = disk
    churned.free -= 40_000
    churned.available -= 40_000
    #expect(!disk.differsVisibly(from: churned))
    var shrunk = disk
    shrunk.free -= 200_000_000
    #expect(disk.differsVisibly(from: shrunk))
    let tiny = Capacity(total: 32_000_000_000, available: 5_000_000, free: 5_000_000)
    var filled = tiny
    filled.free -= 2_000_000
    #expect(tiny.differsVisibly(from: filled))
}

// MARK: Duplicates

private func stamp(dev: Int32 = 1, ino: UInt64, size: Int64 = 4096, alloc: Int64 = 4096,
                   mtime: (Int, Int) = (100, 5), ctime: (Int, Int) = (200, 7)) -> FileStamp {
    var st = stat()
    st.st_dev = dev
    st.st_ino = ino
    st.st_size = size
    st.st_blocks = alloc / 512
    st.st_mtimespec = timespec(tv_sec: mtime.0, tv_nsec: mtime.1)
    st.st_ctimespec = timespec(tv_sec: ctime.0, tv_nsec: ctime.1)
    return FileStamp(st)
}

/// Two separately stored copies, so the extra space is one copy's.
private func pair(_ extra: Int64, ino: UInt64) -> DuplicateSet {
    let copies = [ino, ino + 1].map { i in
        DuplicateSet.Copy(entry: UInt32(i), path: "/x/\(i)", stamp: stamp(ino: i, alloc: extra),
                          family: StorageFamily(dev: 1, id: i, isClone: false))
    }
    return DuplicateSet(size: extra, copies: copies)
}

@MainActor
@Test func duplicateSetsArriveInOrder() {
    let batches: [[DuplicateSet]] = [
        [pair(5 * 4096, ino: 10), pair(10 * 4096, ino: 20)],
        [pair(5 * 4096, ino: 30), pair(1 * 4096, ino: 40), pair(10 * 4096, ino: 50)],
        [],
        [pair(7 * 4096, ino: 60), pair(5 * 4096, ino: 70)],
    ]
    let finder = DuplicateFinder()
    // What inserting them one by one, as found, used to give.
    var expected: [DuplicateSet] = []
    for set in batches.joined() {
        expected.insert(set, at: expected.firstIndex { $0.extraBytes < set.extraBytes } ?? expected.count)
    }
    for batch in batches { finder.receive(batch) }
    #expect(finder.sets.map(\.id) == expected.map(\.id))
    #expect(finder.sets.map(\.id) == ["20", "50", "60", "10", "30", "70", "40"].map { "1:\($0)" })
    #expect(finder.extraBytes == expected.reduce(0) { $0 + $1.extraBytes })
    #expect(Set(finder.sets.map(\.id)).count == finder.sets.count)
}

@MainActor
@Test func pruneOnlyChangesWhatChanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-prune-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["a", "b", "c", "d"] {
        try Data(repeating: name == "a" || name == "b" ? 1 : 2, count: 8192).write(to: root.appendingPathComponent(name))
    }
    let tree = Tree(path: root.path)
    tree.startScan()
    defer { tree.stop() }
    #expect(await wait { tree.progress.idle && tree.progress.finished > 0 })

    func set(_ names: [String]) -> DuplicateSet {
        let copies: [DuplicateSet.Copy] = names.map { n in
            let path = root.appendingPathComponent(n).path
            let st = FileStamp(path: path)!
            return DuplicateSet.Copy(entry: tree.withLock { tree.lookup(path) }, path: path, stamp: st,
                                     family: StorageFamily(dev: st.dev, id: st.ino, isClone: false))
        }
        return DuplicateSet(size: 8192, copies: copies)
    }
    let finder = DuplicateFinder()
    finder.receive([set(["a", "b"]), set(["c", "d"])])
    let ids = finder.sets.map(\.id)
    #expect(ids.count == 2)

    // Nothing changed: nothing reassigned.
    #expect(!finder.prune(tree: tree))
    #expect(finder.sets.map(\.id) == ids)

    // A copy goes: its set is no longer a duplicate and drops out, the other stays as it was.
    try FileManager.default.removeItem(at: root.appendingPathComponent("b"))
    tree.refresh(dir: 0, deep: false, urgent: true)
    #expect(await wait {
        tree.withLock {
            let i = tree.lookup(root.appendingPathComponent("b").path)
            return i == NONE || !tree.isLive(i)
        }
    })
    #expect(await wait { tree.progress.idle })
    #expect(finder.prune(tree: tree))
    #expect(finder.sets.map(\.id) == [set(["c", "d"]).id])
    #expect(!finder.prune(tree: tree))
}

@Test func hashCacheIsBoundedAndKeyedByTheWholeStamp() {
    let cache = HashCache(capacity: 100)
    func digest(_ n: UInt64) -> HashCache.Digest { HashCache.Digest(a: n, b: ~n, c: n &* 31, d: 7) }
    for i in 0..<250 { cache.store(digest(UInt64(i)), for: stamp(ino: UInt64(i)), full: false) }
    #expect(cache.count == 100)
    #expect(cache.cached(stamp(ino: 0), full: false) == nil) // the oldest went first
    #expect(cache.cached(stamp(ino: 149), full: false) == nil)
    #expect(cache.cached(stamp(ino: 150), full: false) == digest(150))
    #expect(cache.cached(stamp(ino: 249), full: false) == digest(249))

    // Storing again replaces, without counting twice.
    cache.store(digest(1), for: stamp(ino: 249), full: false)
    #expect(cache.count == 100)
    #expect(cache.cached(stamp(ino: 249), full: false) == digest(1))

    // Every part of the stamp matters, and sampled and full hashes are apart.
    let known = stamp(ino: 200)
    #expect(cache.cached(known, full: false) == digest(200))
    #expect(cache.cached(known, full: true) == nil)
    for other in [stamp(dev: 2, ino: 200), stamp(ino: 200, size: 4097), stamp(ino: 200, mtime: (101, 5)),
                  stamp(ino: 200, mtime: (100, 6)), stamp(ino: 200, ctime: (201, 7)), stamp(ino: 200, ctime: (200, 8))] {
        #expect(cache.cached(other, full: false) == nil)
    }

    cache.removeAll()
    #expect(cache.count == 0)
    #expect(cache.cached(stamp(ino: 249), full: false) == nil)
}
