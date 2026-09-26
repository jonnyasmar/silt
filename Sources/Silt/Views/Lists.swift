import SwiftUI

/// A header over a flat list view.
private struct ListHeader: View {
    let title: String
    let subtitle: String
    var busy = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            if busy { ProgressView().controlSize(.mini) }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

struct LargestFiles: View {
    let session: Session
    @State private var entries: [UInt32] = []
    @State private var computedFor: String = ""

    var body: some View {
        let key = "\(session.focus):\(session.phase == .live ? "live" : "scan-\(session.version / 25)")"
        VStack(spacing: 0) {
            ListHeader(title: "Largest Files", subtitle: "The 1,000 biggest files in \(focusName)",
                       busy: session.phase == .scanning)
            Divider()
            TreeView(session: session, source: .list(id: "largest-\(computedFor)", entries: entries))
        }
        .task(id: key) {
            let tree = session.tree
            let focus = session.focus
            let result = await Task.detached(priority: .userInitiated) {
                tree.topFiles(under: focus, limit: 1000)
            }.value
            entries = result
            computedFor = key
        }
    }

    private var focusName: String {
        session.focus == 0 ? session.title : session.tree.withLock {
            session.tree.name(of: session.tree.entry(session.tree.dirEntry(session.focus)))
        }
    }
}

struct SearchResults: View {
    let session: Session
    let query: String
    @State private var entries: [UInt32] = []
    @State private var resultQuery = ""
    @State private var searching = false
    @State private var stamp = 0

    var body: some View {
        VStack(spacing: 0) {
            ListHeader(
                title: "Search",
                subtitle: entries.isEmpty && !searching
                    ? "No names contain “\(query)”"
                    : "\(Fmt.count(entries.count))\(entries.count == 2000 ? "+" : "") matches for “\(resultQuery)”, largest first",
                busy: searching
            )
            Divider()
            TreeView(session: session, source: .list(id: "search-\(stamp)", entries: entries))
        }
        // Re-run as a scan fills in, then once more when it finishes.
        .task(id: "\(query)|\(session.focus)|\(session.phase == .live ? "live" : String(session.version / 10))") {
            searching = true
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let tree = session.tree
            let focus = session.focus
            let q = query
            let result = await Task.detached(priority: .userInitiated) {
                tree.search(q, under: focus, limit: 2000)
            }.value
            guard !Task.isCancelled else { return }
            entries = result
            resultQuery = q
            stamp += 1
            searching = false
        }
    }
}
