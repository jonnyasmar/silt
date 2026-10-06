import Foundation
import Testing
@testable import Silt

/// A Time Machine snapshot name for `date`, in local time like the real ones.
private func snapshotName(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return "com.apple.TimeMachine.\(f.string(from: date)).local"
}

private func listing(_ dates: [Date]) -> SnapshotListing {
    SnapshotListing(snapshots: dates.map { .init(name: snapshotName($0), created: $0) })
}

// MARK: - Model

/// Held bytes come back only once every snapshot holding them is gone, in
/// whatever order they go, and only by a listing started after the record.
@Test func heldSpaceReleasesWhenAllItsHoldersAreGone() {
    let volume = "test-\(UUID().uuidString)"
    defer { HeldSpace().save(volume: volume) } // removes the key
    var held = HeldSpace()
    held.record([.init(holders: ["s1", "s2", "s3"], bytes: 3_000), .init(holders: ["s3"], bytes: 2_000),
                 .init(holders: ["s9"], bytes: 0)], ticket: 5)
    #expect(held.total == 5_000)
    func names(_ n: [String]) -> SnapshotListing {
        SnapshotListing(snapshots: n.map { .init(name: $0, created: Date(timeIntervalSince1970: 1_700_000_000)) })
    }
    // The newest went first (deleted by hand, or a backup kept the oldest):
    // the bytes only it held come back; the rest are still in s1.
    #expect(held.release(by: names(["s1", "s2"]), ticket: 6) == 2_000)
    #expect(held.total == 3_000)
    // A listing started before the record says nothing about it.
    #expect(held.release(by: names([]), ticket: 5) == 0)
    held.save(volume: volume)
    // Loaded in a later launch: any listing then is later.
    var loaded = HeldSpace.load(volume: volume)
    #expect(loaded.total == 3_000)
    #expect(loaded.release(by: names([]), ticket: 1) == 3_000)
    #expect(loaded.isEmpty)
    loaded.save(volume: volume)
    #expect(HeldSpace.load(volume: volume).isEmpty)
}

/// Recorded while the snapshots couldn't be listed: any snapshot taken
/// during the removal holds it too, once a listing shows one.
@Test func removalWindowHoldsUntilItsSnapshotsGo() {
    let start = Date(timeIntervalSinceNow: -120), end = Date(timeIntervalSinceNow: -60)
    var held = HeldSpace()
    held.record([.init(holders: [], bytes: 1_000)], ticket: 1, during: DateInterval(start: start, end: end))
    let during = listing([start.addingTimeInterval(30)])
    #expect(held.release(by: during, ticket: 2) == 0) // a snapshot was taken meanwhile
    #expect(held.release(by: listing([Date(timeIntervalSinceNow: -3600)]), ticket: 3) == 1_000) // it's gone
}

/// A snapshot taken while a removal ran holds whatever wasn't gone yet.
@Test func snapshotDuringRemovalHoldsTheRest() {
    var split = SpaceSplit(freesNow: 1_000, shared: 50)
    split.addHold(["a", "b"], 400)
    let caught = split.caught(by: ["c"])
    #expect(caught.freesNow == 0)
    #expect(caught.held == [.init(holders: ["a", "b", "c"], bytes: 400), .init(holders: ["c"], bytes: 1_000)])
    #expect(caught.total == split.total)
    #expect(split.caught(by: []) == split)
}

/// What wasn't removed after all comes off, bucket by bucket.
@Test func splitsSubtract() {
    var before = SpaceSplit(freesNow: 500, shared: 100)
    before.addHold(["a"], 300)
    before.measured = 900
    var left = SpaceSplit(freesNow: 200, shared: 100)
    left.addHold(["a"], 50)
    left.measured = 350
    let went = before.minus(left)
    #expect(went.freesNow == 300 && went.shared == 0 && went.held == [.init(holders: ["a"], bytes: 250)])
    #expect(went.measured == 550)
}

