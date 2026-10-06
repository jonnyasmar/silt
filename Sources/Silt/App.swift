import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct SiltApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(MenuBarMode.key) private var menuBar = true

    var body: some Scene {
        WindowGroup("Silt", id: "main") {
            RootView()
                .frame(minWidth: 880, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { SiltCommands() }

        Settings { SettingsView() }

        MenuBarExtra("Silt", systemImage: "water.waves", isInserted: $menuBar) {
            MenuBarContent()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Measuring what a delete frees holds a descriptor per folder level:
        // more room than the default 256.
        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < 10_240 {
            limit.rlim_cur = min(limit.rlim_max, 10_240)
            setrlimit(RLIMIT_NOFILE, &limit)
        }
        // Parked trees belong to the run that parked them.
        try? FileManager.default.removeItem(at: Session.parkDirectory)
        // The speed setting applies from the first scan on.
        MainActor.assumeIsolated { _ = SpeedController.shared }
        // Icon Services is slow to wake the first time; do it while the
        // window is still being built.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = NSWorkspace.shared.icon(for: .folder)
            _ = NSWorkspace.shared.icon(for: .data)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        MainActor.assumeIsolated { PerfReporter.start() }
        // Launched with a folder argument (`Silt ~/dev`), SwiftUI makes no
        // first window, though the launch still counts as a default one.
        DispatchQueue.main.async { Self.ensureWindow() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { WindowModel.open(url) }
        // A drop on the Dock icon can be what launched Silt: the window it
        // gets picks the folders up from the pending list.
        DispatchQueue.main.async { Self.ensureWindow() }
    }

    private static var askedForWindow = false

    /// Opens a window if there's none, once: the scan it starts with comes
    /// from the pending list or the launch argument (`WindowModel.init`).
    private static func ensureWindow() {
        guard !askedForWindow, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        askedForWindow = true
        // SwiftUI's own File ▸ New Window, found by its shortcut (titles are
        // localized).
        let item = NSApp.mainMenu?.items.lazy.compactMap(\.submenu).flatMap(\.items).first {
            $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command
        }
        if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
    }

    /// In menu-bar mode Silt stays when its last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MenuBarMode.isOn }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { WindowModel.saveAll() }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case files, largest, duplicates, reclaim, types

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Files"
        case .largest: "Largest Files"
        case .duplicates: "Duplicates"
        case .reclaim: "Reclaim"
        case .types: "File Types"
        }
    }

    var shortTitle: String {
        switch self {
        case .files: "Files"
        case .largest: "Largest"
        case .duplicates: "Duplicates"
        case .reclaim: "Reclaim"
        case .types: "Types"
        }
    }

    var symbol: String {
        switch self {
        case .files: "list.bullet.indent"
        case .largest: "arrow.down.right.and.arrow.up.left.square"
        case .duplicates: "square.on.square"
        case .reclaim: "sparkles"
        case .types: "chart.bar.xaxis"
        }
    }
}

enum ItemAction { case reveal, open, up, quickLook, copyPath, trash, delete, mark }

/// Per-window state: which locations have been scanned and what is showing.
///
/// It also tells each scan whether it's on screen (the one showing, in a
/// window that isn't covered, minimized or hidden with the app): scans off
/// screen do only the work that keeps their tree current.
@MainActor
@Observable
final class WindowModel {
    /// Scans held by this window. A location or folder inside one of them is
    /// shown from it rather than scanned again.
    private(set) var sessions: [Session] = [] {
        didSet { setNeedsSync() }
    }
    /// The scan being shown. Whatever stops being shown starts its clock
    /// toward parking; whatever is shown wakes up.
    private(set) var current: Session? {
        didSet {
            guard current !== oldValue else { return }
            let now = ProcessInfo.processInfo.systemUptime
            oldValue?.hiddenSince = now
            // Kept for the menu bar, nothing is on screen: a scan that
            // finishes and takes over stays out of sight until a window
            // comes (`takeBack`).
            if kept {
                if current?.hiddenSince == nil { current?.hiddenSince = now }
                scheduleParking()
            } else {
                current?.hiddenSince = nil
                current?.wake()
            }
            setNeedsSync()
        }
    }
    /// The location or folder on screen: `current`'s root, or a folder inside it.
    private(set) var viewing: String?
    /// A location picked but not scanned yet: shown with a Scan button, since
    /// picking a place never starts a scan by itself.
    private(set) var pending: String?
    /// Folders opened with Scan Folder… (sidebar locations aside), in order.
    private(set) var folders: [String] = []
    var pane: Pane = .files {
        didSet { if pane != oldValue { setNeedsSync() } }
    }
    var search = ""
    var showInspector = true
    var reviewingCleanup = false
    private(set) var locations: [Location] = Locations.all()
    /// What purgeable space added to each volume's free space when last
    /// measured, so a refresh can show an estimate instead of dropping to
    /// plain free space until the next measurement lands.
    @ObservationIgnored private var purgeable: [String: Int64] = [:]
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    /// Set by the view hierarchy once it's in a window.
    @ObservationIgnored weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            if window != nil {
                if kept { takeBack() } else { attach() }
            }
            observeWindow()
            updateVisibility()
        }
    }
    /// The window closed but Silt stayed in the menu bar: this model and its
    /// scans wait, out of sight, for the next window (`keptModel`).
    @ObservationIgnored private var kept = false
    @ObservationIgnored private var windowObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    /// The window closed, and its scans with it.
    @ObservationIgnored private var windowClosed = false
    @ObservationIgnored private var attached = false
    @ObservationIgnored private var syncQueued = false

    private static var active: [WeakModel] = []
    private static var pendingOpen: [URL] = []

    /// Menu-bar mode: the model of the last window to close, with its scans
    /// (they park once out of sight), for the next window to take over.
    private static var keptModel: WindowModel? {
        didSet { KeptScans.shared.model = keptModel } // read here, it isn't observed
    }

    /// The kept model, for a new window's view to start from. Only looked at:
    /// SwiftUI builds a view (and its state's first value) more than once,
    /// so it's the window arriving that takes it over (`takeBack`).
    static var keptForNextWindow: WindowModel? { keptModel }

    /// A main window that's open, if any.
    static var openWindow: NSWindow? {
        active.compactMap(\.model).first { $0.window != nil && !$0.windowClosed && !$0.kept }?.window
    }

    /// Every open location, once each (for the performance log).
    static var allSessions: [Session] {
        var seen = Set<ObjectIdentifier>()
        return active.compactMap(\.model).flatMap(\.sessions).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    init() {
        Self.active.append(WeakModel(model: self))
        let pending = Self.pendingOpen
        Self.pendingOpen = []
        if let first = pending.first ?? Self.launchArgument() {
            scan(first)
        } else if let last = Self.lastScanToRestore(),
                  hasFullDiskAccess || UserDefaults.standard.bool(forKey: "scanWithoutFDA")
                  || !touchesPrivateFolders(last.path) {
            scan(last)
            if let view = UserDefaults.standard.string(forKey: "lastView"), view != last.path { scan(URL(fileURLWithPath: view)) }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--pane"), i + 1 < CommandLine.arguments.count,
           let p = Pane(rawValue: CommandLine.arguments[i + 1]) {
            pane = p
        }
        if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
            search = CommandLine.arguments[i + 1]
        }
    }

    /// Work only a model with a window does. SwiftUI builds this model in a
    /// view's initializer, and builds (and throws away) another each time
    /// that view is rebuilt: `init` stays cheap, and whatever it read would
    /// become something the whole window is rebuilt for.
    private func attach() {
        guard !attached, !windowClosed else { return }
        attached = true
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            appObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateVisibility() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLocations() }
            })
        }
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.parkHidden(after: 0) }
        }
        pressure.resume()
        memoryPressure = pressure
        refineLocations()
        // Free space moves on its own (and with every cleanup, here or
        // anywhere): the sidebar's figures follow while the window is seen.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.windowShown else { return }
                self.refreshLocations()
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        locationsTimer = t
    }

    /// Visibility and the park timer follow changes to what's shown, a turn
    /// later (and once for several changes): changes can happen while
    /// SwiftUI builds a view, where reading the scans' state would tie the
    /// view to it.
    private func setNeedsSync() {
        guard !syncQueued else { return }
        syncQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncQueued = false
                self.updateVisibility()
                self.scheduleParking()
            }
        }
    }

    /// How long a location stays in memory after it's no longer on screen.
    private static let parkAfter: TimeInterval = 120
    /// How often a scan that's due to park but busy is tried again (it's also
    /// tried the moment it settles).
    private static let parkRetry: TimeInterval = 15
    @ObservationIgnored private var parkTimer: Timer?
    @ObservationIgnored private var locationsTimer: Timer?
    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?

    /// Puts away scans that have been out of sight for `after` seconds (all of
    /// them, right away, when macOS runs short of memory).
    private func parkHidden(after: TimeInterval) {
        guard !windowClosed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for s in sessions where s !== current || kept {
            guard let hidden = s.hiddenSince, now - hidden >= after, s.canPark else { continue }
            s.park()
        }
        scheduleParking()
    }

    /// Sets one timer for when the next hidden scan is due to park, or none
    /// if every hidden one is parked already. One that's due but busy (or
    /// still waking, or parking) is tried again now and then; it also parks
    /// as soon as it settles (`onSettled`), and a wake finishing or a park
    /// failing plans again (`onResidencyChange`).
    private func scheduleParking() {
        parkTimer?.invalidate()
        parkTimer = nil
        guard !windowClosed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var due = TimeInterval.infinity
        for s in sessions where (s !== current || kept) && s.residency != .parked && !s.closed {
            guard let hidden = s.hiddenSince else { continue }
            let at = hidden + Self.parkAfter
            due = min(due, at > now && s.isAwake ? at : max(at, now + Self.parkRetry))
        }
        guard due < .infinity else { return }
        let delay = due - now
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.parkHidden(after: Self.parkAfter) }
        }
        t.tolerance = max(1, delay * 0.1)
        RunLoop.main.add(t, forMode: .common)
        parkTimer = t
    }

    /// Whether the window can be seen at all: the app isn't hidden, and the
    /// window isn't minimized, fully covered or on another Space. With no
    /// window yet (or none at all, in tests) it counts as seen.
    private var windowShown: Bool {
        if kept { return false }
        if NSApp?.isHidden == true { return false }
        guard let window else { return true }
        return window.occlusionState.contains(.visible)
    }

    /// Tells each scan whether it's on screen, and whether its Reclaim pane is.
    private func updateVisibility() {
        guard !windowClosed else { return }
        let shown = windowShown
        for s in sessions {
            let onScreen = shown && s === current
            if s.isOnScreen != onScreen { s.isOnScreen = onScreen }
            let reclaim = onScreen && pane == .reclaim
            if s.reclaimVisible != reclaim { s.reclaimVisible = reclaim }
        }
    }

    private func observeWindow() {
        let center = NotificationCenter.default
        for o in windowObservers { center.removeObserver(o) }
        windowObservers = []
        guard let window, !windowClosed else { return }
        windowObservers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                  object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        })
        windowObservers.append(center.addObserver(forName: NSWindow.willCloseNotification,
                                                  object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose() }
        })
    }

    /// The window's scans go with it. Each brings its snapshot up to date off
    /// the main thread first; quitting waits for that.
    private func windowWillClose() {
        guard !windowClosed else { return }
        let others = Self.active.contains(where: { $0.model !== self && $0.model?.window != nil
                                                   && $0.model?.windowClosed == false && $0.model?.kept == false })
        Perf.log.notice("window closing: menu bar mode \(MenuBarMode.isOn, privacy: .public), other windows open \(others, privacy: .public)")
        if MenuBarMode.isOn, !others {
            keep()
            return
        }
        windowClosed = true
        parkTimer?.invalidate()
        parkTimer = nil
        locationsTimer?.invalidate()
        locationsTimer = nil
        let center = NotificationCenter.default
        for o in windowObservers + appObservers { center.removeObserver(o) }
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        windowObservers = []
        appObservers = []
        workspaceObservers = []
        memoryPressure?.cancel()
        memoryPressure = nil
        // What's on screen is left as it is while the window animates away.
        for s in sessions { s.close(saving: true) }
    }

    /// The last window closed and Silt stays in the menu bar: its scans stay,
    /// out of sight from now, so they park after the usual wait (noting what
    /// changes, for waking); the next window takes them over (`takeBack`).
    private func keep() {
        Perf.log.notice("keeping the window's scans for the menu bar")
        kept = true
        Self.keptModel = self
        let center = NotificationCenter.default
        for o in windowObservers { center.removeObserver(o) }
        windowObservers = []
        let now = ProcessInfo.processInfo.systemUptime
        for s in sessions {
            s.flushMarks()
            if s.hiddenSince == nil { s.hiddenSince = now }
        }
        updateVisibility()
        scheduleParking()
        // After the window has gone.
        DispatchQueue.main.async { MainActor.assumeIsolated { MenuBarMode.windowsGone() } }
    }

    /// A new window took this model over: what it shows wakes up.
    private func takeBack() {
        Perf.log.notice("a new window took over the kept scans")
        kept = false
        if Self.keptModel === self { Self.keptModel = nil }
        current?.hiddenSince = nil
        current?.wake()
        MenuBarMode.windowComing()
        setNeedsSync()
    }

    /// At quit: snapshots every live scan in every window, saves marks, waits
    /// for saves that closing windows started, and clears away parked trees.
    static func saveAll() {
        for m in active.compactMap(\.model) {
            for s in m.sessions {
                s.flushMarks()
                s.saveSnapshotNow()
            }
        }
        _ = Session.closingSaves.wait(timeout: .now() + 60)
        try? FileManager.default.removeItem(at: Session.parkDirectory)
    }

    /// Opens `url` in the frontmost window (Dock drops, `open -a Silt dir`).
    static func open(_ url: URL) {
        active.removeAll { $0.model == nil }
        let key = active.first { $0.model?.window?.isKeyWindow == true }?.model ?? active.last?.model
        if let key { key.scan(url) } else { pendingOpen.append(url) }
    }

    /// The first window reopens the last location, but only when a saved
    /// snapshot makes that instant.
    private static var restoredLast = false

    private static func lastScanToRestore() -> URL? {
        guard !restoredLast else { return nil }
        restoredLast = true
        guard let path = UserDefaults.standard.string(forKey: "lastScan"),
              FileManager.default.fileExists(atPath: Snapshots.file(for: path).path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// `Silt <folder>` scans that folder on launch (first window only).
    private static var consumedLaunchArgument = false

    private static func launchArgument() -> URL? {
        guard !consumedLaunchArgument else { return nil }
        consumedLaunchArgument = true
        let args = CommandLine.arguments.dropFirst()
        var skip = false
        for a in args {
            if skip { skip = false; continue }
            if a == "--pane" || a == "--search" { skip = true; continue }
            if a.hasPrefix("-") { continue }
            var isDir: ObjCBool = false
            let path = (a as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    func refreshLocations() {
        locations = Locations.all().map { l in
            guard let extra = purgeable[l.id], let available = l.available else { return l }
            return l.with(available: min(l.total ?? .max, available + extra))
        }
        hasFullDiskAccess = FullDiskAccess.isGranted
        if let p = pending, !FileManager.default.fileExists(atPath: p) { pending = nil } // ejected
        refineLocations()
    }

    /// Fills in each volume's available space counting what macOS can purge,
    /// which is too slow to ask for on the main thread. Starts a turn later
    /// (see `setNeedsSync`), and only for a model with a window.
    private func refineLocations() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.attached, !self.windowClosed else { return }
                let quick = self.locations
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let refined = Locations.withImportantUsage(quick)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.purgeable.merge(refined.purgeable) { $1 }
                            guard self.locations == quick, refined.locations != quick else { return }
                            self.locations = refined.locations
                        }
                    }
                }
            }
        }
    }

    /// Picks a place in the sidebar or on the start screen. One that's
    /// already scanned, or inside a scan, is shown; anything else waits for
    /// an explicit Scan.
    func select(_ path: String) {
        search = ""
        if let s = backing(path) {
            show(s, as: path)
            return
        }
        if let old = current, viewing != nil { old.leaveView() }
        current = nil
        viewing = nil
        pending = path
    }

    func scan(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        search = ""
        if let existing = sessions.first(where: { $0.url.path == path }) {
            show(existing, as: path)
            return
        }
        // Already inside a scan: show it from there, instantly and without a
        // second copy in memory. The deepest covering scan wins.
        if let host = sessions.filter({ $0.covers(path) }).max(by: { $0.url.path.count < $1.url.path.count }) {
            show(host, as: path)
            return
        }
        refreshLocations()
        if !hasFullDiskAccess, touchesPrivateFolders(path), !UserDefaults.standard.bool(forKey: "scanWithoutFDA") {
            askForFullDiskAccess(then: url)
            return
        }
        start(url)
    }

    /// Home and whole volumes contain folders macOS guards with a prompt each.
    private func touchesPrivateFolders(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == "/" || path == "/Users" || path == home || path.hasPrefix("/Volumes/")
    }

    private func askForFullDiskAccess(then url: URL) {
        let alert = NSAlert()
        alert.messageText = "Give Silt Full Disk Access?"
        alert.informativeText = "Without it, macOS asks separately for Desktop, Documents, Downloads and other folders during the scan, and hides Mail, Messages and app data entirely. Grant access in System Settings, then reopen Silt."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Scan Without It")
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            switch r {
            case .alertFirstButtonReturn:
                FullDiskAccess.openSettings()
            case .alertSecondButtonReturn:
                UserDefaults.standard.set(true, forKey: "scanWithoutFDA")
                self?.start(url)
            default:
                break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
    }

    private func start(_ url: URL) {
        let session = Session(url: url, guardPrivateFolders: !hasFullDiskAccess)
        adopt(session)
        sessions.append(session)
        show(session, as: session.url.path)
        pane = .files
    }

    /// Puts `session` on screen as `path` (its root or a folder inside it).
    private func show(_ session: Session, as path: String) {
        if let old = current, viewing != nil { old.leaveView() }
        current = session
        viewing = path
        pending = nil
        session.enter(view: path)
        if !locations.contains(where: { $0.url.path == path }), !folders.contains(path) { folders.append(path) }
        UserDefaults.standard.set(session.url.path, forKey: "lastScan")
        UserDefaults.standard.set(path, forKey: "lastView")
    }

    private func adopt(_ session: Session) {
        session.onNeedsRebuild = { [weak self, weak session] in
            guard let self, let session else { return }
            self.rebuild(session)
        }
        // A hidden scan that was busy when it was due to park parks as soon
        // as it settles.
        session.onResidencyChange = { [weak self] in self?.setNeedsSync() }
        session.onSettled = { [weak self, weak session] in
            guard let self, let session, !self.windowClosed, session !== self.current || self.kept,
                  let hidden = session.hiddenSince,
                  ProcessInfo.processInfo.systemUptime - hidden >= Self.parkAfter else { return }
            session.park()
            self.scheduleParking()
        }
        session.onLive = { [weak self, weak session] in
            guard let self, let session else { return }
            self.absorb(into: session)
        }
    }

    /// Scans that `host` now covers (Home, once Macintosh HD is scanned) fold
    /// into it: their marks and open folders move over, their views are shown
    /// from `host`, and their memory goes.
    private func absorb(into host: Session) {
        guard host.isAwake, sessions.contains(where: { $0 === host }) else { return }
        for s in sessions where s !== host && host.covers(s.url.path) {
            host.adoptMarks(from: s)
            host.adoptView(from: s)
            let shown = current === s
            let view = viewing
            s.close()
            sessions.removeAll { $0 === s }
            if shown { show(host, as: view ?? s.url.path) }
        }
    }

    /// The scan a sidebar row is shown from: its own, or one covering it.
    func backing(_ path: String) -> Session? {
        sessions.first { $0.url.path == path }
            ?? sessions.filter { $0.covers(path) }.max { $0.url.path.count < $1.url.path.count }
    }

    /// Swaps a session for a compacted copy of itself: saved and reloaded
    /// where snapshots are kept, rescanned elsewhere.
    private func rebuild(_ old: Session) {
        guard let i = sessions.firstIndex(where: { $0 === old }) else { return }
        old.saveSnapshotNow()
        old.close()
        let fresh = Session(url: old.url, guardPrivateFolders: !hasFullDiskAccess)
        adopt(fresh)
        sessions[i] = fresh
        if current === old { show(fresh, as: viewing ?? fresh.url.path) }
    }

    /// Rescans in place: everything stays visible while it's re-checked. A
    /// view into a bigger scan re-checks just its own folder.
    func rescan() {
        guard let s = current, s.isAwake else { return }
        if let v = viewing, v != s.url.path, let d = s.tree.withLock({ s.dirID(forPath: v) }) {
            s.rescan(ItemRef(entry: s.tree.withLock { s.tree.dirEntry(d) }, dir: d))
        } else {
            s.rescan()
        }
    }

    /// Throws the scan away and starts over (rarely needed).
    func rescanFromScratch() {
        guard let old = current, let i = sessions.firstIndex(where: { $0 === old }) else { return }
        old.close()
        refreshLocations()
        let fresh = Session(url: old.url, guardPrivateFolders: !hasFullDiskAccess, fresh: true)
        adopt(fresh)
        sessions[i] = fresh
        show(fresh, as: viewing ?? fresh.url.path)
    }

    /// Closes a folder row: its own scan (and the views into it), or just the
    /// view when a bigger scan covers it.
    func closeFolder(_ path: String) {
        folders.removeAll { $0 == path }
        if let own = sessions.first(where: { $0.url.path == path }) {
            own.close()
            sessions.removeAll { $0 === own }
            folders.removeAll { backing($0) == nil } // views that went with it
        }
        if pending != nil { return } // the page on screen isn't a scan; it stays
        if let v = viewing, v != path, let s = backing(v) {
            if current !== s { show(s, as: v) }
        } else if let host = backing(path) {
            show(host, as: host.url.path)
        } else if let next = sessions.last {
            show(next, as: next.url.path)
        } else {
            current = nil
            viewing = nil
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or volume to scan"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .OK, let url = panel.url { self?.scan(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    func perform(_ action: ItemAction) {
        // Text fields keep their own meaning for these keys.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
            switch action {
            case .trash, .delete: editor.deleteToBeginningOfLine(nil)
            case .up: editor.moveToBeginningOfDocument(nil)
            case .open: editor.moveToEndOfDocument(nil)
            default: break
            }
            return
        }
        guard let s = current, s.isAwake else { return } // still loading: nothing to act on
        let sel = s.selection
        switch action {
        case .reveal: s.reveal(sel)
        case .open:
            if sel.count == 1, sel[0].isDir { s.focus(on: sel[0]) } else { s.open(sel) }
        case .up: s.focusParent()
        case .quickLook: s.quickLook?()
        case .copyPath: s.copyPaths(sel)
        case .trash: s.moveToTrash(sel)
        case .delete: s.deleteImmediately(sel, window: window)
        case .mark: s.toggleMarks(sel)
        }
    }
}

