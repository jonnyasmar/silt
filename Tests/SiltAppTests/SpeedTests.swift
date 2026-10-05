import CoreServices
import Foundation
import SiltCore
import Testing
@testable import Silt

/// Speed modes, busy folders and folder rules.

private func scratch(_ prefix: String, folders: [String: Int]) async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    for (folder, files) in folders {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<files { try Data(repeating: 1, count: 4096).write(to: dir.appendingPathComponent("f\(i).bin")) }
    }
    await settle(1.5)
    return root
}

private func live(_ root: URL, fresh: Bool = true) async -> Session {
    let s = await MainActor.run { Session(url: root, guardPrivateFolders: true, fresh: fresh) }
    #expect(await wait { s.phase == .live && s.canPark })
    return s
}

private func finish(_ s: Session) async {
    _ = await wait {
        guard s.canPark else { return false }
        s.close()
        return true
    }
}

private func cleanUp(_ root: URL) {
    Snapshots.discard(for: root)
    UserDefaults.standard.removeObject(forKey: "pausedPending:" + root.path)
    try? FileManager.default.removeItem(at: root)
}

@MainActor
private func dirID(_ s: Session, _ path: String) -> UInt32? {
    s.tree.withLock {
        let i = s.tree.lookup(path)
        return i != NONE && s.tree.entry(i).isDir ? s.tree.entry(i).aux : nil
    }
}

private func event(_ path: String) -> FSWatcher.Event {
    FSWatcher.Event(path: path, flags: 0, id: FSEventsGetCurrentEventId())
}

// MARK: Policy

@Test func speedModesMapToPaces() {
    let cores = CoreCounts(performance: 10, efficiency: 4)
    let plugged = PowerConditions()
    let auto = SpeedPolicy.pace(.automatic, plugged, cores: cores)
    #expect(auto.urgentQoS == .userInitiated && auto.urgentMax == 0)
    #expect(auto.backgroundQoS == .utility && auto.backgroundMax == 4)
    #expect(!auto.catchUpUrgent && auto.paceFactor == 1 && auto.reason == nil)

    let fast = SpeedPolicy.pace(.fast, plugged, cores: cores)
    #expect(fast.catchUpUrgent && fast.backgroundQoS == .userInitiated && fast.backgroundMax == 5)

    let gentle = SpeedPolicy.pace(.gentle, plugged, cores: cores)
    #expect(gentle.urgentQoS == .background && gentle.urgentMax == 4)
    #expect(gentle.backgroundQoS == .background && gentle.backgroundMax == 1 && gentle.paceFactor == 4)

    // Paused holds Silt's own work back, not what the user starts.
    let paused = SpeedPolicy.pace(.paused, plugged, cores: cores)
    #expect(paused.upkeepPaused && !paused.paused)
    #expect(paused.urgentQoS == auto.urgentQoS && paused.urgentMax == auto.urgentMax)

    // Automatic eases off with the Mac.
    let battery = SpeedPolicy.pace(.automatic, PowerConditions(onBattery: true), cores: cores)
    #expect(battery.backgroundQoS == .background && battery.paceFactor == 2 && battery.reason == "on battery")
    #expect(battery.urgentQoS == .userInitiated)
    let low = SpeedPolicy.pace(.automatic, PowerConditions(lowPower: true, onBattery: true), cores: cores)
    #expect(low.urgentQoS == .utility && low.urgentMax == 5 && low.paceFactor == 4 && low.reason == "Low Power Mode")
    let hot = SpeedPolicy.pace(.automatic, PowerConditions(thermal: .serious), cores: cores)
    #expect(hot.urgentQoS == .utility && hot.reason == "running hot")
    // Fast and Gentle are what they say, whatever the conditions.
    #expect(SpeedPolicy.pace(.fast, PowerConditions(lowPower: true), cores: cores) == fast)
    // No efficiency cores (Intel): Gentle still runs two at a time.
    #expect(SpeedPolicy.pace(.gentle, plugged, cores: CoreCounts(performance: 8, efficiency: 0)).urgentMax == 2)
}

// MARK: Busy folders

/// A folder that changes again right after each listing runs hotter each
/// time, so its wait doubles once per listing; quiet, it cools off at once.
/// Open on screen, it never waits more than 2 s.
@Test func busyFoldersBackOffAndCool() async throws {
    let root = try await scratch("silt-busy", folders: ["hot": 3])
    defer { cleanUp(root) }
    let hot = root.appendingPathComponent("hot").path
    let s = await live(root)
    await settle(1)

    // One hop, so no real file event lands between the steps.
    let (heats, busy, every, factor): ([Int], [String], TimeInterval?, Double) = await MainActor.run {
        let dir = dirID(s, hot)!
        // A late event for the files just written may have listed it a
        // moment ago: start from a folder that has been quiet a while.
        s.backdatePacing(by: 300)
        var heats: [Int] = []
        for _ in 0..<7 {
            s.handle([event(hot)])
            s.releasePacedNow() // its wait is over: the listing it waited for happens
            heats.append(s.heat(of: dir))
        }
        return (heats, s.busyFolders.map(\.path), s.busyFolders.first?.every, SpeedController.shared.pace.paceFactor)
    }
    // The first change after a quiet spell doesn't count; each one right
    // after a listing does.
    #expect(heats == [0, 1, 2, 3, 4, 5, 6])
    // 0.25 s doubled five times: 8 s between updates, so it's shown as busy.
    #expect(busy == [hot])
    #expect(every == 8 * factor)

    // Open on screen: capped at 2 s, so not busy any more.
    await MainActor.run {
        let dir = dirID(s, hot)!
        s.setShown([dir], by: ObjectIdentifier(s))
        s.handle([event(hot)])
        s.releasePacedNow()
    }
    #expect(await MainActor.run { s.busyFolders.isEmpty })
    await MainActor.run { s.setShown([], by: ObjectIdentifier(s)) }

    // Quiet for longer than four times its wait (16 s by now), then one
    // change: cooled, listed at once.
    let (heat, waiting): (Int, Int) = await MainActor.run {
        s.backdatePacing(by: 300)
        s.handle([event(hot)])
        return (s.heat(of: dirID(s, hot)!), s.pacedRefreshes)
    }
    #expect(heat == 0)
    #expect(waiting == 0)
    await finish(s)
}

