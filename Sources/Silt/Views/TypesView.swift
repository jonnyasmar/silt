import SwiftUI

struct TypesView: View {
    let session: Session
    let model: WindowModel
    @State private var stats: [Tree.ExtStat] = []
    @State private var loading = true

    private var total: Int64 { stats.reduce(0) { $0 + $1.bytes } }

    private var categories: [(FileCategory, Int64)] {
        var m: [FileCategory: Int64] = [:]
        for s in stats { m[FileCategory.of(extension: s.ext), default: 0] += s.bytes }
        return m.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "File Types",
                       subtitle: "Space by kind of file. Click an extension to find those files.",
                       busy: loading)
            Divider()
            ScrollView { content }
        }
        .task(id: "\(session.focus)-\(session.phase == .live ? session.quietVersion : session.version / 40)") {
            let tree = session.tree
            let focus = session.focus
            let result = await Task.detached(priority: .userInitiated) {
                tree.extensionStats(under: focus, limit: 400)
            }.value
            stats = result
            loading = false
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 20) {
                if loading && stats.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    let cats = categories
                    CategoryBar(parts: cats, total: total)
                        .frame(height: 16)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], alignment: .leading, spacing: 10) {
                        ForEach(cats, id: \.0) { cat, bytes in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3).fill(cat.color).frame(width: 10, height: 10)
                                Text(cat.shortTitle).font(.system(size: 13)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Fmt.bytes(bytes))
                                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                                Text(Fmt.percent(Double(bytes) / Double(max(total, 1))))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                    extensions
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
    }

    private var extensions: some View {
        let top = stats.prefix(120)
        let biggest = top.first?.bytes ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Extension").padding(.leading, 14).frame(width: 120, alignment: .leading)
                Text("Kind").frame(width: 110, alignment: .leading)
                Spacer()
                Text("Files").frame(width: 80, alignment: .trailing)
                Text("Size").frame(width: 84, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Divider()
            ForEach(Array(top.enumerated()), id: \.offset) { i, s in
                ExtRow(stat: s, fraction: Double(s.bytes) / Double(biggest), striped: i % 2 == 1) {
                    guard !s.ext.isEmpty, s.ext != "*" else { return }
                    model.search = "." + s.ext
                }
            }
        }
    }
}

private struct ExtRow: View {
    let stat: Tree.ExtStat
    let fraction: Double
    let striped: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let cat = FileCategory.of(extension: stat.ext)
        Button(action: action) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(cat.color).frame(width: 7, height: 7)
                    Text(stat.ext.isEmpty ? "No extension" : stat.ext == "*" ? "Everything else" : "." + stat.ext)
                        .font(.system(size: 13, design: stat.ext.isEmpty || stat.ext == "*" ? .default : .monospaced))
                        .lineLimit(1)
                }
                .frame(width: 120, alignment: .leading)
                Text(cat.shortTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                GeometryReader { geo in
                    Capsule().fill(cat.color.opacity(0.75))
                        .frame(width: max(3, geo.size.width * fraction), height: 5)
                        .frame(maxHeight: .infinity)
                }
                .frame(height: 20)
                Text(Fmt.count(stat.count))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
                Text(Fmt.bytes(stat.bytes))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(hovering ? Color.primary.opacity(0.06) : striped ? Color.primary.opacity(0.02) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
