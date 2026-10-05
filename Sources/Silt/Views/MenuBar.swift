import AppKit
import SwiftUI

/// Whether Silt stays in the menu bar when its last window closes (on by
/// default). The window's scans stay too, parked once out of sight, so the
/// next window shows them at once and catches up on what changed.
enum MenuBarMode {
    static let key = "menuBar"
    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// No window left: Silt leaves the Dock and lives in the menu bar.
    @MainActor static func windowsGone() {
        guard isOn else { return }
        let ok = NSApp.setActivationPolicy(.accessory)
        Perf.log.notice("menu bar only: activation policy accessory \(ok, privacy: .public), now \(NSApp.activationPolicy().rawValue, privacy: .public)")
    }

    /// A window is coming: back in the Dock, in front.
    @MainActor static func windowComing() {
        if NSApp.activationPolicy() != .regular {
            Perf.log.notice("window coming: back in the Dock")
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }
}

/// The scans the last window left when it closed in menu-bar mode, where the
/// menu can see them come and go.
@MainActor @Observable final class KeptScans {
    static let shared = KeptScans()
    var model: WindowModel?
}

/// The menu under Silt's menu bar icon.
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let speed = SpeedController.shared
        if let line = capacityLine { Text(line) }
        if let line = scanLine { Text(line) }
        Divider()
        Button("Open Silt") { open() }
            .keyboardShortcut("o")
        Picker("Scan Speed", selection: Binding(get: { speed.mode }, set: { speed.mode = $0 })) {
            ForEach(ScanSpeed.allCases) { Text($0.title).tag($0) }
        }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Silt") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The startup disk's free space, as Finder counts it.
    private var capacityLine: String? {
        let url = URL(fileURLWithPath: "/")
        guard let c = Locations.volumeCapacity(for: url) else { return nil }
        return "\(Locations.displayName(for: url)): \(Fmt.bytes(c.available)) available of \(Fmt.bytes(c.total))"
    }

    /// What the window last showed, kept for the next one.
    private var scanLine: String? {
        guard let s = KeptScans.shared.model?.current else { return nil }
        let state = s.residency == .parked ? "parked until you open it" : "watching for changes"
        return "\(s.title): \(Fmt.compactCount(s.stats.items)) items, \(state)"
    }

    /// The open window to the front, or a new one (which takes over the scans
    /// the last one left).
    private func open() {
        MenuBarMode.windowComing()
        if let window = WindowModel.openWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}
