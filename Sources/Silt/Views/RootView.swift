import AppKit
import SwiftUI

struct RootView: View {
    /// The scans the last window left behind (menu-bar mode), or new ones.
    @State private var model = WindowModel.takeKept() ?? WindowModel()

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
        } detail: {
            Detail(model: model)
                .inspector(isPresented: inspectorBinding) {
                    if let s = model.current, s.isAwake {
                        // One per session, so nothing it cached about one
                        // tree is shown for another.
                        InspectorView(session: s)
                            .id(s.id)
                            .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
                    }
                }
        }
        .navigationTitle(model.current?.title ?? model.pending.map { Locations.displayName(for: URL(fileURLWithPath: $0)) } ?? "Silt")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .modifier(SearchWhenScanned(model: model))
        .focusedSceneValue(\.windowModel, model)
        .background(WindowAccessor { model.window = $0 })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
                DispatchQueue.main.async { model.scan(url) }
            }
            return true
        }
    }

    private var subtitle: String {
        guard let s = model.current else { return "" }
        if s.phase == .scanning { return "Scanning…" }
        guard s.showsSavedScan else { return "" }
        let what = s.catchingUp ? "catching up…" : "rechecking…"
        guard let saved = s.restoredFrom, Date().timeIntervalSince(saved) >= 60 else { return what.capitalizedFirstLetter }
        return "Scan from \(Fmt.age(UInt32(saved.timeIntervalSince1970))) · \(what)"
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { model.showInspector && model.current != nil }, set: { model.showInspector = $0 })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.current != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.perform(.up)
                } label: {
                    Label("Enclosing Folder", systemImage: "chevron.up")
                }
                .help("Enclosing folder (⌘↑)")
                .disabled(model.current?.focus == 0 || model.pane != .files)
            }
            ToolbarItem(placement: .principal) {
                // The segments show titles only; the symbols are for the
                // toolbar's overflow menu, which draws a segmented picker as
                // a palette of icons. Without them it's a row of blank tiles.
                Picker("View", selection: paneBinding) {
                    ForEach(Pane.allCases) { Label($0.shortTitle, systemImage: $0.symbol).tag($0) }
                }
                .labelStyle(.titleOnly)
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(Pane.allCases.enumerated().map { "\($1.shortTitle) ⌘\($0 + 1)" }.joined(separator: " · "))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan (⇧⌘R)")
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the inspector")
            }
        }
    }

    private var paneBinding: Binding<Pane> {
        Binding(get: { model.pane }, set: {
            model.pane = $0
            model.search = ""
        })
    }
}

/// The search field only exists once there's a scan to search.
private struct SearchWhenScanned: ViewModifier {
    @Bindable var model: WindowModel

