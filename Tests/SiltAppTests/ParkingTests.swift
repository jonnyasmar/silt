import CoreServices
import Foundation
import SiltCore
import Testing
@testable import Silt

@Test func parkedSessionComesBackExactlyAndCatchesUp() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-app-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    defer {
        Snapshots.discard(for: root) // the scan saved one when it settled
        try? FileManager.default.removeItem(at: root)
    }
    for i in 0..<200 {
        let url = root.appendingPathComponent("p\(i % 5)/f\(i).bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096 + i).write(to: url)
    }
    let s = await MainActor.run { Session(url: root, guardPrivateFolders: true, fresh: true) }
    #expect(await wait { s.phase == .live && s.canPark })
    let (bytes, p2): (Int64, UInt32?) = await MainActor.run {
        let p2 = s.tree.withLock { s.dirID(forPath: root.appendingPathComponent("p2").path) }
        if let p2 { s.treeStates[0] = TreeState(expanded: [p2]) }
        return (s.stats.bytes, p2)
    }
    let dir = try #require(p2)

    // A late event for the files written above can make it busy again, and
    // park() declines while busy: try until it starts.
    #expect(await wait {
        s.park()
        return s.residency != .awake
    })
    #expect(await wait { s.residency == .parked })
    #expect(await MainActor.run { silt_tree_is_parked(s.tree.raw) })

    // Changes while parked are remembered, not lost: the stream stays, and
    // notes the folder. (Fed directly too: under load, FSEvents can take
    // tens of seconds to deliver.)
    let new = root.appendingPathComponent("p2/new.bin")
    try Data(repeating: 2, count: 300_000).write(to: new)
    let noted = await MainActor.run {
        s.handle([FSWatcher.Event(path: new.deletingLastPathComponent().path + "/", flags: 0,
                                  id: FSEventsGetCurrentEventId())])
        return s.watching && s.parkedChanges > 0
    }
    #expect(noted)
    #expect(await MainActor.run { s.stats.bytes } == bytes) // nothing moves while parked

    await MainActor.run { s.wake() }
    #expect(await wait { s.isAwake })
    // Same dir ids as before parking, and what referred to them still does.
    #expect(await MainActor.run { s.tree.withLock { s.dirID(forPath: root.appendingPathComponent("p2").path) } } == dir)
    #expect(await MainActor.run { s.treeStates[0]?.expanded } == [dir])
    // And the change made while it was parked arrives.
    #expect(await wait { s.tree.withLock { s.tree.lookup(root.appendingPathComponent("p2/new.bin").path) } != NONE })
    #expect(await wait { s.stats.bytes > bytes })
    await MainActor.run { s.close() }
}

@Test func wakeRequestedWhileParkingStillWakes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-app-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    defer {
        Snapshots.discard(for: root) // the scan saved one when it settled
        try? FileManager.default.removeItem(at: root)
    }
    for i in 0..<50 {
        let url = root.appendingPathComponent("d/f\(i)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: url)
    }
    let s = await MainActor.run { Session(url: root, guardPrivateFolders: true, fresh: true) }
    #expect(await wait { s.phase == .live && s.canPark })
    await MainActor.run {
        s.park()
        s.wake() // before parking has finished
    }
    #expect(await wait { s.isAwake })
    #expect(await MainActor.run { !silt_tree_is_parked(s.tree.raw) && s.stats.items == 51 })
    await MainActor.run { s.close() }
}

@Test func coveringScanAnswersWithoutItsTree() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-cover-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    defer {
        Snapshots.discard(for: root) // the scan saved one when it settled
        try? FileManager.default.removeItem(at: root)
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
    let s = await MainActor.run { Session(url: root, guardPrivateFolders: true, fresh: true) }
    let answers = await MainActor.run {
        [s.covers(root.appendingPathComponent("a/b").path), s.covers(root.path),
         s.covers(root.deletingLastPathComponent().path), s.covers(root.path + "-sibling/x")]
    }
    #expect(answers == [true, false, false, false])
    await MainActor.run { s.close() }
}

@Test func absorbingKeepsBothScansMarks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-absorb-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    defer {
        Snapshots.discard(for: root) // the scan saved one when it settled
        try? FileManager.default.removeItem(at: root)
    }
    for name in ["top.bin", "sub/inner.bin"] {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 8_192).write(to: url)
    }
    let sub = root.appendingPathComponent("sub")
    defer {
        Snapshots.discard(for: sub)
        UserDefaults.standard.removeObject(forKey: "marks:" + root.path)
        UserDefaults.standard.removeObject(forKey: "marks:" + sub.path)
    }
    // The bigger scan has a mark saved from before...
    var st = stat()
    lstat(root.appendingPathComponent("top.bin").path, &st)
    UserDefaults.standard.set([["path": root.appendingPathComponent("top.bin").path, "reason": "",
                                "dev": Int(st.st_dev), "ino": Int(st.st_ino)]], forKey: "marks:" + root.path)
    // ...and the smaller one gets a mark now.
    let child = await MainActor.run { Session(url: sub, guardPrivateFolders: true, fresh: true) }
    #expect(await wait { child.phase == .live })
    await MainActor.run {
        if let ref = child.liveRef(path: sub.appendingPathComponent("inner.bin").path) { child.mark([ref], reason: "test") }
    }
    #expect(await MainActor.run { child.markedCount } == 1)

    // The host absorbs it the moment it's live, before its own marks were restored.
    let host = await MainActor.run { () -> Session in
        let h = Session(url: root, guardPrivateFolders: true, fresh: true)
        h.onLive = { [weak h] in h?.adoptMarks(from: child) }
        return h
    }
    #expect(await wait { host.markedCount == 2 })
    let saved = UserDefaults.standard.array(forKey: "marks:" + root.path)?.count
    #expect(saved == 2)
    #expect(UserDefaults.standard.array(forKey: "marks:" + sub.path) == nil)
    // Closed once no save is in flight, so none lands after the cleanup.
    for s in [child, host] {
        _ = await wait {
            guard s.canPark || s.closed else { return false }
            s.close()
            return true
        }
    }
}
