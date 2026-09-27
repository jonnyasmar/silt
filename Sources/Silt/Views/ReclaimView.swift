import AppKit
import SwiftUI

struct ReclaimView: View {
    let session: Session
    let model: WindowModel
    @State private var expanded: Set<String> = []

    private var findings: [Finding] { session.findings(under: session.focus) }
    private var analyzing: Bool { session.analyzing || (session.phase == .live && session.findings.isEmpty && session.version == 0) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                list
            }
        }
        .animation(.easeOut(duration: 0.2), value: findings.map(\.id))
    }

    private var list: some View {
            VStack(alignment: .leading, spacing: 22) {
                if findings.isEmpty && (session.phase == .scanning || session.analyzing) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(session.phase == .scanning ? "Waiting for the scan to finish…" : "Looking for space to reclaim…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 12)
                } else if findings.isEmpty {
                    Text("Nothing obvious to clean up here. Try the Largest Files view.")
                        .foregroundStyle(.secondary)
                } else {
                    group("Safe to clear", subtitle: "Caches and build output that rebuild themselves", .safe)
                    group("Worth a look", subtitle: "Probably unneeded, but only you can say", .review)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    private var header: some View {
        let safe = findings.filter { $0.safety == .safe }.reduce(Int64(0)) { $0 + $1.bytes }
        let review = findings.filter { $0.safety == .review }.reduce(Int64(0)) { $0 + $1.bytes }
        let place = session.focus == 0 ? session.title : session.tree.withLock {
            session.tree.name(of: session.tree.entry(session.tree.dirEntry(session.focus)))
        }
        let safeFindings = findings.filter { $0.safety == .safe && !$0.isTrash }
        return PaneHeader(
            title: "Reclaim",
            subtitle: safe + review > 0
                ? "Up to \(Fmt.bytes(safe + review)) you could get back in \(place)"
                : "Caches, build output, installers, and forgotten large files",
            busy: analyzing && session.phase == .live
        ) {
            if safe + review > 0 {
                HStack(spacing: 8) {
                    Chip(color: .green, title: "Safe", value: Fmt.bytes(safe))
                    Chip(color: .orange, title: "Review", value: Fmt.bytes(review))
                    if !safeFindings.isEmpty {
                        Button("Mark All Safe") {
                            for f in safeFindings { session.mark(entries: f.entries, reason: f.title) }
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Marks every Safe to clear item for review in Cleanup")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, subtitle: String, _ safety: Finding.Safety) -> some View {
        let items = findings.filter { $0.safety == safety }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(items) { f in
                        FindingCard(session: session, finding: f, expanded: expandedBinding(f.id))
                    }
                }
            }
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { on in
            if on { expanded.insert(id) } else { expanded.remove(id) }
        })
    }
}

private struct Chip: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .fixedSize() // the subtitle gives way instead
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.1), in: Capsule())
    }
}

private struct FindingCard: View {
    let session: Session
    let finding: Finding
    @Binding var expanded: Bool
    @State private var hovering = false

    private var tint: Color { finding.safety == .safe ? .green : .orange }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: finding.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(finding.title).font(.system(size: 13, weight: .semibold))
                        if finding.entries.count > 1 || finding.isTrash {
                            Text(countLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(LocalizedStringKey(finding.detail))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Text(Fmt.bytes(finding.bytes))
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                actions
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } }

            if expanded {
                Divider().padding(.horizontal, 12)
                Members(session: session, entries: finding.entries, reason: finding.title)
                    .padding(.vertical, 6)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.07)))
        .onHover { hovering = $0 }
    }

    private var countLabel: String {
        let n = finding.entries.count
        return finding.isTrash ? "\(Fmt.count(n)) items" : "\(Fmt.count(n)) found"
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if finding.isTrash {
                Button("Empty Trash") { emptyTrash() }
                    .controlSize(.small)
            } else {
                Button {
                    session.reveal(Array(refs.prefix(20)))
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Show in Finder")
                .controlSize(.small)
                let marked = allMarked
                if finding.safety == .safe || marked {
                    Button {
                        if marked {
                            let keys = session.tree.withLock { refs.compactMap { session.markKey(for: $0) } }
                            session.unmark(keys)
                        } else {
                            session.mark(entries: finding.entries, reason: finding.title)
                        }
                    } label: {
                        Label(marked ? "Marked" : "Mark", systemImage: marked ? "checkmark.circle.fill" : "checklist")
                    }
                    .help(marked ? "Remove from Cleanup" : "Mark for Cleanup")
                    .controlSize(.small)
                    .tint(marked ? Brand.color : nil)
                } else {
                    // "Only you can say": look at each one rather than marking all.
                    Button("Review") { withAnimation(.easeOut(duration: 0.18)) { expanded = true } }
                        .controlSize(.small)
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private var allMarked: Bool {
        let r = refs
        return !r.isEmpty && r.allSatisfy { session.isMarked($0) }
    }

    private var refs: [ItemRef] {
        session.tree.withLock { finding.entries.filter { session.tree.isLive($0) }.map { session.ref(forEntry: $0) } }
    }

    private func emptyTrash() {
        session.emptyTrash(window: NSApp.keyWindow)
    }
}

/// The individual folders/files behind a finding.
private struct Members: View {
    let session: Session
    let entries: [UInt32]
    var reason = ""

    private struct Row: Identifiable {
        let id: UInt32
        let ref: ItemRef
        let name: String
        let location: String
        let size: Int64
        let isDir: Bool
    }

    var body: some View {
        let rows = load()
        VStack(spacing: 0) {
            ForEach(rows) { r in
                MemberRow(session: session, ref: r.ref, name: r.name, location: r.location, size: r.size, isDir: r.isDir,
                          reason: reason)
            }
            if entries.count > rows.count {
                Text("and \(Fmt.count(entries.count - rows.count)) more")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
        }
    }

    private func load() -> [Row] {
        let tree = session.tree
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return tree.withLock {
            entries.prefix(60).compactMap { i -> Row? in
                guard tree.isLive(i) else { return nil }
                let e = tree.entry(i)
                let path = tree.path(of: i)
                let parent = ((path as NSString).deletingLastPathComponent).replacingOccurrences(of: home, with: "~")
                return Row(id: i, ref: session.ref(forEntry: i), name: tree.name(of: e), location: parent,
                           size: e.size, isDir: e.isDir)
            }
            .sorted { $0.size > $1.size }
        }
    }
}

private struct MemberRow: View {
    let session: Session
    let ref: ItemRef
    let name: String
    let location: String
    let size: Int64
    let isDir: Bool
    let reason: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isDir ? "folder.fill" : "doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(isDir ? Brand.color : FileCategory.of(name: name).color)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
            Text(location)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            let marked = session.isMarked(ref)
            HStack(spacing: 6) {
                Button { session.reveal([ref]) } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Show in Finder")
                Button { session.toggleMarks([ref], reason: reason) } label: {
                    Image(systemName: marked ? "minus.circle" : "checklist")
                }
                .help(marked ? "Remove from Cleanup" : "Mark for Cleanup")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
            if marked {
                Text("Cleanup")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Brand.color)
            }
            Text(Fmt.bytes(size))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
    }
}
