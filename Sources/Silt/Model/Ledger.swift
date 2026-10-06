import Foundation
import SiltCore

/// A volume's local snapshots, oldest first, with when each was taken (to
/// the second, from the file system: names are in local time, which a
/// clock change or travel makes ambiguous).
struct SnapshotListing: Equatable, Sendable {
    struct Snapshot: Equatable, Sendable {
        let name: String
        let created: Date
        /// Time Machine's own, which macOS purges as it needs room.
        var isTimeMachine: Bool { name.hasPrefix("com.apple.TimeMachine.") }
    }

    let snapshots: [Snapshot]
    var names: Set<String> { Set(snapshots.map(\.name)) }

    /// Whether what they hold can be estimated: every snapshot is Time
    /// Machine's. Another app's (a backup tool's, say) keeps files for
    /// reasons and as long as Silt can't see.
    var estimable: Bool { snapshots.allSatisfy { $0.isTimeMachine && $0.created.timeIntervalSince1970 > 0 } }

    init(snapshots: [Snapshot]) {
        self.snapshots = snapshots.sorted { $0.created < $1.created }
    }

    /// Lists the snapshots of the volume holding `path`, or nil if that
    /// can't be done (a network volume, or the listing failed). Nil never
    /// means "no snapshots".
    static func read(for path: String) -> SnapshotListing? {
        guard let (mount, apfs) = SpaceVolume.snapshotMount(for: path) else { return nil }
        guard apfs else { return SnapshotListing(snapshots: []) } // only APFS has them
        var buf = [silt_volume_snapshot](repeating: silt_volume_snapshot(), count: 512)
        let n = silt_volume_snapshots(mount, &buf, Int32(buf.count))
        guard n >= 0, n < buf.count else { return nil } // failed, or more than fit: can't tell what's gone
        return SnapshotListing(snapshots: buf.prefix(Int(n)).map { s in
            var s = s
            let name = withUnsafePointer(to: &s.name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            return Snapshot(name: name, created: Date(timeIntervalSince1970: TimeInterval(s.created)))
        })
    }
}

/// Which volume's snapshots matter for a path, and whether Silt can tell.
enum SpaceVolume {
    /// The mount point to list snapshots of, or nil for a volume that isn't
    /// local (a server keeps its own copies Silt can't see). On the startup
    /// disk, files live on the Data volume.
    static func snapshotMount(for path: String) -> (mount: String, apfs: Bool)? {
        var fs = statfs()
        guard statfs(path, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return nil }
        let mount = withUnsafePointer(to: &fs.f_mntonname) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        let type = withUnsafePointer(to: &fs.f_fstypename) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        return (mount == "/" ? "/System/Volumes/Data" : mount, type == "apfs")
    }
}

/// What removing something would give back, against a volume's snapshots.
/// "Frees now" is a lower bound: it counts only files no snapshot can hold
/// (born after the newest one) that share no blocks with other copies.
struct SpaceSplit: Equatable, Sendable {
    struct Hold: Equatable, Sendable, Codable {
        /// Every snapshot that holds these bytes; they come back once all
        /// of them are gone.
        var holders: [String]
        var bytes: Int64
    }

    var freesNow: Int64 = 0
    var held: [Hold] = []
    /// Clones and hard links: other copies keep their blocks, so removing
    /// one gives back little unless every copy goes.
    var shared: Int64 = 0
    /// Open in a running app: its space comes back once the app lets go.
    var inUse: Int64 = 0
    /// False when the snapshots couldn't be listed, or include ones Silt
    /// can't reason about: then nothing is promised.
    var known = true
    /// Some of it couldn't be counted (unreadable folders, or the tree moved
    /// while it was walked): the figures are less than the whole.
    var partial = false

    /// Everything measured, however it splits (also when it can't be).
    var measured: Int64 = 0

    var heldBytes: Int64 { held.reduce(0) { $0 + $1.bytes } }
    var total: Int64 { freesNow + heldBytes + shared + inUse }

    static let unknown = SpaceSplit(known: false)

    mutating func add(_ other: SpaceSplit) {
        freesNow += other.freesNow
        shared += other.shared
        inUse += other.inUse
        measured += other.measured
        known = known && other.known
        partial = partial || other.partial
        for h in other.held { addHold(h.holders, h.bytes) }
    }

