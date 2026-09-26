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

    /// Without Full Disk Access, opening another app's container pops a
    /// privacy prompt and blocks the scanning thread until it's answered, so
    /// those folders are recorded but not opened.
    init(url: URL, guardPrivateFolders: Bool) {
        let resolved = url.resolvingSymlinksInPath()
        self.url = resolved
        title = Locations.displayName(for: resolved)
        let values = try? resolved.resourceValues(forKeys: [.isVolumeKey])
        isVolume = values?.isVolume == true || resolved.path == "/"
        tree = Tree(path: resolved.path)
        if guardPrivateFolders {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for sub in ["Library/Containers", "Library/Group Containers", "Library/Daemon Containers"] {
                silt_tree_guard(tree.raw, home + "/" + sub)
            }
        }
        tree.startScan()
        startWatching()
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
        }

        if gen != lastGeneration {
            lastGeneration = gen
            for body in listeners.values { body() }
            if now - lastVersionBump > 0.2 || phase == .live {
                lastVersionBump = now
                version += 1
            }
        }

        if now - lastCapacityCheck > 3 {
            lastCapacityCheck = now
            capacity = Locations.volumeCapacity(for: url)
        }
    }

    private func startWatching() {
        watcher = FSWatcher(path: url.path) { [weak self] events in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(events) }
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
        tree.withLock {
            for event in events {
                if event.rootChanged { continue }
                guard let dir = nearestListedDir(for: event.path, root: root) else { continue }
                targets[dir] = (targets[dir] ?? false) || event.mustScanSubdirs
            }
        }
        for (dir, deep) in targets { tree.refresh(dir: dir, deep: deep) }
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

    func rescan(_ ref: ItemRef? = nil) {
        let dir = ref?.dir ?? 0
        guard dir != NONE else { return }
        tree.refresh(dir: dir, deep: true)
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

    private struct Target {
        let entry: UInt32
        let url: URL
        let size: Int64
    }

    private static let protected: Set<String> = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var s: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr",
                              "/bin", "/sbin", "/etc", "/var", "/opt", "/cores", "/Volumes", "/tmp",
                              "/System/Volumes/Data", home]
        for sub in ["Library", "Desktop", "Documents", "Downloads", "Applications", "Movies", "Music", "Pictures", "Public"] {
            s.insert(home + "/" + sub)
        }
        return s
    }()

    private func targets(_ refs: [ItemRef]) -> (ok: [Target], refused: [String]) {
        var ok: [Target] = []
        var refused: [String] = []
        tree.withLock {
            for ref in refs {
                let i = entryIndex(ref)
                guard i != 0, tree.isLive(i) else { continue }
                let path = tree.path(of: i)
                if Self.protected.contains(path) {
                    refused.append((path as NSString).lastPathComponent)
                    continue
                }
                ok.append(Target(entry: i, url: URL(fileURLWithPath: path), size: tree.entry(i).size))
            }
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
        let (items, refused) = targets(refs)
        if !refused.isEmpty { refuse(refused) }
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
            show(Toast(symbol: "trash", title: "Moved \(what) to the Trash",
                       detail: "\(Fmt.bytes(bytes)) comes back when you empty the Trash"))
        }
    }

    func deleteImmediately(_ refs: [ItemRef], window: NSWindow?) {
        let (items, refused) = targets(refs)
        if !refused.isEmpty { refuse(refused) }
        guard !items.isEmpty else { return }
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

    private func performDelete(_ items: [Target]) {
        // Optimistic: the rows disappear now; failures come back on refresh.
        for t in items { tree.remove(entry: t.entry) }
        selection = []
        show(Toast(symbol: "hourglass", title: "Deleting…", detail: nil))
        let urls = items.map(\.url)
        Task.detached(priority: .userInitiated) {
            var failures: [URL: String] = [:]
            for url in urls {
                do { try FileManager.default.removeItem(at: url) } catch { failures[url] = error.localizedDescription }
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

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Volume gap

    /// Space the volume reports as used that the scan couldn't see: snapshots,
    /// the sealed system volume's extras, swap, and unreadable folders.
    var unseenBytes: Int64 {
        guard isVolume, phase == .live, let capacity else { return 0 }
        let used = capacity.total - capacity.free
        let gap = used - stats.bytes
        return gap > capacity.total / 200 ? gap : 0
    }
}
