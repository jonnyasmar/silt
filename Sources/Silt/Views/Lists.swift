import SwiftUI

/// Recompute keys for list panes: every so often while scanning, then on
/// each change once live (the task debounces those).
@MainActor private func refreshKey(_ session: Session) -> String {
    session.phase == .live ? "live-\(session.quietVersion)" : "scan-\(session.version / 10)"
}

/// Which folder a whole-subtree result was computed for, and its subtree
/// stamp then. While the stamp holds, nothing under the folder changed, so
/// the result still holds too.
struct SubtreeResult: Equatable {
    let dir: UInt32
    let stamp: UInt32

    @MainActor init(_ session: Session, dir: UInt32) {
        self.dir = dir
        let tree = session.tree
        stamp = tree.withLock { tree.stamp(of: dir) }
    }

    /// Whether `previous` is still good. A stamp of 0 means the tree can't
    /// say (it's parked), so the query runs.
    func matches(_ previous: SubtreeResult?) -> Bool {
        stamp != 0 && previous == self
    }
}

/// Runs a whole-tree query off the main thread and tells the session what
/// it cost, so `quietVersion` can pace these passes by what they take.
@MainActor func measuredQuery<T: Sendable>(_ session: Session, priority: TaskPriority,
                                           _ query: @escaping @Sendable () -> T) async -> T {
    let (result, cost) = await Task.detached(priority: priority) {
        let start = ProcessInfo.processInfo.systemUptime
        let result = query()
        return (result, ProcessInfo.processInfo.systemUptime - start)
    }.value
    session.noteQueryCost(cost)
    return result
}

struct LargestFiles: View {
    let session: Session
    @State private var entries: [UInt32] = []
    @State private var stamp = 0
    @State private var computed: SubtreeResult?

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
            let now = SubtreeResult(session, dir: focus)
            if now.matches(computed) { return } // nothing under the folder changed
            let result = await measuredQuery(session, priority: .userInitiated) {
                tree.topFiles(under: focus, limit: 1000)
            }
            guard !Task.isCancelled else { return }
            if result != entries || stamp == 0 {
                entries = result
                stamp += 1
            }
            computed = now
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
