import SwiftUI

/// Recompute keys for list panes: every so often while scanning, then on
/// each change once live (the task debounces those).
@MainActor private func refreshKey(_ session: Session) -> String {
    session.phase == .live ? "live-\(session.quietVersion)" : "scan-\(session.version / 10)"
}

struct LargestFiles: View {
    let session: Session
    @State private var entries: [UInt32] = []
    @State private var stamp = 0

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Largest Files",
                       subtitle: "The 1,000 biggest files in \(focusName). Copies with the same name and size are grouped.",
                       busy: session.phase == .scanning)
            Divider()
            TreeView(session: session, source: .list(id: "largest-\(stamp)", entries: entries, groupCopies: true))
        }
        .task(id: "\(session.focus)|\(refreshKey(session))") {
            if stamp > 0 { try? await Task.sleep(for: .milliseconds(session.phase == .live ? 900 : 0)) }
            guard !Task.isCancelled else { return }
            let tree = session.tree
            let focus = session.focus
            let result = await Task.detached(priority: .userInitiated) {
                tree.topFiles(under: focus, limit: 1000)
            }.value
            guard !Task.isCancelled else { return }
            if result != entries || stamp == 0 {
                entries = result
                stamp += 1
            }
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
            PaneHeader(
                title: "Search",
                subtitle: entries.isEmpty && !searching
                    ? "No names contain “\(query)”"
                    : "\(Fmt.count(entries.count))\(entries.count == 2000 ? "+" : "") matches for “\(resultQuery)”, largest first",
                busy: searching
            )
            Divider()
            TreeView(session: session, source: .list(id: "search-\(stamp)", entries: entries))
        }
        .task(id: "\(query)|\(session.focus)|\(refreshKey(session))") {
            let newQuery = query != resultQuery
            if newQuery { searching = true }
            try? await Task.sleep(for: .milliseconds(newQuery ? 120 : 900))
            guard !Task.isCancelled else { return }
            let tree = session.tree
            let focus = session.focus
            let q = query
            let result = await Task.detached(priority: .userInitiated) {
                tree.search(q, under: focus, limit: 2000)
            }.value
            guard !Task.isCancelled else { return }
            if result != entries || newQuery {
                entries = result
                resultQuery = q
                stamp += 1
            }
            searching = false
        }
    }
}
