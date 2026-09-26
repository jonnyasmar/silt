import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct SiltApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Silt", id: "main") {
            RootView()
                .frame(minWidth: 880, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands { SiltCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Icon Services is slow to wake the first time; do it while the
        // window is still being built.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = NSWorkspace.shared.icon(for: .folder)
            _ = NSWorkspace.shared.icon(for: .data)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { WindowModel.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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
@MainActor
@Observable
final class WindowModel {
    private(set) var sessions: [Session] = []
    var current: Session?
    var pane: Pane = .files
    var search = ""
    var showInspector = true
    var reviewingCleanup = false
    private(set) var locations: [Location] = Locations.all()
    private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    @ObservationIgnored weak var window: NSWindow?

    private static var active: [WeakModel] = []
    private static var pendingOpen: [URL] = []

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
        }
        if let i = CommandLine.arguments.firstIndex(of: "--pane"), i + 1 < CommandLine.arguments.count,
           let p = Pane(rawValue: CommandLine.arguments[i + 1]) {
            pane = p
        }
        if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
            search = CommandLine.arguments[i + 1]
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLocations() }
            }
        }
    }

    /// Snapshots every live scan in every window (at quit).
    static func saveAll() {
        for m in active.compactMap(\.model) {
            for s in m.sessions { s.saveSnapshotNow() }
        }
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
        locations = Locations.all()
        hasFullDiskAccess = FullDiskAccess.isGranted
    }

    func scan(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        search = ""
        if let existing = sessions.first(where: { $0.url.path == path }) {
            current = existing
            UserDefaults.standard.set(path, forKey: "lastScan")
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
        UserDefaults.standard.set(url.resolvingSymlinksInPath().path, forKey: "lastScan")
        let session = Session(url: url, guardPrivateFolders: !hasFullDiskAccess)
        sessions.append(session)
        current = session
        pane = .files
    }

    /// Rescans in place: everything stays visible while it's re-checked.
    func rescan() {
        current?.rescan()
    }

    /// Throws the scan away and starts over (rarely needed).
    func rescanFromScratch() {
        guard let old = current, let i = sessions.firstIndex(where: { $0 === old }) else { return }
        old.close()
        refreshLocations()
        let fresh = Session(url: old.url, guardPrivateFolders: !hasFullDiskAccess, fresh: true)
        sessions[i] = fresh
        current = fresh
    }

    func closeSession(_ session: Session) {
        session.close()
        sessions.removeAll { $0 === session }
        if current === session { current = sessions.last }
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
        guard let s = current else { return }
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
