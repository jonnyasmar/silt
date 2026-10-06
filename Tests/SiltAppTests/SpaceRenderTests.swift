import AppKit
import SwiftUI
import Testing
@testable import Silt

/// Renders the Space popover, light and dark, to /tmp/silt-space-*.png for
/// a look at it without driving the app (opt in: SILT_RENDER=1).
@Test(.enabled(if: ProcessInfo.processInfo.environment["SILT_RENDER"] == "1"))
func renderSpacePopover() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("silt-render-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    for (rel, n) in [("Trash/old.dmg", 3_000_000), ("Trash/new.zip", 1_000_000), ("work/big.bin", 8_000_000), ("work/doomed.bin", 5_000_000)] {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: n).write(to: u)
    }
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86400 * 30)],
                                          ofItemAtPath: root.appendingPathComponent("Trash/old.dmg").path)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapName: String = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "com.apple.TimeMachine.\(f.string(from: Date(timeIntervalSinceNow: -600))).local"
    }()
    let listing = SnapshotListing(snapshots: [.init(name: snapName, created: Date(timeIntervalSinceNow: -600))])
    let (ledger, s) = await MainActor.run {
        let l = SpaceLedger(volume: "test-\(UUID().uuidString)", mount: root.path, persists: false)
        l.lister = { _ in listing }
        return (l, Session(url: root, guardPrivateFolders: true, fresh: true, ledger: l))
    }
    #expect(await wait { s.phase == .live && s.canPark })
    await MainActor.run {
        s.trashPathOverride = root.appendingPathComponent("Trash").path
        let doomed = s.tree.withLock { s.ref(forEntry: s.tree.lookup(root.appendingPathComponent("work/doomed.bin").path)) }
        s.deleteImmediately([doomed], window: nil, confirmed: true)
    }
    #expect(await wait { ledger.held.total > 0 || ledger.freed > 0 })
    await MainActor.run {
        let big = s.tree.withLock { s.ref(forEntry: s.tree.lookup(root.appendingPathComponent("work/big.bin").path)) }
        s.toggleMarks([big])
        s.recomputeMarks()
        ledger.beginRemoving(bytes: 2_400_000_000, items: 3, deleting: true)
    }
    await settle(1.0)
    for scheme in [NSAppearance.Name.aqua, .darkAqua] {
        let path = "/tmp/silt-space-\(scheme == .aqua ? "light" : "dark").png"
        let host = await MainActor.run { () -> NSHostingView<AnyView> in
            let host = NSHostingView(rootView: AnyView(SpacePopover(session: s).background(Color(nsColor: .windowBackgroundColor))))
            host.appearance = NSAppearance(named: scheme)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderFrontRegardless()
            return host
        }
        await settle(2.0) // the popover's estimates come in
        await MainActor.run {
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.window?.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            host.window?.orderOut(nil)
        }
    }
    await MainActor.run { s.close(); HeldSpace().save(volume: ledger.volume) }
}
