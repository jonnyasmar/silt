import AppKit
import SiltCore
import SwiftUI

struct InspectorView: View {
    let session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if session.selection.isEmpty, let pick = session.hiddenSelection, let hidden = session.hidden {
                    HiddenSpaceCard(hidden: hidden, highlight: pick, volume: session.title,
                                    used: session.capacity.map { $0.total - $0.free } ?? 0,
                                    deleting: session.deletingSnapshots,
                                    deleteSnapshots: { session.deleteLocalSnapshots(window: NSApp.keyWindow) })
                } else if session.selection.count > 1 {
                    SelectionTotal(session: session, refs: session.selection)
                } else {
                    ItemInspector(session: session, ref: session.selection.first ?? ItemRef(entry: 0, dir: session.focus),
                                  isFocus: session.selection.isEmpty)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One item, or the folder being explored when nothing is selected. What it
/// is (name, kind, icon, guidance) is worked out again only when the item or
/// its folder's contents change; its numbers follow `version`.
private struct ItemInspector: View {
    let session: Session
    let ref: ItemRef
    let isFocus: Bool
    @State private var cache = InspectorCache()

    var body: some View {
        let _ = session.version
        if let item = cache.load(ref, in: session) {
            single(item.header, item.live)
        }
    }

    @ViewBuilder
    private func single(_ h: InspectorCache.Header, _ s: InspectorCache.Live) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: h.icon)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(isFocus ? "\(h.kind) · \(Fmt.count(s.items)) items" : h.kind)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }

