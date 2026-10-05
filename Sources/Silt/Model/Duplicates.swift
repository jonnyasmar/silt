import CryptoKit
import Foundation
import Observation
import SiltCore

/// The exact object a path named when it was examined.
struct FileStamp: Hashable, Sendable {
    let dev: Int32
    let ino: UInt64
    let size: Int64
    /// Bytes actually allocated (sparse files use far less than `size`).
    let alloc: Int64
    let mtime: timespec
    let ctime: timespec

    init?(path: String) {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        self.init(st)
    }

    init(_ st: stat) {
        dev = st.st_dev
        ino = st.st_ino
        size = Int64(st.st_size)
        alloc = Int64(st.st_blocks) * 512
        mtime = st.st_mtimespec
        ctime = st.st_ctimespec
    }

    static func == (a: FileStamp, b: FileStamp) -> Bool {
        a.dev == b.dev && a.ino == b.ino && a.size == b.size && a.mtime.tv_sec == b.mtime.tv_sec
            && a.mtime.tv_nsec == b.mtime.tv_nsec && a.ctime.tv_sec == b.ctime.tv_sec && a.ctime.tv_nsec == b.ctime.tv_nsec
    }

    func hash(into h: inout Hasher) {
        h.combine(dev)
        h.combine(ino)
        h.combine(size)
        h.combine(mtime.tv_sec)
        h.combine(mtime.tv_nsec)
        h.combine(ctime.tv_sec)
        h.combine(ctime.tv_nsec)
    }
}

/// Files that share blocks on disk (APFS clones of each other, or one file
/// with several hard links) count as one stored copy.
struct StorageFamily: Hashable, Sendable {
    let dev: Int32
    let id: UInt64
    let isClone: Bool
}

/// Files with identical contents in more than one place.
struct DuplicateSet: Identifiable, Equatable, Sendable {
    struct Copy: Identifiable, Equatable, Sendable {
        let entry: UInt32
        let path: String
        let stamp: FileStamp
        let family: StorageFamily
        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var folder: String { (path as NSString).deletingLastPathComponent }
        var modified: Date {
            Date(timeIntervalSince1970: TimeInterval(stamp.mtime.tv_sec) + TimeInterval(stamp.mtime.tv_nsec) / 1e9)
        }
    }

    /// The device and inode of one of the copies, fixed when the set is
    /// found: every file is in at most one set, and unlike a path or an
    /// entry index it doesn't change when a folder is relisted.
    let id: String
    let size: Int64 // bytes in one copy
    let copies: [Copy]
    /// How many separately stored copies there are (clones and hard links
    /// of each other count once).
    let families: Int
    /// Disk space the extra copies take: one allocation per storage family,
    /// minus the one that stays.
    let extraBytes: Int64

    init(size: Int64, copies: [Copy], id: String? = nil) {
        self.size = size
        self.copies = copies
        var byFamily: [StorageFamily: Int64] = [:]
        for c in copies where byFamily[c.family] == nil { byFamily[c.family] = c.stamp.alloc }
        families = byFamily.count
        let all = byFamily.values
        extraBytes = all.reduce(0, +) - (all.max() ?? 0)
        self.id = id ?? copies.map { ($0.stamp.dev, $0.stamp.ino) }.min { $0 < $1 }.map { "\($0.0):\($0.1)" } ?? ""
    }
}

/// Finds duplicates for a session. Cheap tests first (size, hard links,
/// clone families, sampled hashes), so only real candidates are read in full.
/// Results stream in as they're confirmed, largest first.
@MainActor
@Observable
final class DuplicateFinder {
    enum Phase: Equatable {
        case idle
        case collecting
        case comparing(files: Int, readBytes: Int64, totalBytes: Int64)
        case done
    }

    enum KeepRule: String, CaseIterable, Identifiable {
        case oldest, newest, shortestPath
        var id: String { rawValue }
        var title: String {
            switch self {
            case .oldest: "Keep the oldest copy"
            case .newest: "Keep the newest copy"
            case .shortestPath: "Keep the copy with the shortest path"
            }
        }
        var short: String {
            switch self {
            case .oldest: "oldest"
            case .newest: "newest"
            case .shortestPath: "shortest path"
            }
        }
    }

