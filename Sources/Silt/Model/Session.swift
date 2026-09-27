import AppKit
import Foundation
import Observation
import SiltCore

/// A stable reference to something in the tree. Folders are identified by dir
/// id (which survives refreshes); files by entry index.
struct ItemRef: Hashable {
    let entry: UInt32
    let dir: UInt32

    var isDir: Bool { dir != NONE }
}

/// What's marked for cleanup. Folders by dir id; files by their folder and
/// name, since a file's entry index changes whenever its folder is relisted.
enum MarkKey: Hashable {
    case dir(UInt32)
    case file(parent: UInt32, name: String)
}

/// An in-place rescan (explicit, or a background check after FSEvents lost
/// track), with how far along it is.
struct RescanState: Equatable {
    var fraction: Double
    let explicit: Bool
}

struct ScanStats: Equatable {
    var items = 0
    var bytes: Int64 = 0
    var folders = 0
    var denied = 0
    var elapsed: Double = 0
    var finished: Double = 0
    var queued = 0
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String?
    /// An optional button, e.g. Undo.
    var action: (title: String, run: @MainActor () -> Void)?

    init(symbol: String, title: String, detail: String?, action: (title: String, run: @MainActor () -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.action = action
    }

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// One scanned location: the tree, the scan that fills it, the file-system
/// watch that keeps it current, and the actions you can take on it.
@MainActor
@Observable
final class Session: Identifiable {
    enum Phase: Equatable { case scanning, live }

    let id = UUID()
    let url: URL
    let title: String
    let isVolume: Bool
    @ObservationIgnored let tree: Tree

    private(set) var phase: Phase = .scanning
    private(set) var stats = ScanStats()
    /// Bumps (at most ~5×/s) whenever tree contents change. Views that show
    /// derived numbers read it to know when to recompute.
    private(set) var version = 0
    /// Like `version`, but for views that re-walk the whole tree: once live,
    /// it moves at most every second per two million items, so a disk that
    /// never stops changing doesn't keep them busy.
    private(set) var quietVersion = 0
    @ObservationIgnored private var quietSource = 0
    @ObservationIgnored private var lastQuietBump: TimeInterval = 0
    private(set) var capacity: (total: Int64, available: Int64, free: Int64)?
    var focus: UInt32 = 0
    var selection: [ItemRef] = []
    var toast: Toast?
    private(set) var freedBytes: Int64 = 0
    /// Scanning, but nothing has landed for a few seconds: usually threads
    /// parked on a macOS privacy prompt.
    private(set) var stalled = false
    @ObservationIgnored private var lastGrowth: TimeInterval = ProcessInfo.processInfo.systemUptime
    private(set) var trashedBytes: Int64 = 0
    /// What Silt moved to the Trash that's still there (space not yet back).
    @ObservationIgnored private var inTrash: [(url: URL, bytes: Int64)] = []
    private(set) var waitingInTrash: Int64 = 0
    @ObservationIgnored private var lastTrashCheck: TimeInterval = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastGeneration: UInt64 = .max
    @ObservationIgnored private var lastVersionBump: TimeInterval = 0
    @ObservationIgnored private var lastCapacityCheck: TimeInterval = 0
    @ObservationIgnored private var watcher: FSWatcher?
    @ObservationIgnored private var heldEvents: [FSWatcher.Event] = []
    @ObservationIgnored private var listeners: [ObjectIdentifier: () -> Void] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// Set by the tree view that currently owns the selection.
    @ObservationIgnored var quickLook: (() -> Void)?
    /// How the file tree was left, so switching locations or panes and coming
    /// back doesn't collapse everything.
    @ObservationIgnored var treeState = TreeState()
    /// Called once if the tree is running out of entry indices (they're never
    /// reused, so a folder churning for days could get there): the window
    /// replaces this session with a fresh one.
    @ObservationIgnored var onNeedsRebuild: (() -> Void)?
    @ObservationIgnored private var askedForRebuild = false

    /// When the scan being shown was saved, if it came from a snapshot.
    private(set) var restoredFrom: Date?
    /// Replaying file-system history since that snapshot.
    private(set) var catchingUp = false
    @ObservationIgnored private let fullDiskAccess: Bool
    @ObservationIgnored private var lastEventId: FSEventStreamEventId = 0
    @ObservationIgnored private var lastSave: TimeInterval = 0
    @ObservationIgnored private var lastSaveAttempt: TimeInterval = 0
    @ObservationIgnored private var savedGeneration: UInt64 = 0
    @ObservationIgnored private var saving = false

    /// Rescan in progress, if any. The tree stays fully usable meanwhile.
    private(set) var rescanState: RescanState?
    @ObservationIgnored private var rescanBase: (listed: UInt64, total: Int)?
    @ObservationIgnored private var deepAt: [UInt32: TimeInterval] = [:]
    @ObservationIgnored private var deferredDeep: Set<UInt32> = []
    /// Big folders that change constantly (build output, browser caches) are
    /// re-listed at a pace that scales with their size rather than on every
    /// event: when each was last listed, and when it's next due.
    @ObservationIgnored private var listedAt: [UInt32: TimeInterval] = [:]
    @ObservationIgnored private var dueAt: [UInt32: TimeInterval] = [:]
    @ObservationIgnored private var rootInode: UInt64 = 0
    @ObservationIgnored private var rootVolume: String?

    /// Marked for cleanup, with an optional reason ("node_modules", "copy of …").
    private(set) var marks: [MarkKey: MarkInfo] = [:]
    /// Deduplicated total of everything marked (nested marks count once).
    private(set) var markedBytes: Int64 = 0
    private(set) var markedCount = 0
    @ObservationIgnored private var marksDirty = false
    @ObservationIgnored private var lastMarksRecompute: TimeInterval = 0
    @ObservationIgnored private var marksRestored = false

    /// What the volume's used space holds beyond the scan, for whole volumes.
    private(set) var hidden: HiddenSpace?
    /// The hidden-space row (or one of its parts) the tree has selected.
    var hiddenSelection: String?
    @ObservationIgnored private var snapshots: [String] = []
    @ObservationIgnored private var lastSnapshotCheck: TimeInterval = -.infinity

    /// For whole volumes: roughly how many items a full scan will find
    /// (the volume's used inode count), so the first scan can show a percentage.
    @ObservationIgnored private(set) var scanEstimate: Int?

    /// Duplicate search for this location.
    @ObservationIgnored let duplicates = DuplicateFinder()
    /// Asks the tree to select and scroll to a folder (from banners, lists).
    @ObservationIgnored var pendingSelect: ItemRef?

    func reveal(inTree ref: ItemRef) {
        pendingSelect = ref
        notifyListeners()
    }

    /// Folder sizes to compare against: the restored snapshot, or the moment
    /// a fresh scan finished. Kept for the top few levels only.
    @ObservationIgnored private var baseline: [UInt32: Int64] = [:]
    /// Folders whose every child is in `baseline`, so an unknown child is new.
    @ObservationIgnored private var baselineExpanded: Set<UInt32> = []
    private(set) var baselineDate: Date?
    /// The biggest changes since the baseline, deepest meaningful folder first.
    private(set) var changes: [Change] = []
    /// Net change of the whole location since the baseline.
    private(set) var netChange: Int64 = 0
    @ObservationIgnored private var changesVersion = -1

    struct Change: Identifiable, Equatable {
        let dir: UInt32
        let name: String
        let path: String
        let delta: Int64
        var id: UInt32 { dir }
    }

    /// Reclaim suggestions, shared by the Reclaim pane and the overview.
    private(set) var findings: [Finding] = []
    private(set) var analyzing = false
    @ObservationIgnored private var analyzedVersion = -1
    @ObservationIgnored private var lastAnalysis: TimeInterval = 0
    @ObservationIgnored private var analysisCost: TimeInterval = 0

    /// Without Full Disk Access, opening another app's container pops a
    /// privacy prompt and blocks the scanning thread until it's answered, so
    /// those folders are recorded but not opened.
    init(url: URL, guardPrivateFolders: Bool, fresh: Bool = false) {
        let resolved = url.resolvingSymlinksInPath()
        self.url = resolved
        title = Locations.displayName(for: resolved)
        let values = try? resolved.resourceValues(forKeys: [.isVolumeKey])
        isVolume = values?.isVolume == true || resolved.path == "/"
        fullDiskAccess = !guardPrivateFolders
        var restored = fresh ? nil : Snapshots.load(for: resolved, fullDiskAccess: fullDiskAccess)
        // A restore is only as good as the replay behind it.
        var replay: FSWatcher?
        if let r = restored {
            replay = Session.makeWatcher(path: resolved.path, since: r.eventId, session: nil)
            if replay?.running != true {
                silt_tree_destroy(r.tree)
                restored = nil
                replay = nil
            }
        }
        tree = restored.map { Tree(restored: $0.tree, path: resolved.path) } ?? Tree(path: resolved.path)
        if guardPrivateFolders {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for sub in ["Library/Containers", "Library/Group Containers", "Library/Daemon Containers"] {
                silt_tree_guard(tree.raw, home + "/" + sub)
            }
        }
        if let restored {
            // Show the saved scan now; FSEvents replays everything since.
            (baseline, baselineExpanded) = Session.sizes(tree, depth: 4)
            baselineDate = restored.savedAt
            // Loading used large temporary buffers; give those pages back.
            malloc_zone_pressure_relief(nil, 0)
            tree.startIdle()
            phase = .live
            restoredFrom = restored.savedAt
            catchingUp = true
            lastEventId = restored.eventId
            replay?.stop()
            startWatching(since: restored.eventId)
        } else {
            tree.startScan()
            startWatching(since: nil)
        }
        savedGeneration = tree.generation
        var st = stat()
        if lstat(resolved.path, &st) == 0 { rootInode = st.st_ino }
        rootVolume = Session.volumeUUID(resolved)
        if isVolume {
            var total = 0
            for p in resolved.path == "/" ? ["/", "/System/Volumes/Data"] : [resolved.path] {
                var fs = statfs()
                if statfs(p, &fs) == 0 { total += Int(fs.f_files) - Int(fs.f_ffree) }
            }
            scanEstimate = total > 0 ? total : nil
        }
        capacity = Locations.volumeCapacity(for: resolved)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func close() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        tree.stop()
    }

    // MARK: Live updates

    /// Called on every tick where the tree changed.
    func addListener(_ owner: AnyObject, _ body: @escaping () -> Void) {
        listeners[ObjectIdentifier(owner)] = body
    }

    func removeListener(_ owner: AnyObject) {
        listeners.removeValue(forKey: ObjectIdentifier(owner))
    }

    private func tick() {
        let p = tree.progress
        let gen = tree.generation
        let now = ProcessInfo.processInfo.systemUptime

        var s = ScanStats()
        s.items = Int(p.files)
        s.bytes = Int64(p.bytes)
        s.folders = Int(p.dirs)
        s.denied = Int(p.denied)
        s.elapsed = p.elapsed
        s.finished = p.finished
        s.queued = Int(p.queued)
        if s.items != stats.items || s.folders != stats.folders { lastGrowth = now }
        if phase == .scanning || s != stats { stats = s }
        let isStalled = phase == .scanning && s.queued > 0 && now - lastGrowth > 3
        if isStalled != stalled { stalled = isStalled }

        if phase == .scanning && p.idle && p.finished > 0 {
            phase = .live
            releaseHeldEvents()
            capacity = Locations.volumeCapacity(for: url)
            version += 1
            lastSave = 0 // save the fresh scan as soon as it settles
            (baseline, baselineExpanded) = Session.sizes(tree, depth: 4)
            baselineDate = Date()
            malloc_zone_pressure_relief(nil, 0) // scan batches are done with
            measureHidden(now: now)
        }

        if gen != lastGeneration {
            lastGeneration = gen
            repairFocus()
            notifyListeners()
            if now - lastVersionBump > 0.2 || phase == .live {
                lastVersionBump = now
                version += 1
            }
            marksDirty = true
        }

        if version != quietSource,
           phase == .scanning || now - lastQuietBump > max(1, Double(stats.items) / 2_000_000) {
            quietSource = version
            lastQuietBump = now
            quietVersion += 1
        }

        tickRescan(p, now: now)
        releaseDueRefreshes(now: now)
        if marksDirty { recomputeMarks(force: false) }
        if phase == .live, !marksRestored, !catchingUp {
            marksRestored = true
            restoreMarks()
        }
        tickAnalysis(now: now)
        if phase == .live, !catchingUp, p.idle, version != changesVersion, !baseline.isEmpty {
            changesVersion = version
            computeChanges()
        }

        if !askedForRebuild, tree.raw.pointee.entry_count > 3_500_000_000 {
            askedForRebuild = true
            onNeedsRebuild?()
        }
        if now - lastCapacityCheck > 3 {
            lastCapacityCheck = now
            capacity = Locations.volumeCapacity(for: url)
            measureHidden(now: now)
        }
        if !inTrash.isEmpty, now - lastTrashCheck > 5 {
            lastTrashCheck = now
            recountTrash()
        }

        // Keep the snapshot reasonably fresh without rewriting it constantly.
        if phase == .live, !catchingUp, !saving, p.idle, gen != savedGeneration,
           now - lastSave > (lastSave == 0 ? 1 : 300), now - lastSaveAttempt > 5 {
            saveSnapshot(now: now, generation: gen)
        }
    }

    private func saveSnapshot(now: TimeInterval, generation: UInt64) {
        saving = true
        lastSaveAttempt = now
        let tree = tree, url = url, eventId = lastEventId, fda = fullDiskAccess
        Task { [weak self] in
            let ok = await Task.detached(priority: .utility) {
                let ok = Snapshots.save(tree, url: url, eventId: eventId, fullDiskAccess: fda)
                malloc_zone_pressure_relief(nil, 0) // the save's buffers were big and short-lived
                return ok
            }.value
            self?.saving = false
            if ok {
                self?.savedGeneration = generation
                self?.lastSave = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    /// At quit: save synchronously if anything changed since the last save.
    func saveSnapshotNow() {
        guard phase == .live, !catchingUp, tree.generation != savedGeneration else { return }
        if Snapshots.save(tree, url: url, eventId: lastEventId, fullDiskAccess: fullDiskAccess) {
            savedGeneration = tree.generation
        }
    }

    /// If the focused folder was deleted or replaced, fall back to its nearest
    /// surviving ancestor.
    private func repairFocus() {
        guard focus != 0 else { return }
        let fixed: UInt32? = tree.withLock {
            var d = focus
            while d != 0 {
                let i = tree.dirEntry(d)
                if tree.isLive(i) { return d == focus ? nil : d }
                let parent = tree.entry(i).parent
                d = parent == NONE ? 0 : parent
            }
            return 0
        }
        if let fixed {
            focus = fixed
            selection = []
        }
    }

    nonisolated static func volumeUUID(_ url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    private func startWatching(since: FSEventStreamEventId?) {
        let w = Session.makeWatcher(path: url.path, since: since, session: self)
        watcher = w
        if since == nil { lastEventId = w.startId }
    }

    private static func makeWatcher(path: String, since: FSEventStreamEventId?, session: Session?) -> FSWatcher {
        FSWatcher(path: path, since: since) { [weak session] events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session?.handle(events) }
            }
        }
    }

    private func handle(_ events: [FSWatcher.Event]) {
        // Changes that land mid-scan are applied once the scan settles, so the
        // scan never races its own refreshes.
        if phase == .scanning {
            heldEvents.append(contentsOf: events)
            return
        }
        apply(events)
    }

    private func releaseHeldEvents() {
        let events = heldEvents
        heldEvents = []
        apply(events)
    }

    private func apply(_ events: [FSWatcher.Event]) {
        guard !events.isEmpty else { return }
        var targets: [UInt32: Bool] = [:]
        let root = url.path
        var rootChanged = false, wrapped = false
        for event in events {
            if event.id > lastEventId && event.id != UInt64(kFSEventStreamEventIdSinceNow) { lastEventId = event.id }
            if event.historyDone { catchingUp = false }
            if event.rootChanged { rootChanged = true }
            if event.idsWrapped { wrapped = true }
        }
        if rootChanged {
            // Usually a volume that unmounted and came back: same volume (by
            // UUID, since the device number can change) and same root inode.
            // Reattach and check the top level; anything else is a different
            // tree at this path, so revalidate all of it.
            var st = stat()
            let same = lstat(root, &st) == 0 && st.st_ino == rootInode
                && rootVolume != nil && Session.volumeUUID(url) == rootVolume
            watcher?.stop()
            startWatching(since: lastEventId)
            if same { tree.refresh(dir: 0, deep: false) } else { requestDeep(0) }
        }
        if wrapped { requestDeep(0) }
        var sizes: [UInt32: UInt32] = [:]
        tree.withLock {
            for event in events {
                if event.rootChanged || event.historyDone { continue }
                guard let dir = nearestListedDir(for: event.path, root: root) else { continue }
                targets[dir] = (targets[dir] ?? false) || event.mustScanSubdirs
                sizes[dir] = tree.dir(dir).count
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (dir, deep) in targets {
            if deep { requestDeep(dir) } else { refreshPaced(dir, children: sizes[dir] ?? 0, now: now) }
        }
    }

    /// Re-lists `dir` now, or once its pace allows: at most every 40 µs per
    /// child (a 60,000-file build folder every 2.4 s), capped at 5 s. Small
    /// folders are never held back.
    private func refreshPaced(_ dir: UInt32, children: UInt32, now: TimeInterval) {
        let gap = min(5, Double(children) * 40e-6)
        guard gap >= 0.1 else {
            tree.refresh(dir: dir, deep: false)
            return
        }
        if let last = listedAt[dir], now - last < gap {
            if dueAt[dir] == nil { dueAt[dir] = last + gap }
            return
        }
        listedAt[dir] = now
        tree.refresh(dir: dir, deep: false)
    }

    private func releaseDueRefreshes(now: TimeInterval) {
        if !dueAt.isEmpty {
            for (dir, due) in dueAt where due <= now {
                dueAt.removeValue(forKey: dir)
                listedAt[dir] = now
                tree.refresh(dir: dir, deep: false)
            }
        }
        // Forget folders that have gone quiet.
        if listedAt.count > 256 {
            listedAt = listedAt.filter { now - $0.value < 10 }
        }
    }

    /// FSEvents asks for a subtree revalidation when it coalesced or dropped
    /// events. On a busy disk that can arrive in bursts, so each folder is
    /// revalidated at most every 30 s; requests in between are deferred.
    private func requestDeep(_ dir: UInt32) {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = deepAt[dir], now - last < 30 {
            deferredDeep.insert(dir)
            return
        }
        deepAt[dir] = now
        startRescan(dir, explicit: false)
    }

    /// Lock held.
    private func nearestListedDir(for rawPath: String, root: String) -> UInt32? {
        var path = rawPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        // Paths inside the data volume can arrive in either firmlink form.
        let dataPrefix = "/System/Volumes/Data"
        if root == "/" && path.hasPrefix(dataPrefix + "/") {
            path = String(path.dropFirst(dataPrefix.count))
        }
        guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        while true {
            let e = tree.lookup(path)
            if e != NONE {
                let entry = tree.entry(e)
                if entry.isDir { return entry.aux }
            }
            if path == root || path.count <= 1 { return e == NONE ? 0 : nil }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// Re-lists everything under `ref` (the whole location by default) in
    /// place: the tree stays browsable, sizes update as folders are
    /// revisited, and `rescanState` reports progress.
    func rescan(_ ref: ItemRef? = nil) {
        let dir = ref?.dir ?? 0
        guard dir != NONE else { return }
        startRescan(dir, explicit: true)
    }

    private func startRescan(_ dir: UInt32, explicit: Bool) {
        let p = tree.progress
        let total = tree.withLock { Int(tree.dir(dir).items) }
        if rescanBase == nil || explicit {
            rescanBase = (p.listed, max(total, 1))
            rescanState = RescanState(fraction: 0, explicit: explicit || (rescanState?.explicit ?? false))
        }
        tree.refresh(dir: dir, deep: true)
    }

    private func tickRescan(_ p: silt_progress, now: TimeInterval) {
        if let base = rescanBase {
            if p.idle {
                let wasExplicit = rescanState?.explicit ?? false
                rescanBase = nil
                rescanState = nil
                if wasExplicit {
                    show(Toast(symbol: "checkmark.circle", title: "Rescan complete",
                               detail: "\(Fmt.count(stats.items)) items · \(Fmt.bytes(stats.bytes))"))
                }
            } else {
                let f = min(0.99, Double(p.listed &- base.listed) / Double(base.total))
                if abs(f - (rescanState?.fraction ?? 0)) > 0.004 {
                    rescanState?.fraction = f
                }
            }
        }
        // Deferred background checks whose quiet period has passed.
        if !deferredDeep.isEmpty, rescanBase == nil {
            for dir in deferredDeep where now - (deepAt[dir] ?? 0) >= 30 {
                deferredDeep.remove(dir)
                deepAt[dir] = now
                startRescan(dir, explicit: false)
            }
        }
    }

    // MARK: Resolution

    /// Current entry index for a reference. Lock held.
    func entryIndex(_ ref: ItemRef) -> UInt32 {
        ref.isDir ? tree.dirEntry(ref.dir) : ref.entry
    }

    func ref(forEntry index: UInt32) -> ItemRef {
        let e = tree.entry(index)
        return ItemRef(entry: index, dir: e.isDir ? e.aux : NONE)
    }

    func path(_ ref: ItemRef) -> String {
        tree.withLock { tree.path(of: entryIndex(ref)) }
    }

    func urls(_ refs: [ItemRef]) -> [URL] {
        tree.withLock {
            refs.compactMap { ref in
                let i = entryIndex(ref)
                guard tree.isLive(i) else { return nil }
                return URL(fileURLWithPath: tree.path(of: i))
            }
        }
    }

    // MARK: Actions

    func reveal(_ refs: [ItemRef]) {
        let urls = urls(refs)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func open(_ refs: [ItemRef]) {
        for url in urls(refs) { NSWorkspace.shared.open(url) }
    }

    func copyPaths(_ refs: [ItemRef]) {
        let paths = urls(refs).map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        show(Toast(symbol: "doc.on.doc", title: paths.count == 1 ? "Path copied" : "\(paths.count) paths copied", detail: nil))
    }

    func focus(on ref: ItemRef) {
        guard ref.isDir else { return }
        focus = ref.dir
        selection = []
    }

    func focusParent() {
        guard focus != 0 else { return }
        let parent = tree.withLock { tree.entry(tree.dirEntry(focus)).parent }
        let previous = focus
        focus = parent == NONE ? 0 : parent
        selection = [ItemRef(entry: tree.withLock { tree.dirEntry(previous) }, dir: previous)]
    }

    /// Which object on disk a path named when we resolved it.
    fileprivate struct Identity: Hashable, Sendable {
        let dev: Int32
        let ino: UInt64

        init?(path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            dev = st.st_dev
            ino = st.st_ino
        }
    }

    fileprivate struct Target: Sendable {
        let entry: UInt32
        let url: URL
        let size: Int64
        let identity: Identity

        /// Still the same object we showed the user?
        var unchanged: Bool { Identity(path: url.path) == identity }
    }

    private static let protectedPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var s = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin",
                 "/etc", "/var", "/opt", "/cores", "/Volumes", "/tmp", "/System/Volumes/Data", home]
        for sub in ["Library", "Desktop", "Documents", "Downloads", "Applications", "Movies", "Music", "Pictures",
                    "Public", ".Trash"] {
            s.append(home + "/" + sub)
        }
        return s
    }()

    /// Compared by inode as well as by path, so firmlink spellings
    /// (/System/Volumes/Data/Users/…) can't slip past.
    private static let protectedIdentities: Set<Identity> = Set(protectedPaths.compactMap { Identity(path: $0) })

    private static func isProtected(_ path: String, _ identity: Identity) -> Bool {
        protectedIdentities.contains(identity) || protectedPaths.contains(path)
    }

    private func targets(_ refs: [ItemRef]) -> (ok: [Target], refused: [String]) {
        var ok: [Target] = []
        var refused: [String] = []
        var resolved: [(UInt32, String, Int64)] = []
        tree.withLock {
            for ref in refs {
                let i = entryIndex(ref)
                guard i != 0, tree.isLive(i) else { continue }
                resolved.append((i, tree.path(of: i), tree.entry(i).size))
            }
        }
        for (i, path, size) in resolved {
            guard let identity = Identity(path: path) else { continue }
            if Self.isProtected(path, identity) {
                refused.append((path as NSString).lastPathComponent)
                continue
            }
            ok.append(Target(entry: i, url: URL(fileURLWithPath: path), size: size, identity: identity))
        }
        // Drop anything nested inside another target.
        let paths = Set(ok.map(\.url.path))
        ok = ok.filter { t in
            var p = (t.url.path as NSString).deletingLastPathComponent
            while p.count > 1 {
                if paths.contains(p) { return false }
                p = (p as NSString).deletingLastPathComponent
            }
            return true
        }
        return (ok, refused)
    }

    func moveToTrash(_ refs: [ItemRef]) {
        let (all, refused) = targets(refs)
        if !refused.isEmpty { refuse(refused) }
        recycle(all.filter(\.unchanged))
    }

    private func recycle(_ items: [Target]) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.recycle(items.map(\.url)) { [weak self] trashed, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishTrash(items, trashed: trashed, error: error)
                }
            }
        }
    }

    private func finishTrash(_ items: [Target], trashed: [URL: URL], error: Error?) {
        let done = items.filter { trashed[$0.url] != nil }
        for t in done { tree.remove(entry: t.entry) }
        refreshParents(of: items)
        selection = []
        let bytes = done.reduce(Int64(0)) { $0 + $1.size }
        trashedBytes += bytes
        if done.isEmpty, let error {
            show(Toast(symbol: "exclamationmark.triangle", title: "Couldn’t move to Trash", detail: error.localizedDescription))
        } else {
            let what = done.count == 1 ? done[0].url.lastPathComponent : "\(done.count) items"
            let moves = done.compactMap { t in trashed[t.url].map { (from: $0, to: t.url) } }
            for t in done { if let u = trashed[t.url] { inTrash.append((u, t.size)) } }
            recountTrash()
            show(Toast(symbol: "trash", title: "Moved \(what) to the Trash",
                       detail: "\(Fmt.bytes(bytes)) comes back when you empty the Trash",
                       action: ("Undo", { [weak self] in self?.putBack(moves, bytes: bytes) })), seconds: 8)
        }
    }

    /// Items leave the Trash when it's emptied (anywhere) or put back.
    private func recountTrash() {
        inTrash = inTrash.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        let bytes = inTrash.reduce(Int64(0)) { $0 + $1.bytes }
        if bytes != waitingInTrash { waitingInTrash = bytes }
    }

    /// Empties the Trash through Finder (which asks permission the first time).
    func emptyTrash(window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = waitingInTrash > 0
            ? "Everything in the Trash is removed for good, including the \(Fmt.bytes(waitingInTrash)) Silt put there."
            : "Everything in the Trash is removed for good."
        let b = alert.addButton(withTitle: "Empty Trash")
        b.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            let before = self?.capacity?.available ?? 0
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
                let message = error?[NSAppleScript.errorMessage] as? String
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.capacity = Locations.volumeCapacity(for: self.url)
                        self.recountTrash()
                        if let message {
                            self.show(Toast(symbol: "exclamationmark.triangle", title: "Couldn’t empty the Trash", detail: message))
                        } else {
                            let gained = (self.capacity?.available ?? before) - before
                            self.freedBytes += max(0, gained)
                            self.show(Toast(symbol: "checkmark.circle", title: "Emptied the Trash",
                                            detail: gained > 0 ? "\(Fmt.bytes(gained)) freed" : nil))
                        }
                    }
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    /// Undoes a Move to Trash: each item goes back where it was, unless
    /// something new has taken its place.
    private func putBack(_ moves: [(from: URL, to: URL)], bytes: Int64) {
        var restored = 0
        for m in moves where !FileManager.default.fileExists(atPath: m.to.path) {
            if (try? FileManager.default.moveItem(at: m.from, to: m.to)) != nil { restored += 1 }
        }
        trashedBytes -= restored == moves.count ? bytes : 0
        recountTrash()
        var dirs = Set<UInt32>()
        tree.withLock {
            for m in moves {
                let parent = m.to.deletingLastPathComponent().path
                let e = tree.lookup(parent)
                if e != NONE, tree.entry(e).isDir { dirs.insert(tree.entry(e).aux) }
            }
        }
        for d in dirs { tree.refresh(dir: d, deep: false) }
        show(Toast(symbol: "arrow.uturn.backward", title: restored == moves.count
                       ? "Put back \(restored == 1 ? "1 item" : "\(restored) items")"
                       : "Put back \(restored) of \(moves.count) items",
                   detail: restored == moves.count ? nil : "Something new was already in the others’ places."))
    }

    func deleteImmediately(_ refs: [ItemRef], window: NSWindow?, confirmed: Bool = false) {
        let (items, refused) = targets(refs)
        if !refused.isEmpty { refuse(refused) }
        guard !items.isEmpty else { return }
        if confirmed {
            performDelete(items)
            return
        }
        let bytes = items.reduce(Int64(0)) { $0 + $1.size }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1
            ? "Delete “\(items[0].url.lastPathComponent)” immediately?"
            : "Delete \(items.count) items immediately?"
        alert.informativeText = "This frees \(Fmt.bytes(bytes)) right away and can’t be undone."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(items)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    private func performDelete(_ confirmed: [Target]) {
        // The sheet may have been open a while: only delete what is still the
        // very object the user confirmed.
        let items = confirmed.filter(\.unchanged)
        if items.count < confirmed.count {
            refreshParents(of: confirmed)
            show(Toast(symbol: "exclamationmark.triangle", title: "Some items changed on disk",
                       detail: "They were left alone. Look again and retry."))
        }
        guard !items.isEmpty else { return }
        // Optimistic: the rows disappear now; failures come back on refresh.
        for t in items { tree.remove(entry: t.entry) }
        selection = []
        show(Toast(symbol: "hourglass", title: "Deleting…", detail: nil))
        Task.detached(priority: .userInitiated) {
            var failures: [URL: String] = [:]
            for t in items {
                if let problem = Self.quarantineAndDelete(t) { failures[t.url] = problem }
            }
            let failed = failures
            await MainActor.run { [weak self] in
                guard let self else { return }
                let done = items.filter { failed[$0.url] == nil }
                let bytes = done.reduce(Int64(0)) { $0 + $1.size }
                self.freedBytes += bytes
                self.refreshParents(of: items)
                self.capacity = Locations.volumeCapacity(for: self.url)
                if let first = failed.first {
                    self.show(Toast(symbol: "exclamationmark.triangle",
                                    title: "Couldn’t delete \(first.key.lastPathComponent)", detail: first.value))
                } else {
                    self.show(Toast(symbol: "checkmark.circle", title: "Freed \(Fmt.bytes(bytes))", detail: nil))
                }
            }
        }
    }

    /// Renames the target to a private name first (atomic, same folder), then
    /// checks that what moved is the object the user confirmed, and only then
    /// deletes it. A lookalike that appeared at the path is moved back
    /// untouched. Returns a problem description, or nil on success.
    nonisolated private static func quarantineAndDelete(_ t: Target) -> String? {
        let path = t.url.path
        let parked = t.url.deletingLastPathComponent()
            .appendingPathComponent(".silt-deleting-\(UUID().uuidString)").path
        guard rename(path, parked) == 0 else { return String(cString: strerror(errno)) }
        guard Identity(path: parked) == t.identity else {
            _ = renamex_np(parked, path, UInt32(RENAME_EXCL))
            return "It changed on disk after you confirmed, so it was left alone."
        }
        do {
            try FileManager.default.removeItem(atPath: parked)
            return nil
        } catch {
            // Partly deleted: put what's left back where the user expects it.
            _ = renamex_np(parked, path, UInt32(RENAME_EXCL))
            return error.localizedDescription
        }
    }

    private func refreshParents(of items: [Target]) {
        var dirs = Set<UInt32>()
        tree.withLock {
            for t in items { dirs.insert(tree.entry(t.entry).parent) }
        }
        for d in dirs where d != NONE { tree.refresh(dir: d, deep: false) }
    }

    private func refuse(_ names: [String]) {
        show(Toast(symbol: "hand.raised", title: "Silt won’t delete \(names.joined(separator: ", "))",
                   detail: "It’s a system or home folder location."))
    }

    func show(_ toast: Toast, seconds: Double = 4) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Activity

    /// Long-running work on this location, for progress bars: the first scan
    /// (measured against the volume's used inode count, when it's a volume),
    /// a rescan, or catching up after a relaunch. No fraction when there's
    /// nothing to measure against.
    struct Activity: Equatable {
        let fraction: Double?
        let label: String
    }

    var activity: Activity? {
        switch phase {
        case .scanning:
            guard let est = scanEstimate, est > 0 else { return Activity(fraction: nil, label: "Scanning") }
            return Activity(fraction: min(0.99, Double(stats.items) / Double(est)), label: "Scanning")
        case .live:
            if let r = rescanState {
                return Activity(fraction: r.fraction, label: r.explicit ? "Rescanning" : "Checking for changes")
            }
            return catchingUp ? Activity(fraction: nil, label: "Catching up on changes") : nil
        }
    }

    // MARK: Volume gap

    /// Space the volume reports as used that the scan couldn't see: snapshots,
    /// other volumes in its container, swap, and unreadable folders.
    var unseenBytes: Int64 {
        guard isVolume, phase == .live else { return 0 }
        return hidden?.total ?? 0
    }

    /// Re-measures the hidden space; local snapshots are listed every few
    /// minutes, off the main thread.
    fileprivate func measureHidden(now: TimeInterval) {
        guard isVolume, phase == .live, let capacity else {
            if hidden != nil { hidden = nil }
            return
        }
        if now - lastSnapshotCheck > 180 {
            lastSnapshotCheck = now
            let path = url.path
            Task { [weak self] in
                let names = await Task.detached(priority: .utility) { LocalSnapshots.list(for: path) }.value
                guard let self else { return }
                self.snapshots = names
                self.measureHidden(now: ProcessInfo.processInfo.systemUptime)
            }
        }
        let next = HiddenSpace.measure(url: url, scanned: stats.bytes, capacity: capacity,
                                       unreadable: stats.denied, snapshots: snapshots)
        if next != hidden { hidden = next }
    }
}

// MARK: - Cleanup marks

extension Session {
    func notifyListeners() {
        for body in listeners.values { body() }
    }

    /// Lock held.
    func markKey(for ref: ItemRef) -> MarkKey? {
        if ref.isDir { return .dir(ref.dir) }
        guard tree.isLive(ref.entry) else { return nil }
        let e = tree.entry(ref.entry)
        return .file(parent: e.parent, name: tree.name(of: e))
    }

    /// Lock held. Current entry for a mark, if it still exists.
    func resolve(_ key: MarkKey) -> UInt32? {
        switch key {
        case .dir(let d):
            guard d < tree.raw.pointee.dir_count else { return nil }
            let i = tree.dirEntry(d)
            return tree.isLive(i) ? i : nil
        case .file(let parent, let name):
            guard parent < tree.raw.pointee.dir_count, tree.isLive(tree.dirEntry(parent)) else { return nil }
            let d = tree.dir(parent)
            let bytes = Array(name.utf8)
            for i in d.first..<(d.first + d.count) {
                let e = tree.entry(i)
                if e.isRemoved || Int(e.name_len) != bytes.count { continue }
                if bytes.withUnsafeBufferPointer({ memcmp(silt_name_ptr(tree.raw, e.name), $0.baseAddress!, bytes.count) }) == 0 {
                    return i
                }
            }
            return nil
        }
    }

    /// The live item at `path`, if the scan has it.
    func liveRef(path: String) -> ItemRef? {
        tree.withLock {
            let i = tree.lookup(path)
            return i != NONE && tree.isLive(i) ? ref(forEntry: i) : nil
        }
    }

    /// Live items for many paths, under one lock.
    func liveRefs(paths: [String]) -> [ItemRef] {
        tree.withLock {
            paths.compactMap { p in
                let i = tree.lookup(p)
                return i != NONE && tree.isLive(i) ? ref(forEntry: i) : nil
            }
        }
    }

    /// Paths of everything marked, for views that check many rows at once.
    func markedPaths() -> Set<String> {
        guard !marks.isEmpty else { return [] }
        return tree.withLock { Set(marks.keys.compactMap { resolve($0).map { tree.path(of: $0) } }) }
    }

    func isMarked(_ ref: ItemRef) -> Bool {
        guard !marks.isEmpty else { return false }
        return tree.withLock { markKey(for: ref).map { marks[$0] != nil } ?? false }
    }

    /// What a mark points at, captured when it was made, so cleanup can tell
    /// if the file was since replaced by a different one with the same name.
    struct MarkInfo {
        var reason: String
        var dev: Int32
        var ino: UInt64
    }

    /// Identity of what each ref is right now, for new marks.
    private func captureMarks(_ refs: [ItemRef]) -> [(MarkKey, MarkInfo)] {
        let resolved: [(MarkKey, String)] = tree.withLock {
            refs.compactMap { r in
                guard let k = markKey(for: r) else { return nil }
                return (k, tree.path(of: entryIndex(r)))
            }
        }
        return resolved.compactMap { k, path in
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            return (k, MarkInfo(reason: "", dev: st.st_dev, ino: st.st_ino))
        }
    }

    /// Adds or removes `refs`; if every one is already marked, unmarks them.
    func toggleMarks(_ refs: [ItemRef], reason: String? = nil) {
        let keys = tree.withLock { refs.compactMap { markKey(for: $0) } }
        guard !keys.isEmpty else { return }
        if keys.allSatisfy({ marks[$0] != nil }) {
            for k in keys { marks.removeValue(forKey: k) }
        } else {
            for (k, info) in captureMarks(refs) where marks[k] == nil {
                marks[k] = MarkInfo(reason: reason ?? "", dev: info.dev, ino: info.ino)
            }
        }
        marksChanged()
    }

    func mark(_ refs: [ItemRef], reason: String) {
        for (k, info) in captureMarks(refs) where marks[k] == nil {
            marks[k] = MarkInfo(reason: reason, dev: info.dev, ino: info.ino)
        }
        marksChanged()
    }

    func mark(entries: [UInt32], reason: String) {
        mark(tree.withLock { entries.filter { tree.isLive($0) }.map { ref(forEntry: $0) } }, reason: reason)
    }

    func unmark(_ keys: [MarkKey]) {
        for k in keys { marks.removeValue(forKey: k) }
        marksChanged()
    }

    func clearMarks() {
        marks = [:]
        marksChanged()
    }

    private func marksChanged() {
        recomputeMarks()
        notifyListeners()
        persistMarks()
    }

    struct MarkedItem: Identifiable {
        let key: MarkKey
        let entry: UInt32
        let path: String
        let size: Int64
        let isDir: Bool
        let reason: String
        var id: MarkKey { key }
    }

    /// Lock held. Live marks with their entries, minus anything inside
    /// another marked folder (it goes with its parent).
    private func liveMarks() -> [(MarkKey, UInt32)] {
        var live: [(MarkKey, UInt32)] = []
        var markedDirs = Set<UInt32>()
        for key in marks.keys {
            guard let i = resolve(key) else { continue }
            live.append((key, i))
            if case .dir(let d) = key { markedDirs.insert(d) }
        }
        return live.filter { _, i in
            var p = tree.entry(i).parent
            while p != NONE {
                if markedDirs.contains(p) { return false }
                p = tree.entry(tree.dirEntry(p)).parent
            }
            return true
        }
    }

    /// Everything marked that still exists and is still the same object it
    /// was when marked, largest first. Marks that no longer hold are dropped.
    func markedItems() -> [MarkedItem] {
        let candidates: [MarkedItem] = tree.withLock {
            liveMarks().map { key, i in
                let e = tree.entry(i)
                return MarkedItem(key: key, entry: i, path: tree.path(of: i), size: e.size, isDir: e.isDir,
                                  reason: marks[key]?.reason ?? "")
            }
        }
        var stale: [MarkKey] = []
        let valid = candidates.filter { item in
            guard let info = marks[item.key] else { return false }
            var st = stat()
            let same = lstat(item.path, &st) == 0 && st.st_dev == info.dev && st.st_ino == info.ino
            if !same { stale.append(item.key) }
            return same
        }
        if !stale.isEmpty {
            for k in stale { marks.removeValue(forKey: k) }
            recomputeMarks()
            notifyListeners()
        }
        return valid.sorted { $0.size > $1.size }
    }

    /// How many marked items were left out because a marked folder holds them.
    func nestedMarkCount() -> Int {
        tree.withLock { marks.count - liveMarks().count }
    }

    /// Lock held. True if `entry` or a folder above it is marked.
    func isCovered(_ entry: UInt32, key: MarkKey?) -> Bool {
        if let key, marks[key] != nil { return true }
        var p = tree.entry(entry).parent
        while p != NONE {
            if marks[.dir(p)] != nil { return true }
            p = tree.entry(tree.dirEntry(p)).parent
        }
        return false
    }

    /// The running total. Cheap (no paths, no sorting, no disk access) and
    /// throttled while the tree is churning.
    func recomputeMarks(force: Bool = true) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force && now - lastMarksRecompute < 0.5 { return }
        lastMarksRecompute = now
        marksDirty = false
        guard !marks.isEmpty else {
            if markedCount != 0 || markedBytes != 0 {
                markedCount = 0
                markedBytes = 0
            }
            return
        }
        let (count, bytes): (Int, Int64) = tree.withLock {
            let live = liveMarks()
            return (live.count, live.reduce(Int64(0)) { $0 + tree.entry($1.1).size })
        }
        if count != markedCount { markedCount = count }
        if bytes != markedBytes { markedBytes = bytes }
    }

    enum CleanupMethod: String, CaseIterable, Identifiable {
        case trash, delete
        var id: String { rawValue }
    }

    /// Removes everything marked. Marks for items that went away, or were
    /// replaced since they were marked, are dropped instead.
    func cleanUp(_ method: CleanupMethod) {
        let items = markedItems()
        // The object each mark was made on, to hold every target to.
        var expected: [String: (dev: Int32, ino: UInt64)] = [:]
        for item in items {
            if let m = marks[item.key] { expected[item.path] = (m.dev, m.ino) }
        }
        let refs = tree.withLock { items.map { ref(forEntry: $0.entry) } }
        marks = [:]
        marksChanged()
        let (all, refused) = targets(refs)
        if !refused.isEmpty { refuse(refused) }
        let ok = all.filter { t in
            guard let e = expected[t.url.path] else { return false }
            return e.dev == t.identity.dev && e.ino == t.identity.ino && t.unchanged
        }
        if ok.count < all.count {
            show(Toast(symbol: "exclamationmark.triangle",
                       title: "\(all.count - ok.count) \(all.count - ok.count == 1 ? "item" : "items") changed since marked",
                       detail: "They were left alone."))
        }
        switch method {
        case .trash: recycle(ok)
        case .delete: performDelete(ok)
        }
    }

    // MARK: Persisted marks

    private var marksDefaultsKey: String { "marks:" + url.path }

    /// Marks survive a relaunch: saved by path and identity, restored when
    /// the same objects are still there.
    fileprivate func persistMarks() {
        let entries: [[String: Any]] = tree.withLock {
            marks.compactMap { key, info in
                guard let i = resolve(key) else { return nil }
                return ["path": tree.path(of: i), "reason": info.reason, "dev": Int(info.dev), "ino": Int(info.ino)]
            }
        }
        UserDefaults.standard.set(entries, forKey: marksDefaultsKey)
    }

    fileprivate func restoreMarks() {
        guard let saved = UserDefaults.standard.array(forKey: marksDefaultsKey) as? [[String: Any]] else { return }
        for m in saved {
            guard let path = m["path"] as? String, let dev = m["dev"] as? Int, let ino = m["ino"] as? Int,
                  let ref = liveRef(path: path) else { continue }
            var st = stat()
            guard lstat(path, &st) == 0, Int(st.st_dev) == dev, Int(st.st_ino) == ino,
                  let key = tree.withLock({ markKey(for: ref) }) else { continue }
            marks[key] = MarkInfo(reason: m["reason"] as? String ?? "", dev: st.st_dev, ino: st.st_ino)
        }
        recomputeMarks()
        notifyListeners()
    }

    // MARK: Reclaim analysis

    /// Re-runs the Reclaim analysis when the tree settles and has changed.
    fileprivate func tickAnalysis(now: TimeInterval) {
        // A disk that never stops changing would keep this running forever,
        // so it waits ten times as long as the last pass took.
        guard phase == .live, !analyzing, version != analyzedVersion,
              now - lastAnalysis > max(3, analysisCost * 10), rescanBase == nil else { return }
        analyzing = true
        lastAnalysis = now
        let v = version
        let tree = tree
        Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            let result = await Task.detached(priority: .utility) {
                Reclaim.analyze(tree: tree, under: 0)
            }.value
            guard let self else { return }
            self.analysisCost = ProcessInfo.processInfo.systemUptime - start
            self.findings = result
            self.analyzedVersion = v
            self.analyzing = false
        }
    }
}

// MARK: - What changed

extension Session {
    /// Sizes of every folder in the top `depth` levels, descending only into
    /// folders big enough to matter. Returns the sizes and the folders whose
    /// children were all recorded.
    nonisolated static func sizes(_ tree: Tree, depth: Int) -> ([UInt32: Int64], Set<UInt32>) {
        tree.withLock {
            var out: [UInt32: Int64] = [0: tree.entry(0).size]
            var expanded = Set<UInt32>()
            var frontier: [UInt32] = [0]
            for _ in 0..<depth {
                var next: [UInt32] = []
                for d in frontier {
                    let dir = tree.dir(d)
                    expanded.insert(d)
                    for i in dir.first..<(dir.first + dir.count) {
                        let e = tree.entry(i)
                        guard e.isDir, !e.isRemoved else { continue }
                        out[e.aux] = e.size
                        if e.size > 50_000_000 { next.append(e.aux) }
                    }
                }
                frontier = next
            }
            return (out, expanded)
        }
    }

    /// Size change of a folder since the baseline, if it's big enough to
    /// mention (at least 100 MB and 5%).
    func growth(of dir: UInt32, now size: Int64) -> Int64? {
        guard let before = baseline[dir] else { return nil }
        let delta = size - before
        guard abs(delta) >= 100_000_000, abs(delta) * 20 >= max(before, 1) else { return nil }
        return delta
    }

    fileprivate func computeChanges() {
        let base = baseline
        let expanded = baselineExpanded
        let found: [Change] = tree.withLock {
            var deltas: [UInt32: Int64] = [:]
            for (d, before) in base where d < tree.raw.pointee.dir_count {
                let i = tree.dirEntry(d)
                guard tree.isLive(i) else { continue }
                let delta = tree.entry(i).size - before
                if abs(delta) >= 200_000_000 { deltas[d] = delta }
                // Big folders that didn't exist at the baseline are changes too.
                guard expanded.contains(d) else { continue }
                let dir = tree.dir(d)
                for k in dir.first..<(dir.first + dir.count) {
                    let c = tree.entry(k)
                    if c.isDir, !c.isRemoved, base[c.aux] == nil, c.size >= 200_000_000 { deltas[c.aux] = c.size }
                }
            }
            // Keep the deepest folder that explains most of a change: drop a
            // parent when one child accounts for 80% of its delta.
            var keep: [(UInt32, Int64)] = []
            for (d, delta) in deltas {
                let dir = tree.dir(d)
                var explained = false
                for k in dir.first..<(dir.first + dir.count) {
                    let e = tree.entry(k)
                    if e.isDir, let cd = deltas[e.aux], cd.signum() == delta.signum(), abs(cd) * 5 >= abs(delta) * 4 {
                        explained = true
                        break
                    }
                }
                if !explained && d != 0 { keep.append((d, delta)) }
            }
            return keep.sorted { abs($0.1) > abs($1.1) }.prefix(5).map { d, delta in
                let e = tree.entry(tree.dirEntry(d))
                return Change(dir: d, name: tree.name(of: e), path: tree.path(of: tree.dirEntry(d)), delta: delta)
            }
        }
        if found != changes { changes = found }
        let net = tree.withLock { tree.entry(0).size } - (base[0] ?? 0)
        if net != netChange { netChange = net }
    }
}