    mutating func addHold(_ holders: [String], _ bytes: Int64) {
        guard bytes > 0 else { return }
        if let i = held.firstIndex(where: { $0.holders == holders }) { held[i].bytes += bytes }
        else { held.append(Hold(holders: holders, bytes: bytes)) }
    }

    /// What's left after taking away `other` (what wasn't removed after
    /// all), never below zero.
    func minus(_ other: SpaceSplit) -> SpaceSplit {
        var s = self
        s.freesNow = max(0, freesNow - other.freesNow)
        s.shared = max(0, shared - other.shared)
        s.inUse = max(0, inUse - other.inUse)
        s.measured = max(0, measured - other.measured)
        s.known = known && other.known
        s.partial = partial || other.partial
        s.held = held.compactMap { h in
            let left = h.bytes - (other.held.first { $0.holders == h.holders }?.bytes ?? 0)
            return left > 0 ? Hold(holders: h.holders, bytes: left) : nil
        }
        return s
    }

    static func sum(_ splits: [SpaceSplit]) -> SpaceSplit {
        var s = SpaceSplit()
        for x in splits { s.add(x) }
        return s
    }

    /// A snapshot taken while the removal ran caught whatever wasn't gone
    /// yet: nothing is free for sure, it's all held by that snapshot too.
    func caught(by newer: [String]) -> SpaceSplit {
        guard !newer.isEmpty else { return self }
        var s = self
        s.held = held.map { Hold(holders: ($0.holders + newer).sorted(), bytes: $0.bytes) }
        s.freesNow = 0
        s.addHold(newer.sorted(), freesNow)
        return s
    }

    // MARK: Measuring

    /// A snapshot is taken over a few seconds before its creation time is
    /// set: a minute of slack, erring toward held.
    static let margin: TimeInterval = 60

    /// Measures `path` on disk, now, against `listing`. With a `deadline`
    /// (seconds) it stops early and says so (`partial`). Blocks: call it off
    /// the main thread.
    /// Measures `paths` in turn, all within `seconds`; past that, the rest
    /// isn't measured and the sum says so (`partial`).
    static func measureAll(_ paths: [String], listing: SnapshotListing?, within seconds: TimeInterval) -> SpaceSplit {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        let open = paths.first.map { openFiles(on: $0) } ?? []
        var sum = SpaceSplit()
        if listing?.estimable != true { sum.known = false }
        for path in paths {
            let left = end - ProcessInfo.processInfo.systemUptime
            guard left > 0 else {
                sum.partial = true
                break
            }
            if let split = measure(path, listing: listing, open: open, deadline: left) { sum.add(split) }
            else { sum.partial = true }
        }
        return sum
    }

    /// The files running apps hold open on the volume of `path` (their
    /// inodes): deleting one frees nothing until it's closed.
    static func openFiles(on path: String) -> [UInt64] {
        var st = stat()
        guard stat(path, &st) == 0 else { return [] }
        var inodes = [UInt64](repeating: 0, count: 200_000)
        let n = silt_open_files(st.st_dev, &inodes, UInt32(inodes.count))
        return Array(inodes.prefix(Int(n)))
    }

    /// Nil if `path` can't be read at all. `open`: from `openFiles(on:)`.
    static func measure(_ path: String, listing: SnapshotListing?, open: [UInt64] = [],
                        deadline: TimeInterval = 0) -> SpaceSplit? {
        let estimable = listing?.estimable == true
        let snaps = estimable ? listing!.snapshots : []
        let cutoffs = snaps.map { Int64($0.created.timeIntervalSince1970 + margin) }
        var buckets = [Int64](repeating: 0, count: cutoffs.count + 1)
        var out = silt_measure()
        guard silt_measure_path(path, cutoffs, UInt32(cutoffs.count), &buckets, open, UInt32(open.count),
                                deadline, &out) else { return nil }
        var split = SpaceSplit(shared: out.shared, known: estimable, partial: !out.complete || out.unreadable > 0)
        split.inUse = out.in_use
        split.measured = out.total
        guard estimable else { return split } // its size, but no promise
        split.freesNow = buckets[cutoffs.count]
        for j in 0..<snaps.count { split.addHold(snaps[j...].map(\.name), buckets[j]) }
        return split
    }
}

/// Space Silt removed that local snapshots still hold, by the snapshots
/// holding it: it comes back once none of them is left, in whatever order
/// they go. Kept per volume across launches (snapshots outlive them).
struct HeldSpace: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var holders: [String]
        var bytes: Int64
        /// When the removal ran, if the snapshots couldn't be listed right
        /// after it: any snapshot taken meanwhile holds this too.
        var during: DateInterval?
        /// The listing ticket when it was recorded: only a listing started
        /// later can release it. Zero once loaded from a previous launch.
        var ticket: Int = 0