    private(set) var phase: Phase = .idle
    /// Largest extra space first.
    private(set) var sets: [DuplicateSet] = [] {
        didSet { extraBytes = sets.reduce(0) { $0 + $1.extraBytes } }
    }
    /// The candidate list hit its cap, so some files weren't compared.
    private(set) var truncated = false
    var minSize: Int64 = 1_000_000
    var includeManaged = false
    var keepRule: KeepRule = .oldest

    /// Everything the extra copies take, across all sets.
    private(set) var extraBytes: Int64 = 0
    var running: Bool {
        if case .comparing = phase { return true }
        return phase == .collecting
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var stop: CancelFlag?
    @ObservationIgnored private let cache = HashCache()
    /// Sets found but not yet shown: they're handed over in batches, so a
    /// search that finds thousands doesn't re-render the list for each one.
    @ObservationIgnored private let inbox = Inbox()
    nonisolated private static let candidateCap = 1_000_000
    /// How long found sets wait to be shown together.
    nonisolated private static let batchDelay: TimeInterval = 0.15

    /// Folders whose files are managed by a tool (duplicates there are normal,
    /// and deleting one breaks the tool's view of the world).
    nonisolated static let managedFolders = [
        "node_modules", ".git", ".build", "DerivedData", "Pods", ".venv", "venv", "site-packages", "__pycache__",
        ".next", ".turbo", ".cache", ".gradle", ".cargo", ".rustup", ".npm", ".pnpm-store", "Caches",
        "CoreSimulator", ".Trash", ".Trashes", "target", "vendor", ".terraform", ".yarn", "bower_components",
        "SourcePackages", "checkouts", "artifacts", "Carthage", "build", "dist", "out",
    ]

    /// Compiler output: identical copies across build folders are expected.
    nonisolated static let buildProducts: Set<String> = [
        "a", "o", "rlib", "rmeta", "dylib", "so", "d", "pcm", "pch", "swiftmodule", "swiftdoc", "dSYM", "wasm",
        "node", "pyc", "class", "jar", "bc",
    ]

    func run(session: Session) {
        cancel()
        sets = []
        truncated = false
        phase = .collecting
        run += 1
        let token = run
        let flag = CancelFlag()
        stop = flag
        let tree = session.tree
        let min = minSize, managed = includeManaged, cache = cache
        // Every callback carries this run's token, so a stopped run's
        // stragglers can't land in a newer one.
        let report: @Sendable (Int, Int64, Int64) -> Void = { [weak self] files, read, total in
            Task { @MainActor in
                guard let self, self.run == token, self.running else { return }
                self.phase = .comparing(files: files, readBytes: read, totalBytes: total)
            }
        }
        let inbox = inbox
        inbox.reset(token: token)
        let found: @Sendable (DuplicateSet) -> Void = { [weak self] set in
            // The first set of a batch schedules its delivery.
            guard inbox.add(set, token: token) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.batchDelay) {
                MainActor.assumeIsolated { self?.deliver(token: token) }
            }
        }
        let capped: @Sendable () async -> Void = { [weak self] in
            guard let finder = self else { return }
            await finder.markTruncated(token: token)
        }
        // The search is this task's own async work, so cancelling it reaches
        // the reads; the flag reaches the parallel stat phase. Hashing is
        // background work: it runs at utility priority.
        task = Task(priority: .utility) { [weak self] in
            await Self.find(tree: tree, minSize: min, includeManaged: managed, cache: cache, stop: flag,
                            progress: report, found: found, capped: capped)
            guard let self, self.run == token, !Task.isCancelled else { return }
            self.deliver(token: token) // whatever is still waiting
            self.phase = .done
        }
    }

    /// Shows the sets found since the last delivery.
    private func deliver(token: Int) {
        let batch = inbox.take(token: token)
        guard run == token else { return }
        receive(batch)
    }

