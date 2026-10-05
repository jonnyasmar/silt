import CoreServices
import Foundation
import SiltCore
import Testing
@testable import Silt

/// A scratch location, scanned once and closed, whose tree is saved by hand
/// so each test can choose what the snapshot claims.
private struct Saved {
    let root: URL
    let first: Session

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-restore-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        for i in 0..<60 {
            let url = root.appendingPathComponent("p\(i % 3)/f\(i).bin")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4_096 + i).write(to: url)
        }
        let root = root
        let first = await MainActor.run { Session(url: root, guardPrivateFolders: true, fresh: true) }
        self.first = first
        // Closed in the same turn it's seen settled: a late event for the
        // files written above would otherwise queue a listing that closing
        // cancels, and a tree with a listing pending can't be saved.
        #expect(await wait {
            guard first.phase == .live && first.canPark else { return false }
            first.close()
            return true
        })
    }

    func url(_ rel: String) -> URL { root.appendingPathComponent(rel) }

    /// Saves the closed scan as if current as of now (FSEvents-wise), saved
    /// `age` seconds ago. `incomplete`: folders to flag as having stopped early.
    @MainActor
    func save(age: TimeInterval, incomplete: [String] = []) -> Bool {
        let tree = first.tree
        tree.withLock {
            for rel in incomplete {
                if let d = first.dirID(forPath: url(rel).path) {
                    silt_dir_at(tree.raw, d).pointee.state |= UInt32(SILT_DIR_INCOMPLETE)
                }
            }
        }
        guard let uuid = FSWatcher.databaseUUID(for: root.path) else { return false }
        var meta = silt_snapshot_meta()
        meta.event_id = FSEventsGetCurrentEventId()
        meta.saved_at = Date().timeIntervalSince1970 - age
        withUnsafeMutableBytes(of: &meta.volume_uuid) { dst in
            withUnsafeBytes(of: uuid) { src in dst.copyMemory(from: src) }
        }
        try? FileManager.default.createDirectory(at: Snapshots.directory, withIntermediateDirectories: true)
        return silt_tree_save(tree.raw, Snapshots.file(for: root.path).path, &meta)
    }

    func cleanUp() {
        Snapshots.discard(for: root)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Settled (no save in flight) and closed before the scratch folder is
/// cleaned up, or it saves once more.
private func finish(_ s: Session) async {
    _ = await wait {
        guard s.canPark else { return false }
        s.close()
        return true
    }
}

@Test func restoreCatchesUpAndRereadsFoldersThatStoppedEarly() async throws {
    let saved = try await Saved()
    defer { saved.cleanUp() }
    // Lands before the id the snapshot is current as of, so no replay will
    // bring it back: only listing p1 again finds it.
    let missed = saved.url("p1/missed.bin")
    try Data(repeating: 3, count: 50_000).write(to: missed)
    await settle(1.5)
    #expect(await MainActor.run { saved.save(age: 60, incomplete: ["p1"]) })

    // Read in the same turn as the restore: on a folder this small, catching
    // up can be over by the next one.
    let (s, restoring) = await MainActor.run {
        let s = Session(url: saved.root, guardPrivateFolders: true)
        return (s, s.restoredFrom != nil && s.catchingUp && s.recheckingSince == nil && s.showsSavedScan)
    }
    #expect(restoring)
    #expect(await wait { !s.catchingUp })
    #expect(await wait { s.tree.withLock { s.tree.lookup(missed.path) } != NONE })
    #expect(await MainActor.run { !s.showsSavedScan })
    await finish(s)
}

/// Replayed history names a busy folder over and over. Listing it reads it
/// as it is now, so changes older than that listing need nothing more; a
/// newer one lists it again.
@Test func replayListsAFolderOnceForEverythingOlder() async throws {
    let saved = try await Saved()
    defer { saved.cleanUp() }
    #expect(await MainActor.run { saved.save(age: 60) })

    // In the same turn as the restore, before the real replay is delivered.
    let (s, replaying, skips): (Session, Bool, [Int]) = await MainActor.run {
        let s = Session(url: saved.root, guardPrivateFolders: true)
        let path = saved.url("p1").path + "/"
        let replaying = s.catchingUp
        var skips: [Int] = []
        s.handle([FSWatcher.Event(path: path, flags: 0, id: 1)]) // listed
        skips.append(s.replaySkips)
        s.handle([FSWatcher.Event(path: path, flags: 0, id: 2)]) // older than that listing
        skips.append(s.replaySkips)
        s.handle([FSWatcher.Event(path: path, flags: 0, id: FSEventsGetCurrentEventId() + 1)]) // newer
        skips.append(s.replaySkips)
        return (s, replaying, skips)
    }
    #expect(replaying)
    #expect(skips == [0, 1, 1])
    #expect(await wait { !s.catchingUp })
    await finish(s)
}

/// A replay that drops events can't be trusted: the saved scan is checked
/// again in place instead, which finds what no replay would bring back.
/// More drops the old stream had already sent change nothing.
@Test func replayThatDropsEventsChecksEverythingInstead() async throws {
    let saved = try await Saved()
    defer { saved.cleanUp() }
    // Lands before the id the snapshot is current as of: only a check of
    // everything finds it.
    let missed = saved.url("p1/missed.bin")
    try Data(repeating: 3, count: 50_000).write(to: missed)
    await settle(1.5)
    #expect(await MainActor.run { saved.save(age: 60) })

    let (s, replaying, rechecking, live, deferred): (Session, Bool, Bool, Bool, Int) = await MainActor.run {
        let s = Session(url: saved.root, guardPrivateFolders: true)
        let replaying = s.catchingUp
        let now = FSEventsGetCurrentEventId(), old = s.watcherGeneration
        let drop = FSWatcher.Event(path: saved.root.path + "/", flags: UInt32(kFSEventStreamEventFlagUserDropped), id: 0)
        s.handle([drop], generation: old)
        let rechecking = !s.catchingUp && s.recheckingSince != nil && s.rescanState != nil
        // The replay is dropped for a stream from now, and what the old one
        // already sent is ignored.
        let live = s.lastEventId >= now && s.watcherGeneration != old
        s.handle([drop], generation: old)
        return (s, replaying, rechecking, live, s.deferredDeepChecks)
    }
    #expect(replaying)
    #expect(rechecking)
    #expect(live)
    #expect(deferred == 0)
    #expect(await wait { s.recheckingSince == nil })
    #expect(await wait { s.tree.withLock { s.tree.lookup(missed.path) } != NONE })
    await finish(s)
}

@Test func tooOldSnapshotIsShownWhileEverythingIsReadAgain() async throws {
    let saved = try await Saved()
    defer { saved.cleanUp() }
    let added = saved.url("p2/later.bin"), removed = saved.url("p0/f0.bin")
    try Data(repeating: 2, count: 300_000).write(to: added)
    try FileManager.default.removeItem(at: removed)
    #expect(await MainActor.run { saved.save(age: 8 * 86400) })

    let (s, rechecking, showing) = await MainActor.run {
        let s = Session(url: saved.root, guardPrivateFolders: true)
        return (s, s.recheckingSince, s.restoredFrom != nil && !s.catchingUp && s.showsSavedScan)
    }
    let since = try #require(rechecking)
    #expect(showing)

    #expect(await wait { s.recheckingSince == nil })
    #expect(await MainActor.run { !s.showsSavedScan })
    let (hasAdded, hasRemoved, oldest): (Bool, Bool, UInt32) = await MainActor.run {
        s.tree.withLock {
            let a = s.tree.lookup(added.path), r = s.tree.lookup(removed.path)
            var oldest = UInt32.max
            for d in 0..<s.tree.raw.pointee.dir_count {
                let dir = s.tree.dir(d)
                guard s.tree.isLive(dir.entry) else { continue }
                oldest = min(oldest, dir.listed_at)
            }
            return (a != NONE && s.tree.isLive(a), r != NONE && s.tree.isLive(r), oldest)
        }
    }
    #expect(hasAdded && !hasRemoved)
    #expect(oldest >= since) // every folder was read again

    // Up to date now, so it's saved again, and the next launch can catch up.
    #expect(await wait { (Snapshots.savedAt(for: saved.root.path) ?? .distantPast) > Date().addingTimeInterval(-60) })
    let reloaded = try #require(Snapshots.load(for: saved.root, fullDiskAccess: false))
    #expect(reloaded.replayable)
    silt_tree_destroy(reloaded.tree)
    await finish(s)
}