// MARK: Folder rules

/// Live: listed on every change, never held back. Paused: changes wait
/// until the folder is opened.
@Test func liveAndPausedRules() async throws {
    let root = try await scratch("silt-rules", folders: ["live": 2, "quiet": 2])
    defer { cleanUp(root) }
    let livePath = root.appendingPathComponent("live").path
    let quietPath = root.appendingPathComponent("quiet").path
    let s = await live(root)
    await settle(1)

    let (held, heat): (Int, Int) = await MainActor.run {
        FolderRules.shared.set(.live, for: livePath)
        for _ in 0..<6 { s.handle([event(livePath)]) }
        return (s.pacedRefreshes, s.heat(of: dirID(s, livePath)!))
    }
    #expect(held == 0)
    #expect(heat == 0)

    await MainActor.run { FolderRules.shared.set(.paused, for: quietPath) }
    #expect(await wait { s.tree.progress.idle }) // the Live folder's listings are done
    let listed = await MainActor.run { s.tree.progress.listed }
    await MainActor.run { s.handle([event(quietPath + "/f0.bin")]) }
    await settle(0.5)
    let quiet = try #require(await MainActor.run { dirID(s, quietPath) })
    #expect(await MainActor.run { s.tree.progress.listed } == listed)
    #expect(await MainActor.run { s.hasPausedChanges(under: quiet) })
    // Remembered for a relaunch.
    #expect(UserDefaults.standard.dictionary(forKey: "pausedPending:" + root.path)?[quietPath] != nil)

    await MainActor.run { s.lookedAt(dir: quiet) }
    #expect(await wait { s.tree.progress.listed > listed })
    #expect(await MainActor.run { !s.hasPausedChanges(under: quiet) })
    #expect(UserDefaults.standard.dictionary(forKey: "pausedPending:" + root.path) == nil)
    await finish(s)
    await MainActor.run {
        FolderRules.shared.set(nil, for: livePath)
        FolderRules.shared.set(nil, for: quietPath)
    }
}

/// Don't Scan: the folder's contents leave the scan (and its size), and come
/// back when the rule goes; a restored scan follows the rules of today.
@Test func excludeRuleDropsAndRestoresAFolder() async throws {
    let root = try await scratch("silt-exclude", folders: ["keep": 2, "vm": 20])
    let vm = root.appendingPathComponent("vm").path
    defer { cleanUp(root) }
    let s = await live(root)
    let whole = await MainActor.run { s.tree.withLock { s.tree.entry(0).size } }
    @MainActor @Sendable func total(_ s: Session) -> Int64 { s.tree.withLock { s.tree.entry(0).size } }
    @MainActor @Sendable func vmEntry(_ s: Session) -> (size: Int64, excluded: Bool)? {
        s.tree.withLock {
            let i = s.tree.lookup(vm)
            guard i != NONE else { return nil }
            let e = s.tree.entry(i)
            return (e.size, e.flags & UInt8(SILT_FLAG_EXCLUDED) != 0)
        }
    }

    await MainActor.run { FolderRules.shared.set(.excluded, for: vm) }
    #expect(await wait { vmEntry(s)?.excluded == true })
    #expect(await MainActor.run { vmEntry(s)?.size } == 0)
    #expect(await MainActor.run { total(s) } < whole)

    await MainActor.run { FolderRules.shared.set(nil, for: vm) }
    #expect(await wait { vmEntry(s)?.excluded == false && total(s) == whole })
    await MainActor.run { s.flushMarks() }
    _ = await wait { Snapshots.savedAt(for: root.path) != nil }
    await finish(s)

    // Saved with vm scanned; excluded since: the restored scan drops it.
    await MainActor.run { FolderRules.shared.set(.excluded, for: vm) }
    let restored = await MainActor.run { Session(url: root, guardPrivateFolders: true) }
    #expect(await wait { restored.phase == .live && vmEntry(restored)?.excluded == true })
    #expect(await MainActor.run { vmEntry(restored)?.size } == 0)
    await finish(restored)
    await MainActor.run { FolderRules.shared.set(nil, for: vm) }
}