private struct WeakModel {
    weak var model: WindowModel?
}

struct WindowModelKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var windowModel: WindowModel? {
        get { self[WindowModelKey.self] }
        set { self[WindowModelKey.self] = newValue }
    }
}

struct SiltCommands: Commands {
    @FocusedValue(\.windowModel) private var model

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Scan Folder…") { model?.chooseFolder() }
                .keyboardShortcut("o")
            Button("Rescan") { model?.rescan() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.current == nil)
            Button("Rescan from Scratch") { model?.rescanFromScratch() }
                .keyboardShortcut("r", modifiers: [.command, .shift, .option])
                .disabled(model?.current == nil)
            // Read here, so the checkmark follows changes made elsewhere.
            let speed = SpeedController.shared.mode
            Picker("Scan Speed", selection: Binding(get: { speed }, set: { SpeedController.shared.mode = $0 })) {
                ForEach(ScanSpeed.allCases) { Text($0.title).tag($0) }
            }
        }
        CommandMenu("Item") {
            let none = model?.current?.selection.isEmpty ?? true
            Button("Show in Finder") { model?.perform(.reveal) }
                .keyboardShortcut("r")
                .disabled(none)
            Button("Open / Focus Folder") { model?.perform(.open) }
                .keyboardShortcut(.downArrow)
                .disabled(none)
            Button("Enclosing Folder") { model?.perform(.up) }
                .keyboardShortcut(.upArrow)
                .disabled(model?.current == nil)
            Button("Quick Look") { model?.perform(.quickLook) }
                .keyboardShortcut("y")
                .disabled(none)
            Button("Copy Path") { model?.perform(.copyPath) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(none)
            // Plain M is handled by the file list itself: as a menu key
            // equivalent it would swallow typing in the search field.
            Button("Mark for Cleanup   M") { model?.perform(.mark) }
                .disabled(none)
            Button("Review Cleanup…") { model?.reviewingCleanup = true }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled((model?.current?.markedCount ?? 0) == 0)
            Divider()
            Button("Move to Trash") { model?.perform(.trash) }
                .keyboardShortcut(.delete)
                .disabled(none)
            Button("Delete Immediately…") { model?.perform(.delete) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(none)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(Pane.allCases.enumerated()), id: \.element) { i, pane in
                Button(pane.title) { model?.pane = pane; model?.search = "" }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                    .disabled(model?.current == nil)
            }
            Divider()
        }
    }
}