    func body(content: Content) -> some View {
        if model.current != nil {
            content.searchable(text: $model.search, placement: .toolbar, prompt: "Search names")
                .onSubmit(of: .search) {
                    // Return in the field moves the keyboard to the results.
                    NotificationCenter.default.post(name: .siltFocusResults, object: nil)
                }
        } else {
            content
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Bindable var model: WindowModel

    var body: some View {
        List(selection: selection) {
            Section("Locations") {
                ForEach(model.locations) { loc in
                    LocationRow(location: loc, session: model.backing(loc.url.path))
                        .tag(loc.url.path)
                }
                ForEach(model.folders, id: \.self) { path in
                    FolderSessionRow(path: path, session: model.backing(path)) { model.closeFolder(path) }
                        .tag(path)
                }
            }
            Section {
                Button {
                    model.chooseFolder()
                } label: {
                    Label("Scan Folder…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .onAppear { model.refreshLocations() }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.viewing ?? model.pending },
            set: { path in
                guard let path, path != model.viewing, path != model.pending else { return }
                model.select(path)
            }
        )
    }
}

private struct LocationRow: View {
    let location: Location
    let session: Session?

    var body: some View {
        HStack(spacing: 8) {
            Label(location.name, systemImage: location.symbol)
                .lineLimit(1)
            Spacer(minLength: 6)
            trailing
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    private var help: String {
        if session != nil { return "" }
        guard let saved = Snapshots.savedAt(for: location.url.path) else { return "Not scanned yet" }
        return "Last scanned \(Fmt.age(UInt32(saved.timeIntervalSince1970)))"
    }

    @ViewBuilder
    private var trailing: some View {
        let own = session?.url.path == location.url.path
        if let session, own, let activity = session.activity {
            ActivityBadge(activity: activity)
        } else if let avail = location.available {
            Text("\(Fmt.bytesShort(avail)) free")
        } else if let session, let size = session.size(ofView: location.url.path) {
            Text(Fmt.bytes(size))
        }
    }
}

/// A folder opened with Scan Folder…: its own scan, or a view into a bigger
/// one that covers it.
private struct FolderSessionRow: View {
    let path: String
    let session: Session?
    let close: () -> Void

    /// Finder's name for each folder. Looking it up reads the disk, and rows
    /// redraw as their scans move along, so it's done once per path.
    private static var displayNames: [String: String] = [:]

    private var displayName: String {
        if let hit = Self.displayNames[path] { return hit }
        let name = FileManager.default.displayName(atPath: path)
        Self.displayNames[path] = name
        return name
    }

    var body: some View {
        HStack(spacing: 8) {
            Label(displayName, systemImage: "folder")
                .lineLimit(1)
            Spacer(minLength: 6)
            Group {
                if let session, session.url.path == path, let activity = session.activity {
                    ActivityBadge(activity: activity)
                } else if let size = session?.size(ofView: path) {
                    Text(Fmt.bytes(size))
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .help(session.map { $0.url.path == path ? path : "\(path), shown from the \($0.title) scan" } ?? path)
        .contextMenu { Button("Close", action: close) }
    }
}

/// Shown for the moment a parked location takes to come back.
private struct WakingView: View {
    let session: Session
    let name: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading \(name)…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { ActivityStrip(activity: Session.Activity(fraction: nil, label: "Loading")) }
    }
}

/// A slim bar along the top of the content while a scan, rescan or catch-up
/// runs: it fills when there's something to measure against and sweeps when
/// there isn't.
struct ActivityStrip: View {
    let activity: Session.Activity?

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .leading) {
                if let activity {
                    StripLayers(fraction: activity.fraction)
                }
            }
        }
        .frame(height: 3)
        .clipped()
        .opacity(activity == nil ? 0 : 1)
        .animation(.easeOut(duration: 0.5), value: activity == nil)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(activity?.label ?? "")
        .accessibilityValue(activity?.fraction.map { Fmt.percent($0) } ?? "")
    }
}

/// A session's strip. It reads the session's activity itself, so as a scan
/// moves along only the strip updates, not the view it sits on.
private struct SessionActivityStrip: View {
    let session: Session

    var body: some View {
        ActivityStrip(activity: session.activity)
    }
}

/// The strip's track, fill and sweep, drawn as Core Animation layers. The
/// render server runs their animations, so a scan doesn't make the app
/// redraw at display rate the whole time it runs.
private struct StripLayers: NSViewRepresentable {
    let fraction: Double?

    func makeNSView(context: Context) -> StripView { StripView() }

    func updateNSView(_ view: StripView, context: Context) {
        view.show(fraction: fraction)
    }
}

private final class StripView: NSView {
    private let track = CALayer()
    private let fill = CALayer()
    private let sweep = CAGradientLayer()
    private var fraction: Double?
    private var shown = false
    /// The width the running sweep was set up for.
    private var sweepWidth: CGFloat?
    private static let cycle = 1.6

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        sweep.anchorPoint = CGPoint(x: 0, y: 0.5)
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        for l in [track, fill, sweep] { layer?.addSublayer(l) }
        applyColors()
        // With Reduce Motion the sweep holds still; follow the setting live.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Clicks go to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Fills to `fraction` (easing there from where it was), or sweeps when
    /// there's nothing to measure against.
    func show(fraction new: Double?) {
        guard !shown || new != fraction else { return }
        let from = fill.bounds.width
        let animate = shown && fraction != nil && new != nil
        fraction = new
        shown = true
        layOut()
        let to = fill.bounds.width
        guard animate, from != to else { return }
        // Additive, so a new value arriving mid-way carries on smoothly from
        // wherever the fill is.
        let a = CABasicAnimation(keyPath: "bounds.size.width")
        a.fromValue = from - to
        a.toValue = 0
        a.isAdditive = true
        a.duration = 0.4
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fill.add(a, forKey: nil)
    }

    override func layout() {
        super.layout()
        layOut()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        applyColors()
        sweepWidth = nil
        startSweep()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    @objc private func motionPreferenceChanged() {
        sweepWidth = nil
        layOut()
    }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The layers are this view's own, so AppKit doesn't match them to the
    /// screen: the gradient would render at 1× on a Retina display.
    private func applyScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [layer, track, fill, sweep].compactMap({ $0 }) { l.contentsScale = scale }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func layOut() {
        let w = bounds.width * 0.3
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        fill.bounds = CGRect(x: 0, y: 0, width: max(3, bounds.width * CGFloat(fraction ?? 0)), height: bounds.height)
        fill.position = CGPoint(x: 0, y: bounds.midY)
        sweep.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
        // Held still in the middle with Reduce Motion; otherwise it starts
        // off the left edge and the animation carries it across.
        sweep.position = CGPoint(x: Self.reduceMotion ? (bounds.width - w) / 2 : -w, y: bounds.midY)
        fill.isHidden = fraction == nil
        sweep.isHidden = fraction != nil
        CATransaction.commit()
        startSweep()
    }

    /// Across and around every 1.6 s. The phase follows the clock, so
    /// strips that take over from each other (loading, then catching up)
    /// don't jump.
    private func startSweep() {
        guard fraction == nil, window != nil, bounds.width > 0, !Self.reduceMotion else {
            sweep.removeAnimation(forKey: "sweep")
            sweepWidth = nil
            return
        }
        guard sweepWidth != bounds.width || sweep.animation(forKey: "sweep") == nil else { return }
        sweepWidth = bounds.width
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -bounds.width * 0.3
        a.toValue = bounds.width
        a.duration = Self.cycle
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .linear)
        a.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
        sweep.add(a, forKey: "sweep")
    }

    private func applyColors() {
        var colors: (track: CGColor, clear: CGColor, full: CGColor)?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = (Brand.ochre.withAlphaComponent(0.15).cgColor, Brand.ochre.withAlphaComponent(0).cgColor,
                      Brand.ochre.cgColor)
        }
        guard let colors else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.backgroundColor = colors.track
        fill.backgroundColor = colors.full
        sweep.colors = [colors.clear, colors.full, colors.clear]
        CATransaction.commit()
    }
}

/// Progress in a sidebar row: a ring and a percentage, or a spinner when
/// there's nothing to measure against.
struct ActivityBadge: View {
    let activity: Session.Activity

    var body: some View {
        HStack(spacing: 5) {
            if let f = activity.fraction {
                Text("\(Int(f * 100))%")
                ProgressView(value: f)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .help(activity.fraction.map { "\(activity.label) · \(Int($0 * 100))%" } ?? activity.label)
    }
}

struct CapacityBar: View {
    let fraction: Double
    /// Share of the volume marked for cleanup: drawn hatched at the end of
    /// the used part, the bit that would come back.
    var marked: Double = 0

    var body: some View {
        GeometryReader { geo in
            let used = geo.size.width * min(1, fraction)
            let staged = min(used, geo.size.width * max(0, marked))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 0.9 ? Color.orange : Brand.color)
                    .frame(width: max(4, used))
                if staged >= 1 {
                    Stripes()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: staged)
                        .offset(x: used - staged)
                        .clipShape(Capsule())
                }
            }
        }
    }
}

/// Diagonal hatching, the app's shorthand for "not settled yet".
struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 4
        var x = rect.minX - rect.height
        while x < rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + 1.5, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + 1.5 + rect.height, y: rect.minY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            p.closeSubpath()
            x += step
        }
        return p
    }
}

/// The strip at the top of every pane: a title, a line of context, and
/// optional trailing content.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var busy = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).fixedSize()
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if busy { ProgressView().controlSize(.mini) }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, busy: Bool = false) {
        self.init(title: title, subtitle: subtitle, busy: busy) { EmptyView() }
    }
}