        // The folder being explored already shows its total in the path bar,
        // so the hero number is for selections only.
        if !isFocus {
            VStack(alignment: .leading, spacing: 4) {
                let parts = Fmt.bytesParts(s.size)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(parts.number)
                        .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(parts.unit)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if s.parentSize > 0 {
                    Text("\(Fmt.percent(Double(s.size) / Double(s.parentSize))) of \(s.parentName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }

        notes(h, s)

        if !isFocus {
            let marked = session.isMarked(ref)
            HStack(spacing: 8) {
                Button("Show in Finder") { session.reveal([ref]) }
                Button { session.quickLook?() } label: {
                    Image(systemName: "eye")
                }
                .help("Quick Look")
                Button { session.toggleMarks([ref], reason: h.guidance?.title) } label: {
                    Image(systemName: marked ? "minus.circle" : "checklist")
                }
                .help(marked ? "Remove from Cleanup (M)" : "Mark for Cleanup (M)")
                .tint(marked ? Brand.color : nil)
                Button(role: .destructive) { session.moveToTrash([ref]) } label: {
                    Image(systemName: "trash")
                }
                .help("Move to Trash")
            }
            .controlSize(.regular)
            if let g = h.guidance {
                GuidanceCard(guidance: g, marked: marked)
            }
            details(h, s)
        }

        if h.isDir {
            Composition(session: session, dir: ref.dir)
            if !s.top.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Largest inside")
                    ForEach(Array(s.top.enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 8) {
                            Image(systemName: t.isDir ? "folder.fill" : "doc.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(t.isDir ? Brand.color : FileCategory.of(name: t.name).color)
                                .frame(width: 14)
                            Text(t.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(Fmt.bytes(t.size))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notes(_ h: InspectorCache.Header, _ s: InspectorCache.Live) -> some View {
        let f = s.flags
        if s.stale, let saved = session.restoredFrom {
            let age = Fmt.age(UInt32(saved.timeIntervalSince1970))
            Note(symbol: "clock.arrow.circlepath", color: .secondary,
                 text: session.catchingUp
                     ? "From the scan saved \(age). Silt is catching up on what changed since, so this may be out of date."
                     : "From the scan saved \(age). Silt hasn’t read this folder again yet, so it may be out of date.") { EmptyView() }
        }
        if f & UInt8(SILT_FLAG_DENIED) != 0 {
            Note(symbol: "lock", color: .orange,
                 text: "Silt couldn’t read inside this folder, so its size is incomplete.") {
                Button("Grant Full Disk Access") { FullDiskAccess.openSettings() }
                    .controlSize(.small)
            }
        }
        if f & UInt8(SILT_FLAG_MOUNT) != 0 {
            Note(symbol: "externaldrive", color: .secondary,
                 text: "Another volume is mounted here. Scan it from the sidebar.") { EmptyView() }
        }
        if f & UInt8(SILT_FLAG_CLONE) != 0 {
            Note(symbol: "square.on.square.dashed", color: .secondary,
                 text: "An APFS clone: it shares \(Fmt.bytes(h.rawAlloc)) of blocks with other copies, so Silt counts only its share (\(Fmt.bytes(s.size))). Deleting it frees little unless every copy goes.") { EmptyView() }
        }
        if f & UInt8(SILT_FLAG_HARDLINK) != 0 {
            Note(symbol: "link", color: .secondary,
                 text: "A hard link. Its size is split evenly across every link, and deleting one link frees nothing until the last one goes.") { EmptyView() }
        }
        if f & UInt8(SILT_FLAG_DATALESS) != 0 {
            Note(symbol: "icloud", color: .secondary,
                 text: "Stored in iCloud. It isn’t using space on this Mac.") { EmptyView() }
        }
    }

    @ViewBuilder
    private func details(_ h: InspectorCache.Header, _ s: InspectorCache.Live) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Details")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                if h.isDir {
                    GridRow {
                        label("Items")
                        Text(Fmt.count(s.items)).monospacedDigit()
                    }
                }
                GridRow {
                    label(h.isDir ? "Last changed" : "Modified")
                    Text(s.modified == 0 ? "—" : Date(timeIntervalSince1970: TimeInterval(s.modified))
                        .formatted(date: .abbreviated, time: .shortened))
                }
                if s.listedAt > 0 {
                    GridRow {
                        label("Scanned")
                        Text(scanned(s))
                    }
                }
                GridRow {
                    label("Where")
                    Text(displayPath(h.path))
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
        }
    }

    /// When Silt last read the item's folder, and whether it can vouch for it since.
    private func scanned(_ s: InspectorCache.Live) -> String {
        let age = Fmt.age(s.listedAt)
        if s.stale { return "\(age) · not checked again yet" }
        let quiet = Date().timeIntervalSince1970 - TimeInterval(s.listedAt) >= 60
        return quiet && s.flags & UInt8(SILT_FLAG_DENIED) == 0 ? "\(age) · no changes since" : age
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func displayPath(_ p: String) -> String {
        p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}

/// Several items selected: how many, and their total.
private struct SelectionTotal: View {
    let session: Session
    let refs: [ItemRef]

    var body: some View {
        let _ = session.version
        let total = session.tree.withLock {
            refs.reduce(Int64(0)) { $0 + session.tree.entry(session.entryIndex($1)).size }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("\(refs.count) items")
                .font(.system(size: 15, weight: .semibold))
            let parts = Fmt.bytesParts(total)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(parts.number)
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                Text(parts.unit)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 8) {
            Button("Show in Finder") { session.reveal(refs) }
            Button(role: .destructive) { session.moveToTrash(refs) } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }
}

/// What the inspector last worked out for an item, kept across redraws: the
/// parts that say what it is, which are costly (its guidance, icon and kind)
/// and change only when the item's folder is relisted, and the biggest
/// things inside, which change only when its subtree does.
@MainActor
private final class InspectorCache {
    struct Header {
        var name: String
        var path: String
        var isDir: Bool
        var kind: String
        var icon: NSImage
        var guidance: Guidance?
        /// A clone's blocks, shared or not.
        var rawAlloc: Int64 = 0
    }

    struct Live {
        var size: Int64
        var items = 0
        var modified: UInt32
        var flags: UInt8
        var parentName = ""
        var parentSize: Int64 = 0
        /// When its folder (a file's, or its own) was last read; 0 if unknown.
        var listedAt: UInt32 = 0
        /// Possibly still what a saved scan saw.
        var stale = false
        var top: [(name: String, size: Int64, isDir: Bool)] = []
    }

    private struct Run: Equatable {
        var first: UInt32 = 0, count: UInt32 = 0, version: UInt32 = 0
    }

    /// Everything the header depends on. A folder's guidance looks at what's
    /// beside it and inside it, a file's at what's beside it, so a relist of
    /// either redoes it; so do new flags, and a file's new size (a clone's
    /// blocks go with it).
    private struct HeaderKey: Equatable {
        var ref: ItemRef
        var entry: UInt32
        var flags: UInt8
        var fileSize: Int64
        var parent = Run()
        var own = Run()
    }

    private var headerKey: HeaderKey?
    private var header: Header?
    private var topKey: (dir: UInt32, stamp: UInt32)?
    private var top: [(name: String, size: Int64, isDir: Bool)] = []

    func load(_ ref: ItemRef, in session: Session) -> (header: Header, live: Live)? {
        let tree = session.tree
        func run(_ d: silt_dir) -> Run { Run(first: d.first, count: d.count, version: d.version) }
        typealias Read = (key: HeaderKey, live: Live, topDir: UInt32?, stamp: UInt32)
        let read: Read? = tree.withLock {
            let i = session.entryIndex(ref)
            guard tree.isLive(i) else { return nil }
            let e = tree.entry(i)
            var key = HeaderKey(ref: ref, entry: i, flags: e.flags, fileSize: e.isDir ? 0 : e.size)
            var live = Live(size: e.size, modified: e.aux, flags: e.flags)
            if e.isDir || e.parent != NONE {
                let d = tree.dir(e.isDir ? e.aux : e.parent)
                live.listedAt = d.listed_at
                live.stale = session.isStale(d)
            }
            if e.isDir {
                let d = tree.dir(e.aux)
                live.items = Int(d.items)
                live.modified = d.newest
                key.own = run(d)
            }
            if e.parent != NONE {
                let pe = tree.entry(tree.dirEntry(e.parent))
                live.parentName = e.parent == 0 ? session.title : tree.name(of: pe)
                live.parentSize = pe.size
                key.parent = run(tree.dir(e.parent))
            }
            return (key, live, e.isDir ? e.aux : nil, e.isDir ? tree.stamp(of: e.aux) : 0)
        }
        guard let read else { return nil }
        let key = read.key
        var live = read.live

        if key != headerKey || header == nil {
            let made: Header? = tree.withLock {
                guard tree.isLive(key.entry) else { return nil }
                let e = tree.entry(key.entry)
                let name = key.entry == 0 ? session.title : tree.name(of: e)
                let path = tree.path(of: key.entry)
                let guidance = Guide.classify(tree: tree, entry: key.entry, name: name) { path }
                return Header(name: name, path: path, isDir: e.isDir, kind: "", icon: NSImage(), guidance: guidance)
            }
            guard var h = made else { return nil }
            h.kind = kind(of: ref, name: h.name, isDir: h.isDir, isVolume: session.isVolume)
            h.icon = IconCache.icon(forFile: h.path, size: 64)
            if key.flags & UInt8(SILT_FLAG_CLONE) != 0 {
                var st = stat()
                if lstat(h.path, &st) == 0 { h.rawAlloc = Int64(st.st_blocks) * 512 }
            }
            header = h
            headerKey = key
        }

        if let dir = read.topDir {
            // A stamp of 0 means the tree can't say, so look again.
            let stamp = read.stamp
            if topKey.map({ $0.dir != dir || $0.stamp != stamp }) ?? true || stamp == 0 {
                let entries = tree.topChildren(of: dir, limit: 6)
                top = tree.withLock {
                    entries.filter { tree.isLive($0) }.map { c in
                        let ce = tree.entry(c)
                        return (tree.name(of: ce), ce.size, ce.isDir)
                    }
                }
                topKey = (dir, stamp)
            }
            live.top = top
        }
        guard let header else { return nil }
        return (header, live)
    }

    private func kind(of ref: ItemRef, name: String, isDir: Bool, isVolume: Bool) -> String {
        if ref.entry == 0 && ref.dir == 0 { return isVolume ? "Volume" : "Folder" }
        if isDir {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, let t = UTType(filenameExtension: ext, conformingTo: .directory), t.conforms(to: .package) {
                return t.localizedDescription ?? "Package"
            }
            return "Folder"
        }
        let ext = (name as NSString).pathExtension.lowercased()
        // A few extensions map to misleading legacy types ("MacBinary archive").
        if ["bin", "dat", "raw"].contains(ext) { return "Binary data" }
        return UTType(filenameExtension: ext)?.localizedDescription?.capitalizedFirst ?? "File"
    }
}

import UniformTypeIdentifiers

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct Note<Accessory: View>: View {
    let symbol: String
    let color: Color
    let text: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// What a folder is made of, by kind of file.
struct Composition: View {
    let session: Session
    let dir: UInt32
    @State private var parts: [(FileCategory, Int64)] = []
    @State private var total: Int64 = 0
    @State private var computed: SubtreeResult?
    /// The folder on show, for passes that finish after a newer one started.
    @State private var showing: UInt32?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("What’s inside")
            if total > 0 {
                CategoryBar(parts: parts, total: total)
                    .frame(height: 10)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(parts.prefix(5), id: \.0) { cat, bytes in
                        HStack(spacing: 7) {
                            Circle().fill(cat.color).frame(width: 7, height: 7)
                            Text(cat.shortTitle).font(.system(size: 12))
                            Spacer()
                            Text(Fmt.bytes(bytes))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .onChange(of: dir, initial: true) { showing = dir }
        .task(id: "\(dir)-\(session.phase == .live ? session.quietVersion : session.version / 40)") {
            let tree = session.tree
            let d = dir
            let now = SubtreeResult(session, dir: d)
            if now.matches(computed) { return } // nothing under the folder changed
            let stats = await measuredQuery(session, priority: .utility) { tree.extensionStats(under: d, limit: 2000) }
            // Superseded by a newer pass for the same folder, it's still the
            // latest result there is.
            guard !Task.isCancelled || showing == d else { return }
            var byCat: [FileCategory: Int64] = [:]
            for s in stats { byCat[FileCategory.of(extension: s.ext), default: 0] += s.bytes }
            let sorted = byCat.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
            parts = sorted
            total = sorted.reduce(0) { $0 + $1.1 }
            computed = now
        }
    }
}

struct CategoryBar: View {
    let parts: [(FileCategory, Int64)]
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(parts, id: \.0) { cat, bytes in
                    let w = geo.size.width * CGFloat(Double(bytes) / Double(max(total, 1)))
                    if w >= 1 {
                        Rectangle().fill(cat.color).frame(width: max(1, w - 1.5))
                    }
                }
            }
            .clipShape(Capsule())
        }
    }
}

/// "What is this, and can it go?"
private struct GuidanceCard: View {
    let guidance: Guidance
    let marked: Bool

    private var tint: Color {
        switch guidance.safety {
        case .safe: .green
        case .review: .orange
        case .keep: .secondary
        }
    }

    private var verdict: String {
        switch guidance.safety {
        case .safe: "Safe to clear"
        case .review: "Worth a look"
        case .keep: "Keep"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(guidance.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                VerdictPill(safety: guidance.safety, marked: marked)
            }
            Text(LocalizedStringKey(guidance.detail))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.2)))
    }
}

/// The inspector for "System & hidden space": what the volume holds beyond
/// the files Silt can reach, and what (if anything) to do about it.
private struct HiddenSpaceCard: View {
    let hidden: HiddenSpace
    let highlight: String
    let volume: String
    let used: Int64
    let deleting: Bool
    let deleteSnapshots: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("System & hidden space")
                    .font(.system(size: 15, weight: .semibold))
                Text("In use, but outside any folder Silt can read")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }

        VStack(alignment: .leading, spacing: 4) {
            let parts = Fmt.bytesParts(hidden.total)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(parts.number)
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(parts.unit)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if used > 0 {
                Text("\(Fmt.percent(Double(hidden.total) / Double(used))) of what \(volume) has in use")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }

        if !hidden.parts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle("What it is")
                ForEach(hidden.parts) { part in
                    PartRow(part: part, highlighted: highlight == part.id)
                }
            }
        }

        if !hidden.snapshots.isEmpty {
            snapshots
        }
    }

    @ViewBuilder
    private var snapshots: some View {
        let dates = hidden.snapshots.compactMap(LocalSnapshots.date(of:))
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Local snapshots")
            Text(summary(dates))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS deletes them on its own as space runs low, so there’s usually nothing to do. To get the space back now, delete them here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(role: .destructive, action: deleteSnapshots) {
                    Label("Delete Snapshots…", systemImage: "trash")
                }
                .disabled(deleting)
                if deleting {
                    ProgressView().controlSize(.small)
                    Text("Deleting…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Text("That removes Time Machine’s local restore points on this Mac. Backups on your backup disk aren’t touched.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(_ dates: [Date]) -> String {
        let n = hidden.snapshots.count
        let what = "\(n) Time Machine snapshot\(n == 1 ? "" : "s")"
        guard let first = dates.min(), let last = dates.max() else { return what + "." }
        let f = Date.FormatStyle(date: .abbreviated, time: .shortened)
        if n == 1 { return "\(what), from \(first.formatted(f))." }
        return "\(what), taken between \(first.formatted(f)) and \(last.formatted(f))."
    }

    private struct PartRow: View {
        let part: HiddenSpace.Part
        let highlighted: Bool

        private var symbol: String {
            switch part.kind {
            case .purgeable: "clock.arrow.circlepath"
            case .volume: "internaldrive"
            case .unmounted: "externaldrive.badge.minus"
            case .unreadable: "lock"
            }
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(part.title).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 6)
                        Text(Fmt.bytes(part.bytes))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(part.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(highlighted ? 8 : 0)
            .background(highlighted ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