        private enum CodingKeys: String, CodingKey { case holders, bytes, during }
    }

    private(set) var entries: [Entry] = []

    var total: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    var isEmpty: Bool { entries.isEmpty }
    /// Every snapshot name anything is held by.
    var holders: Set<String> { Set(entries.flatMap(\.holders)) }

    mutating func record(_ holds: [SpaceSplit.Hold], ticket: Int, during: DateInterval? = nil) {
        for h in holds where h.bytes > 0 {
            entries.append(Entry(holders: h.holders.sorted(), bytes: h.bytes, during: during, ticket: ticket))
        }
    }

    /// Releases what no listed snapshot holds any more, judged only by a
    /// listing (`ticket`) started after it was recorded, and returns the
    /// bytes.
    mutating func release(by listing: SnapshotListing, ticket: Int) -> Int64 {
        let present = listing.names
        var released: Int64 = 0
        entries.removeAll { e in
            guard e.ticket < ticket, e.holders.allSatisfy({ !present.contains($0) }) else { return false }
            if let during = e.during,
               listing.snapshots.contains(where: { during.contains($0.created) || abs($0.created.timeIntervalSince(during.end)) < SpaceSplit.margin }) {
                return false
            }
            released += e.bytes
            return true
        }
        return released
    }

    // MARK: Storage

    private static func key(_ volume: String) -> String { "heldSpace:\(volume)" }

    static func load(volume: String) -> HeldSpace {
        guard let data = UserDefaults.standard.data(forKey: key(volume)),
              let held = try? JSONDecoder().decode(HeldSpace.self, from: data) else { return HeldSpace() }
        return held // tickets decode as 0: any listing now is later
    }

    func save(volume: String) {
        if isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key(volume))
        } else if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(volume))
        }
    }
}

/// One volume's space accounting, shared by every scan on it: what Silt is
/// removing, what it gave back, and what local snapshots still hold of what
/// it removed.
@MainActor @Observable
final class SpaceLedger {
    struct Removing: Equatable {
        var bytes: Int64 = 0
        var items = 0
        /// Of `items`, the ones being deleted (the rest go to the Trash,
        /// which gives nothing back until it's emptied).
        var deleting = 0
        var deletingBytes: Int64 = 0
        var isEmpty: Bool { items == 0 }
    }

    let volume: String
    /// The volume's mount point, for listing its snapshots (a folder of a
    /// scan could be renamed or deleted; the volume stays).
    let mount: String
    private(set) var listing: SnapshotListing?
    /// The last listing attempt failed (or the volume isn't local).
    private(set) var listingFailed = false
    private(set) var held: HeldSpace
    /// What Silt's removals gave back while it's been open: the part no
    /// snapshot held, and held parts (from this launch or earlier ones) as
    /// their snapshots went.
    private(set) var freed: Int64 = 0
    private(set) var removing = Removing()

    @ObservationIgnored var lister: @Sendable (String) -> SnapshotListing?
    @ObservationIgnored private var persists: Bool
    @ObservationIgnored private var started = 0
    @ObservationIgnored private var applied = 0

    private static var all: [String: SpaceLedger] = [:]
    /// Under test: ledgers see no snapshots and keep nothing, unless a test
    /// gives a scan its own.
    static var testing = ["swiftpm-testing-helper", "xctest"].contains(ProcessInfo.processInfo.processName) {
        didSet {
            guard testing else { return }
            for l in all.values {
                l.lister = { _ in SnapshotListing(snapshots: []) }
                l.persists = false
            }
        }
    }

    /// The ledger of the volume holding `url`.
    static func of(_ url: URL) -> SpaceLedger {
        let mount = SpaceVolume.snapshotMount(for: url.path)?.mount ?? url.path
        let volume = Session.volumeUUID(url) ?? mount
        if let l = all[volume] { return l }
        let l = SpaceLedger(volume: volume, mount: mount, persists: !testing)
        if testing { l.lister = { _ in SnapshotListing(snapshots: []) } }
        all[volume] = l
        return l
    }

