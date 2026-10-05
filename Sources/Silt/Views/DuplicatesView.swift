import AppKit
import SwiftUI

struct DuplicatesView: View {
    let session: Session
    @Bindable var finder: DuplicateFinder
    @State private var expanded: Set<String> = []
    @State private var cache = ResultsCache()

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Duplicates", subtitle: subtitle, busy: finder.running) {
                if finder.running {
                    Button("Stop") { finder.cancel() }
                        .controlSize(.small)
                } else if !finder.sets.isEmpty {
                    Menu {
                        Picker("Which copy to keep", selection: $finder.keepRule) {
                            ForEach(DuplicateFinder.KeepRule.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text("Keeping: \(finder.keepRule.short)")
                    }
                    .fixedSize()
                    .help("Which copy stays when you mark the rest")
                    Button("Mark All Extras (\(Fmt.bytes(finder.extraBytes)))") { markExtras(finder.sets, announce: true) }
                        .controlSize(.small)
                        .help("Marks every copy except the one kept, for review in Cleanup")
                }
            }
            Divider()
            content
        }
        // Copies move when their folders are relisted, and some go away.
        // Following `quietVersion` keeps that from redrawing every card at
        // tick rate while the disk is busy; what the user just did (marks,
        // trashing, deleting) shows at once.
        .onAppear { finder.prune(tree: session.tree) }
        .onChange(of: session.quietVersion) { finder.prune(tree: session.tree) }
        .onChange(of: UserActions(session)) { finder.prune(tree: session.tree) }
    }

    private var subtitle: String {
        switch finder.phase {
        case .idle: return "Files with identical contents in more than one place"
        case .collecting: return "Gathering candidates…"
        case .comparing(let files, let read, let total):
            let found = finder.sets.isEmpty ? "" : " · \(Fmt.bytes(finder.extraBytes)) found so far"
            return "Comparing \(Fmt.count(files)) files · read \(Fmt.bytes(read)) of up to \(Fmt.bytes(total))" + found
        case .done:
            if finder.sets.isEmpty { return "No duplicates over \(Fmt.bytes(finder.minSize))" }
            return "\(Fmt.bytes(finder.extraBytes)) in extra copies across \(Fmt.count(finder.sets.count)) sets"
                + (finder.truncated ? " · stopped at 1M candidates" : "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if finder.phase == .idle {
            start
        } else if finder.sets.isEmpty {
            if finder.running {
                VStack(spacing: 12) {
                    progressBar.frame(width: 320)
                    Text("Largest matches show up here as soon as they’re confirmed.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 30))
                        .foregroundStyle(.green)
                    Text("No duplicates found").font(.system(size: 15, weight: .semibold))
                    Button("Search Again") { finder.run(session: session) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            results
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if case .comparing(_, let read, let total) = finder.phase, total > 0 {
            ProgressView(value: Double(read), total: Double(max(total, read)))
        } else {
            ProgressView().progressViewStyle(.linear)
        }
    }

    private var start: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.on.square")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Brand.color)
            Text("Find files that exist more than once")
                .font(.system(size: 15, weight: .semibold))
            Text("Silt compares sizes first, then samples, and only reads whole files that could match. APFS clones already share their space, so they aren’t counted as waste.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 14) {
                Picker("Files over", selection: $finder.minSize) {
                    Text("1 MB").tag(Int64(1_000_000))
                    Text("10 MB").tag(Int64(10_000_000))
                    Text("100 MB").tag(Int64(100_000_000))
                }
                .fixedSize()
                // Apps' insides and version-control stores stay out either way.
                Toggle("Include dependency & build folders", isOn: $finder.includeManaged)
                    .toggleStyle(.checkbox)
            }
            .font(.system(size: 12))
            Button("Find Duplicates") { finder.run(session: session) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(session.phase != .live)
            if session.phase != .live {
                Text("Available when the scan finishes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        // Sets that share a file name get their folder added to tell them apart.
        let shared = cache.sharedNames(finder.sets)
        // One pass over the marks for every card, instead of a lookup per row.
        let marked = cache.markedPaths(session)
        return ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(finder.sets.prefix(2000)) { set in
                    SetCard(session: session, finder: finder, group: set, keeper: finder.keeper(of: set),
                            disambiguate: shared.contains(set.copies.first?.name ?? ""), marked: marked,
                            expanded: expandedBinding(set.id)) {
                        markExtras([set], announce: false)
                    }
                }
                if finder.sets.count > 2000 {
                    Text("and \(Fmt.count(finder.sets.count - 2000)) smaller sets")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { on in
            if on { expanded.insert(id) } else { expanded.remove(id) }
        })
    }

    private func markExtras(_ sets: [DuplicateSet], announce: Bool) {
        let rule = finder.keepRule
        Task {
            // Re-checking every copy touches the disk: keep it off the main thread.
            let (copies, changed) = await Task.detached(priority: .userInitiated) {
                DuplicateFinder.extraCopies(of: sets, rule: rule)
            }.value
            finishMarking(copies: copies, of: sets, changed: changed, announce: announce)
        }
    }

    /// Marks by the identity each copy was just checked against, so nothing
    /// is looked up on disk again here.
    private func finishMarking(copies: [DuplicateSet.Copy], of sets: [DuplicateSet], changed: Int, announce: Bool) {
        session.mark(copies: copies, of: sets, reason: "Duplicate")
        if changed > 0 {
            session.show(Toast(symbol: "exclamationmark.triangle",
                               title: "\(changed) \(changed == 1 ? "copy" : "copies") changed since the search",
                               detail: "They weren’t marked. Search again to compare them fresh."))
        } else if announce {
            session.show(Toast(symbol: "checklist", title: "Marked \(Fmt.count(copies.count)) extra copies",
                               detail: "Review them in Cleanup before anything is removed."))
        }
    }
}

/// What the user does that can take copies away: marking, trashing,
/// deleting.
private struct UserActions: Equatable {
    let marked: Int
    let trashed: Int64
    let freed: Int64

    @MainActor init(_ session: Session) {
        marked = session.markedCount
        trashed = session.trashedBytes
        freed = session.freedBytes
    }
}

/// What the results list derives from the sets and the marks, kept until
/// either changes: the view redraws often while a search streams in.
@MainActor
private final class ResultsCache {
    /// Each set's first copy, which is what names the set.
    private var firsts: [String] = []
    private var shared: Set<String> = []
    /// The marks, and how many of them still resolve (one whose item went
    /// away drops out of the paths).
    private var marks: (keys: Set<MarkKey>, live: Int)?
    private var marked: Set<String> = []

    /// File names more than one set goes by.
    func sharedNames(_ sets: [DuplicateSet]) -> Set<String> {
        let now = sets.map { $0.copies.first?.path ?? "" }
        guard now != firsts else { return shared }
        firsts = now
        var seen: Set<String> = []
        shared = []
        for path in now {
            let name = (path as NSString).lastPathComponent
            if !seen.insert(name).inserted { shared.insert(name) }
        }
        return shared
    }

    func markedPaths(_ session: Session) -> Set<String> {
        let keys = Set(session.marks.keys)
        let live = session.markedCount
        if let marks, marks.keys == keys, marks.live == live { return marked }
        marks = (keys, live)
        marked = session.markedPaths()
        return marked
    }
}

private struct SetCard: View {
    let session: Session
    let finder: DuplicateFinder
    let group: DuplicateSet
    let keeper: DuplicateSet.Copy?
    let disambiguate: Bool
    let marked: Set<String>
    @Binding var expanded: Bool
    let markExtras: () -> Void
    @State private var hovering = false

    private var extras: [DuplicateSet.Copy] {
        group.copies.filter { $0.path != keeper?.path && $0.family != keeper?.family }
    }

    private var allMarked: Bool {
        let e = extras
        return !e.isEmpty && e.allSatisfy { marked.contains($0.path) }
    }

    var body: some View {
        let isMarked = allMarked
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.copies.first?.name ?? "")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if disambiguate, let k = keeper {
                            Text((k.folder as NSString).lastPathComponent)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.bytes(group.extraBytes))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    Text("\(group.families - 1) extra")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button {
                    if isMarked {
                        let refs = session.liveRefs(paths: extras.map(\.path))
                        let keys = session.tree.withLock { refs.compactMap { session.markKey(for: $0) } }
                        session.unmark(keys)
                    } else {
                        markExtras()
                    }
                } label: {
                    Label(isMarked ? "Marked" : "Mark Extras", systemImage: isMarked ? "checkmark.circle.fill" : "checklist")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(isMarked ? Brand.color : nil)
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
                VStack(spacing: 0) {
                    ForEach(group.copies) { copy in
                        CopyRow(session: session, set: group, copy: copy, keep: copy.path == keeper?.path,
                                cloneOfKeeper: copy.path != keeper?.path && copy.family == keeper?.family,
                                marked: marked.contains(copy.path))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(hovering ? 0.14 : 0.07)))
        .onHover { hovering = $0 }
    }

    private var summary: String {
        let where_ = keeper.map {
            $0.folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        } ?? ""
        var s = "\(group.copies.count) copies of \(Fmt.bytes(group.size)) · keeping the \(finder.keepRule.short) in \(where_)"
        if group.families < group.copies.count { s += " · some are clones" }
        return s
    }

    private var icon: NSImage {
        IconCache.icon(forFile: group.copies.first?.path ?? "/", size: 30)
    }
}

private struct CopyRow: View {
    let session: Session
    let set: DuplicateSet
    let copy: DuplicateSet.Copy
    let keep: Bool
    let cloneOfKeeper: Bool
    let marked: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                // Marked comes first: a copy marked under another keep rule
                // is still going, whatever this rule would keep.
                if marked {
                    Text("Cleanup").foregroundStyle(Brand.color)
                } else if keep {
                    Text("Keep").foregroundStyle(.green)
                } else if cloneOfKeeper {
                    Text("Clone").foregroundStyle(.secondary)
                        .help("Shares its blocks with the kept copy: removing it frees almost nothing")
                } else {
                    Text("Extra").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayFolder)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .strikethrough(marked)
                Text(copy.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.path)])
                } label: { Image(systemName: "arrow.up.right.square") }
                    .help("Show in Finder")
                Button {
                    if !session.toggleMark(copy: copy, of: set, reason: "Duplicate") {
                        session.show(Toast(symbol: "exclamationmark.triangle", title: "This copy changed since the search",
                                           detail: "It wasn’t marked. Search again to compare it fresh."))
                    }
                } label: {
                    Image(systemName: marked ? "minus.circle" : "checklist")
                }
                .help(marked ? "Remove from Cleanup" : "Mark for Cleanup")
                .disabled(keep && !marked)
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .onHover { hovering = $0 }
    }

    private var displayFolder: String {
        copy.folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
