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
///
/// Nothing here runs on a fixed beat. Each pass of `tick` works out when
/// something next needs doing (following a scan or refresh while one runs, a
/// paced refresh coming due, a save, a capacity check) and sets one timer
/// for that moment; with nothing due there's no timer at all. Whatever
/// starts work or changes what's due sets it again (`rearm`).
@MainActor
@Observable
final class Session: Identifiable {
    enum Phase: Equatable { case scanning, live }

    let id = UUID()
    let url: URL
    let title: String
    let isVolume: Bool
    @ObservationIgnored let tree: Tree

    private(set) var phase: Phase = .scanning {
        didSet { updateActivity() }
    }
    private(set) var stats = ScanStats()
    /// Bumps whenever tree contents change: at most about 4×/s while the
    /// session is on screen, at the `quietVersion` pace while it isn't.
    /// Views that show derived numbers read it to know when to recompute.
    private(set) var version = 0
    /// Like `version`, but for views that re-walk the whole tree: once live,
    /// it moves at most every `quietInterval`, which follows what those
    /// passes report costing, so a disk that never stops changing doesn't
    /// keep them busy.
    private(set) var quietVersion = 0
    @ObservationIgnored private var quietSource = 0
    @ObservationIgnored private var lastQuietBump: TimeInterval = 0
    @ObservationIgnored private var lastVersionBump: TimeInterval = 0
    /// The tree changed since `version` last moved.
    @ObservationIgnored private var versionPending = false
    /// The tree changed while off screen, and listeners haven't heard yet.
    @ObservationIgnored private var unshown = false
    /// The volume's size and space. `available` counts purgeable space as
    /// last measured exactly; see `checkCapacity`.
    private(set) var capacity: Capacity?
    @ObservationIgnored private var lastCapacityCheck: TimeInterval = -.infinity
    /// Available minus free at the last exact measurement.
    @ObservationIgnored private var purgeable: Int64?
    @ObservationIgnored private var lastExactCapacity: TimeInterval = -.infinity
    @ObservationIgnored private var measuringCapacity = false
    @ObservationIgnored private var measureCapacityAgain = false
    var focus: UInt32 = 0 {
        didSet { if focus != oldValue { lookedAt(dir: focus) } }
    }
    var selection: [ItemRef] = []
    var toast: Toast?
    private(set) var freedBytes: Int64 = 0
    private(set) var deletingSnapshots = false
    /// Scanning, but nothing has landed for a few seconds: usually threads
    /// parked on a macOS privacy prompt.
    private(set) var stalled = false
    @ObservationIgnored private var lastGrowth: TimeInterval = ProcessInfo.processInfo.systemUptime
    private(set) var trashedBytes: Int64 = 0
    /// What Silt moved to the Trash that's still there (space not yet back).
    @ObservationIgnored private var inTrash: [(url: URL, bytes: Int64)] = []
    private(set) var waitingInTrash: Int64 = 0
    @ObservationIgnored private var lastTrashCheck: TimeInterval = 0

    /// Whether a visible window shows this session. The window's model keeps
    /// it current; a session without a window counts as on screen. Off
    /// screen, the tree is kept current, but what only a viewer needs waits
    /// until it's back: version bumps, capacity and Reclaim, periodic saves,
    /// paced refreshes of busy folders.
    @ObservationIgnored var isOnScreen = true {
        didSet {
            guard isOnScreen != oldValue else { return }
            if isOnScreen { cameOnScreen() } else { rearm() }
        }
    }
    /// Whether the Reclaim pane is what's showing for this session: its
    /// analysis then runs as often as it can afford, instead of once a
    /// minute for the overview's chip.
    @ObservationIgnored var reclaimVisible = false {
        didSet { if reclaimVisible != oldValue { rearm() } }
    }
    @ObservationIgnored private(set) var recentQueryCost: TimeInterval = 0
    @ObservationIgnored private var queryCostReported = false

    /// Views that re-walk the tree on `quietVersion` report what a pass cost,
    /// so the pacing can follow it. The most expensive recent pass counts,
    /// fading as cheaper ones come in.
    func noteQueryCost(_ seconds: TimeInterval) {
        recentQueryCost = max(seconds, recentQueryCost * 0.7)
        queryCostReported = true
        rearm()
    }

    /// How long `quietVersion` waits between moves once live: ten times what
    /// a pass costs, at least a second. Until a view has reported a cost,
    /// a second per two million items.
    private var quietInterval: TimeInterval {
        queryCostReported ? max(1, recentQueryCost * 10) : max(1, Double(stats.items) / 2_000_000)
    }

    @ObservationIgnored private var timer: Timer?
    /// When `timer` fires, in system uptime.
    @ObservationIgnored private var timerFire: TimeInterval?
    @ObservationIgnored private var lastTick: TimeInterval = -.infinity
    @ObservationIgnored private var inTick = false
    /// Set a turn after `init`; see `start`.
    @ObservationIgnored private var started = false
    /// How many times the timer has fired, for tests.
    @ObservationIgnored private(set) var ticks = 0
    @ObservationIgnored private var lastGeneration: UInt64 = .max
    /// When `tick` last saw the tree change.
    @ObservationIgnored private var lastChange: TimeInterval = -.infinity
    /// Held while work someone waits on runs, so App Nap doesn't slow it.
    @ObservationIgnored private var busyActivity: NSObjectProtocol?
    /// The stream holds its watcher, so a session dropped without `close()`
    /// would leave it running: `deinit` stops it (hence reachable from there).
    @ObservationIgnored nonisolated(unsafe) private var watcher: FSWatcher?
    @ObservationIgnored nonisolated(unsafe) private var paceObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var rulesObserver: NSObjectProtocol?
    /// Per folder: how hot it runs. Each time it changes again soon after
    /// being listed, the wait before its next listing doubles (`paceGap`).
    @ObservationIgnored private var heat: [UInt32: Int] = [:]
    /// The replay of what changed while Silt wasn't watching has all been
    /// delivered; catching up ends once what it asked for is listed.
    @ObservationIgnored private var historyDelivered = false
    /// The pace factor `dueAt` deadlines were set under.
    @ObservationIgnored private var dueFactor: Double = 1
    /// Folders open on screen, per tree view (see `setShown`).
    @ObservationIgnored private var shown: [ObjectIdentifier: Set<UInt32>] = [:]
    @ObservationIgnored private var shownDirs: Set<UInt32> = []
    /// Folders under a Paused rule with changes waiting, and whether a deep
    /// check is among them.
    @ObservationIgnored private var pausedPending: [UInt32: Bool] = [:]
    /// The exclusions this tree was last given (absolute paths).
    @ObservationIgnored private var appliedExclusions: Set<String> = []
    /// Folders Silt updates less often because they change constantly, by
    /// folder: how often they're updated now.
    @ObservationIgnored private var busyEvery: [UInt32: TimeInterval] = [:]
    /// The same, for views.
    private(set) var busyFolders: [BusyFolder] = []

    struct BusyFolder: Identifiable, Equatable {
        let dir: UInt32
        let path: String
        let every: TimeInterval
        var id: UInt32 { dir }
    }
    @ObservationIgnored private var heldEvents: [FSWatcher.Event] = []
    @ObservationIgnored private var listeners: [ObjectIdentifier: () -> Void] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// Set by the tree view that currently owns the selection.
    @ObservationIgnored var quickLook: (() -> Void)?
    /// How the file tree was left under each folder it was rooted at, so
    /// switching locations, views or panes and coming back doesn't collapse
    /// everything.
    @ObservationIgnored var treeStates: [UInt32: TreeState] = [:]
    /// Called once the location is scanned (or caught up) and settled.
    @ObservationIgnored var onLive: (() -> Void)?
    /// Set by the tree view on screen: saves its state into `treeStates` now.
    @ObservationIgnored var captureTreeState: (() -> Void)?
    @ObservationIgnored private var reportedLive = false
    /// Called once if the tree is running out of entry indices (they're never
    /// reused, so a folder churning for days could get there): the window
    /// replaces this session with a fresh one.
    @ObservationIgnored var onNeedsRebuild: (() -> Void)?
    @ObservationIgnored private var askedForRebuild = false
    /// Called when a session that's off screen (and not the one showing)
    /// has settled enough to park, so the window can put it away without
    /// polling.
    @ObservationIgnored var onSettled: (() -> Void)?
    /// Called when the session is parked, woken, or stays awake after a
    /// failed park, so the window can plan its next park.
    @ObservationIgnored var onResidencyChange: (() -> Void)?

    /// When the scan being shown was saved, if it came from a snapshot.
    private(set) var restoredFrom: Date?
    /// Replaying file-system history since that snapshot (or since the
    /// location was parked).
    private(set) var catchingUp = false {
        didSet { updateActivity() }
    }
    /// Set while a snapshot FSEvents can't bring up to date (too old, or the
    /// volume's history was reset) is checked again in place: folders not
    /// listed since this moment (unix seconds) still show what it saw.
    private(set) var recheckingSince: UInt32? {
        didSet { updateActivity() }
    }
    /// What's on screen may be out of date: a restored scan that hasn't
    /// caught up yet.
    var showsSavedScan: Bool { catchingUp || recheckingSince != nil }

    /// Whether a folder's contents may still be what a saved scan saw. Until
    /// a catch-up ends, any folder might yet turn out to have changed.
    func isStale(_ d: silt_dir) -> Bool {
        catchingUp || recheckingSince.map { d.listed_at < $0 } ?? false
    }
    @ObservationIgnored private let fullDiskAccess: Bool
    /// Whether FSEvents history for this location survives relaunches (see
    /// `Snapshots.eligible`): it gets snapshots, and parks without a stream.
    @ObservationIgnored private let keepsHistory: Bool
    @ObservationIgnored private var lastEventId: FSEventStreamEventId = 0
    /// When the snapshot was last saved (or loaded), in system uptime.
    @ObservationIgnored private var lastSave: TimeInterval = ProcessInfo.processInfo.systemUptime
    @ObservationIgnored private var lastSaveAttempt: TimeInterval = -.infinity
    @ObservationIgnored private var failedSaves = 0
    /// A scan settled (or a saved one was fully rechecked): save it soon,
    /// whether or not it's on screen.
    @ObservationIgnored private var saveSoon = false
    @ObservationIgnored private var savedGeneration: UInt64 = 0
    @ObservationIgnored private var saving = false
    /// Saves started by closing sessions, which quitting waits for.
    nonisolated static let closingSaves = DispatchGroup()

    /// Rescan in progress, if any. The tree stays fully usable meanwhile.
    private(set) var rescanState: RescanState? {
        didSet { updateActivity() }
    }
    private struct RescanBase {
        let listed: UInt64
        var total: Int
        /// Someone is waiting on it: it's over when the urgent work is,
        /// whatever background refreshes are still coming in.
        var urgent: Bool
    }
    @ObservationIgnored private var rescanBase: RescanBase?
    /// When each folder's last deep check started, how long it took (until
    /// the rescan it was part of ended), and the folders the rescan under
    /// way is checking.
    @ObservationIgnored private var deepAt: [UInt32: TimeInterval] = [:]
    @ObservationIgnored private var deepCost: [UInt32: TimeInterval] = [:]
    @ObservationIgnored private var deepRunning: Set<UInt32> = []
    /// Deep checks held back until they're due (see `deepDue`), with the
    /// first event that asked for each.
    @ObservationIgnored private var deferredDeep: [UInt32: FSEventStreamEventId] = [:]
    /// Big folders that change constantly (build output, browser caches) are
    /// re-listed at a pace that scales with their size rather than on every
    /// event: when each was last listed, and when it's next due (with the
    /// first event it's due for).
    @ObservationIgnored private var listedAt: [UInt32: TimeInterval] = [:]
    @ObservationIgnored private var dueAt: [UInt32: (at: TimeInterval, event: FSEventStreamEventId)] = [:]
    @ObservationIgnored private var rootInode: UInt64 = 0
    @ObservationIgnored private var rootVolume: String?

