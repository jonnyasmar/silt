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
                .help("Files ⌘1 · Largest ⌘2 · Reclaim ⌘3 · Types ⌘4")
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
        if let session, session.phase == .scanning {
            ProgressView().controlSize(.mini)
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
            if session.phase == .scanning {
                ProgressView().controlSize(.mini)
            } else {
                Text(Fmt.bytes(session.stats.bytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu { Button("Close Scan", action: close) }
    }
}

struct CapacityBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fraction > 0.9 ? Color.orange : Brand.color)
                    .frame(width: max(4, geo.size.width * min(1, fraction)))
            }
        }
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
            Text(title).font(.system(size: 15, weight: .semibold))
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
                StatusBar(session: session, model: model)
            }
            .overlay(alignment: .bottom) {
                if let toast = session.toast {
                    ToastView(toast: toast)
                        .padding(.bottom, 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .animation(.spring(duration: 0.35), value: session.toast)
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

    var body: some View {
        let s = session.stats
        HStack(spacing: 10) {
            leading(s)
            Spacer(minLength: 8)
            if s.denied > 0 && !model.hasFullDiskAccess {
                Button {
                    FullDiskAccess.openSettings()
                } label: {
                    Label("\(Fmt.count(s.denied)) folders need Full Disk Access", systemImage: "lock")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
            if session.freedBytes > 0 {
                Label("Freed \(Fmt.bytes(session.freedBytes))", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            if let cap = session.capacity {
                HStack(spacing: 6) {
                    CapacityBar(fraction: Double(cap.total - cap.available) / Double(max(cap.total, 1)))
                        .frame(width: 54, height: 5)
                    Text("\(Fmt.bytes(cap.available)) available")
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
                ProgressView().controlSize(.mini)
                if session.stalled {
                    Text("Waiting on macOS — look for a permission prompt")
                        .foregroundStyle(.orange)
                } else {
                    Text("Scanning · \(Fmt.count(s.items)) items · \(Fmt.bytes(s.bytes)) · \(Fmt.duration(s.elapsed))")
                        .monospacedDigit()
                }
            }
        case .live:
            HStack(spacing: 6) {
                if session.catchingUp {
                    ProgressView().controlSize(.mini)
                    Text("Restored the scan from \(restoredAge) · catching up on changes")
                } else {
                    Circle().fill(.green).frame(width: 6, height: 6)
                        .help("Watching for changes")
                    if session.restoredFrom != nil {
                        Text("Live · \(Fmt.count(s.items)) items · restored from \(restoredAge) and caught up")
                            .monospacedDigit()
                    } else {
                        Text("Live · \(Fmt.count(s.items)) items scanned in \(Fmt.duration(s.finished))")
                            .monospacedDigit()
                    }
                }
            }
        }
    }
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