/// The listing comes from the file system, oldest first, with real dates.
@Test func snapshotsListedWithTheirTimes() throws {
    let listing = try #require(SnapshotListing.read(for: NSTemporaryDirectory()))
    #expect(listing.snapshots.map(\.created) == listing.snapshots.map(\.created).sorted())
    #expect(listing.snapshots.allSatisfy { $0.created <= Date() && $0.created > Date(timeIntervalSince1970: 1_600_000_000) })
    let mixed = SnapshotListing(snapshots: [.init(name: "com.bombich.ccc.x", created: Date()),
                                            .init(name: "com.apple.TimeMachine.2026-10-06-113928.local", created: Date())])
    #expect(!mixed.estimable) // another app's snapshot: nothing can be promised
    let undated = SnapshotListing(snapshots: [.init(name: "com.apple.TimeMachine.x.local", created: Date(timeIntervalSince1970: 0))])
    #expect(!undated.estimable)
}

/// Every combination reads as bounds, and says nothing when there's nothing.
@Test func summariesSayOnlyWhatsTrue() {
    #expect(SpaceSplit.unknown.summary(done: false).contains("couldn’t check"))
    #expect(SpaceSplit().summary(done: false).isEmpty)
    #expect(SpaceSplit(freesNow: 2_000_000).summary(done: false) == "At least 2.0 MB comes back right away.")
    var held = SpaceSplit()
    held.addHold(["s"], 3_000_000)
    #expect(held.summary(done: true) == "Up to 3.0 MB is held by local Time Machine snapshots until they’re gone.")
    #expect(SpaceSplit(shared: 1_000_000).summary(done: false).contains("only if every copy goes"))
    var whole = SpaceSplit(freesNow: 1_000_000)
    whole.addHold(["s"], 1_000_000)
    #expect(whole.summary(done: false).contains("Up to 1.0 MB stays held"))
    // Cut short, what's held is only a floor.
    var cut = whole
    cut.partial = true
    let text = cut.summary(done: false)
    #expect(text.hasPrefix("At least 1.0 MB comes back") && text.contains("At least 1.0 MB stays held"))
    #expect(text.hasSuffix("so more may be held."))
    #expect(SpaceSplit(inUse: 2_000_000).summary(done: true).contains("open in a running app"))
}

// MARK: - Session and ledger

/// Listings handed out in turn (the last one repeats), counting the calls.
private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [SnapshotListing?]
    init(_ listings: [SnapshotListing?]) { queue = listings }
    func next(_: String) -> SnapshotListing? {
        lock.lock(); defer { lock.unlock() }
        return queue.count > 1 ? queue.removeFirst() : queue.first ?? nil
    }
    func set(_ listings: [SnapshotListing?]) {
        lock.lock(); defer { lock.unlock() }
        queue = listings
    }
}

/// A scratch location with files to delete, scanned, with a ledger of its own.
private struct Scene {
    let root: URL
    let file: URL
    let ledger: SpaceLedger
    let session: Session
    let script: Script