    /// Whether the tree is in memory; see `park()`.
    enum Residency { case awake, parking, parked, waking }
    private(set) var residency: Residency = .awake {
        didSet {
            updateActivity()
            if residency != oldValue { onResidencyChange?() }
        }
    }
    var isAwake: Bool { residency == .awake }
    /// When this location was last on screen (nil while it is).
    @ObservationIgnored var hiddenSince: TimeInterval? {
        // Shown and hidden again while it was parking: it needn't wake after all.
        didSet { if hiddenSince != nil { wakeWhenParked = false } }
    }
    @ObservationIgnored fileprivate var wakeWhenParked = false {
        didSet { updateActivity() }
    }
    @ObservationIgnored fileprivate(set) var closed = false
    @ObservationIgnored fileprivate var parkedEvents: [String: FSWatcher.Event] = [:]
    @ObservationIgnored fileprivate var parkedOverflow = false
    @ObservationIgnored fileprivate var parkedMaxEventId: FSEventStreamEventId = 0
    @ObservationIgnored fileprivate var parkedSpecial: [FSWatcher.Event] = []
    /// Parked without its FSEvents stream: waking replays history instead.
    @ObservationIgnored fileprivate var streamStopped = false
    @ObservationIgnored fileprivate var parkedAt: Date?
    @ObservationIgnored fileprivate var parkedDatabase: [UInt8]?

    /// The location or folder this scan is being shown as.
    private(set) var viewPath: String = ""
    @ObservationIgnored fileprivate var viewFocus: [String: UInt32] = [:]
    @ObservationIgnored fileprivate var pendingFocus: String?
    @ObservationIgnored fileprivate var viewSizes: [String: Int64] = [:]

    /// Marked for cleanup, with an optional reason ("node_modules", "copy of …").
    private(set) var marks: [MarkKey: MarkInfo] = [:]
    /// Deduplicated total of everything marked (nested marks count once).
    private(set) var markedBytes: Int64 = 0
    private(set) var markedCount = 0
    @ObservationIgnored private var marksDirty = false
    @ObservationIgnored private var lastMarksRecompute: TimeInterval = 0
    @ObservationIgnored fileprivate var marksRestored = false
    /// Where each file mark was last found, and its folder's run then: while
    /// that run hasn't changed, the file is still at the same index.
    @ObservationIgnored fileprivate var markSpots: [MarkKey: MarkSpot] = [:]
    /// Marks changed since they were last written to the defaults.
    @ObservationIgnored fileprivate var marksUnsaved = false
    @ObservationIgnored fileprivate var lastMarksSave: TimeInterval = -.infinity

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

