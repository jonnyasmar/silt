import AppKit
import SiltCore
import SwiftUI

struct InspectorView: View {
    let session: Session

    private struct Summary {
        var ref: ItemRef
        var name: String
        var path: String
        var isDir: Bool
        var size: Int64
        var items: Int
        var modified: UInt32
        var flags: UInt8
        var parentName: String
        var parentSize: Int64
        var top: [(name: String, size: Int64, isDir: Bool)]
        var guidance: Guidance?
        var rawAlloc: Int64 = 0
    }

    var body: some View {
        let _ = session.version
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if session.selection.isEmpty, let pick = session.hiddenSelection, let hidden = session.hidden {
                    HiddenSpaceCard(hidden: hidden, highlight: pick, volume: session.title,
                                    used: session.capacity.map { $0.total - $0.free } ?? 0)
                } else if session.selection.count > 1 {
                    multiple
                } else if let s = summary(for: session.selection.first ?? ItemRef(entry: 0, dir: session.focus)) {
                    single(s)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Single

    @ViewBuilder
    private func single(_ s: Summary) -> some View {
        let isFocus = session.selection.isEmpty
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: bigIcon(s.path))
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(isFocus ? "\(kind(s)) · \(Fmt.count(s.items)) items" : kind(s))
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

        notes(s)

        if !isFocus {
            let marked = session.isMarked(s.ref)
            HStack(spacing: 8) {
                Button("Show in Finder") { session.reveal([s.ref]) }
                Button { session.quickLook?() } label: {
                    Image(systemName: "eye")
                }
                .help("Quick Look")
                Button { session.toggleMarks([s.ref], reason: s.guidance?.title) } label: {
                    Image(systemName: marked ? "minus.circle" : "checklist")
                }
                .help(marked ? "Remove from Cleanup (M)" : "Mark for Cleanup (M)")
                .tint(marked ? Brand.color : nil)
                Button(role: .destructive) { session.moveToTrash([s.ref]) } label: {
                    Image(systemName: "trash")
                }
                .help("Move to Trash")
            }
            .controlSize(.regular)
            if let g = s.guidance {
                GuidanceCard(guidance: g, marked: marked)
            }
            details(s)
        }

        if s.isDir {
            Composition(session: session, dir: s.ref.dir)
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
    private func notes(_ s: Summary) -> some View {
        let f = s.flags
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
                 text: "An APFS clone: it shares \(Fmt.bytes(s.rawAlloc)) of blocks with other copies, so Silt counts only its share (\(Fmt.bytes(s.size))). Deleting it frees little unless every copy goes.") { EmptyView() }
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
    private func details(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Details")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                if s.isDir {
                    GridRow {
                        label("Items")
                        Text(Fmt.count(s.items)).monospacedDigit()
                    }
                }
                GridRow {
                    label(s.isDir ? "Last changed" : "Modified")
                    Text(s.modified == 0 ? "—" : Date(timeIntervalSince1970: TimeInterval(s.modified))
                        .formatted(date: .abbreviated, time: .shortened))
                }
                GridRow {
                    label("Where")
                    Text(displayPath(s.path))
                        .lineLimit(4)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 12))
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    // MARK: Multiple

    @ViewBuilder
    private var multiple: some View {
        let refs = session.selection
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

    // MARK: Data

    private func summary(for ref: ItemRef) -> Summary? {
        let tree = session.tree
        let dirForTop: UInt32? = tree.withLock {
            let i = session.entryIndex(ref)
            let e = tree.entry(i)
            return tree.isLive(i) && e.isDir ? e.aux : nil
        }
        let topEntries = dirForTop.map { tree.topChildren(of: $0, limit: 6) } ?? []
        return tree.withLock {
            let i = session.entryIndex(ref)
            guard tree.isLive(i) else { return nil }
            let e = tree.entry(i)
            var s = Summary(ref: ref, name: i == 0 ? session.title : tree.name(of: e), path: tree.path(of: i),
                            isDir: e.isDir, size: e.size, items: 0, modified: e.aux, flags: e.flags,
                            parentName: "", parentSize: 0, top: [])
            if e.isDir {
                let d = tree.dir(e.aux)
                s.items = Int(d.items)
                s.modified = d.newest
                s.top = topEntries.filter { tree.isLive($0) }.map { c in
                    let ce = tree.entry(c)
                    return (tree.name(of: ce), ce.size, ce.isDir)
                }
            }
            if e.parent != NONE {
                let pe = tree.entry(tree.dirEntry(e.parent))
                s.parentName = e.parent == 0 ? session.title : tree.name(of: pe)
                s.parentSize = pe.size
            }
            s.guidance = Guide.classify(tree: tree, entry: i, name: s.name) { tree.path(of: i) }
            if e.flags & UInt8(SILT_FLAG_CLONE) != 0 {
                var st = stat()
                if lstat(s.path, &st) == 0 { s.rawAlloc = Int64(st.st_blocks) * 512 }
            }
            return s
        }
    }

    private func kind(_ s: Summary) -> String {
        if s.ref.entry == 0 && s.ref.dir == 0 { return session.isVolume ? "Volume" : "Folder" }
        if s.isDir {
            let ext = (s.name as NSString).pathExtension
            if !ext.isEmpty, let t = UTType(filenameExtension: ext, conformingTo: .directory), t.conforms(to: .package) {
                return t.localizedDescription ?? "Package"
            }
            return "Folder"
        }
        let ext = (s.name as NSString).pathExtension.lowercased()
        // A few extensions map to misleading legacy types ("MacBinary archive").
        if ["bin", "dat", "raw"].contains(ext) { return "Binary data" }
        return UTType(filenameExtension: ext)?.localizedDescription?.capitalizedFirst ?? "File"
    }

    private func displayPath(_ p: String) -> String {
        p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func bigIcon(_ path: String) -> NSImage {
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 64, height: 64)
        return i
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
        .task(id: "\(dir)-\(session.phase == .live ? session.quietVersion : session.version / 40)") {
            let tree = session.tree
            let d = dir
            let stats = await Task.detached(priority: .utility) { tree.extensionStats(under: d, limit: 2000) }.value
            var byCat: [FileCategory: Int64] = [:]
            for s in stats { byCat[FileCategory.of(extension: s.ext), default: 0] += s.bytes }
            let sorted = byCat.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
            parts = sorted
            total = sorted.reduce(0) { $0 + $1.1 }
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
    @State private var copied = false

    private static let command = "tmutil deletelocalsnapshots /"

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
            Text("macOS deletes them on its own as space runs low, so there’s usually nothing to do. To get the space back now, run this in Terminal:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(Self.command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.command, forType: .string)
                    copied = true
                }
                .controlSize(.small)
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