    init(_ listings: [SnapshotListing?], bytes: Int = 400_000) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-ledger-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let file = root.appendingPathComponent("sub/doomed.bin")
        try Data(repeating: 9, count: bytes).write(to: file)
        let script = Script(listings)
        let (ledger, session) = await MainActor.run {
            let ledger = SpaceLedger(volume: "test-\(UUID().uuidString)", mount: root.path, persists: false)
            ledger.lister = { script.next($0) }
            return (ledger, Session(url: root, guardPrivateFolders: true, fresh: true, ledger: ledger))
        }
        self.root = root
        self.file = file
        self.ledger = ledger
        self.session = session
        self.script = script
        #expect(await wait { session.phase == .live && session.canPark })
    }

    /// Allocated size on disk, as the ledger measures it.
    func size(_ u: URL? = nil) -> Int64 {
        Int64((try? (u ?? file).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }

    @MainActor func delete(_ urls: [URL]? = nil) {
        let refs = session.tree.withLock { (urls ?? [file]).map { session.ref(forEntry: session.tree.lookup($0.path)) } }
        session.deleteImmediately(refs, window: nil, confirmed: true)
    }

    func cleanUp() async {
        await MainActor.run { session.close() }
        Snapshots.discard(for: root)
        try? FileManager.default.removeItem(at: root)
    }
}

/// A file older than the newest snapshot is held by it when deleted, and
/// comes back once that snapshot is gone.
@Test func deletedFileHeldBySnapshotComesBackWhenItGoes() async throws {
    let scene = try await Scene([listing([Date()])]) // taken after the file was written
    let size = scene.size()
    await MainActor.run { scene.delete() }
    #expect(await wait { scene.ledger.held.total > 0 && scene.ledger.removing.isEmpty })
    let (held, freed) = await MainActor.run { (scene.ledger.held.total, scene.ledger.freed) }
    #expect(held == size)
    #expect(freed == 0)
    #expect(!FileManager.default.fileExists(atPath: scene.file.path))
    // The snapshot expires: the next listing gives the space back.
    scene.script.set([listing([])])
    _ = await scene.ledger.refresh()
    let after = await MainActor.run { (scene.ledger.held.total, scene.ledger.freed) }
    #expect(after == (0, size))
    await scene.cleanUp()
}

/// A file born after the newest snapshot is in none of them: it frees now.
@Test func fileNewerThanEverySnapshotFreesNow() async throws {
    let scene = try await Scene([listing([Date(timeIntervalSinceNow: -3 * 3600)])])
    let size = scene.size()
    await MainActor.run { scene.delete() }
    #expect(await wait { scene.ledger.freed > 0 && scene.ledger.removing.isEmpty })
    let state = await MainActor.run { (scene.ledger.held.total, scene.ledger.freed) }
    #expect(state == (0, size))
    await scene.cleanUp()
}

/// A snapshot taken while the delete ran holds what wasn't gone yet, so
/// nothing is counted as free for sure.
@Test func snapshotTakenDuringDeleteHoldsIt() async throws {
    let before = listing([Date(timeIntervalSinceNow: -3 * 3600)])
    let after = listing([Date(timeIntervalSinceNow: -3 * 3600), Date()])
    let scene = try await Scene([before, after])
    let size = scene.size()
    await MainActor.run { scene.delete() }
    #expect(await wait { scene.ledger.held.total > 0 && scene.ledger.removing.isEmpty })
    let state = await MainActor.run { (scene.ledger.held.total, scene.ledger.freed) }
    #expect(state == (size, 0))
    await scene.cleanUp()
}

/// If the snapshots can't be listed after the delete, nothing counts as
/// freed until a listing shows no snapshot was taken meanwhile.
@Test func failedListingAfterDeleteHoldsUntilKnown() async throws {
    let old = listing([Date(timeIntervalSinceNow: -3 * 3600)])
    let scene = try await Scene([old, nil])
    let size = scene.size()
    await MainActor.run { scene.delete() }
    #expect(await wait { scene.ledger.held.total > 0 && scene.ledger.removing.isEmpty })
    #expect(await MainActor.run { scene.ledger.freed } == 0)
    // One was taken during the delete: still held.
    let during = Date(timeIntervalSinceNow: -0.5)
    scene.script.set([listing([Date(timeIntervalSinceNow: -3 * 3600), during])])
    _ = await scene.ledger.refresh()
    #expect(await MainActor.run { scene.ledger.held.total } == size)
    // It's gone: now it's free.
    scene.script.set([old])
    _ = await scene.ledger.refresh()
    let state = await MainActor.run { (scene.ledger.held.total, scene.ledger.freed) }
    #expect(state == (0, size))
    await scene.cleanUp()
}

/// A file an app holds open frees nothing until it's closed: it isn't
/// counted as freed, however new it is.
@Test func fileHeldOpenIsNotCountedAsFreed() async throws {
    let scene = try await Scene([listing([Date(timeIntervalSinceNow: -3 * 3600)])])
    let handle = try FileHandle(forReadingFrom: scene.file) // this process holds it open
    defer { try? handle.close() }
    await MainActor.run { scene.delete() }
    #expect(await wait { !FileManager.default.fileExists(atPath: scene.file.path) && scene.ledger.removing.isEmpty })
    #expect(await wait { scene.session.toast?.title.hasPrefix("Deleted") == true })
    let state = await MainActor.run { (scene.ledger.held.total, scene.ledger.freed, scene.session.toast?.detail ?? "") }
    #expect(state.0 == 0 && state.1 == 0)
    #expect(state.2.contains("open in a running app"))
    await scene.cleanUp()
}

/// A file mapped into memory (its descriptor closed, like a running app's
/// own binary) frees nothing until it's unmapped: it isn't counted as freed.
@Test func fileMappedIntoMemoryIsNotCountedAsFreed() async throws {
    let scene = try await Scene([listing([Date(timeIntervalSinceNow: -3 * 3600)])])
    let fd = open(scene.file.path, O_RDONLY)
    #expect(fd >= 0)
    let length = 400_000
    let map = mmap(nil, length, PROT_READ, MAP_SHARED, fd, 0)
    close(fd) // only the mapping is left
    #expect(map != MAP_FAILED)
    defer { munmap(map, length) }
    await MainActor.run { scene.delete() }
    #expect(await wait { scene.session.toast?.title.hasPrefix("Deleted") == true && scene.ledger.removing.isEmpty })
    let state = await MainActor.run { (scene.ledger.freed, scene.session.toast?.detail ?? "") }
    #expect(state.0 == 0)
    #expect(state.1.contains("open in a running app"))
    await scene.cleanUp()
}

/// Snapshots that can't be listed mean nothing is promised or recorded.
@Test func unlistableSnapshotsPromiseNothing() async throws {
    let scene = try await Scene([nil])
    await MainActor.run { scene.delete() }
    #expect(await wait { !FileManager.default.fileExists(atPath: scene.file.path) && scene.ledger.removing.isEmpty })
    await settle(0.5)
    let state = await MainActor.run { (scene.ledger.held.total, scene.ledger.freed, scene.ledger.listingFailed) }
    #expect(state == (0, 0, true))
    await scene.cleanUp()
}

/// A delete that fails partway records only what went.
@Test func partialDeleteRecordsOnlyWhatWent() async throws {
    let scene = try await Scene([listing([Date(timeIntervalSinceNow: -3 * 3600)])])
    let stuck = scene.root.appendingPathComponent("stuck")
    try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
    let locked = stuck.appendingPathComponent("locked.bin")
    try Data(repeating: 1, count: 300_000).write(to: locked)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
    await MainActor.run { scene.session.rescan() }
    #expect(await wait { scene.session.tree.withLock { scene.session.tree.lookup(locked.path) } != NONE && scene.session.canPark })
    let size = scene.size()
    await MainActor.run { scene.delete([scene.file, stuck]) }
    #expect(await wait { scene.ledger.freed > 0 && scene.ledger.removing.isEmpty })
    let state = await MainActor.run { (scene.ledger.held.total, scene.ledger.freed) }
    #expect(state == (0, size)) // the locked folder stayed, and isn't counted
    #expect(FileManager.default.fileExists(atPath: locked.path))
    await scene.cleanUp()
}

/// The Trash is measured on disk, and what emptying it gives back is split
/// against the snapshots like a delete.
@Test func trashIsMeasuredAndSplit() async throws {
    let scene = try await Scene([listing([Date()])])
    let reading = await MainActor.run { () -> Task<Session.TrashReading, Never> in
        scene.session.trashPathOverride = scene.root.appendingPathComponent("sub").path
        return Task { await scene.session.measureTrash() }
    }
    guard case .measured(let split) = await reading.value else {
        Issue.record("trash not measured")
        await scene.cleanUp()
        return
    }
    let size = scene.size()
    #expect(split.measured == size && split.known && split.heldBytes == size && split.freesNow == 0)
    await scene.cleanUp()
}

/// Against real Time Machine (opt in: SILT_REAL_SNAPSHOTS=1; it takes and
/// deletes a local snapshot). A file a fresh snapshot holds is held after a
/// delete, then counted as freed once that snapshot is deleted.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SILT_REAL_SNAPSHOTS"] == "1"))
func realSnapshotHoldsADeletedFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-real-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("held.bin")
    try Data(repeating: 5, count: 50_000_000).write(to: file)
    defer { try? FileManager.default.removeItem(at: root) }
    func tmutil(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
    let made = try tmutil(["localsnapshot", "/"])
    let stamp = try #require(made.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines))
    defer { _ = try? tmutil(["deletelocalsnapshots", stamp]) }
    let size = Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    let (ledger, s) = await MainActor.run {
        let l = SpaceLedger(volume: "test-\(UUID().uuidString)", mount: root.path, persists: false)
        return (l, Session(url: root, guardPrivateFolders: true, fresh: true, ledger: l))
    }
    #expect(await wait { s.phase == .live && s.canPark })
    await MainActor.run {
        let ref = s.tree.withLock { s.ref(forEntry: s.tree.lookup(file.path)) }
        s.deleteImmediately([ref], window: nil, confirmed: true)
    }
    #expect(await wait { ledger.held.total > 0 && ledger.removing.isEmpty })
    #expect(await MainActor.run { ledger.held.total } == size)
    _ = try tmutil(["deletelocalsnapshots", stamp])
    _ = await ledger.refresh()
    let state = await MainActor.run { (ledger.held.total, ledger.freed) }
    #expect(state.0 == 0)
    #expect(state.1 == size)
    await MainActor.run { s.close() }
    Snapshots.discard(for: root)
}

/// Progress through deletes: how far into the current item, as a fraction
/// of everything there was to delete.
@Test @MainActor func deleteProgressAddsUp() {
    let ledger = SpaceLedger(volume: "test-\(UUID().uuidString)", mount: "/", persists: false)
    ledger.beginRemoving(bytes: 1_000, items: 2, deleting: true)
    #expect(ledger.removing.fractionDeleted == 0)
    ledger.progress(250)
    #expect(ledger.removing.deletingLeft == 750 && ledger.removing.fractionDeleted == 0.25)
    ledger.endRemoving(bytes: 500, items: 1, deleting: true) // first item done
    #expect(ledger.removing.deletingLeft == 500 && ledger.removing.fractionDeleted == 0.5)
    ledger.endRemoving(bytes: 500, items: 1, deleting: true)
    #expect(ledger.removing.isEmpty && ledger.removing.fractionDeleted == nil)
}

/// The bar's parts always add up to the disk, whatever overlaps.
@Test func spaceBarPartsAddUp() {
    let cap = Capacity(total: 1_000, available: 300, free: 100)
    let p = SpaceBar.Parts(capacity: cap, trash: 50, held: 80, marked: 40)
    #expect(p.files + p.trash + p.held + p.purgeable + p.free == 1_000)
    #expect(p.purgeable == 200 && p.free == 100 && p.trash == 50 && p.held == 80 && p.files == 570)
    // Held space that macOS already counts as purgeable can't push files below zero.
    let squeezed = SpaceBar.Parts(capacity: cap, trash: 600, held: 600)
    #expect(squeezed.files >= 0 && squeezed.files + squeezed.trash + squeezed.held + squeezed.purgeable + squeezed.free == 1_000)
}

/// What emptying the Trash and the snapshots letting go would bring free
/// space to, in bounds.
@Test func projectionsAreBounds() {
    var trash = SpaceSplit(freesNow: 2_000_000_000)
    trash.addHold(["s"], 1_000_000_000)
    trash.measured = 3_000_000_000
    let both = SpacePopover.projection(free: 10_000_000_000, trash: trash, held: 500_000_000)
    #expect(both == "Emptying the Trash would bring free space to at least 12.0 GB, and up to 13.5 GB once local snapshots let go.")
    #expect(SpacePopover.projection(free: 10_000_000_000, trash: nil, held: 500_000_000)
        == "Once local snapshots let go, free space would reach up to 10.5 GB.")
    #expect(SpacePopover.projection(free: 10_000_000_000, trash: nil, held: 1_000) == nil) // too small to mention
    var unknown = trash
    unknown.known = false
    #expect(SpacePopover.projection(free: 10_000_000_000, trash: unknown, held: 0) == nil) // no promise
}