    /// Adds found sets to what's shown, in order (see `merge`).
    func receive(_ batch: [DuplicateSet]) {
        guard !batch.isEmpty else { return }
        sets = Self.merge(sets, batch)
    }

    /// `sets` (largest extra space first) with `batch` merged in. Each new
    /// set goes after every set already there with at least as much extra
    /// space, and sets that tie keep the order they arrived in: the same
    /// order as inserting them one by one, without the quadratic cost.
    nonisolated static func merge(_ sets: [DuplicateSet], _ batch: [DuplicateSet]) -> [DuplicateSet] {
        guard !batch.isEmpty else { return sets }
        let incoming = batch.enumerated().sorted { a, b in
            a.element.extraBytes != b.element.extraBytes ? a.element.extraBytes > b.element.extraBytes : a.offset < b.offset
        }.map(\.element)
        var out: [DuplicateSet] = []
        out.reserveCapacity(sets.count + incoming.count)
        var i = 0, j = 0
        while i < sets.count, j < incoming.count {
            if incoming[j].extraBytes > sets[i].extraBytes {
                out.append(incoming[j])
                j += 1
            } else {
                out.append(sets[i])
                i += 1
            }
        }
        out += sets[i...]
        out += incoming[j...]
        return out
    }

    private func markTruncated(token: Int) {
        if run == token { truncated = true }
    }

    func cancel() {
        stop?.cancel()
        task?.cancel()
        task = nil
        run += 1
        inbox.reset(token: run) // a stopped run's stragglers are dropped
        phase = sets.isEmpty ? .idle : .done
    }

    /// Forgets remembered hashes (when the location is put away).
    func dropCache() {
        cache.removeAll()
    }

    /// Re-points copies at their current entries (entries move when a folder
    /// is relisted) and drops copies that are gone, and sets that are no
    /// longer duplicates. `sets` is only reassigned when that changed
    /// something; returns whether it did.
    @discardableResult
    func prune(tree: Tree) -> Bool {
        guard !sets.isEmpty, !running else { return false }
        var changed = false
        let next: [DuplicateSet] = tree.withLock {
            sets.compactMap { s in
                var copies: [DuplicateSet.Copy] = []
                copies.reserveCapacity(s.copies.count)
                var moved = false
                for c in s.copies {
                    let i = tree.isLive(c.entry) ? c.entry : tree.lookup(c.path)
                    guard i != NONE, tree.isLive(i) else { continue }
                    if i == c.entry {
                        copies.append(c)
                    } else {
                        copies.append(DuplicateSet.Copy(entry: i, path: c.path, stamp: c.stamp, family: c.family))
                        moved = true
                    }
                }
                guard copies.count != s.copies.count || moved else { return s }
                changed = true
                let set = DuplicateSet(size: s.size, copies: copies, id: s.id)
                return set.copies.count > 1 && set.families > 1 ? set : nil
            }
        }
        if changed { sets = next }
        return changed
    }

    /// The copy `keepRule` would keep in `set`.
    func keeper(of set: DuplicateSet) -> DuplicateSet.Copy? { Self.keeper(of: set, rule: keepRule) }

    nonisolated static func keeper(of set: DuplicateSet, rule: KeepRule) -> DuplicateSet.Copy? {
        switch rule {
        case .oldest: set.copies.min { $0.modified < $1.modified }
        case .newest: set.copies.max { $0.modified < $1.modified }
        case .shortestPath: set.copies.min { ($0.path.count, $0.path) < ($1.path.count, $1.path) }
        }
    }

    /// The copies worth removing from `sets`: everything but the kept copy
    /// and its clones, and only copies still exactly the file that was
    /// compared (the kept copy too). Returns the paths, and how many were
    /// skipped because something changed since.
    nonisolated static func extras(of sets: [DuplicateSet], rule: KeepRule) -> (paths: [String], changed: Int) {
        let found = extraCopies(of: sets, rule: rule)
        return (found.copies.map(\.path), found.changed)
    }

