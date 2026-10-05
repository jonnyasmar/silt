import AppKit
import SwiftUI

/// A strip above the status bar while anything is marked: the running total
/// and the way to act on it. Staging is reversible, so it wears the brand
/// color; red is saved for actually deleting.
struct CleanupBar: View {
    let session: Session
    @Binding var reviewing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Brand.color)
            Text("\(Fmt.count(session.markedCount)) \(session.markedCount == 1 ? "item" : "items") marked for cleanup")
                .font(.system(size: 13, weight: .medium))
            Text(Fmt.bytes(session.markedBytes))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            Button("Unmark All") { session.clearMarks() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            BrandButton("Review & Clean Up…") { reviewing = true }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Brand.color.opacity(0.08))
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy, value: session.markedBytes)
    }
}

/// The last look before anything is removed.
struct CleanupSheet: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var method: Session.CleanupMethod = .trash
    @State private var items: [Session.MarkedItem] = []
    @State private var verdicts: [MarkKey: Guidance] = [:]
    @State private var nested = 0

    private var total: Int64 { items.reduce(0) { $0 + $1.size } }
    private var safeFindings: [Finding] { session.findings.filter { $0.safety == .safe && !$0.isTrash } }
    private var keepers: [Session.MarkedItem] { items.filter { verdicts[$0.key]?.safety == .keep } }
    private var grown: [Session.MarkedItem] { items.filter(\.grew) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 640, height: 580)
        .onAppear(perform: reload)
        .onChange(of: session.markedCount) { reload() }
    }

    private func reload() {
        items = session.markedItems()
        nested = session.nestedMarkCount()
        let tree = session.tree
        verdicts = tree.withLock {
            var out: [MarkKey: Guidance] = [:]
            for item in items where tree.isLive(item.entry) {
                let name = (item.path as NSString).lastPathComponent
                if let g = Guide.classify(tree: tree, entry: item.entry, name: name, path: { item.path }) {
                    out[item.key] = g
                }
            }
            return out
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Clean up \(Fmt.bytes(total))")
                .font(.system(size: 22, weight: .semibold))
                .contentTransition(.numericText())
            Text("\(Fmt.count(items.count)) \(items.count == 1 ? "item" : "items") in \(session.title)."
                 + (nested > 0 ? " \(nested) marked \(nested == 1 ? "item is" : "items are") inside a marked folder and go with it." : ""))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !keepers.isEmpty {
                Label("\(keepers.count == 1 ? "1 item" : "\(keepers.count) items") Silt would keep: "
                      + keepers.prefix(3).map { (($0.path as NSString).lastPathComponent) }.joined(separator: ", "),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
            if !grown.isEmpty {
                Label("\(grown.count == 1 ? "1 item has" : "\(grown.count) items have") grown since you marked "
                      + (grown.count == 1 ? "it" : "them") + ": "
                      + grown.prefix(3).map { (($0.path as NSString).lastPathComponent) }.joined(separator: ", "),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }
            let unmarkedSafe = safeFindings.filter { f in !f.entries.allSatisfy { e in isMarkedEntry(e) } }
            if !unmarkedSafe.isEmpty {
                let bytes = unmarkedSafe.reduce(Int64(0)) { $0 + $1.bytes }
                Button {
                    for f in unmarkedSafe { session.mark(entries: f.entries, reason: f.title) }
                    reload()
                } label: {
                    Label("Also include everything Safe to clear (+\(Fmt.bytes(bytes)))", systemImage: "plus.circle")
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
        }
        .padding(20)
    }

    private func isMarkedEntry(_ e: UInt32) -> Bool {
        let ref = session.tree.withLock { session.tree.isLive(e) ? session.ref(forEntry: e) : nil }
        return ref.map { session.isMarked($0) } ?? true
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    MarkedRow(item: item, verdict: verdicts[item.key]) {
                        session.unmark([item.key])
                        reload()
                    } reveal: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    }
                    Divider().padding(.leading, 48)
                }
            }
        }
        .background(.background)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $method) {
                Text("Move to Trash").tag(Session.CleanupMethod.trash)
                Text("Delete immediately").tag(Session.CleanupMethod.delete)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            Text(projection)
                .font(.system(size: 12))
                .foregroundStyle(method == .trash ? Color.secondary : Color.red)
                .monospacedDigit()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                // Return confirms only the recoverable path; deleting needs a click.
                if method == .trash {
                    BrandButton("Move \(items.count) to Trash") { commit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(items.isEmpty)
                } else {
                    Button("Delete \(items.count) Now") { commit() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(items.isEmpty)
                }
            }
        }
        .padding(20)
    }

    private var projection: String {
        switch method {
        case .trash:
            return "Recoverable from the Trash. \(Fmt.bytes(total)) comes back when you empty it."
        case .delete:
            guard let cap = session.capacity else { return "Frees \(Fmt.bytes(total)) right away. This can’t be undone." }
            return "Frees \(Fmt.bytes(total)) right away: \(Fmt.bytes(cap.available)) → \(Fmt.bytes(cap.available + total)) available. This can’t be undone."
        }
    }

    private func commit() {
        session.cleanUp(method)
        dismiss()
    }
}

private struct MarkedRow: View {
    let item: Session.MarkedItem
    let verdict: Guidance?
    let keep: () -> Void
    let reveal: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text((item.path as NSString).lastPathComponent)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    if let v = verdict { VerdictPill(safety: v.safety) }
                }
                Text(displayFolder)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if item.grew, let before = item.markedSize {
                    Text("Was \(Fmt.bytes(before)) when you marked it"
                         + (item.markedAt.map { " " + Fmt.age(UInt32(clamping: Int($0.timeIntervalSince1970))) } ?? ""))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button(action: reveal) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                Button("Keep", action: keep)
                    .buttonStyle(.borderless)
                    .help("Take it off the cleanup list")
            }
            .opacity(hovering ? 1 : 0)
            Text(Fmt.bytes(item.size))
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var displayFolder: String {
        ((item.path as NSString).deletingLastPathComponent)
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private var icon: NSImage {
        IconCache.icon(forFile: item.path, size: 22)
    }
}

/// Safe / Worth a look / Keep, as a small colored capsule.
struct VerdictPill: View {
    let safety: Guidance.Safety
    var marked = false

    private var look: (String, Color) {
        if marked { return ("Marked for Cleanup", Brand.color) }
        switch safety {
        case .safe: return ("Safe to clear", .green)
        case .review: return ("Worth a look", .orange)
        case .keep: return ("Keep", .secondary)
        }
    }

    var body: some View {
        let (text, color) = look
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}