    init(volume: String, mount: String, persists: Bool = true) {
        self.volume = volume
        self.mount = mount
        self.persists = persists
        lister = { SnapshotListing.read(for: $0) }
        held = persists ? HeldSpace.load(volume: volume) : HeldSpace()
    }

    private func save() {
        if persists { held.save(volume: volume) }
    }

    /// Lists the snapshots again (off the main thread) and releases what
    /// they no longer hold. Returns the listing, or nil if it failed; a
    /// result overtaken by a newer listing is not applied.
    @discardableResult
    func refresh() async -> SnapshotListing? {
        started += 1
        let ticket = started, mount = mount, lister = lister
        // A volume that hangs mustn't hold up a delete: after five seconds
        // the snapshots count as unlisted.
        let result: SnapshotListing? = await withTaskGroup(of: SnapshotListing??.self) { group in
            group.addTask { .some(await Task.detached(priority: .utility) { lister(mount) }.value) }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .none
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? nil
        }
        guard ticket > applied else { return result }
        applied = ticket
        listingFailed = result == nil
        guard let result else { return nil }
        if result != listing { listing = result }
        let back = held.release(by: result, ticket: ticket)
        if back > 0 {
            freed += back
            save()
        }
        return result
    }

    func beginRemoving(bytes: Int64, items: Int, deleting: Bool) {
        removing.bytes += bytes
        removing.items += items
        if deleting {
            removing.deleting += items
            removing.deletingBytes += bytes
        }
    }

    func endRemoving(bytes: Int64, items: Int, deleting: Bool) {
        removing.bytes -= bytes
        removing.items -= items
        if deleting {
            removing.deleting -= items
            removing.deletingBytes -= bytes
        }
    }

    /// Records what was removed, measured as it went against `before`.
    /// Snapshots that appeared meanwhile hold whatever was left when they
    /// were taken, so for sure none of it is free; if the snapshots can't be
    /// listed afterwards, any taken during the removal (`during`) will count
    /// once they can be. Returns the split as recorded.
    @discardableResult
    func removed(_ split: SpaceSplit, listedBefore before: SnapshotListing?, during: DateInterval) async -> SpaceSplit {
        let after = await refresh()
        guard split.known, let before else { return split }
        let ticket = started
        if let after {
            let newer = after.snapshots.map(\.name).filter { !before.names.contains($0) }
            let final = split.caught(by: newer)
            freed += final.freesNow
            held.record(final.held, ticket: ticket)
            save()
            return final
        }
        // Not known yet whether one was taken meanwhile: nothing is free for
        // sure until a listing says.
        var pending = split.held
        if split.freesNow > 0 { pending.append(.init(holders: [], bytes: split.freesNow)) }
        held.record(pending, ticket: ticket, during: during)
        save()
        var shown = split
        shown.held = pending
        shown.freesNow = 0
        return shown
    }
}

extension SpaceSplit {
    /// What removing this gives back, for a confirmation (`done == false`)
    /// or a result. Bounds, not promises: "at least", "up to". When not all
    /// of it could be measured, what's held is only a floor.
    func summary(done: Bool) -> String {
        guard known else {
            return done ? "How much came back depends on local snapshots Silt couldn’t check."
                        : "How much this frees depends on local snapshots Silt couldn’t check."
        }
        var parts: [String] = []
        if freesNow > 0 {
            parts.append(done ? "At least \(Fmt.bytes(freesNow)) came back." : "At least \(Fmt.bytes(freesNow)) comes back right away.")
        }
        if heldBytes > 0 {
            parts.append("\(partial ? "At least" : "Up to") \(Fmt.bytes(heldBytes)) \(done ? "is" : "stays")"
                + " held by local Time Machine snapshots until they’re gone.")
        }
        if inUse > 0 {
            parts.append("\(Fmt.bytes(inUse)) is open in a running app, so it comes back only once that app lets go of it.")
        }
        if shared > 0 {
            parts.append("\(Fmt.bytes(shared)) is shared with other copies, so it comes back only if every copy goes.")
        }
        if partial { parts.append("Silt couldn’t measure all of it, so more may be held.") }
        return parts.joined(separator: " ")
    }
}