    /// `extras`, as the copies themselves. Each was just checked on disk
    /// against its stamp, so `Session.mark(copies:of:reason:)` can take the
    /// identity from it instead of looking again. Reads the disk: call it
    /// off the main thread.
    nonisolated static func extraCopies(of sets: [DuplicateSet], rule: KeepRule) -> (copies: [DuplicateSet.Copy], changed: Int) {
        var copies: [DuplicateSet.Copy] = []
        var changed = 0
        for s in sets {
            guard let keep = keeper(of: s, rule: rule) else { continue }
            guard FileStamp(path: keep.path) == keep.stamp else {
                changed += s.copies.count - 1
                continue
            }
            for c in s.copies where c.path != keep.path && c.family != keep.family {
                if FileStamp(path: c.path) == c.stamp { copies.append(c) } else { changed += 1 }
            }
        }
        return (copies, changed)
    }

    // MARK: Pipeline (off the main thread)

    private struct Candidate: Sendable {
        let entry: UInt32
        let path: String
        let stamp: FileStamp
        var family: StorageFamily
    }

    nonisolated private static func find(
        tree: Tree, minSize: Int64, includeManaged: Bool, cache: HashCache, stop: CancelFlag,
        progress: @escaping @Sendable (Int, Int64, Int64) -> Void,
        found: @escaping @Sendable (DuplicateSet) -> Void,
        capped: @escaping @Sendable () async -> Void
    ) async {
        // 1. Everything big enough, straight from the scan.
        let entries = tree.filesAtLeast(minSize, skip: includeManaged ? [".Trash", ".Trashes"] : managedFolders,
                                        skipPackages: !includeManaged, limit: candidateCap)
        if entries.count >= candidateCap { await capped() }
        // Paths in short batches, so scanner commits aren't starved.
        var paths: [(UInt32, String)] = []
        paths.reserveCapacity(entries.count)
        for chunk in stride(from: 0, to: entries.count, by: 4096) {
            let slice = entries[chunk..<min(chunk + 4096, entries.count)]
            paths += tree.withLock { slice.filter { tree.isLive($0) }.map { ($0, tree.path(of: $0)) } }
        }
        if !includeManaged {
            paths = paths.filter { !buildProducts.contains(($0.1 as NSString).pathExtension.lowercased()) }
        }
        // Copies inside apps, installed tools and macOS are theirs to keep:
        // only your own files are offered.
        let home = NSHomeDirectory()
        paths = paths.filter { Place.of($0.1, home: home).isYours }
        if Task.isCancelled { return }

        // 2. Real sizes and identities: stored sizes are shares of allocations,
        // so group on the byte count lstat reports.
        var stats = [Candidate?](repeating: nil, count: paths.count)
        stats.withUnsafeMutableBufferPointer { out in
            nonisolated(unsafe) let buf = out // each iteration writes only its own slot
            DispatchQueue.concurrentPerform(iterations: paths.count) { k in
                guard !stop.cancelled, let st = FileStamp(path: paths[k].1), st.size >= minSize else { return }
                buf[k] = Candidate(entry: paths[k].0, path: paths[k].1, stamp: st,
                                   family: StorageFamily(dev: st.dev, id: st.ino, isClone: false))
            }
        }
        var bySize: [Int64: [Candidate]] = [:]
        var seen = Set<StorageFamily>()
        for c in stats.compactMap({ $0 }) {
            // Hard links are one file, not copies.
            guard seen.insert(c.family).inserted else { continue }
            bySize[c.stamp.size, default: []].append(c)
        }
        stats = []
        var groups = bySize.values.filter { $0.count > 1 }
        bySize = [:]
        if Task.isCancelled || stop.cancelled { return }

        // 3. Clone families: pure clones of each other share every block, so
        // a group that's all one family has nothing to reclaim.
        groups = groups.compactMap { g in
            let withFamily = g.map { c -> Candidate in
                var c = c
                if let clone = cloneID(c.path) { c.family = StorageFamily(dev: c.stamp.dev, id: clone, isClone: true) }
                return c
            }
            return Set(withFamily.map(\.family)).count > 1 ? withFamily : nil
        }

        let total = groups.reduce(Int64(0)) { $0 + $1.reduce(0) { $0 + $1.stamp.size } }
        let meter = ReadMeter(total: total, progress: progress)
        meter.report(files: groups.reduce(0) { $0 + $1.count })

        // 4. Sampled hash (start, middle, end), then 5. full hash of what's
        // left. Biggest potential savings first, so they show up first.
        for g in groups.sorted(by: { $0[0].stamp.size * Int64($0.count) > $1[0].stamp.size * Int64($1.count) }) {
            if Task.isCancelled { return }
            let sampled = await split(g) { cache.hash($0.path, stamp: $0.stamp, full: false, meter: meter) }
            for s in sampled {
                let full = await split(s) { cache.hash($0.path, stamp: $0.stamp, full: true, meter: meter) }
                for set in full where Set(set.map(\.family)).count > 1 {
                    found(DuplicateSet(
                        size: set[0].stamp.size,
                        copies: set.map { DuplicateSet.Copy(entry: $0.entry, path: $0.path, stamp: $0.stamp, family: $0.family) }))
                }
            }
        }
    }

