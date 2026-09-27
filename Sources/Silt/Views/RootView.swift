import AppKit
import SwiftUI

struct RootView: View {
    @State private var model = WindowModel()

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
        } detail: {
            Detail(model: model)
                .inspector(isPresented: inspectorBinding) {
                    if let s = model.current {
                        InspectorView(session: s)
                            .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
                    }
                }
        }
        .navigationTitle(model.current?.title ?? "Silt")
        .navigationSubtitle(model.current?.phase == .scanning ? "Scanning…" : "")
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
                Picker("View", selection: paneBinding) {
                    ForEach(Pane.allCases) { Text($0.shortTitle).tag($0) }
                }
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
                    LocationRow(location: loc, session: model.sessions.first { $0.url.path == loc.url.path })
                        .tag(loc.url.path)
                }
                ForEach(model.sessions.filter { s in !model.locations.contains { $0.url.path == s.url.path } }) { s in
                    FolderSessionRow(session: s) { model.closeSession(s) }
                        .tag(s.url.path)
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
            get: { model.current?.url.path },
            set: { path in
                guard let path, path != model.current?.url.path else { return }
                model.scan(URL(fileURLWithPath: path))
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
    }

    @ViewBuilder
    private var trailing: some View {
        if let session, let activity = session.activity {
            ActivityBadge(activity: activity)
        } else if let avail = location.available {
            Text("\(Fmt.bytesShort(avail)) free")
        } else if let session {
            Text(Fmt.bytes(session.stats.bytes))
        }
    }
}

private struct FolderSessionRow: View {
    let session: Session
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(session.title, systemImage: "folder")
                .lineLimit(1)
            Spacer(minLength: 6)
            if let activity = session.activity {
                ActivityBadge(activity: activity)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(Fmt.bytes(session.stats.bytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu { Button("Close Scan", action: close) }
    }
}

/// A slim bar along the top of the content while a scan, rescan or catch-up
/// runs: it fills when there's something to measure against and sweeps when
/// there isn't.
struct ActivityStrip: View {
    let activity: Session.Activity?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                if let activity {
                    Rectangle().fill(Brand.color.opacity(0.15))
                    if let f = activity.fraction {
                        Rectangle()
                            .fill(Brand.color)
                            .frame(width: max(3, g.size.width * f))
                            .animation(.easeOut(duration: 0.4), value: f)
                    } else {
                        TimelineView(.animation) { t in
                            let cycle = 1.6
                            let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
                            let w = g.size.width * 0.3
                            Rectangle()
                                .fill(LinearGradient(colors: [Brand.color.opacity(0), Brand.color, Brand.color.opacity(0)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: w)
                                .offset(x: -w + (g.size.width + w) * phase)
                        }
                    }
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
        if let session = model.current {
            VStack(spacing: 0) {
                content(session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { ActivityStrip(activity: session.activity) }
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

    var body: some View {
        let s = session.stats
        HStack(spacing: 12) {
            leading(s)
            Spacer(minLength: 8)
            chips(s)
            if let cap = session.capacity {
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
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
                                    : "Checking for changes · \(Int(r.fraction * 100))%")
                        .monospacedDigit()
                } else if session.catchingUp {
                    ProgressView().controlSize(.mini)
                    Text("Catching up on changes since \(restoredAge)")
                } else {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Live · \(Fmt.compactCount(s.items)) items")
                        .monospacedDigit()
                }
            }
            .help(session.restoredFrom != nil
                  ? "Restored from the scan saved \(restoredAge), then caught up with every change since. Watching for more."
                  : "Scanned in \(Fmt.duration(s.finished)). Watching for changes.")
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