// MARK: Detail

struct Detail: View {
    @Bindable var model: WindowModel

    var body: some View {
        if let session = model.current, !session.isAwake {
            WakingView(session: session, name: model.viewing.map { FileManager.default.displayName(atPath: $0) } ?? session.title)
        } else if let session = model.current {
            VStack(spacing: 0) {
                content(session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { SessionActivityStrip(session: session) }
                if session.markedCount > 0 {
                    CleanupBar(session: session, reviewing: $model.reviewingCleanup)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                StatusBar(session: session, model: model)
            }
            .overlay(alignment: .bottom) {
                if let toast = session.toast {
                    ToastView(toast: toast)
                        .padding(.bottom, session.markedCount > 0 ? 76 : 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .animation(.spring(duration: 0.35), value: session.toast)
            .animation(.spring(duration: 0.35), value: session.markedCount > 0)
            .sheet(isPresented: $model.reviewingCleanup) {
                CleanupSheet(session: session)
            }
            .id(session.id)
        } else if let path = model.pending {
            ScanPrompt(model: model, path: path)
                .id(path)
        } else {
            StartView(model: model)
        }
    }

    @ViewBuilder
    private func content(_ s: Session) -> some View {
        let query = model.search.trimmingCharacters(in: .whitespaces)
        if query.count >= 2 {
            SearchResults(session: s, query: query)
        } else {
            switch model.pane {
            case .files:
                VStack(spacing: 0) {
                    PathBar(session: s)
                    Divider()
                    TreeView(session: s, source: .folder(s.focus))
                }
            case .largest: LargestFiles(session: s)
            case .duplicates: DuplicatesView(session: s, finder: s.duplicates)
            case .reclaim: ReclaimView(session: s, model: model)
            case .types: TypesView(session: s, model: model)
            }
        }
    }
}

struct PathBar: View {
    let session: Session

    private struct Crumb: Identifiable {
        let id: UInt32
        let name: String
    }

    var body: some View {
        let _ = session.version
        let crumbs = chain()
        let total = session.tree.withLock { () -> (Int64, Int) in
            let d = session.tree.dir(session.focus)
            return (session.tree.entry(d.entry).size, Int(d.items))
        }
        HStack(spacing: 2) {
            ForEach(Array(crumbs.enumerated()), id: \.element.id) { i, c in
                if i > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    session.focus = c.id
                } label: {
                    Text(c.name)
                        .font(.system(size: 13, weight: i == crumbs.count - 1 ? .semibold : .regular))
                        .foregroundStyle(i == crumbs.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 12)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.bytes(total.0))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                Text("\(Fmt.count(total.1)) items")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private func chain() -> [Crumb] {
        let tree = session.tree
        return tree.withLock {
            var out: [Crumb] = []
            var d = session.focus
            while d != NONE {
                let e = tree.entry(tree.dirEntry(d))
                out.append(Crumb(id: d, name: d == 0 ? session.title : tree.name(of: e)))
                d = e.parent
            }
            return out.reversed()
        }
    }
}

struct StatusBar: View {
    let session: Session
    let model: WindowModel
    @State private var showingChanges = false
    @State private var showingBusy = false

    var body: some View {
        let s = session.stats
        // In a narrow window the bar sheds what it can do without (the chips,
        // then the capacity) instead of asking the window for more room: a
        // detail column that needs more than it's given squeezes the sidebar
        // and inspector until they're cut off.
        ViewThatFits(in: .horizontal) {
            row(s, chips: true, capacity: true)
                // The chip it hangs from is gone: don't reopen by itself later.
                .onChange(of: session.busyFolders.isEmpty) { _, empty in if empty { showingBusy = false } }
            row(s, chips: false, capacity: true)
            row(s, chips: false, capacity: false)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func row(_ s: ScanStats, chips showChips: Bool, capacity showCapacity: Bool) -> some View {
        HStack(spacing: 12) {
            leading(s)
            Spacer(minLength: 8)
            if showChips { chips(s) }
            SpeedMenu(compact: !showChips)
            if showCapacity, let cap = session.capacity {
                HStack(spacing: 6) {
                    CapacityBar(fraction: Double(cap.total - cap.available) / Double(max(cap.total, 1)),
                                marked: Double(session.markedBytes) / Double(max(cap.total, 1)))
                        .frame(width: 54, height: 5)
                    Text("\(Fmt.bytes(cap.available)) available")
                        .monospacedDigit()
                }
                .help(session.markedBytes > 0
                      ? "\(Fmt.bytes(session.markedBytes)) marked for cleanup (hatched)"
                      : "\(Fmt.bytes(cap.available)) available of \(Fmt.bytes(cap.total))")
            }
        }
    }

    /// Small, quiet pointers to the next useful thing.
    @ViewBuilder
    private func chips(_ s: ScanStats) -> some View {
        if s.denied > 0 && !model.hasFullDiskAccess {
            Chip(symbol: "lock", text: "\(Fmt.count(s.denied)) folders need Full Disk Access", tint: .orange) {
                FullDiskAccess.openSettings()
            }
        }
        if session.waitingInTrash > 0 {
            Chip(symbol: "trash", text: "\(Fmt.bytes(session.waitingInTrash)) waiting in the Trash · Empty…", tint: Brand.color) {
                session.emptyTrash(window: model.window)
            }
        } else if session.freedBytes > 0 {
            Label("Freed \(Fmt.bytes(session.freedBytes))", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
        if let delta = netChange, !session.changes.isEmpty {
            Chip(symbol: delta >= 0 ? "arrow.up.right" : "arrow.down.right",
                 text: "\(delta >= 0 ? "+" : "−")\(Fmt.bytesShort(abs(delta))) \(sinceText)",
                 tint: delta >= 0 ? .orange : .green) {
                showingChanges.toggle()
            }
            .popover(isPresented: $showingChanges, arrowEdge: .top) {
                ChangesPopover(session: session, title: sinceText.capitalizedFirstLetter) { showingChanges = false }
            }
        }
        if !session.busyFolders.isEmpty {
            let n = session.busyFolders.count
            Chip(symbol: "flame", text: n == 1 ? "1 busy folder" : "\(n) busy folders", tint: .secondary) {
                showingBusy.toggle()
            }
            .popover(isPresented: $showingBusy, arrowEdge: .top) {
                BusyFoldersPopover(folders: session.busyFolders) { showingBusy = false }
            }
            .help("Folders that change constantly, so Silt updates them less often")
        }
        let easy = session.findings.filter { $0.safety == .safe && !$0.isTrash }.reduce(Int64(0)) { $0 + $1.bytes }
        if easy > 500_000_000, session.markedCount == 0, model.pane != .reclaim {
            Chip(symbol: "sparkles", text: "\(Fmt.bytesShort(easy)) easy to reclaim", tint: Brand.color) {
                model.pane = .reclaim
                model.search = ""
            }
        }
    }

    /// The location's own net change (children would double-count).
    private var netChange: Int64? {
        session.changes.isEmpty || abs(session.netChange) < 100_000_000 ? nil : session.netChange
    }

    private var sinceText: String {
        guard let d = session.baselineDate else { return "since the scan" }
        if session.restoredFrom == nil { return "since the scan finished" }
        let age = Date().timeIntervalSince(d)
        if age < 3600 { return "in the last hour" }
        if Calendar.current.isDateInToday(d) { return "since earlier today" }
        if Calendar.current.isDateInYesterday(d) { return "since yesterday" }
        return "since " + d.formatted(.relative(presentation: .named))
    }

    private var restoredAge: String {
        guard let d = session.restoredFrom else { return "" }
        return Fmt.age(UInt32(max(0, d.timeIntervalSince1970)))
    }

    private var showingSaved: String {
        guard let d = session.restoredFrom, Date().timeIntervalSince(d) >= 60 else { return "Showing the last scan" }
        return "Showing the scan from \(restoredAge)"
    }

    private func liveHelp(_ s: ScanStats) -> String {
        if SpeedController.shared.pace.upkeepPaused {
            return "Scan speed is Paused: Silt isn’t following changes on its own. Scans and rescans you start still run. Choose another speed to catch up."
        }
        if session.catchingUp {
            return "These sizes are from the scan saved \(restoredAge). Silt is replaying what changed since; hatched rows may be out of date until it’s done."
        }
        if session.recheckingSince != nil {
            return "The scan saved \(restoredAge) is too old to catch up on, so Silt is reading every folder again. Hatched rows haven’t been checked yet."
        }
        if session.restoredFrom != nil {
            return "Restored from the scan saved \(restoredAge), then caught up with every change since. Watching for more."
        }
        return "Scanned in \(Fmt.duration(s.finished)). Watching for changes."
    }

    @ViewBuilder
    private func leading(_ s: ScanStats) -> some View {
        switch session.phase {
        case .scanning:
            HStack(spacing: 6) {
                if let f = session.activity?.fraction, !session.stalled {
                    ProgressView(value: f)
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                        .controlSize(.small)
                } else {
                    ProgressView().controlSize(.mini)
                }
                if session.stalled {
                    Text("Waiting on macOS — look for a permission prompt")
                        .foregroundStyle(.orange)
                } else if let est = session.scanEstimate, est > 0 {
                    Text("Scanning · \(min(99, s.items * 100 / est))% · \(Fmt.compactCount(s.items)) items")
                        .monospacedDigit()
                } else {
                    Text("Scanning · \(Fmt.compactCount(s.items)) items · \(Fmt.duration(s.elapsed))")
                        .monospacedDigit()
                }
            }
        case .live:
            HStack(spacing: 6) {
                if let r = session.rescanState {
                    // Everything stays usable; this just says how far along it is.
                    ProgressView(value: r.fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                        .controlSize(.small)
                    Text(r.explicit ? "Rescanning in place · \(Int(r.fraction * 100))%"
                         : session.recheckingSince != nil ? "\(showingSaved) · rechecking · \(Int(r.fraction * 100))%"
                         : "Checking for changes · \(Int(r.fraction * 100))%")
                        .monospacedDigit()
                } else if session.catchingUp, SpeedController.shared.pace.upkeepPaused {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text("\(showingSaved) · paused")
                } else if session.catchingUp {
                    ProgressView().controlSize(.mini)
                    Text("\(showingSaved) · catching up")
                } else if SpeedController.shared.pace.upkeepPaused {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text("Paused · \(Fmt.compactCount(s.items)) items")
                        .monospacedDigit()
                } else {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Live · \(Fmt.compactCount(s.items)) items")
                        .monospacedDigit()
                }
            }
            .help(liveHelp(s))
        }
    }
}

private struct Chip: View {
    let symbol: String
    let text: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).foregroundStyle(hovering ? .primary : .secondary)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(hovering ? 0.16 : 0.09), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// What grew or shrank since the baseline; each row jumps to the folder.
private struct ChangesPopover: View {
    let session: Session
    let title: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            ForEach(session.changes) { c in
                Button {
                    session.focus = session.tree.withLock {
                        let p = session.tree.entry(session.tree.dirEntry(c.dir)).parent
                        return p == NONE ? 0 : p
                    }
                    session.reveal(inTree: ItemRef(entry: session.tree.withLock { session.tree.dirEntry(c.dir) }, dir: c.dir))
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Brand.color)
                            .font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).font(.system(size: 12, weight: .medium))
                            Text(c.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 12)
                        Text((c.delta > 0 ? "+" : "−") + Fmt.bytes(abs(c.delta)))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(c.delta > 0 ? Color.orange : Color.green)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Brand.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.system(size: 13, weight: .semibold))
                if let d = toast.detail {
                    Text(d).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if let action = toast.action {
                Button(action.title) { action.run() }
                    .controlSize(.small)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// Hands the hosting NSWindow to the model (for sheets and key-window checks).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

extension Notification.Name {
    static let siltFocusResults = Notification.Name("SiltFocusResults")
}