    /// Groups `items` by `key`, hashing a few files at a time; singletons and
    /// unreadable files drop out.
    nonisolated private static func split(_ items: [Candidate],
                                          by key: @escaping @Sendable (Candidate) -> HashCache.Digest?) async -> [[Candidate]] {
        var results = [HashCache.Digest?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, HashCache.Digest?).self) { group in
            var next = 0
            func add() {
                guard next < items.count, !Task.isCancelled else { return }
                let i = next
                next += 1
                let item = items[i]
                group.addTask { (i, key(item)) }
            }
            for _ in 0..<min(4, items.count) { add() }
            for await (i, k) in group {
                results[i] = k
                add()
            }
        }
        var buckets: [HashCache.Digest: [Candidate]] = [:]
        for (c, k) in zip(items, results) { if let k { buckets[k, default: []].append(c) } }
        return buckets.values.filter { $0.count > 1 }
    }

    nonisolated private static func cloneID(_ path: String) -> UInt64? {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        al.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)
        var buf = [UInt8](repeating: 0, count: 64)
        let r = getattrlist(path, &al, &buf, buf.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        guard r == 0 else { return nil }
        return buf.withUnsafeBytes { raw -> UInt64? in
            var ret = attribute_set_t()
            memcpy(&ret, raw.baseAddress! + 4, MemoryLayout<attribute_set_t>.size)
            guard ret.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0,
                  ret.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 else { return nil }
            let base = 4 + MemoryLayout<attribute_set_t>.size
            var clone: UInt64 = 0, flags: UInt64 = 0
            memcpy(&clone, raw.baseAddress! + base, 8)
            memcpy(&flags, raw.baseAddress! + base + 8, 8)
            // Only pure clones share every block; anything else is its own data.
            return flags & UInt64(EF_SHARES_ALL_BLOCKS) != 0 ? clone : nil
        }
    }
}

/// Counts bytes read and reports progress at a sane rate.
final class ReadMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var read: Int64 = 0
    private var files = 0
    private var last: TimeInterval = 0
    let total: Int64
    let progress: @Sendable (Int, Int64, Int64) -> Void

    init(total: Int64, progress: @escaping @Sendable (Int, Int64, Int64) -> Void) {
        self.total = total
        self.progress = progress
    }

    func add(_ n: Int64) {
        lock.lock()
        read += n
        let now = ProcessInfo.processInfo.systemUptime
        let fire = now - last > 0.1
        if fire { last = now }
        let (f, r) = (files, read)
        lock.unlock()
        if fire { progress(f, r, total) }
    }

    func report(files n: Int) {
        lock.lock()
        files = n
        lock.unlock()
        progress(n, 0, total)
    }
}