    /// Reclaim suggestions for the whole scan, shared by the Reclaim pane and
    /// the overview. `findings(under:)` narrows them to a view.
    private(set) var findings: [Finding] = []
    @ObservationIgnored private var scoped: (dir: UInt32, source: Int, findings: [Finding])?
    private(set) var analyzing = false
    @ObservationIgnored private var analyzedVersion = -1
    @ObservationIgnored private var lastAnalysis: TimeInterval = -.infinity
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
        keepsHistory = Snapshots.eligible(resolved)
        let restored = fresh ? nil : Snapshots.load(for: resolved, fullDiskAccess: fullDiskAccess)
        tree = restored.map { Tree(restored: $0.tree, path: resolved.path) } ?? Tree(path: resolved.path)
        // A restored tree is what's saved, until something changes it. A new
        // scan isn't saved at all: taken after it starts, the generation
        // could already be its last one (a small folder scans in a
        // millisecond), and the scan would never be saved.
        savedGeneration = restored == nil ? .max : tree.generation
        if guardPrivateFolders {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for sub in ["Library/Containers", "Library/Group Containers", "Library/Daemon Containers"] {
                silt_tree_guard(tree.raw, home + "/" + sub)
            }
        }
        // Before the first listing: an excluded folder must never be opened.
        applyExclusions(refresh: false)
        if let restored {
            // Show the saved scan now; FSEvents replays everything since.
            (baseline, baselineExpanded) = Session.sizes(tree, depth: 4)
            baselineDate = restored.savedAt
            // Loading used large temporary buffers; give those pages back.
            malloc_zone_pressure_relief(nil, 0)
            tree.startIdle()
            // The saved scan predates the current rules: drop what's now
            // excluded, scan what no longer is.
            applyExclusions(refresh: true, also: Set(staleExclusions()))
            restorePaused()
            phase = .live
            restoredFrom = restored.savedAt
            // Catching up is only as good as the replay behind it; without
            // one, the saved scan is shown while everything is checked again.
            if restored.replayable {
                lastEventId = restored.eventId
                startWatching(since: restored.eventId)
            }
            if restored.replayable, watcher?.running == true {
                catchingUp = true
                historyDelivered = false
                // A listing that stopped early may have missed changes no
                // replay will bring back.
                let incomplete = tree.withLock {
                    (0..<tree.raw.pointee.dir_count).filter { tree.dir($0).state & UInt32(SILT_DIR_INCOMPLETE) != 0 }
                }
                for dir in incomplete { tree.refresh(dir: dir, deep: true, urgent: catchUpUrgent) }
            } else {
                startWatching(since: nil)
                recheckingSince = UInt32(Date().timeIntervalSince1970)
                startRescan(0, explicit: false, urgent: catchUpUrgent)
            }
        } else {
            tree.startScan()
            startWatching(since: nil)
        }
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
        holdBusyActivity(true) // a scan, catch-up or recheck is starting; the first tick decides
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    /// The rest of starting up, a turn after `init`. SwiftUI can create a
    /// session while it builds a view (the window's model does, in its
    /// initializer), and every observed property read then becomes something
    /// that view is rebuilt for: so nothing that reads them runs until now.
    private func start() {
        guard !started, !closed else { return }
        started = true
        checkCapacity(now: ProcessInfo.processInfo.systemUptime, exact: true)
        paceObserver = NotificationCenter.default.addObserver(forName: .siltPaceChanged, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.rescaleDue()
                self.updateActivity()
                self.rearm()
            }
        }
        rulesObserver = NotificationCenter.default.addObserver(forName: .siltFolderRulesChanged, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.rulesChanged()
            }
        }
        updateActivity()
        rearm()
    }

    deinit {
        watcher?.stop()
        if let paceObserver { NotificationCenter.default.removeObserver(paceObserver) }
        if let rulesObserver { NotificationCenter.default.removeObserver(rulesObserver) }
    }

    /// Everything on screen jumps the queue: the focused folder and the
    /// folders open under it (those a tree view reports, and those it will
    /// reopen when it's shown again).
    private func lookedAtShown() {
        var dirs = shownDirs
        dirs.insert(focus)
        if let open = treeStates[focus]?.expanded { dirs.formUnion(open) }
        for d in dirs { lookedAt(dir: d) }
    }

    /// Whether catching up counts as work someone waits on (the speed
    /// setting decides; only Fast says yes).
    private var catchUpUrgent: Bool { SpeedController.shared.pace.catchUpUrgent }

    /// The user opened `dir` (expanded it, or focused on it). While Silt
    /// catches up in the background, a listing it still has coming jumps the
    /// queue, so what's on screen is current first.
    func lookedAt(dir: UInt32) {
        guard isAwake, phase == .live else { return }
        releasePaused(under: dir)
        let due: Bool = tree.withLock {
            guard dir < tree.raw.pointee.dir_count, tree.isLive(tree.dirEntry(dir)) else { return false }
            let d = tree.dir(dir)
            if d.state & UInt32(SILT_DIR_QUEUED) != 0 { return true }
            return catchingUp || recheckingSince.map { d.listed_at < $0 } ?? false
        }
        guard due else { return }
        tree.refresh(dir: dir, deep: false, urgent: true)
        rearm()
    }

    func close() {
        close(saving: false)
    }

    /// Ends this session. `saving` (a window closing): first bring its
    /// snapshot up to date, off the main thread; quitting waits for that.
    func close(saving: Bool) {
        guard !closed else { return }
        flushMarks()
        let save = saving && residency == .awake && keepsHistory && phase == .live && !showsSavedScan
            && tree.generation != savedGeneration
        closed = true
        if let paceObserver { NotificationCenter.default.removeObserver(paceObserver) }
        if let rulesObserver { NotificationCenter.default.removeObserver(rulesObserver) }
        paceObserver = nil
        rulesObserver = nil
        duplicates.cancel()
        cancelTimer()
        holdBusyActivity(false)
        watcher?.stop()
        watcher = nil
        switch residency {
        case .awake:
            guard save else {
                tree.stop()
                break
            }
            let tree = tree, url = url, eventId = safeEventId, fda = fullDiskAccess
            Session.closingSaves.enter()
            // Quitting waits for this, so it runs at the priority of that wait.
            DispatchQueue.global(qos: .userInitiated).async {
                Snapshots.save(tree, url: url, eventId: eventId, fullDiskAccess: fda)
                tree.stop()
                malloc_zone_pressure_relief(nil, 0)
                Session.closingSaves.leave()
            }
        case .parked: try? FileManager.default.removeItem(atPath: parkFile)
        case .parking, .waking: break // the worker cleans up when it's done
        }
    }

    // MARK: Live updates

    /// Called on every tick where the tree changed, while on screen.
    func addListener(_ owner: AnyObject, _ body: @escaping () -> Void) {
        listeners[ObjectIdentifier(owner)] = body
    }

    func removeListener(_ owner: AnyObject) {
        listeners.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// Deadlines this close count as met: a timer never fires early, but
    /// arithmetic on its fire date can land a hair short.
    private static let slack: TimeInterval = 0.002
    /// Least time between `version` bumps.
    private static let versionInterval: TimeInterval = 0.25

    /// Off screen, `version` still moves, but only at the pace of
    /// `quietVersion`: enough for what a sidebar shows of a hidden scan (the
    /// size of a folder shown from it), and too slow to cost much where it
    /// isn't seen. Listeners and `quietVersion` wait until it's back.
    private var hiddenVersionInterval: TimeInterval { max(1, quietInterval) }

    /// Does whatever is due, then sets the timer for the next thing.
    private func tick() {
        timer = nil
        timerFire = nil
        guard residency == .awake, !closed else { return }
        ticks += 1
        inTick = true
        defer { inTick = false }
        let now = ProcessInfo.processInfo.systemUptime
        lastTick = now
        let p = tree.progress
        let gen = tree.generation // read after the progress, so it includes every listing that's done
        let onScreen = isOnScreen

        var s = ScanStats()
        s.items = Int(p.files)
        s.bytes = Int64(p.bytes)
        s.folders = Int(p.dirs)
        s.denied = Int(p.denied)
        s.elapsed = p.elapsed.rounded(.down) // shown in whole seconds: finer would only redraw
        s.finished = p.finished
        s.queued = Int(p.queued)
        if s.items != stats.items || s.folders != stats.folders { lastGrowth = now }
        if s != stats { stats = s }
        let isStalled = phase == .scanning && s.queued > 0 && now - lastGrowth > 3
        if isStalled != stalled { stalled = isStalled }
        holdBusyActivity(p.urgent_queued > 0 || phase == .scanning)

        if phase == .scanning && p.idle && p.finished > 0 {
            phase = .live
            releaseHeldEvents()
            version += 1
            saveSoon = true // save the fresh scan as soon as it settles
            (baseline, baselineExpanded) = Session.sizes(tree, depth: 4)
            baselineDate = Date()
            malloc_zone_pressure_relief(nil, 0) // scan batches are done with
            if onScreen { checkCapacity(now: now, exact: true) }
            reportLive()
        }

        if gen != lastGeneration {
            lastGeneration = gen
            lastChange = now
            resolvePendingFocus()
            repairFocus()
            marksDirty = true
            unshown = true
            versionPending = true
            if !askedForRebuild, tree.raw.pointee.entry_count > 3_500_000_000 {
                askedForRebuild = true
                onNeedsRebuild?()
            }
        }
        if onScreen {
            if unshown {
                unshown = false
                notifyListeners()
            }
            if versionPending, now - lastVersionBump >= Self.versionInterval - Self.slack { bumpVersion(now) }
            if version != quietSource, phase == .scanning || now - lastQuietBump >= quietInterval - Self.slack {
                bumpQuiet(now)
            }
        } else if versionPending, now - lastVersionBump >= hiddenVersionInterval - Self.slack {
            bumpVersion(now)
        }

        tickRescan(p, now: now)
        tickCatchUp(p)
        if onScreen {
            releaseDueRefreshes(now: now)
            if marksDirty, now - lastMarksRecompute >= 0.5 - Self.slack { recomputeMarks() }
            tickAnalysis(now: now)
            if changesDue(p) {
                changesVersion = quietVersion
                computeChanges()
            }
            if now - lastCapacityCheck >= 3 - Self.slack { checkCapacity(now: now) }
            if !inTrash.isEmpty, now - lastTrashCheck >= 5 - Self.slack {
                lastTrashCheck = now
                recountTrash()
            }
        }
        if marksUnsaved, now - lastMarksSave >= 1 - Self.slack { persistMarks() }
        if phase == .live, !marksRestored, !showsSavedScan {
            marksRestored = true
            restoreMarks()
        }
        if let due = saveDue(p, onScreen: onScreen), due <= now + Self.slack {
            saveSnapshot(now: now, generation: gen)
        }
        updateActivity()
        schedule(p, now: now)
        noteIfSettled(p)
    }

    /// Sets the timer for whatever is due next, or clears it if nothing is.
    private func schedule(_ p: silt_progress, now: TimeInterval) {
        guard residency == .awake, !closed else { return cancelTimer() }
        let onScreen = isOnScreen
        var due = TimeInterval.infinity
        func at(_ t: TimeInterval) { due = min(due, t) }

        // Work under way: followed closely while someone waits on it or
        // watches the tree move, loosely otherwise, and never more than
        // twice a second off screen.
        // Upkeep held back (Paused): nothing of it moves, so it isn't followed.
        let held = p.paused || SpeedController.shared.pace.upkeepPaused && p.urgent_queued == 0
        if tree.generation != lastGeneration || (onScreen && now - lastChange < 0.5)
            || (!p.paused && (p.urgent_queued > 0 || phase == .scanning)) || (catchingUp && !held) {
            at(lastTick + (onScreen ? 1.0 / 12 : 0.5))
        } else if !held && (!p.idle || rescanBase != nil || recheckingSince != nil) {
            at(lastTick + (onScreen ? 0.25 : 0.5))
        }

        // Chores with deadlines.
        if onScreen {
            if let first = dueAt.values.lazy.map({ $0.at }).min() { at(first) }
            if let t = nextCooling { at(t) }
            if rescanBase == nil { for dir in deferredDeep.keys { at(deepDue(dir)) } }
            if versionPending { at(lastVersionBump + Self.versionInterval) }
            if version != quietSource { at(phase == .scanning ? now : lastQuietBump + quietInterval) }
            if marksDirty { at(lastMarksRecompute + 0.5) }
            if let t = analysisDue() { at(t) }
            if changesDue(p) { at(now) }
            at(lastCapacityCheck + 3)
            if !inTrash.isEmpty { at(lastTrashCheck + 5) }
        } else if versionPending {
            at(lastVersionBump + hiddenVersionInterval)
        }
        if marksUnsaved { at(lastMarksSave + 1) }
        if phase == .live, !marksRestored, !showsSavedScan { at(now) }
        if let t = saveDue(p, onScreen: onScreen) { at(t) }
        arm(due, now: now)
    }

    /// One one-shot timer, at `due` (now, if that's passed). A timer already
    /// set for no later than that stays: it'll look again when it fires.
    private func arm(_ due: TimeInterval, now: TimeInterval) {
        guard due < .infinity else { return cancelTimer() }
        let fire = max(due, now)
        if timer != nil, let armed = timerFire, armed <= fire + Self.slack { return }
        timer?.invalidate()
        let delay = fire - now
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = min(1, max(0.004, delay * 0.15))
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerFire = fire
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
        timerFire = nil
    }

    /// Sets the timer again after something started work or changed what's
    /// due. Inside a tick, the tick does that on its way out.
    private func rearm() {
        guard started, !inTick, residency == .awake, !closed else { return }
        schedule(tree.progress, now: ProcessInfo.processInfo.systemUptime)
    }

    /// When the timer next fires (system uptime), or nil if nothing is due.
    var nextTick: TimeInterval? { timerFire }

    /// How many busy folders are waiting for their paced refresh.
    var pacedRefreshes: Int { dueAt.count }
    /// When a paced refresh was last let through (system uptime), for tests.
    @ObservationIgnored private(set) var lastPacedRelease: TimeInterval?

    private func bumpVersion(_ now: TimeInterval) {
        version += 1
        lastVersionBump = now
        versionPending = false
    }

    private func bumpQuiet(_ now: TimeInterval) {
        quietSource = version
        lastQuietBump = now
        quietVersion += 1
    }

    /// After something the user did (a mark, a trash, a delete): show its
    /// effect now instead of on the next beat, in the views that follow
    /// `quietVersion` too. That restarts the quiet pacing, so no second
    /// quiet bump follows right behind; user actions are too rare for this
    /// to cost anything at rest.
    private func showChangesNow() {
        guard residency == .awake else { return }
        if isOnScreen {
            let now = ProcessInfo.processInfo.systemUptime
            bumpVersion(now)
            bumpQuiet(now)
        } else {
            versionPending = true
        }
        rearm()
    }

    /// Back on screen: show what changed meanwhile, and do what waited.
    private func cameOnScreen() {
        guard started else { return } // `start` does all this
        guard residency == .awake, !closed else { return } // waking: `wake` does this when it's done
        let now = ProcessInfo.processInfo.systemUptime
        releaseDueRefreshes(now: .infinity)
        releaseDeferredDeep(now: now)
        if unshown || versionPending || version != quietSource {
            unshown = false
            notifyListeners()
            bumpVersion(now)
            bumpQuiet(now)
        }
        if marksDirty { recomputeMarks() }
        if now - lastCapacityCheck >= 3 { checkCapacity(now: now) }
        rearm()
    }

    /// Keeps App Nap from slowing work someone is waiting on, and lets it
    /// back as soon as that's done.
    private func holdBusyActivity(_ busy: Bool) {
        if busy, busyActivity == nil {
            busyActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Scanning \(title)")
        } else if !busy, let activity = busyActivity {
            ProcessInfo.processInfo.endActivity(activity)
            busyActivity = nil
        }
    }

    /// Tells the window an off-screen session could park now.
    private func noteIfSettled(_ p: silt_progress? = nil) {
        guard !isOnScreen, hiddenSince != nil, let onSettled, canPark(p) else { return }
        onSettled()
    }

    // MARK: Snapshots

    /// When the snapshot should next be saved, if it should: soon after a
    /// scan settles (on screen or not), then at most every 30 minutes while
    /// on screen and changed (FSEvents replay covers the rest; quitting and
    /// closing save too). A save needs the scanner idle, so while it's busy
    /// this waits for the tick that sees it finish. Failures retry, further
    /// apart each time.
    private func saveDue(_ p: silt_progress, onScreen: Bool) -> TimeInterval? {
        guard keepsHistory, phase == .live, !showsSavedScan, !saving, residency == .awake, !closed, p.idle,
              tree.generation != savedGeneration else { return nil }
        let retry = lastSaveAttempt + min(1800, 5 * Double(1 << min(failedSaves, 9)))
        if saveSoon { return retry }
        guard onScreen else { return nil }
        return max(lastSave + 1800, retry)
    }

    private func saveSnapshot(now: TimeInterval, generation: UInt64) {
        saving = true
        lastSaveAttempt = now
        let tree = tree, url = url, eventId = safeEventId, fda = fullDiskAccess
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // A refresh may have started since the tick saw the scanner idle.
            // A tree with a listing pending can't be saved; that's not a
            // failure worth backing off for, just a save for the next idle.
            let idle = tree.progress.idle
            let ok = idle && Snapshots.save(tree, url: url, eventId: eventId, fullDiskAccess: fda)
            let unsettled = !ok && (!idle || tree.withLock { tree.dir(0).pending != 0 })
            malloc_zone_pressure_relief(nil, 0) // the save's buffers were big and short-lived
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.saving = false
                    if ok {
                        self.savedGeneration = generation
                        self.lastSave = ProcessInfo.processInfo.systemUptime
                        self.saveSoon = false
                        self.failedSaves = 0
                    } else if !unsettled {
                        self.failedSaves += 1
                    }
                    self.rearm()
                    self.noteIfSettled()
                }
            }
        }
    }

    /// The event id a save is current as of: the newest one applied, or just
    /// before the first change still waiting in a paced or deferred refresh,
    /// so that a relaunch replays it.
    private var safeEventId: FSEventStreamEventId {
        var id = lastEventId
        for w in dueAt.values where w.event > 0 { id = min(id, w.event - 1) }
        for e in deferredDeep.values where e > 0 { id = min(id, e - 1) }
        return id
    }

    /// At quit: save synchronously if anything changed since the last save.
    /// (A parked location relies on its last snapshot, which FSEvents can
    /// bring up to date; see `park`.)
    func saveSnapshotNow() {
        guard !closed, isAwake, keepsHistory, phase == .live, !showsSavedScan else { return }
        let generation = tree.generation
        guard generation != savedGeneration else { return }
        if Snapshots.save(tree, url: url, eventId: safeEventId, fullDiskAccess: fullDiskAccess) {
            savedGeneration = generation
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

    // MARK: File-system events

    private func startWatching(since: FSEventStreamEventId?) {
        watcher?.stop()
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

    /// Events from the stream (tests feed it directly).
    func handle(_ events: [FSWatcher.Event]) {
        guard !closed else { return } // one in flight when it closed
        // Parked (or on the way in or out): remember which folders changed,
        // once each, and catch up on waking.
        if residency != .awake {
            for e in events {
                parkedMaxEventId = max(parkedMaxEventId, e.id)
                // A remount, wrapped ids or the end of a replay needs its own
                // handling on waking, however many other changes pile up.
                if e.rootChanged || e.idsWrapped || e.historyDone { parkedSpecial.append(e) }
                guard !parkedOverflow else { continue }
                if let old = parkedEvents[e.path] {
                    parkedEvents[e.path] = FSWatcher.Event(path: e.path, flags: old.flags | e.flags, id: max(old.id, e.id))
                } else {
                    parkedEvents[e.path] = e
                }
            }
            if parkedEvents.count > 50_000 {
                parkedOverflow = true // cheaper to re-check everything on waking
                parkedEvents = [:]
            }
            return
        }
        // Changes that land mid-scan are applied once the scan settles, so the
        // scan never races its own refreshes.
        if phase == .scanning {
            heldEvents.append(contentsOf: events)
            return
        }
        // Live changes are background work. Replayed history is too, unless
        // the speed setting says catching up comes first (Fast).
        apply(events, urgent: catchingUp && !historyDelivered && catchUpUrgent)
        rearm()
    }

    private func releaseHeldEvents() {
        let events = heldEvents
        heldEvents = []
        apply(events, urgent: false)
    }

    private func apply(_ events: [FSWatcher.Event], urgent: Bool) {
        guard !events.isEmpty else { return }
        var targets: [UInt32: (deep: Bool, event: FSEventStreamEventId)] = [:]
        let root = url.path
        var rootEvent: FSEventStreamEventId?, wrapEvent: FSEventStreamEventId?
        for event in events {
            if event.id > lastEventId && event.id != UInt64(kFSEventStreamEventIdSinceNow) { lastEventId = event.id }
            if event.historyDone { historyDelivered = true } // `tickCatchUp` ends it
            if event.rootChanged, rootEvent == nil { rootEvent = event.id }
            if event.idsWrapped, wrapEvent == nil { wrapEvent = event.id }
        }
        if let rootEvent {
            // Usually a volume that unmounted and came back: same volume (by
            // UUID, since the device number can change) and same root inode.
            // Reattach and check the top level; anything else is a different
            // tree at this path, so revalidate all of it.
            var st = stat()
            let inode = lstat(root, &st) == 0 ? st.st_ino : 0
            let volume = Session.volumeUUID(url)
            let same = inode == rootInode && rootVolume != nil && volume == rootVolume
            startWatching(since: lastEventId)
            if same {
                tree.refresh(dir: 0, deep: false, urgent: urgent)
            } else {
                if inode != 0, volume != nil {
                    rootInode = inode
                    rootVolume = volume
                }
                requestDeep(0, event: rootEvent, urgent: urgent)
            }
        }
        if let wrapEvent { requestDeep(0, event: wrapEvent, urgent: urgent) }
        var sizes: [UInt32: UInt32] = [:]
        var ruled: [UInt32: FolderRule] = [:]
        var pausedChanged = false
        defer { if pausedChanged { persistPaused() } }
        let rules = FolderRules.shared
        tree.withLock {
            for event in events {
                if event.rootChanged || event.historyDone { continue }
                guard let dir = nearestListedDir(for: event.path, root: root) else { continue }
                let known = targets[dir]
                targets[dir] = ((known?.deep ?? false) || event.mustScanSubdirs, min(known?.event ?? .max, event.id))
                sizes[dir] = tree.dir(dir).count
                if let r = rules.rule(for: event.path)?.rule { ruled[dir] = r }
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (dir, t) in targets {
            switch ruled[dir] {
            case .excluded:
                continue // never opened (the engine refuses too)
            case .paused:
                let known = pausedPending[dir]
                pausedPending[dir] = (known ?? false) || t.deep
                if known != pausedPending[dir] { pausedChanged = true }
                continue
            default:
                break
            }
            if t.deep {
                requestDeep(dir, event: t.event, urgent: urgent)
            } else {
                refreshPaced(dir, children: sizes[dir] ?? 0, now: now, urgent: urgent, event: t.event, rule: ruled[dir])
            }
        }
    }

    /// How long `dir` waits between listings: by its size (40 µs a child,
    /// at most 5 s), and while it runs hot, 0.25 s doubled for each step of
    /// heat, at most 30 s (2 s while it's open on screen). Both stretch with
    /// the speed setting. A Slowly rule waits a minute.
    private func paceGap(_ dir: UInt32, children: UInt32, heat h: Int, rule: FolderRule?) -> TimeInterval {
        let factor = SpeedController.shared.pace.paceFactor
        if rule == .slow { return 60 * factor }
        let size = min(5, Double(children) * 40e-6)
        return max(size, hotGap(dir, heat: h)) * factor
    }

    /// The part of the wait that comes from running hot, before the speed
    /// setting stretches it.
    private func hotGap(_ dir: UInt32, heat h: Int) -> TimeInterval {
        guard h > 0 else { return 0 }
        let gap = min(30, 0.25 * pow(2, Double(h - 1)))
        return isOnScreen && shownDirs.contains(dir) ? min(gap, 2) : gap
    }

    /// The folders a tree view has open (its root included), so busy ones
    /// on screen keep updating every couple of seconds.
    func setShown(_ dirs: Set<UInt32>, by owner: ObjectIdentifier) {
        shown[owner] = dirs.isEmpty ? nil : dirs
        shownDirs = shown.values.reduce(into: Set()) { $0.formUnion($1) }
    }

    /// The speed setting changed how far waits stretch: deadlines already set
    /// move with it, so plugging in doesn't leave a two-minute wait behind.
    private func rescaleDue() {
        let factor = SpeedController.shared.pace.paceFactor
        guard factor != dueFactor else { return }
        let clock = ProcessInfo.processInfo.systemUptime
        for (dir, due) in dueAt {
            let last = listedAt[dir] ?? clock
            dueAt[dir] = (last + (due.at - last) * factor / dueFactor, due.event)
        }
        dueFactor = factor
    }

    /// Folders that wait this long between updates are shown as busy.
    static let busyAfter: TimeInterval = 4

    /// Re-lists `dir` now, or once its pace allows (`paceGap`). A folder
    /// that changes again within 2 s (or twice its wait) of being listed
    /// runs hotter, so a folder that never stops changing ends up listed
    /// every 30 s; one quiet for 10 s (or four times its wait) cools off at
    /// once. Small, quiet folders are never held back. A Live rule lists on
    /// every change.
    private func refreshPaced(_ dir: UInt32, children: UInt32, now: TimeInterval, urgent: Bool,
                              event: FSEventStreamEventId, rule: FolderRule? = nil) {
        if rule == .live {
            heat[dir] = nil
            noteBusy(dir, every: 0)
            listedAt[dir] = now
            dueAt[dir] = nil
            tree.refresh(dir: dir, deep: false, urgent: urgent)
            return
        }
        // Already waiting: that listing will cover this change too.
        guard dueAt[dir] == nil else { return }
        var h = heat[dir] ?? 0
        let last = listedAt[dir]
        if let last {
            let elapsed = now - last
            let gap = paceGap(dir, children: children, heat: h, rule: rule)
            if elapsed < max(2, 2 * gap) { h = min(8, h + 1) } else if elapsed > max(10, 4 * gap) { h = 0 }
        }
        heat[dir] = h == 0 ? nil : h
        let gap = paceGap(dir, children: children, heat: h, rule: rule)
        // Busy means it changes constantly, not that it's big or the pace slow.
        noteBusy(dir, every: rule != .slow && hotGap(dir, heat: h) >= Self.busyAfter ? gap : 0)
        dueFactor = SpeedController.shared.pace.paceFactor
        if gap < 0.1 {
            listedAt[dir] = now
            tree.refresh(dir: dir, deep: false, urgent: urgent)
            return
        }
        if let last, now - last < gap {
            dueAt[dir] = (last + gap, event)
            return
        }
        listedAt[dir] = now
        tree.refresh(dir: dir, deep: false, urgent: urgent)
    }

    /// Keeps `busyFolders` current: `dir` is updated every `every` seconds.
    private func noteBusy(_ dir: UInt32, every: TimeInterval) {
        let busy = every >= Self.busyAfter
        guard busy || busyEvery[dir] != nil else { return }
        if busy, let shown = busyEvery[dir], abs(shown - every) < 0.5 { return }
        busyEvery[dir] = busy ? every : nil
        publishBusy()
    }

    private func publishBusy() {
        let next: [BusyFolder] = tree.withLock {
            busyEvery.compactMap { dir, every in
                guard dir < tree.raw.pointee.dir_count, tree.isLive(tree.dirEntry(dir)) else { return nil }
                return BusyFolder(dir: dir, path: tree.path(of: tree.dirEntry(dir)), every: every)
            }
        }.sorted { $0.path < $1.path }
        if next != busyFolders { busyFolders = next }
    }

    /// Busy folders that have gone quiet: off the list, and cooled.
    private func coolQuietFolders(now: TimeInterval) {
        var changed = false
        for (dir, every) in busyEvery where now - (listedAt[dir] ?? 0) > max(10, 4 * every) && dueAt[dir] == nil {
            busyEvery[dir] = nil
            heat[dir] = nil
            changed = true
        }
        if changed { publishBusy() }
    }

    /// When the next busy folder may go quiet, for the timer.
    private var nextCooling: TimeInterval? {
        busyEvery.lazy.map { dir, every in (self.listedAt[dir] ?? 0) + max(10, 4 * every) }.min()
    }

    // MARK: Folder rules

    /// Lists the Paused folders inside `dir` (itself included) that have
    /// changes waiting.
    func releasePaused(under dir: UInt32) {
        guard !pausedPending.isEmpty else { return }
        let inside: [(UInt32, Bool)] = tree.withLock {
            pausedPending.filter { d, _ in
                var p = d
                while true {
                    if p == dir { return true }
                    guard p < tree.raw.pointee.dir_count, tree.isLive(tree.dirEntry(p)) else { return false }
                    let parent = tree.entry(tree.dirEntry(p)).parent
                    if parent == NONE { return false }
                    p = parent
                }
            }.map { ($0.key, $0.value) }
        }
        for (d, deep) in inside {
            pausedPending[d] = nil
            if deep { startRescan(d, explicit: false, urgent: true) } else { tree.refresh(dir: d, deep: false, urgent: true) }
        }
        if !inside.isEmpty {
            persistPaused()
            rearm()
        }
    }

    /// Paused folders with changes waiting are saved by path: a snapshot
    /// taken meanwhile is past those changes, so no replay would bring them
    /// back after a relaunch.
    private var pausedKey: String { "pausedPending:" + url.path }

    private func persistPaused() {
        guard keepsHistory else { return }
        if pausedPending.isEmpty {
            UserDefaults.standard.removeObject(forKey: pausedKey)
            return
        }
        let byPath: [String: Bool] = tree.withLock {
            var out: [String: Bool] = [:]
            for (d, deep) in pausedPending where d < tree.raw.pointee.dir_count && tree.isLive(tree.dirEntry(d)) {
                out[tree.path(of: tree.dirEntry(d))] = deep
            }
            return out
        }
        UserDefaults.standard.set(byPath, forKey: pausedKey)
    }

    private func restorePaused() {
        guard let saved = UserDefaults.standard.dictionary(forKey: pausedKey) as? [String: Bool] else { return }
        tree.withLock {
            for (path, deep) in saved {
                let i = tree.lookup(path)
                guard i != NONE, tree.isLive(i), tree.entry(i).isDir else { continue }
                pausedPending[tree.entry(i).aux] = deep
            }
        }
    }

    /// Whether a Paused folder at or inside `dir` has changes waiting.
    func hasPausedChanges(under dir: UInt32) -> Bool {
        guard !pausedPending.isEmpty else { return false }
        return tree.withLock {
            pausedPending.keys.contains { d in
                var p = d
                while true {
                    if p == dir { return true }
                    guard p < tree.raw.pointee.dir_count, tree.isLive(tree.dirEntry(p)) else { return false }
                    let parent = tree.entry(tree.dirEntry(p)).parent
                    if parent == NONE { return false }
                    p = parent
                }
            }
        }
    }

    /// The excluded folders inside this scan.
    private var exclusions: Set<String> {
        let root = url.path
        let prefix = root == "/" ? "/" : root + "/"
        return Set(FolderRules.shared.excluded.filter { $0.hasPrefix(prefix) && $0 != root })
    }

    /// Gives the tree the current exclusions. `refresh`: re-list the parent
    /// of every folder whose exclusion changed, so it's dropped or scanned.
    private func applyExclusions(refresh: Bool, also extra: Set<String> = []) {
        let next = exclusions
        let changed = next.symmetricDifference(appliedExclusions).union(extra)
        appliedExclusions = next
        let paths = Array(next)
        var cStrings = paths.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        cStrings.withUnsafeMutableBufferPointer { buf in
            buf.withMemoryRebound(to: UnsafePointer<CChar>?.self) {
                silt_tree_set_excluded(tree.raw, $0.baseAddress, UInt32(paths.count))
            }
        }
        guard refresh, !changed.isEmpty else { return }
        let parents: Set<UInt32> = tree.withLock {
            Set(changed.compactMap { path in
                let i = tree.lookup((path as NSString).deletingLastPathComponent)
                guard i != NONE, tree.isLive(i), tree.entry(i).isDir else { return nil }
                return tree.entry(i).aux
            })
        }
        for d in parents { tree.refresh(dir: d, deep: false, urgent: true) }
        rearm()
    }

    /// Rules changed while parked: applied on waking.
    @ObservationIgnored private var rulesPending = false

    /// Where a saved scan disagrees with the rules: folders it flags
    /// EXCLUDED that no rule excludes any more, and excluded folders it
    /// still holds the contents of.
    private func staleExclusions() -> [String] {
        let wanted = exclusions
        return tree.withLock {
            var out = [UInt32](repeating: 0, count: 256)
            let n = Int(silt_tree_excluded_dirs(tree.raw, &out, UInt32(out.count)))
            if n > out.count {
                out = [UInt32](repeating: 0, count: n)
                _ = silt_tree_excluded_dirs(tree.raw, &out, UInt32(n))
            }
            let flagged = out.prefix(n).map { tree.path(of: $0) }
            let unwanted = flagged.filter { !wanted.contains($0) }
            let unflagged = wanted.filter { path in
                let i = tree.lookup(path)
                return i != NONE && tree.isLive(i) && tree.entry(i).flags & UInt8(SILT_FLAG_EXCLUDED) == 0
            }
            return unwanted + unflagged
        }
    }

    private func rulesChanged() {
        guard isAwake else {
            rulesPending = true
            return
        }
        rulesPending = false
        applyExclusions(refresh: true)
        // Folders whose Paused rule went away: bring them up to date.
        let rules = FolderRules.shared
        let freed: [UInt32] = tree.withLock {
            pausedPending.keys.filter { d in
                guard d < tree.raw.pointee.dir_count, tree.isLive(tree.dirEntry(d)) else { return true }
                return rules.rule(for: tree.path(of: tree.dirEntry(d)))?.rule != .paused
            }
        }
        for d in freed { releasePaused(under: d) }
        // A folder now Live or Slowly starts over.
        for (dir, _) in busyEvery { heat[dir] = nil }
        busyEvery = [:]
        publishBusy()
        rearm()
    }

    /// Paced refreshes whose time has come (all of them, with `.infinity`).
    private func releaseDueRefreshes(now: TimeInterval) {
        let clock = ProcessInfo.processInfo.systemUptime
        if !dueAt.isEmpty {
            for (dir, due) in dueAt where due.at <= now + Self.slack {
                dueAt[dir] = nil
                lastPacedRelease = clock
                listedAt[dir] = clock
                tree.refresh(dir: dir, deep: false, urgent: false)
            }
        }
        // Forget folders that have gone quiet (busy ones keep their pace).
        if listedAt.count > 256 {
            listedAt = listedAt.filter { clock - $0.value < 10 || heat[$0.key] != nil || dueAt[$0.key] != nil }
            heat = heat.filter { listedAt[$0.key] != nil }
        }
        coolQuietFolders(now: clock)
    }

    /// FSEvents asks for a subtree revalidation when it coalesced or dropped
    /// events. On a busy disk that can arrive in bursts, and after every
    /// burst it drops, it asks for the whole volume. A folder whose check is
    /// still under way, or isn't due again yet, has the request deferred
    /// rather than a second walk laid over the first.
    private func requestDeep(_ dir: UInt32, event: FSEventStreamEventId, urgent: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if deepRunning.contains(dir) || now < deepDue(dir) {
            if deferredDeep[dir] == nil { deferredDeep[dir] = event }
            return
        }
        startRescan(dir, explicit: false, urgent: urgent)
    }

    /// When `dir` may be checked in depth again: 30 s after its last check
    /// started, and not until ten times what that check took has passed
    /// since it ended. Checking a whole disk takes minutes, and FSEvents can
    /// ask again sooner than that, so without the second limit the scanner
    /// would never rest.
    private func deepDue(_ dir: UInt32) -> TimeInterval {
        guard let start = deepAt[dir] else { return -.infinity }
        return start + max(30, (deepCost[dir] ?? 0) * 11) * SpeedController.shared.pace.paceFactor
    }

    /// Every folder the running deep checks cover has been listed since.
    private func deepChecksListed() -> Bool {
        guard !deepRunning.isEmpty else { return false }
        return tree.withLock {
            deepRunning.allSatisfy { d in
                d >= tree.raw.pointee.dir_count || !tree.isLive(tree.dirEntry(d)) || tree.dir(d).pending == 0
            }
        }
    }

    /// Deferred deep checks that are due.
    private func releaseDeferredDeep(now: TimeInterval) {
        guard !deferredDeep.isEmpty, rescanBase == nil else { return }
        for dir in deferredDeep.keys where now >= deepDue(dir) - Self.slack {
            startRescan(dir, explicit: false, urgent: false)
        }
    }

    /// Deep checks waiting until they're due, for tests.
    var deferredDeepChecks: Int { deferredDeep.count }

    /// How hot `dir` runs (see `refreshPaced`), for tests.
    func heat(of dir: UInt32) -> Int { heat[dir] ?? 0 }

    /// Lets every paced refresh through now, for tests.
    func releasePacedNow() { releaseDueRefreshes(now: .infinity) }

    /// Moves every folder's last listing `seconds` earlier, for tests.
    func backdatePacing(by seconds: TimeInterval) {
        for (dir, at) in listedAt { listedAt[dir] = at - seconds }
    }

    /// Moves every deep check's start `seconds` earlier, as if each had
    /// started (and taken) that much longer ago. For tests.
    func backdateDeepChecks(by seconds: TimeInterval) {
        for (dir, at) in deepAt { deepAt[dir] = at - seconds }
        rearm()
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
        // /var, /tmp and /etc are links into /private: FSEvents reports the
        // real path, the root may be the familiar one.
        if path.hasPrefix("/private/") && !root.hasPrefix("/private/") && root != "/" {
            path = String(path.dropFirst("/private".count))
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
        guard isAwake else { return }
        let dir = ref?.dir ?? 0
        guard dir != NONE else { return }
        startRescan(dir, explicit: true, urgent: true)
    }

    /// `urgent`: someone is waiting on it (a rescan they asked for, a saved
    /// scan being rechecked, a catch-up on screen); otherwise it's background
    /// work, like any other FSEvents refresh.
    private func startRescan(_ dir: UInt32, explicit: Bool, urgent: Bool) {
        let p = tree.progress
        let total = max(tree.withLock { Int(tree.dir(dir).items) }, 1)
        if rescanBase == nil || explicit || (urgent && rescanBase?.urgent == false) {
            rescanBase = RescanBase(listed: p.listed, total: total, urgent: urgent)
            rescanState = RescanState(fraction: 0, explicit: explicit || (rescanState?.explicit ?? false))
        } else {
            rescanBase?.total += total // joins the one under way: more for it to get through
        }
        // It covers whatever a deferred request for the folder was waiting on.
        deferredDeep[dir] = nil
        deepAt[dir] = ProcessInfo.processInfo.systemUptime
        deepRunning.insert(dir)
        tree.refresh(dir: dir, deep: true, urgent: urgent)
        if urgent { holdBusyActivity(true) }
        rearm()
    }

    /// Catching up ends when the replay has been delivered and everything it
    /// queued is listed; a recheck of a saved scan, when every folder has been
    /// listed since it began (whichever rescan did it).
    private func tickCatchUp(_ p: silt_progress) {
        guard catchingUp || recheckingSince != nil, p.urgent_queued == 0 else { return }
        let settled = p.idle || tree.withLock { tree.dir(0).pending == 0 }
        guard settled else { return }
        if catchingUp, historyDelivered {
            catchingUp = false
            lastGeneration = .max // rows drawn as out of date should look again
            reportLive()
        }
        if recheckingSince != nil, rescanBase == nil {
            // The saved scan is fully replaced, and worth saving again.
            recheckingSince = nil
            saveSoon = true
            lastGeneration = .max
            reportLive()
        }
    }

    private func tickRescan(_ p: silt_progress, now: TimeInterval) {
        if let base = rescanBase {
            // A rescan someone waits on ends with its urgent work (which
            // counts everything the refresh leads to), even while background
            // refreshes carry on.
            // A background one, when what it checks has all been listed: on a
            // busy disk the background queue itself may never empty.
            let done = base.urgent ? p.urgent_queued == 0 : p.idle || deepChecksListed()
            if done {
                for dir in deepRunning { deepCost[dir] = now - (deepAt[dir] ?? now) }
                deepRunning = []
                let wasExplicit = rescanState?.explicit ?? false
                rescanBase = nil
                rescanState = nil
                if wasExplicit {
                    // What it corrected must reach the snapshot: parking
                    // skips saving while the old one is still replayable.
                    saveSoon = true
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
        // Deferred background checks whose quiet period has passed; off
        // screen they wait until the session is back.
        if isOnScreen { releaseDeferredDeep(now: now) }
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
        for sub in ["Library", "Library/Caches", "Desktop", "Documents", "Downloads", "Applications", "Movies", "Music",
                    "Pictures", "Public", ".Trash"] {
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

    /// True for a mount point (or a firmlinked system folder): it's on a
    /// different volume from the folder holding it. Deleting one would empty
    /// the volume mounted there, so it's never a target. If its folder can't
    /// be read, it's treated as one.
    nonisolated static func isVolumeRoot(_ path: String) -> Bool {
        var st = stat()
        var up = stat()
        guard lstat(path, &st) == 0 else { return false }
        guard stat((path as NSString).deletingLastPathComponent, &up) == 0 else { return true }
        return st.st_dev != up.st_dev
    }

    enum Refusal { case protected, volume }

    private func targets(_ refs: [ItemRef]) -> (ok: [Target], refused: [(name: String, why: Refusal)]) {
        var ok: [Target] = []
        var refused: [(name: String, why: Refusal)] = []
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
                refused.append(((path as NSString).lastPathComponent, .protected))
                continue
            }
            if Self.isVolumeRoot(path) {
                refused.append(((path as NSString).lastPathComponent, .volume))
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

    /// `note`: what was left out of `items`, for the result's toast.
    private func recycle(_ items: [Target], note: String? = nil) {
        guard !items.isEmpty else { return }
        NSWorkspace.shared.recycle(items.map(\.url)) { [weak self] trashed, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishTrash(items, trashed: trashed, error: error, note: note)
                }
            }
        }
    }

    private func finishTrash(_ items: [Target], trashed: [URL: URL], error: Error?, note: String?) {
        let done = items.filter { trashed[$0.url] != nil }
        for t in done { tree.remove(entry: t.entry) }
        refreshParents(of: items)
        selection = []
        if !done.isEmpty, isAwake {
            showChangesNow()
            checkCapacity(now: ProcessInfo.processInfo.systemUptime, exact: true)
        }
        let bytes = done.reduce(Int64(0)) { $0 + $1.size }
        trashedBytes += bytes
        if done.isEmpty {
            let why = error?.localizedDescription ?? "macOS didn’t say why."
            show(Toast(symbol: "exclamationmark.triangle", title: "Couldn’t move to Trash",
                       detail: [why, note].compactMap { $0 }.joined(separator: " ")), seconds: note == nil ? 4 : 8)
        } else {
            let what = done.count == 1 ? done[0].url.lastPathComponent : "\(done.count) items"
            let moves = done.compactMap { t in trashed[t.url].map { (from: $0, to: t.url) } }
            for t in done { if let u = trashed[t.url] { inTrash.append((u, t.size)) } }
            recountTrash()
            let failed = items.count - done.count
            let failure = failed == 0 ? nil
                : "\(failed) couldn’t be moved" + (error.map { ": \($0.localizedDescription)" } ?? ".")
            show(Toast(symbol: failed == 0 ? "trash" : "exclamationmark.triangle", title: "Moved \(what) to the Trash",
                       detail: (["\(Fmt.bytes(bytes)) comes back when you empty the Trash."] + [failure, note].compactMap { $0 })
                           .joined(separator: " "),
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
            guard r == .alertFirstButtonReturn, let url = self?.url else { return }
            let estimate = self?.capacity?.available ?? 0
            DispatchQueue.global(qos: .userInitiated).async {
                // Exact figures on both sides (they're slow, so not on the
                // main thread): the estimate between checks could be off.
                let before = Locations.volumeCapacity(for: url)?.available ?? estimate
                var error: NSDictionary?
                NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
                let message = error?[NSAppleScript.errorMessage] as? String
                let after = Locations.volumeCapacity(for: url)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let after { self.adoptExactCapacity(after) }
                        self.recountTrash()
                        if let message {
                            self.show(Toast(symbol: "exclamationmark.triangle", title: "Couldn’t empty the Trash", detail: message))
                        } else {
                            let gained = (after?.available ?? before) - before
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
        // The user is waiting to see these come back.
        for d in dirs { tree.refresh(dir: d, deep: false, urgent: true) }
        rearm()
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
        // A folder left out of the scan has no size Silt knows.
        let unscanned = tree.withLock { items.filter { tree.entry($0.entry).flags & UInt8(SILT_FLAG_EXCLUDED) != 0 }.count }
        alert.informativeText = unscanned > 0
            ? "It can’t be undone. Silt doesn’t scan \(unscanned == items.count ? (items.count == 1 ? "it" : "them") : "\(unscanned) of them"), so how much this frees isn’t known."
            : "This frees \(Fmt.bytes(bytes)) right away and can’t be undone."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performDelete(items)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    /// `note`: what was left out of `confirmed`, for the result's toast.
    private func performDelete(_ confirmed: [Target], note: String? = nil) {
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
        showChangesNow()
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
                self.checkCapacity(now: ProcessInfo.processInfo.systemUptime, exact: true)
                if let first = failed.first {
                    let title = failed.count == 1 ? "Couldn’t delete \(first.key.lastPathComponent)"
                        : "Couldn’t delete \(failed.count) of \(items.count) items"
                    let freed = done.isEmpty ? nil : "Freed \(Fmt.bytes(bytes))."
                    let why = failed.count == 1 ? first.value : "\(first.key.lastPathComponent): \(first.value)"
                    self.show(Toast(symbol: "exclamationmark.triangle", title: title,
                                    detail: [freed, why, note].compactMap { $0 }.joined(separator: " ")), seconds: 8)
                } else {
                    self.show(Toast(symbol: "checkmark.circle", title: "Freed \(Fmt.bytes(bytes))", detail: note),
                              seconds: note == nil ? 4 : 8)
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
        let volume = "It’s another volume mounted there, so it was left alone."
        guard !isVolumeRoot(path) else { return volume }
        let parked = t.url.deletingLastPathComponent()
            .appendingPathComponent(".silt-deleting-\(UUID().uuidString)").path
        guard rename(path, parked) == 0 else { return String(cString: strerror(errno)) }
        guard !isVolumeRoot(parked) else {
            _ = renamex_np(parked, path, UInt32(RENAME_EXCL))
            return volume
        }
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
        guard isAwake else { return } // parked since: its events will catch it up
        var dirs = Set<UInt32>()
        tree.withLock {
            for t in items { dirs.insert(tree.entry(t.entry).parent) }
        }
        // Urgent: these reconcile what the user just did.
        for d in dirs where d != NONE { tree.refresh(dir: d, deep: false, urgent: true) }
        rearm()
    }

    private func refuse(_ refused: [(name: String, why: Refusal)]) {
        let detail = refused.allSatisfy({ $0.why == .volume })
            ? "It’s another volume mounted there. Eject it instead."
            : refused.allSatisfy({ $0.why == .protected })
            ? "It’s a system or home folder location."
            : "They’re system or home folder locations, or other volumes."
        show(Toast(symbol: "hand.raised",
                   title: "Silt won’t delete \(refused.map(\.name).joined(separator: ", "))", detail: detail))
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

    /// The findings inside folder `dir` (a view such as Home inside the
    /// Macintosh HD scan), with their sizes recounted.
    func findings(under dir: UInt32) -> [Finding] {
        guard dir != 0, isAwake else { return findings }
        let source = analyzedVersion
        if let s = scoped, s.dir == dir, s.source == source { return s.findings }
        let result: [Finding] = tree.withLock {
            findings.compactMap { f in
                let inside = f.entries.filter { i in
                    guard tree.isLive(i) else { return false }
                    var p = tree.entry(i).parent
                    if tree.entry(i).isDir && tree.entry(i).aux == dir { return true }
                    while p != NONE {
                        if p == dir { return true }
                        p = tree.entry(tree.dirEntry(p)).parent
                    }
                    return false
                }
                guard !inside.isEmpty else { return nil }
                var g = Finding(id: f.id, title: f.title, detail: f.detail, symbol: f.symbol, safety: f.safety,
                                entries: inside, bytes: inside.reduce(Int64(0)) { $0 + tree.entry($1).size })
                g.isTrash = f.isTrash
                return g
            }
        }
        scoped = (dir, source, result)
        return result
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

    /// Stored, and only moved when its label changes or its fraction moves
    /// by a quarter of a percent, so what draws it doesn't redraw every tick.
    private(set) var activity: Activity?

    private func updateActivity() {
        guard started else { return } // see `start`
        let next = currentActivity
        guard next != activity else { return }
        if let next, let shown = activity, next.label == shown.label, let a = next.fraction, let b = shown.fraction,
           abs(a - b) < 0.0025 { return }
        activity = next
    }

    private var currentActivity: Activity? {
        if residency == .waking || (residency == .parking && wakeWhenParked) {
            return Activity(fraction: nil, label: "Loading")
        }
        if SpeedController.shared.pace.upkeepPaused, phase == .live,
           catchingUp || recheckingSince != nil || rescanState.map({ !$0.explicit }) == true {
            return Activity(fraction: rescanState?.fraction, label: "Paused")
        }
        switch phase {
        case .scanning:
            guard let est = scanEstimate, est > 0 else { return Activity(fraction: nil, label: "Scanning") }
            return Activity(fraction: min(0.99, Double(stats.items) / Double(est)), label: "Scanning")
        case .live:
            if let r = rescanState {
                return Activity(fraction: r.fraction, label: r.explicit ? "Rescanning"
                                : recheckingSince != nil ? "Rechecking the saved scan" : "Checking for changes")
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

    /// Refreshes `capacity`: total and free from statfs (microseconds);
    /// the purgeable share behind `available` is measured exactly off the
    /// main thread at most once a minute, or right away with `exact` (after
    /// a trash, a delete or Empty Trash), and estimated in between.
    private func checkCapacity(now: TimeInterval, exact: Bool = false) {
        lastCapacityCheck = now
        if let quick = Locations.quickCapacity(for: url.path) {
            let available = min(quick.total, max(0, quick.free + (purgeable ?? 0)))
            let next = Capacity(total: quick.total, available: available, free: quick.free)
            if capacity.map({ $0.differsVisibly(from: next) }) ?? true { capacity = next }
        }
        measureHidden(now: now)
        if exact || now - lastExactCapacity >= 60 { measureCapacity(now: now) }
    }

    private func measureCapacity(now: TimeInterval) {
        guard !measuringCapacity else {
            measureCapacityAgain = true // what's under way may predate the change
            return
        }
        measuringCapacity = true
        lastExactCapacity = now
        let url = url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let exact = Locations.volumeCapacity(for: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.measuringCapacity = false
                    if let exact { self.adoptExactCapacity(exact) }
                    if self.measureCapacityAgain, !self.closed {
                        self.measureCapacityAgain = false
                        self.measureCapacity(now: ProcessInfo.processInfo.systemUptime)
                    }
                }
            }
        }
    }

    private func adoptExactCapacity(_ exact: Capacity) {
        purgeable = exact.available - exact.free
        if exact != capacity { capacity = exact }
        measureHidden(now: ProcessInfo.processInfo.systemUptime)
    }

    /// Re-measures the hidden space; local snapshots are listed every few
    /// minutes, off the main thread. Only on screen: it's redone when the
    /// session comes back.
    fileprivate func measureHidden(now: TimeInterval) {
        guard isVolume, phase == .live, let capacity else {
            if hidden != nil { hidden = nil }
            return
        }
        guard isOnScreen, residency == .awake else { return }
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
                                       unreadable: stats.denied, excluded: appliedExclusions.count, snapshots: snapshots)
        if next != hidden { hidden = next }
    }

    /// Deletes the volume's local Time Machine snapshots, after asking.
    func deleteLocalSnapshots(window: NSWindow?) {
        guard !snapshots.isEmpty, !deletingSnapshots else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        // No count: the list may have changed since it was last read. The
        // result says how many went.
        alert.messageText = "Delete this volume’s local snapshots?"
        alert.informativeText = "Time Machine’s restore points on this Mac are removed for good. Backups on your backup disk aren’t touched, but if you’ve been away from it, these may be the only copies of recent changes."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .alertFirstButtonReturn, let url = self?.url else { return }
            self?.deletingSnapshots = true
            DispatchQueue.global(qos: .userInitiated).async {
                // Snapshot space already counts as available (it's
                // purgeable): what deleting them changes is free space.
                let before = Locations.volumeCapacity(for: url)?.free
                let result = LocalSnapshots.deleteAll(on: url.path)
                let after = Locations.volumeCapacity(for: url)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.deletingSnapshots = false
                        self.lastSnapshotCheck = -.infinity // list them again
                        if let after { self.adoptExactCapacity(after) }
                        else { self.measureHidden(now: ProcessInfo.processInfo.systemUptime) }
                        let gained = max(0, (after?.free ?? 0) - (before ?? after?.free ?? 0))
                        self.freedBytes += gained
                        let n = result.deleted
                        let deleted = n == 1 ? "1 local snapshot" : "\(n) local snapshots"
                        let freed = gained > 0 ? "\(Fmt.bytes(gained)) freed." : nil
                        if let problem = result.problem {
                            self.show(Toast(symbol: "exclamationmark.triangle",
                                            title: n == 0 ? "Couldn’t delete the snapshots"
                                                : "Deleted \(n) of \(n + result.remaining) local snapshots",
                                            detail: [freed, problem].compactMap { $0 }.joined(separator: " ")), seconds: 8)
                        } else {
                            self.show(Toast(symbol: "checkmark.circle",
                                            title: n == 0 ? "No local snapshots were left to delete" : "Deleted \(deleted)",
                                            detail: freed))
                        }
                    }
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
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

    /// Where a file mark was found, and its folder's run at the time.
    struct MarkSpot {
        let entry: UInt32 // NONE: it wasn't there
        let first: UInt32
        let count: UInt32
        let version: UInt32
    }

    /// Lock held. `resolve`, remembering where file marks were found: a
    /// folder whose run hasn't changed (same place, size and version) still
    /// has each file at the same index, so it needn't be searched again.
    fileprivate func resolveCached(_ key: MarkKey) -> UInt32? {
        guard case .file(let parent, _) = key else { return resolve(key) }
        guard parent < tree.raw.pointee.dir_count, tree.isLive(tree.dirEntry(parent)) else {
            markSpots[key] = nil
            return nil
        }
        let d = tree.dir(parent)
        if let spot = markSpots[key], spot.first == d.first, spot.count == d.count, spot.version == d.version {
            guard spot.entry != NONE, !tree.entry(spot.entry).isRemoved else { return nil }
            return spot.entry
        }
        let found = resolve(key)
        markSpots[key] = MarkSpot(entry: found ?? NONE, first: d.first, count: d.count, version: d.version)
        return found
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
        return tree.withLock { Set(marks.keys.compactMap { resolveCached($0).map { tree.path(of: $0) } }) }
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
        /// Set for a duplicate copy: cleanup holds it to the file that was
        /// compared and removes it only while another copy survives.
        var copy: CopyCheck? = nil
        /// Its size and the time it was marked, so the review can point out a
        /// folder that has grown since (marks from before these were kept
        /// have neither).
        var size: Int64? = nil
        var at: Date? = nil
    }

    /// A duplicate copy as it was compared, and the other copies of its
    /// contents as they were then.
    struct CopyCheck {
        struct Other {
            let path: String
            let stamp: FileStamp
        }
        let stamp: FileStamp
        let others: [Other]

        init(_ c: DuplicateSet.Copy, in set: DuplicateSet) {
            stamp = c.stamp
            others = set.copies.filter { $0.path != c.path }.map { Other(path: $0.path, stamp: $0.stamp) }
        }

        init(stamp: FileStamp, others: [Other]) {
            self.stamp = stamp
            self.others = others
        }
    }

    /// Identity and size of what each ref is right now, for new marks.
    private func captureMarks(_ refs: [ItemRef], reason: String) -> [(MarkKey, MarkInfo)] {
        let resolved: [(MarkKey, String, Int64)] = tree.withLock {
            refs.compactMap { r in
                guard let k = markKey(for: r) else { return nil }
                let i = entryIndex(r)
                return (k, tree.path(of: i), tree.entry(i).size)
            }
        }
        let now = Date()
        return resolved.compactMap { k, path, size in
            var st = stat()
            guard lstat(path, &st) == 0 else { return nil }
            return (k, MarkInfo(reason: reason, dev: st.st_dev, ino: st.st_ino, size: size, at: now))
        }
    }

    /// Adds or removes `refs`; if every one is already marked, unmarks them.
    func toggleMarks(_ refs: [ItemRef], reason: String? = nil) {
        guard isAwake else { return }
        let keys = tree.withLock { refs.compactMap { markKey(for: $0) } }
        guard !keys.isEmpty else { return }
        if keys.allSatisfy({ marks[$0] != nil }) {
            for k in keys { marks.removeValue(forKey: k) }
        } else {
            for (k, info) in captureMarks(refs, reason: reason ?? "") where marks[k] == nil { marks[k] = info }
        }
        marksChanged()
    }

    func mark(_ refs: [ItemRef], reason: String) {
        guard isAwake, !refs.isEmpty else { return } // e.g. a search that finished after parking
        for (k, info) in captureMarks(refs, reason: reason) where marks[k] == nil { marks[k] = info }
        marksChanged()
    }

    func mark(entries: [UInt32], reason: String) {
        guard isAwake else { return }
        mark(tree.withLock { entries.filter { tree.isLive($0) }.map { ref(forEntry: $0) } }, reason: reason)
    }

    /// Marks duplicate copies of `sets` by the identity they were checked
    /// against (`DuplicateFinder.extraCopies`), without looking each up on
    /// disk again.
    func mark(copies: [DuplicateSet.Copy], of sets: [DuplicateSet], reason: String) {
        guard isAwake, !copies.isEmpty else { return }
        var setOf: [String: DuplicateSet] = [:]
        for s in sets { for c in s.copies { setOf[c.path] = s } }
        let found: [(MarkKey, DuplicateSet.Copy, Int64)] = tree.withLock {
            copies.compactMap { c in
                let i = tree.lookup(c.path)
                guard i != NONE, tree.isLive(i), let k = markKey(for: ref(forEntry: i)) else { return nil }
                return (k, c, tree.entry(i).size)
            }
        }
        let now = Date()
        for (k, c, size) in found where marks[k] == nil {
            guard let set = setOf[c.path] else { continue }
            marks[k] = MarkInfo(reason: reason, dev: c.stamp.dev, ino: c.stamp.ino, copy: CopyCheck(c, in: set),
                                size: size, at: now)
        }
        marksChanged()
    }

    /// Marks or unmarks one copy of `set`. A copy that changed since the
    /// search isn't marked. Returns false if it wasn't marked for that reason.
    @discardableResult
    func toggleMark(copy c: DuplicateSet.Copy, of set: DuplicateSet, reason: String) -> Bool {
        guard isAwake, let ref = liveRef(path: c.path),
              let k = tree.withLock({ markKey(for: ref) }) else { return true }
        if marks[k] != nil {
            marks.removeValue(forKey: k)
        } else {
            guard FileStamp(path: c.path) == c.stamp else { return false }
            let size = tree.withLock { tree.entry(entryIndex(ref)).size }
            marks[k] = MarkInfo(reason: reason, dev: c.stamp.dev, ino: c.stamp.ino, copy: CopyCheck(c, in: set),
                                size: size, at: Date())
        }
        marksChanged()
        return true
    }

    func unmark(_ keys: [MarkKey]) {
        guard isAwake else { return }
        for k in keys { marks.removeValue(forKey: k) }
        marksChanged()
    }

    func clearMarks() {
        guard isAwake else { return }
        marks = [:]
        marksChanged()
    }

    private func marksChanged() {
        recomputeMarks()
        notifyListeners()
        persistMarksSoon()
        showChangesNow()
    }

    struct MarkedItem: Identifiable {
        let key: MarkKey
        let entry: UInt32
        let path: String
        let size: Int64
        let isDir: Bool
        let reason: String
        /// Size and time when marked, if known.
        var markedSize: Int64? = nil
        var markedAt: Date? = nil
        var id: MarkKey { key }

        /// Noticeably bigger than when it was marked: a folder that has
        /// filled with new things since, which the user may not want gone.
        var grew: Bool {
            guard let before = markedSize else { return false }
            return size - before >= max(1_000_000, before / 10)
        }
    }

    /// Lock held. Live marks with their entries, minus anything inside
    /// another marked folder (it goes with its parent).
    private func liveMarks() -> [(MarkKey, UInt32)] {
        var live: [(MarkKey, UInt32)] = []
        var markedDirs = Set<UInt32>()
        for key in marks.keys {
            guard let i = resolveCached(key) else { continue }
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
                                  reason: marks[key]?.reason ?? "", markedSize: marks[key]?.size,
                                  markedAt: marks[key]?.at)
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

    /// The running total. Cheap (no paths, no sorting, no disk access, and
    /// file marks found again only in folders whose run changed); while the
    /// tree churns, `tick` runs it at most every half second.
    func recomputeMarks() {
        lastMarksRecompute = ProcessInfo.processInfo.systemUptime
        marksDirty = false
        if markSpots.count > marks.count * 2 + 64 { markSpots = markSpots.filter { marks[$0.key] != nil } }
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
        var expected: [String: MarkInfo] = [:]
        for item in items {
            if let m = marks[item.key] { expected[item.path] = m }
        }
        let refs = tree.withLock { items.map { ref(forEntry: $0.entry) } }
        marks = [:]
        marksChanged()
        let (all, refused) = targets(refs)
        var ok = all.filter { t in
            guard let e = expected[t.url.path], e.dev == t.identity.dev, e.ino == t.identity.ino, t.unchanged
            else { return false }
            // A duplicate must still be exactly the file that was compared.
            return e.copy.map { FileStamp(path: t.url.path) == $0.stamp } ?? true
        }
        let changed = all.count - ok.count
        let kept = Self.keepLastCopies(&ok) { expected[$0.url.path]?.copy }
        // One summary at the end: a toast now would be replaced by the result.
        var notes: [String] = []
        if !refused.isEmpty {
            notes.append("Silt won’t delete \(refused.map(\.name).joined(separator: ", ")): "
                + (refused.allSatisfy({ $0.why == .volume }) ? "another volume is mounted there."
                    : "it’s a system or home folder location, or another volume."))
        }
        if changed > 0 {
            notes.append(changed == 1 ? "1 item changed since it was marked and was left alone."
                                      : "\(changed) items changed since they were marked and were left alone.")
        }
        if kept > 0 {
            notes.append(kept == 1 ? "1 copy was kept: it’s the last of its contents."
                                   : "\(kept) copies were kept: they’re the last of their contents.")
        }
        let note = notes.isEmpty ? nil : notes.joined(separator: " ")
        if ok.isEmpty {
            if let note { show(Toast(symbol: "exclamationmark.triangle", title: "Nothing was removed", detail: note)) }
            return
        }
        switch method {
        case .trash: recycle(ok, note: note)
        case .delete: performDelete(ok, note: note)
        }
    }

    /// Drops from `targets` any duplicate copy whose contents would leave
    /// with it: each one goes only while another copy stays, unchanged since
    /// the search and not inside anything else going. Copies are taken in
    /// order, so of copies marked together, one is kept. Returns how many
    /// were kept. Reads the disk.
    fileprivate static func keepLastCopies(_ targets: inout [Target], check: (Target) -> CopyCheck?) -> Int {
        var going = Set(targets.map(\.url.path))
        func isGoing(_ path: String) -> Bool {
            var p = path
            while p.count > 1 {
                if going.contains(p) { return true }
                p = (p as NSString).deletingLastPathComponent
            }
            return false
        }
        var kept = 0
        targets = targets.filter { t in
            guard let c = check(t) else { return true }
            let survivor = c.others.contains { !isGoing($0.path) && FileStamp(path: $0.path) == $0.stamp }
            if !survivor {
                going.remove(t.url.path)
                kept += 1
            }
            return survivor
        }
        return kept
    }

    // MARK: Persisted marks

    fileprivate var marksDefaultsKey: String { "marks:" + url.path }

    /// Marks survive a relaunch: saved by path and identity, restored when
    /// the same objects are still there. Written at once, unless the last
    /// write was under a second ago: then `tick` writes them when that's up
    /// (and parking, closing and quitting flush them).
    fileprivate func persistMarksSoon() {
        marksUnsaved = true
        if ProcessInfo.processInfo.systemUptime - lastMarksSave >= 1 { persistMarks() } else { rearm() }
    }

    /// Writes marks that are waiting to be saved.
    func flushMarks() {
        if marksUnsaved { persistMarks() }
    }

    fileprivate func persistMarks() {
        // A parked tree resolves nothing; what's saved stays as it is.
        guard isAwake else { return }
        marksUnsaved = false
        lastMarksSave = ProcessInfo.processInfo.systemUptime
        let entries: [[String: Any]] = tree.withLock {
            marks.compactMap { key, info in
                guard let i = resolveCached(key) else { return nil }
                var m: [String: Any] = ["path": tree.path(of: i), "reason": info.reason,
                                        "dev": Int(info.dev), "ino": Int(info.ino)]
                if let size = info.size { m["size"] = Int(size) }
                if let at = info.at { m["at"] = at.timeIntervalSince1970 }
                if let c = info.copy {
                    m["stamp"] = c.stamp.saved
                    m["others"] = c.others.map { ["path": $0.path, "stamp": $0.stamp.saved] }
                }
                return m
            }
        }
        UserDefaults.standard.set(entries, forKey: marksDefaultsKey)
    }

    fileprivate func restoreMarks() {
        guard let saved = UserDefaults.standard.array(forKey: marksDefaultsKey) as? [[String: Any]] else { return }
        importMarks(saved)
    }

    /// Marks saved as paths plus the exact file each was made on.
    fileprivate func importMarks(_ saved: [[String: Any]]) {
        for m in saved {
            guard let path = m["path"] as? String, let dev = m["dev"] as? Int, let ino = m["ino"] as? Int,
                  let ref = liveRef(path: path) else { continue }
            var st = stat()
            guard lstat(path, &st) == 0, Int(st.st_dev) == dev, Int(st.st_ino) == ino,
                  let key = tree.withLock({ markKey(for: ref) }) else { continue }
            var copy: CopyCheck?
            if m["stamp"] != nil {
                // A duplicate whose check can't be read back can't be held to it.
                guard let stamp = FileStamp(saved: m["stamp"]),
                      let others = (m["others"] as? [[String: Any]])?.map({ o -> CopyCheck.Other? in
                          guard let p = o["path"] as? String, let s = FileStamp(saved: o["stamp"]) else { return nil }
                          return CopyCheck.Other(path: p, stamp: s)
                      }), !others.contains(where: { $0 == nil }) else { continue }
                copy = CopyCheck(stamp: stamp, others: others.compactMap { $0 })
            }
            marks[key] = MarkInfo(reason: m["reason"] as? String ?? "", dev: st.st_dev, ino: st.st_ino, copy: copy,
                                  size: (m["size"] as? Int).map(Int64.init),
                                  at: (m["at"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        recomputeMarks()
        notifyListeners()
    }

    // MARK: Reclaim analysis

    /// When the Reclaim analysis should run again, if the tree changed since
    /// the last pass. Only for a session on screen: with the Reclaim pane
    /// showing it waits ten times as long as the last pass took (at least
    /// 3 s), so a disk that never stops changing can't keep it running;
    /// otherwise it only feeds the overview's chip, once a minute.
    fileprivate func analysisDue() -> TimeInterval? {
        guard isOnScreen, residency == .awake, phase == .live, !analyzing, version != analyzedVersion,
              rescanBase == nil else { return nil }
        let gap = reclaimVisible ? max(3, analysisCost * 10) : max(60, analysisCost * 10)
        return lastAnalysis + gap
    }

    /// Re-runs the Reclaim analysis when it's due.
    fileprivate func tickAnalysis(now: TimeInterval) {
        guard let due = analysisDue(), due <= now + Self.slack else { return }
        analyzing = true
        lastAnalysis = now
        let v = version
        let tree = tree
        let excluded = appliedExclusions
        Task { [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            let result = await Task.detached(priority: .utility) {
                Reclaim.analyze(tree: tree, under: 0, excluded: excluded)
            }.value
            guard let self else { return }
            self.analysisCost = ProcessInfo.processInfo.systemUptime - start
            if result != self.findings { self.findings = result }
            self.analyzedVersion = v
            self.analyzing = false
            self.rearm()
            self.noteIfSettled()
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

    /// Whether the changes since the baseline should be worked out again:
    /// on screen, settled, and `quietVersion` moved since the last time.
    fileprivate func changesDue(_ p: silt_progress) -> Bool {
        isOnScreen && phase == .live && !catchingUp && p.idle && quietVersion != changesVersion && !baseline.isEmpty
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

// MARK: - Parking

extension Session {
    static var parkDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.jonnyasmar.silt/Parked", isDirectory: true)
    }

    fileprivate var parkFile: String {
        Session.parkDirectory.appendingPathComponent(id.uuidString + ".park").path
    }

    /// Settled enough to put away: not scanning, rescanning or catching up,
    /// the scanner idle, and no save, analysis or duplicate search running.
    /// Paced refreshes and deferred deep checks don't hold it back: they
    /// stay pending and run on waking (dir ids survive parking).
    var canPark: Bool { canPark(nil) }

    fileprivate func canPark(_ progress: silt_progress?) -> Bool {
        guard residency == .awake, !closed, phase == .live, !catchingUp, rescanBase == nil, heldEvents.isEmpty,
              !saving, !analyzing else { return false }
        switch duplicates.phase {
        case .collecting, .comparing: return false
        default: break
        }
        return (progress ?? tree.progress).idle
    }

    /// Writes the tree to a file and frees its memory. Everything that refers
    /// into it (marks, open folders, Reclaim results, duplicates) stays valid:
    /// it comes back exactly as it was. A parked location has no timer, and
    /// on a volume whose FSEvents history can be trusted, no stream either:
    /// waking replays what changed meanwhile.
    func park() {
        guard canPark else { return }
        flushMarks() // saving them needs the tree
        residency = .parking
        cancelTimer()
        holdBusyActivity(false)
        let tree = tree, url = url, eventId = safeEventId, fda = fullDiskAccess, file = parkFile
        let generation = tree.generation
        let history = keepsHistory
        let stale = history && generation != savedGeneration
        try? FileManager.default.createDirectory(at: Session.parkDirectory, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            tree.stopScanner()
            // A relaunch should still open this instantly. A saved scan that
            // FSEvents can bring up to date does that as well as a new one
            // (and will for at least another day), so only save without one.
            let saved = stale && !Snapshots.replayable(for: url, fullDiskAccess: fda, margin: 86400)
                && Snapshots.save(tree, url: url, eventId: eventId, fullDiskAccess: fda)
            let database = history ? FSWatcher.databaseID(for: url.path) : nil
            let parked = tree.park(to: file)
            if !parked { tree.resumeIdle() }
            malloc_zone_pressure_relief(nil, 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.closed else {
                        try? FileManager.default.removeItem(atPath: file)
                        return
                    }
                    if saved { self.savedGeneration = generation }
                    self.residency = parked ? .parked : .awake
                    if parked {
                        self.duplicates.dropCache()
                        if let database { self.stopWatchingWhileParked(database: database) }
                    } else {
                        self.releaseParkedEvents(urgent: false) // it stayed; catch up now
                        self.rearm()
                    }
                    if self.wakeWhenParked {
                        self.wakeWhenParked = false
                        self.wake()
                    }
                }
            }
        }
    }

    /// Parked on a volume whose history FSEvents keeps: the stream can go,
    /// since waking replays everything after `lastEventId`.
    private func stopWatchingWhileParked(database: [UInt8]) {
        watcher?.stop()
        watcher = nil
        streamStopped = true
        parkedAt = Date()
        parkedDatabase = database
        // The replay brings back whatever arrived while parking.
        parkedEvents = [:]
        parkedSpecial = []
        parkedOverflow = false
        parkedMaxEventId = 0
    }

    /// What a location's root is right now: which folder, on which volume,
    /// and which FSEvents history its event ids belong to.
    fileprivate struct RootIdentity: Sendable {
        let inode: UInt64
        let volume: String?
        let database: [UInt8]?

        init(_ url: URL) {
            var st = stat()
            inode = lstat(url.path, &st) == 0 ? st.st_ino : 0
            volume = Session.volumeUUID(url)
            database = FSWatcher.databaseID(for: url.path)
        }
    }

    /// Brings a parked tree back, then catches up on what changed meanwhile.
    func wake() {
        switch residency {
        case .awake, .waking:
            return
        case .parking:
            wakeWhenParked = true
        case .parked:
            residency = .waking
            let tree = tree, file = parkFile, url = url, replay = streamStopped
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ok = tree.unpark(from: file)
                if ok { tree.resumeIdle() }
                try? FileManager.default.removeItem(atPath: file)
                let root = replay ? RootIdentity(url) : nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, !self.closed else { return }
                        guard ok else {
                            // The file is gone or damaged: start this location over.
                            self.residency = .parked
                            self.onNeedsRebuild?()
                            return
                        }
                        let now = ProcessInfo.processInfo.systemUptime
                        self.residency = .awake
                        self.lastGeneration = .max // everything showing it should look again
                        if let root { self.resumeWatching(root) }
                        if self.rulesPending { self.rulesChanged() }
                        // It's being woken to be shown. Catching up runs at the
                        // speed setting's pace; what's opened comes first
                        // (`lookedAt`).
                        self.releaseParkedEvents(urgent: self.catchUpUrgent)
                        self.releaseDueRefreshes(now: .infinity)
                        self.releaseDeferredDeep(now: now)
                        self.lookedAtShown()
                        self.resolvePendingFocus()
                        self.bumpVersion(now)
                        self.bumpQuiet(now)
                        self.rearm()
                    }
                }
            }
        }
    }

    /// Restarts the stream a parked location went without, replaying what
    /// changed meanwhile. A root that was replaced (a replay may not show
    /// it), a different FSEvents history, or longer parked than a snapshot
    /// may be old mean no replay can be trusted: everything is checked
    /// again instead.
    private func resumeWatching(_ root: RootIdentity) {
        guard streamStopped else { return }
        streamStopped = false
        let away = parkedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let sameRoot = root.inode != 0 && root.inode == rootInode && rootVolume != nil && root.volume == rootVolume
        let sameHistory = root.database != nil && root.database == parkedDatabase
        parkedAt = nil
        parkedDatabase = nil
        if sameRoot, sameHistory, away < Snapshots.maxAge {
            startWatching(since: lastEventId)
            if watcher?.running == true {
                catchingUp = true
                historyDelivered = false
                holdBusyActivity(true)
                return
            }
        }
        if !sameRoot, root.inode != 0, root.volume != nil {
            rootInode = root.inode
            rootVolume = root.volume
        }
        startWatching(since: nil)
        startRescan(0, explicit: false, urgent: catchUpUrgent)
    }

    private func releaseParkedEvents(urgent: Bool) {
        let events = Array(parkedEvents.values)
        let special = parkedSpecial
        let overflow = parkedOverflow
        parkedEvents = [:]
        parkedSpecial = []
        parkedOverflow = false
        if !special.isEmpty { apply(special, urgent: urgent) } // remounts: reattach the stream first
        if overflow {
            lastEventId = max(lastEventId, parkedMaxEventId)
            startRescan(0, explicit: false, urgent: urgent)
        } else if !events.isEmpty {
            apply(events, urgent: urgent)
        }
    }

    fileprivate func reportLive() {
        guard !reportedLive, phase == .live, !showsSavedScan else { return }
        reportedLive = true
        onLive?()
    }
}

// MARK: - Views

extension Session {
    /// Whether this scan reaches `path`: inside its root and not across a
    /// mount point (another volume gets its own scan). Needs no tree, so it
    /// answers while parked too.
    func covers(_ path: String) -> Bool {
        let root = url.path
        let prefix = root == "/" ? "/" : root + "/"
        guard path != root, path.hasPrefix(prefix) else { return false }
        for m in Mounts.all() where m.path != root && m.path.hasPrefix(prefix) {
            if path == m.path || path.hasPrefix(m.path + "/") { return false }
        }
        return true
    }

    /// Lock held. The folder at `path`, if the scan has listed it.
    func dirID(forPath path: String) -> UInt32? {
        let e = tree.lookup(path)
        guard e != NONE else { return nil }
        let entry = tree.entry(e)
        return entry.isDir ? entry.aux : nil
    }

    /// Shows this scan as `path`: its root, or a folder inside it. Each view
    /// comes back where it was left.
    func enter(view path: String) {
        viewPath = path
        selection = []
        if path == url.path {
            focus = viewFocus[path] ?? 0
            pendingFocus = nil
            return
        }
        pendingFocus = path
        if let saved = viewFocus[path] {
            focus = saved
            pendingFocus = nil
        }
        resolvePendingFocus()
    }

    /// The size to show beside a view in the sidebar: the whole scan, or the
    /// folder it opened as (the last known size while parked).
    func size(ofView path: String) -> Int64? {
        _ = version // follow changes
        if path == url.path { return stats.bytes }
        guard isAwake else { return viewSizes[path] }
        let size: Int64? = tree.withLock {
            guard let d = dirID(forPath: path) else { return nil }
            return tree.entry(tree.dirEntry(d)).size
        }
        if let size { viewSizes[path] = size }
        return size ?? viewSizes[path]
    }

    /// Remembers where the current view was left.
    func leaveView() {
        viewFocus[viewPath] = focus
    }

    /// A view's folder the scan hadn't reached yet: until it does, show the
    /// nearest folder it has.
    fileprivate func resolvePendingFocus() {
        guard let target = pendingFocus, isAwake else { return }
        let (exact, nearest): (UInt32?, UInt32) = tree.withLock {
            if let d = dirID(forPath: target) { return (d, d) }
            var p = (target as NSString).deletingLastPathComponent
            while p.count > url.path.count {
                if let d = dirID(forPath: p) { return (nil, d) }
                p = (p as NSString).deletingLastPathComponent
            }
            return (nil, 0)
        }
        if let exact {
            pendingFocus = nil
            if focus != exact { focus = exact }
        } else {
            if focus != nearest { focus = nearest }
            if phase == .live && !showsSavedScan { pendingFocus = nil } // it isn't coming
        }
    }

    /// Takes over the marks of a scan this one now covers.
    func adoptMarks(from other: Session) {
        // Our own saved marks first, or saving the merged set would lose them.
        if !marksRestored {
            marksRestored = true
            restoreMarks()
        }
        if other.isAwake { other.persistMarks() }
        let key = other.marksDefaultsKey
        guard let saved = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return }
        importMarks(saved)
        UserDefaults.standard.removeObject(forKey: key)
        persistMarks()
    }

    /// Takes over how a covered scan was left: where each of its views was
    /// focused and which folders were open, found again by path. (A parked
    /// scan's is lost: reading it would mean waking it.)
    func adoptView(from other: Session) {
        guard other.isAwake else { return }
        other.captureTreeState?() // the tree on screen hasn't saved its state yet
        other.leaveView()
        let otherTree = other.tree
        func path(_ d: UInt32) -> String? {
            d < otherTree.raw.pointee.dir_count && otherTree.isLive(otherTree.dirEntry(d))
                ? (d == 0 ? other.url.path : otherTree.path(of: otherTree.dirEntry(d))) : nil
        }
        let (states, focuses): ([(String, [String])], [(String, String)]) = otherTree.withLock {
            let states = other.treeStates.compactMap { root, state in path(root).map { ($0, state.expanded.compactMap(path)) } }
            let focuses = other.viewFocus.compactMap { view, d in path(d).map { (view, $0) } }
            return (states, focuses)
        }
        tree.withLock {
            for (root, open) in states {
                guard let r = dirID(forPath: root) else { continue }
                treeStates[r] = TreeState(expanded: open.compactMap { dirID(forPath: $0) })
            }
            for (view, focusPath) in focuses {
                if let d = dirID(forPath: focusPath) { viewFocus[view] = d }
            }
        }
    }
}

/// A stamp as saved with a duplicate's mark.
extension FileStamp {
    fileprivate var saved: [String: Int] {
        ["dev": Int(dev), "ino": Int(truncatingIfNeeded: ino), "size": Int(size), "alloc": Int(alloc),
         "ms": mtime.tv_sec, "mns": mtime.tv_nsec, "cs": ctime.tv_sec, "cns": ctime.tv_nsec]
    }

    fileprivate init?(saved: Any?) {
        guard let d = saved as? [String: Int], let dev = d["dev"], let ino = d["ino"], let size = d["size"],
              let alloc = d["alloc"], let ms = d["ms"], let mns = d["mns"], let cs = d["cs"], let cns = d["cns"]
        else { return nil }
        self.dev = Int32(truncatingIfNeeded: dev)
        self.ino = UInt64(truncatingIfNeeded: ino)
        self.size = Int64(size)
        self.alloc = Int64(alloc)
        mtime = timespec(tv_sec: ms, tv_nsec: mns)
        ctime = timespec(tv_sec: cs, tv_nsec: cns)
    }
}
