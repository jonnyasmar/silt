import AppKit
import SwiftUI

struct ReclaimView: View {
    let session: Session
    let model: WindowModel
    @State private var findings: [Finding] = []
    @State private var analyzing = true
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if analyzing && findings.isEmpty {
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
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: analysisKey) {
            guard session.phase == .live else { return }
            analyzing = true
            if !findings.isEmpty { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled else { return }
            let tree = session.tree
            let focus = session.focus
            let result = await Task.detached(priority: .userInitiated) {
                Reclaim.analyze(tree: tree, under: focus)
            }.value
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { findings = result }
            analyzing = false
        }
    }

    private var analysisKey: String {
        "\(session.focus)-\(session.phase == .live)-\(session.version / 3)"
    }

    private var header: some View {
        let safe = findings.filter { $0.safety == .safe }.reduce(Int64(0)) { $0 + $1.bytes }
        let review = findings.filter { $0.safety == .review }.reduce(Int64(0)) { $0 + $1.bytes }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Reclaim")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            if safe + review > 0 {
                (Text("Silt found up to ") + Text(Fmt.bytes(safe + review)).fontWeight(.semibold).foregroundColor(.primary)
                    + Text(" you could get back in \(session.focus == 0 ? session.title : "this folder")."))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Chip(color: .green, title: "Safe to clear", value: Fmt.bytes(safe))
                    Chip(color: .orange, title: "Worth a look", value: Fmt.bytes(review))
                }
            } else {
                Text("Known caches, build output, installers, and forgotten large files, found from the scan.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, subtitle: String, _ safety: Finding.Safety) -> some View {
        let items = findings.filter { $0.safety == safety }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 15, weight: .semibold))
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
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
                        Text(finding.title).font(.system(size: 13.5, weight: .semibold))
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
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
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
                Members(session: session, entries: finding.isTrash ? finding.entries : finding.entries)
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
                    Image(systemName: "magnifyingglass")
                }
                .help("Show in Finder")
                .controlSize(.small)
                if finding.safety == .safe {
                    Button {
                        confirmTrash()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Move all to Trash")
                    .controlSize(.small)
                }
            }
        }
        .buttonStyle(.bordered)
        .opacity(hovering || expanded ? 1 : 0.55)
    }

    private var refs: [ItemRef] {
        session.tree.withLock { finding.entries.filter { session.tree.isLive($0) }.map { session.ref(forEntry: $0) } }
    }

    private func confirmTrash() {
        let alert = NSAlert()
        alert.messageText = "Move \(finding.title) to the Trash?"
        alert.informativeText = finding.entries.count == 1
            ? "\(Fmt.bytes(finding.bytes)) will move to the Trash."
            : "\(finding.entries.count) folders, \(Fmt.bytes(finding.bytes)) in all, will move to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        let refs = refs
        let run: (NSApplication.ModalResponse) -> Void = { r in
            if r == .alertFirstButtonReturn { session.moveToTrash(refs) }
        }
        if let w = NSApp.keyWindow { alert.beginSheetModal(for: w, completionHandler: run) } else { run(alert.runModal()) }
    }

    private func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "This permanently frees \(Fmt.bytes(finding.bytes)). Finder will ask for permission the first time."
        let b = alert.addButton(withTitle: "Empty Trash")
        b.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let run: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .alertFirstButtonReturn else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
                DispatchQueue.main.async {
                    if let error {
                        session.show(Toast(symbol: "exclamationmark.triangle", title: "Couldn’t empty the Trash",
                                           detail: error[NSAppleScript.errorMessage] as? String))
                    } else {
                        session.show(Toast(symbol: "checkmark.circle", title: "Emptied the Trash", detail: nil))
                    }
                }
            }
        }
        if let w = NSApp.keyWindow { alert.beginSheetModal(for: w, completionHandler: run) } else { run(alert.runModal()) }
    }
}

/// The individual folders/files behind a finding.
private struct Members: View {
    let session: Session
    let entries: [UInt32]

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
                MemberRow(session: session, ref: r.ref, name: r.name, location: r.location, size: r.size, isDir: r.isDir)
            }
            if entries.count > rows.count {
                Text("and \(Fmt.count(entries.count - rows.count)) more")
                    .font(.system(size: 11.5))
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
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isDir ? "folder.fill" : "doc.fill")
                .font(.system(size: 11))
                .foregroundStyle(isDir ? Brand.color : FileCategory.of(name: name).color)
                .frame(width: 16)
            Text(name)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Text(location)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if hovering {
                Button { session.reveal([ref]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                Button { session.moveToTrash([ref]) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Move to Trash")
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