/// Content hashes keyed by exact file identity (device, inode, size and
/// nanosecond times: all of `FileStamp`), so a second run only reads files
/// that changed. Bounded: past `capacity` entries the oldest go first.
final class HashCache: @unchecked Sendable {
    /// A SHA-256 digest, as four words.
    struct Digest: Hashable, Sendable {
        let a: UInt64, b: UInt64, c: UInt64, d: UInt64
    }

    private struct Key: Hashable {
        let stamp: FileStamp
        let full: Bool
    }

    private let lock = NSLock()
    private var table: [Key: Digest] = [:]
    /// Keys in the order they were added; `head` is the oldest still counted.
    private var order: [Key] = []
    private var head = 0
    let capacity: Int

    /// About 200 bytes an entry, so the default stays around 10 MB.
    init(capacity: Int = 50_000) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return table.count
    }

    func hash(_ path: String, stamp: FileStamp, full wantFull: Bool, meter: ReadMeter) -> Digest? {
        if let hit = cached(stamp, full: wantFull) { return hit }
        guard let h = Self.read(path, stamp: stamp, full: wantFull, meter: meter) else { return nil }
        store(h, for: stamp, full: wantFull)
        return h
    }

    func cached(_ stamp: FileStamp, full: Bool) -> Digest? {
        lock.lock()
        defer { lock.unlock() }
        return table[Key(stamp: stamp, full: full)]
    }

    func store(_ digest: Digest, for stamp: FileStamp, full: Bool) {
        let key = Key(stamp: stamp, full: full)
        lock.lock()
        defer { lock.unlock() }
        if table.updateValue(digest, forKey: key) == nil { order.append(key) }
        while table.count > capacity, head < order.count {
            table.removeValue(forKey: order[head])
            head += 1
        }
        if head > 4096, head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        table = [:]
        order = []
        head = 0
    }

    /// Hashes the file, but only if it's still the object `stamp` describes
    /// before and after reading (a file edited mid-read gives no answer).
    private static func read(_ path: String, stamp: FileStamp, full: Bool, meter: ReadMeter) -> Digest? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1) // don't flush the user's page cache for this
        var st = stat()
        guard fstat(fd, &st) == 0, FileStamp(st) == stamp else { return nil }
        var hasher = SHA256()
        let chunk = full ? 1 << 20 : 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        let size = stamp.size
        let ranges: [(Int64, Int)]
        if full {
            ranges = stride(from: Int64(0), to: size, by: chunk).map { ($0, Int(min(Int64(chunk), size - $0))) }
        } else if size <= Int64(chunk * 3) {
            ranges = [(0, Int(size))]
        } else {
            ranges = [(0, chunk), (size / 2 - Int64(chunk / 2), chunk), (size - Int64(chunk), chunk)]
        }
        for (offset, length) in ranges {
            if Task.isCancelled { return nil }
            var done = 0
            while done < length {
                let n = pread(fd, buf + done, length - done, offset + Int64(done))
                if n < 0 { return nil }
                if n == 0 { break }
                done += n
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: done))
            meter.add(Int64(done))
        }
        guard fstat(fd, &st) == 0, FileStamp(st) == stamp else { return nil }
        return hasher.finalize().withUnsafeBytes { raw in
            Digest(a: raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self),
                   b: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self),
                   c: raw.loadUnaligned(fromByteOffset: 16, as: UInt64.self),
                   d: raw.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
        }
    }
}

/// Found duplicate sets on their way to the main thread.
private final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var token = 0
    private var waiting: [DuplicateSet] = []

    func reset(token: Int) {
        lock.lock()
        self.token = token
        waiting = []
        lock.unlock()
    }

    /// Returns true if `set` starts a new batch (the caller schedules its
    /// delivery). Sets from a stopped run are dropped.
    func add(_ set: DuplicateSet, token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard token == self.token else { return false }
        waiting.append(set)
        return waiting.count == 1
    }

    func take(token: Int) -> [DuplicateSet] {
        lock.lock()
        defer { lock.unlock() }
        guard token == self.token else { return [] }
        let out = waiting
        waiting = []
        return out
    }
}

/// A cancellation signal that plain threads (not tasks) can check.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
