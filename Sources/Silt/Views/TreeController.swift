import AppKit
import Quartz
import SiltCore
import SwiftUI

enum TreeSource: Equatable {
    /// A folder's contents, drillable.
    case folder(UInt32)
    /// A flat, precomputed list of entries (largest files, search results…).
    /// With `groupCopies`, files sharing a name and size fold into one row.
    case list(id: String, entries: [UInt32], groupCopies: Bool = false)

    var isList: Bool {
        if case .list = self { return true }
        return false
    }

    static func == (a: TreeSource, b: TreeSource) -> Bool {
        switch (a, b) {
        case let (.folder(x), .folder(y)): x == y
        case let (.list(x, _, _), .list(y, _, _)): x == y
        default: false
        }
    }
}

final class SiltOutlineView: NSOutlineView {
    weak var controller: TreeController?

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if event.charactersIgnoringModifiers == " " && plain {
            controller?.toggleQuickLook()
            return
        }
        if event.charactersIgnoringModifiers?.lowercased() == "m" && plain {
            controller?.toggleMarkOnSelection()
            return
        }
        super.keyDown(with: event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = controller
        panel.delegate = controller
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

/// How the file tree was left: which folders were open, what was selected,
/// and what was at the top, so coming back to a location or pane looks the
/// same. Folders are kept by dir id, which survives refreshes.
struct TreeState {
    var expanded: [UInt32] = [] // outermost first
    var selection: [ItemRef] = []
    var top: ItemRef?
}

/// Drives one NSOutlineView over a session's tree: lazy children, live
/// refresh while a scan runs, animated re-sorting, and the item actions.
@MainActor
final class TreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate
{
    let session: Session
    let outline = SiltOutlineView()
    let scroll = NSScrollView()
    private(set) var source: TreeSource
    private var root: Node
    /// Folder mode only: a folder appears at most once in a hierarchy, so
    /// one node per dir id keeps expansion state across refreshes. Lists
    /// can show a folder both as a hit and inside another hit, so they build
    /// nodes per parent instead.
    private var dirNodes: [UInt32: Node] = [:]
    private var sortKey: SortKey = .size
    private var ascending = false
    /// A re-sort held back by pacing is picked up by this one-shot timer:
    /// the listener only fires when the tree changes again.
    private var resortTimer: Timer?
    private var resortDue: CFTimeInterval = .infinity
    /// One row's values, shared by its cells while the outline builds them,
    /// so the tree is read once per row rather than once per column. Only
    /// good until the current main-queue turn ends.
    private var cachedRow: (node: Node, values: RowValues)?
    private var focusObserver: NSObjectProtocol?
    private var quickLookURLs: [URL] = []
    /// Folders that became expandable while being rebuilt; the outline must
    /// be told or it keeps showing them without a disclosure triangle.
    private var expandFlips: [Node] = []
    /// Largest top-level size in a list, which list bars are scaled to.
    private var listMax: Int64 = 1
    private var locationCache: [UInt32: String] = [:]
    private var tree: Tree { session.tree }
    private var sharesDirNodes: Bool { !source.isList }
    private static let maxChildren = 20_000
    /// Folders with more children than this are sorted without holding the
    /// tree lock, so a big sort doesn't keep the scanner from committing.
    private static let unlockedSortMin = 2_000
    /// Rows a relist may add or remove before the folder is simply reloaded.
    private static let maxRowChanges = 64
    /// What an order is sorted by, to tell when a folder's is out of date.
    private var sortTag: Int { Int(sortKey.rawValue) * 2 + (ascending ? 1 : 0) }

    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let shareColumn = NSUserInterfaceItemIdentifier("share")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    private static let itemsColumn = NSUserInterfaceItemIdentifier("items")
    private static let modifiedColumn = NSUserInterfaceItemIdentifier("modified")
    private static let locationColumn = NSUserInterfaceItemIdentifier("location")

    init(session: Session, source: TreeSource) {
        self.session = session
        self.source = source
        root = Node(summary: .list, parent: nil)
        super.init()
        root = makeRoot(for: source)
        configureOutline()
        session.addListener(self) { [weak self] in self?.treeChanged() }
        if !source.isList {
            session.captureTreeState = { [weak self] in
                guard let self, !self.source.isList else { return }
                self.session.treeStates[self.root.dir] = self.captureState()
            }
        }
        if source.isList {
            focusObserver = NotificationCenter.default.addObserver(forName: .siltFocusResults, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.outline.window else { return }
                    window.makeFirstResponder(self.outline)
                    if self.outline.selectedRow < 0, self.outline.numberOfRows > 0 {
                        self.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    }
                }
            }
        }
    }

    func teardown() {
        if !source.isList { session.treeStates[root.dir] = captureState() }
        // What this tree selected goes with it, so ⌘⌫ can't act on rows nobody
        // can see (the Files tree brings its selection back when it returns).
        // A tree that replaced this one may have selected already: leave that.
        if session.selection == selectedNodes().filter(\.isReal).map(\.ref) { session.selection = [] }
        session.removeListener(self)
        resortTimer?.invalidate()
        resortTimer = nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
    }

    // MARK: Setup

    private func configureOutline() {
        outline.controller = self
        outline.style = .inset
        outline.rowHeight = 24
        outline.intercellSpacing = NSSize(width: 8, height: 0)
        outline.indentationPerLevel = 14
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = false
        outline.gridStyleMask = []
        outline.autosaveExpandedItems = false
        outline.floatsGroupRows = false
        outline.allowsColumnReordering = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.setDraggingSourceOperationMask([.copy, .move, .delete], forLocal: false)
        outline.menu = {
            let m = NSMenu()
            m.delegate = self
            return m
        }()

        @discardableResult
        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat,
                    sortKey: String?, ascending: Bool = false, align: NSTextAlignment = .left) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = min
            c.resizingMask = .userResizingMask
            c.headerCell.alignment = align
            if let sortKey { c.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: ascending) }
            outline.addTableColumn(c)
            return c
        }

        if source.isList {
            // The location is the long, flexible part of a list row.
            let name = column(Self.nameColumn, "Name", width: 230, min: 180, sortKey: "name", ascending: true)
            outline.outlineTableColumn = name
            column(Self.shareColumn, shareTitle, width: 100, min: 70, sortKey: "share")
            column(Self.sizeColumn, "Size", width: 84, min: 70, sortKey: "size", align: .right)
            column(Self.modifiedColumn, "Modified", width: 108, min: 80, sortKey: "modified", align: .right)
            // Starts at its minimum so the table never begins wider than the
            // view; growth then flows into it.
            let location = column(Self.locationColumn, "Location", width: 80, min: 80, sortKey: nil)
            location.resizingMask = [.autoresizingMask, .userResizingMask]
            outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        } else {
            // Starts narrow; as the first column it absorbs whatever width is left.
            let name = column(Self.nameColumn, "Name", width: 200, min: 180, sortKey: "name", ascending: true)
            name.resizingMask = [.autoresizingMask, .userResizingMask]
            outline.outlineTableColumn = name
            column(Self.shareColumn, "Share", width: 116, min: 70, sortKey: "share")
            column(Self.sizeColumn, "Size", width: 84, min: 70, sortKey: "size", align: .right)
            column(Self.itemsColumn, "Items", width: 76, min: 56, sortKey: "items", align: .right)
            column(Self.modifiedColumn, "Modified", width: 108, min: 80, sortKey: "modified", align: .right)
            outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        }
        outline.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]

        // The table stays exactly as wide as the view, and the flexible column
        // (name, or location in lists) absorbs every resize. Below the
        // columns' combined minimums (a narrow window) it scrolls sideways
        // rather than cutting off what's on the right.
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
    }

    /// Lists show each hit's share of the folder being explored.
    private var shareTitle: String {
        let name = session.focus == 0 ? session.title : tree.withLock {
            tree.name(of: tree.entry(tree.dirEntry(session.focus)))
        }
        return "% of \(name)"
    }

    private func makeRoot(for source: TreeSource) -> Node {
        switch source {
        case .folder(let dir):
            return tree.withLock {
                let n = dirNode(dir, entry: tree.dirEntry(dir), parent: nil)
                n.children = nil // it may have been collapsed, and unwatched, for a while
                return n
            }
        case .list:
            return Node(summary: .list, parent: nil)
        }
    }

    func setSource(_ newSource: TreeSource) {
        guard newSource != source else { return }
        // Each folder the tree is rooted at keeps its own open folders.
        if !source.isList { session.treeStates[root.dir] = captureState() }
        let previous = source.isList ? root.children ?? [] : []
        source = newSource
        root = makeRoot(for: newSource)
        if newSource.isList {
            root.children = previous // lets buildList reuse row objects
            tree.withLock { root.children = buildList(root) }
            outline.tableColumns.first { $0.identifier == Self.shareColumn }?.title = shareTitle
        }
        let selected = selectedNodes()
        cachedRow = nil
        outline.reloadData()
        if newSource.isList {
            restoreSelection(selected)
        } else {
            outline.scrollRowToVisible(0)
            restored = false
            restoreState()
        }
    }

    // MARK: Nodes

    /// Lock held.
    private func dirNode(_ dir: UInt32, entry: UInt32, parent: Node?) -> Node {
        if let n = dirNodes[dir] {
            n.parent = parent
            return n
        }
        let n = Node(entry: entry, value: tree.entry(entry), parent: parent)
        dirNodes[dir] = n
        return n
    }

    /// The engine sorts names ascending and everything else descending.
    private var flipsOrder: Bool { (sortKey == .name) == !ascending }

    /// Lock held. Returns the display order for `node`'s children.
    private func sortedOrder(_ node: Node) -> [UInt32] {
        let start = CACurrentMediaTime()
        let stamp = tree.stamp(of: node.dir)
        var order = tree.children(of: node.dir, key: sortKey)
        if flipsOrder { order.reverse() }
        noteSorted(node, stamp: stamp, at: start, cost: CACurrentMediaTime() - start)
        return order
    }

    /// Remembers what `node`'s order was sorted against, and what it cost,
    /// to decide when it next needs sorting.
    private func noteSorted(_ node: Node, stamp: UInt32, at start: CFTimeInterval, cost: CFTimeInterval) {
        node.subtreeStamp = stamp
        node.sortedBy = sortTag
        node.sortedAt = start
        node.sortCost = cost
    }

    /// A folder whose children need sorting, and what it looked like when
    /// that was decided (lock held).
    private struct SortJob {
        let node: Node
        let run: (first: UInt32, count: UInt32, version: UInt32)
        let stamp: UInt32
        /// Entries joined or left the run, so its rows must be rebuilt.
        let relisted: Bool
    }

    /// Sorts a big folder's children WITHOUT holding the tree lock, then
    /// re-locks, checks nothing joined or left its run meanwhile, and hands
    /// the order to `apply` under that same lock. Returns false, applying
    /// nothing, if the run changed (or the tree isn't in memory): try again
    /// later. Never call it inside `withLock`.
    private func sortUnlocked(_ job: SortJob, apply: ([UInt32]) -> Void) -> Bool {
        // Parking starts on the main thread, so a tree that's awake now
        // stays mapped until this returns.
        guard session.isAwake else { return false }
        let start = CACurrentMediaTime()
        var order = tree.childrenUnlocked(of: job.node.dir, key: sortKey)
        if flipsOrder { order.reverse() }
        let cost = CACurrentMediaTime() - start
        return tree.withLock {
            let d = tree.dir(job.node.dir)
            guard tree.isLive(d.entry), (d.first, d.count, d.version) == job.run else { return false }
            noteSorted(job.node, stamp: job.stamp, at: start, cost: cost)
            apply(order)
            return true
        }
    }

    /// Lock held.
    private func buildChildren(_ node: Node, order fullOrder: [UInt32]) -> [Node] {
        let d = tree.dir(node.dir)
        let relisted = node.stamp != (d.first, d.count, d.version)
        node.stamp = (d.first, d.count, d.version)
        node.order = fullOrder
        var order = fullOrder[...]
        var more: Node?
        if order.count > Self.maxChildren {
            let rest = order[Self.maxChildren...]
            let m = node.moreNode ?? Node(summary: .more, parent: node)
            m.moreCount = rest.count
            m.moreBytes = rest.reduce(0) { $0 + tree.entry($1).size }
            node.moreNode = m
            more = m
            order = order.prefix(Self.maxChildren)
        }
        var oldFiles: [UInt32: Node] = [:]
        var oldDirs: [UInt32: Node] = [:]
        for c in node.children ?? [] {
            if c.kind == .file { oldFiles[c.entry] = c } else if c.kind == .dir { oldDirs[c.dir] = c }
            // Siblings changed, so what Guide says about them may have too.
            if relisted { c.guidance = nil }
        }
        var result: [Node] = []
        result.reserveCapacity(order.count + 2)
        for i in order {
            let e = tree.entry(i)
            let child: Node
            if e.isDir {
                if sharesDirNodes {
                    child = dirNode(e.aux, entry: i, parent: node)
                } else {
                    child = oldDirs[e.aux] ?? Node(entry: i, value: e, parent: node)
                }
                let expandable = tree.dir(e.aux).count > 0
                if expandable != child.expandable {
                    child.expandable = expandable
                    expandFlips.append(child)
                }
            } else {
                child = oldFiles[i] ?? Node(entry: i, value: e, parent: node)
            }
            result.append(child)
        }
        if node.dir == 0, !source.isList, session.isVolume, session.unseenBytes > 0 {
            let u = node.unseenNode ?? Node(summary: .unseen, parent: node)
            node.unseenNode = u
            u.expandable = !(session.hidden?.parts.isEmpty ?? true)
            let bytes = session.unseenBytes
            let at = sortKey == .size && !ascending
                ? (result.firstIndex { valueSize($0) < bytes } ?? result.count)
                : result.count
            result.insert(u, at: at)
        }
        if let more { result.append(more) }
        return result
    }

    /// Lock held.
    private func buildList(_ node: Node) -> [Node] {
        guard case .list(_, let entries, let groupCopies) = source else { return [] }
        var oldFiles: [UInt32: Node] = [:]
        var oldDirs: [UInt32: Node] = [:]
        var oldGroups: [String: Node] = [:]
        for c in node.children ?? [] {
            switch c.kind {
            case .file: oldFiles[c.entry] = c
            case .dir: oldDirs[c.dir] = c
            case .group: if let k = c.groupKey { oldGroups[k] = c }
            default: break
            }
        }
        var rows: [Node] = []
        var groups: [String: Node] = [:]
        for i in entries where tree.isLive(i) {
            let e = tree.entry(i)
            if e.isDir {
                let n = oldDirs[e.aux] ?? Node(entry: i, value: e, parent: node)
                n.parent = node
                n.expandable = tree.dir(e.aux).count > 0
                rows.append(n)
                continue
            }
            let file = oldFiles[i] ?? Node(entry: i, value: e, parent: node)
            guard groupCopies else {
                file.parent = node
                rows.append(file)
                continue
            }
            let key = "\(tree.name(of: e))\u{0}\(e.size)"
            if let g = groups[key] {
                file.parent = g
                g.children?.append(file)
            } else {
                let g = oldGroups[key] ?? Node(groupOf: file, key: key, parent: node)
                g.parent = node
                g.children = [file]
                file.parent = g
                groups[key] = g
                rows.append(g)
            }
        }
        // A "group" of one is just the file.
        rows = rows.map { r in
            guard r.kind == .group, let only = r.children?.first, r.children?.count == 1 else { return r }
            only.parent = node
            return only
        }
        for r in rows where r.kind == .group {
            r.expandable = true
            r.moreCount = r.children?.count ?? 0
        }
        listMax = max(1, rows.map { valueSize($0) }.max() ?? 1)
        node.order = rows.map(\.entry)
        if groupCopies { rows.sort { valueSize($0) > valueSize($1) } }
        return rows
    }

    /// Lock held.
    private func loadChildren(_ node: Node) {
        switch node.kind {
        case .list: node.children = buildList(node)
        case .dir: node.children = buildChildren(node, order: sortedOrder(node))
        case .group: break // members were assigned by buildList
        case .unseen: node.children = hiddenParts(node)
        default: node.children = []
        }
    }

    /// Rows breaking down the hidden space, reusing existing ones by id.
    private func hiddenParts(_ node: Node) -> [Node] {
        let old = Dictionary((node.children ?? []).compactMap { c in c.partID.map { ($0, c) } }) { a, _ in a }
        return (session.hidden?.parts ?? []).map { part in
            let n = old[part.id] ?? Node(summary: .hiddenPart, parent: node)
            n.partID = part.id
            n.partTitle = part.title
            n.partKind = part.kind
            return n
        }
    }

    private func hiddenPart(_ n: Node) -> HiddenSpace.Part? {
        session.hidden?.parts.first { $0.id == n.partID }
    }

    private func node(_ item: Any?) -> Node { (item as? Node) ?? root }

    // MARK: Values

    /// Lock held.
    private func valueSize(_ n: Node) -> Int64 {
        switch n.kind {
        case .file: tree.entry(n.entry).size
        case .dir: tree.entry(tree.dirEntry(n.dir)).size
        case .more: n.moreBytes
        case .unseen: session.unseenBytes
        case .hiddenPart: hiddenPart(n)?.bytes ?? 0
        case .group: (n.children ?? []).reduce(0) { $0 + tree.entry($1.entry).size }
        case .list: 0
        }
    }

    private var showsProgress: Bool {
        session.phase == .scanning || session.rescanState != nil || session.catchingUp
    }

    /// Lock held.
    private func values(for n: Node) -> RowValues {
        var v = RowValues()
        switch n.kind {
        case .file:
            let e = tree.entry(n.entry)
            v.size = e.size
            v.modified = e.aux
            v.flags = e.flags
            v.growing = session.showsSavedScan && e.parent != NONE && session.isStale(tree.dir(e.parent))
        case .dir:
            let d = tree.dir(n.dir)
            let e = tree.entry(d.entry)
            v.size = e.size
            v.items = Int(d.items)
            v.modified = d.newest
            v.flags = e.flags
            // Hatched only while a scan or rescan is working through the tree,
            // or while it may still show a saved scan's out-of-date sizes: on
            // a busy disk some folder is always being re-listed, and routine
            // updates shouldn't make everything look unfinished.
            v.growing = d.pending > 0 && showsProgress || session.isStale(d)
            v.isDir = true
            v.hasItems = true
            v.growth = session.growth(of: n.dir, now: e.size)
        case .more:
            v.size = n.moreBytes
            v.items = n.moreCount
            v.hasItems = true
        case .unseen:
            v.size = session.unseenBytes
        case .hiddenPart:
            v.size = hiddenPart(n)?.bytes ?? 0
        case .group:
            v.size = valueSize(n)
            v.modified = (n.children ?? []).map { tree.entry($0.entry).aux }.max() ?? 0
            v.copies = n.children?.count ?? 0
        case .list:
            break
        }
        if n.isReal {
            if !session.marks.isEmpty {
                let key = session.markKey(for: n.ref)
                v.marked = key.map { session.marks[$0] != nil } ?? false
                v.covered = v.marked || session.isCovered(session.entryIndex(n.ref), key: nil)
            }
            if n.guidance == nil {
                let i = session.entryIndex(n.ref)
                n.guidance = .some(Guide.classify(tree: tree, entry: i, name: n.name(in: tree)) { tree.path(of: i) })
            }
            v.guidance = n.guidance ?? nil
        }
        if source.isList && n.parent === root {
            // Bars compare hits with each other; the percentage says how much
            // of the explored folder each one is.
            v.parentSize = tree.entry(tree.dirEntry(session.focus)).size
            v.barBase = listMax
        } else if let p = n.parent {
            v.parentSize = valueSize(p)
            if p.kind == .dir && p.dir == 0 && session.isVolume, let cap = session.capacity {
                v.parentSize = max(v.parentSize, cap.total - cap.free)
            }
            v.barBase = v.parentSize
        }
        return v
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let n = node(item)
        if n.children == nil { tree.withLock { loadChildren(n) } }
        return n.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item).children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        let n = node(item)
        n.shownExpandable = (n.isDir || n.kind == .group || n.kind == .unseen) && n.expandable
        return n.shownExpandable
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        // Always open onto fresh contents.
        let n = node(item)
        if n.isDir { tree.withLock { loadChildren(n) } }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        let n = node(item)
        guard n.isReal else { return nil }
        return NSURL(fileURLWithPath: session.path(n.ref))
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = outlineView.sortDescriptors.first, let key = d.key else { return }
        sortKey = switch key {
        case "name": .name
        case "items": .items
        case "modified": .modified
        default: .size
        }
        ascending = d.ascending
        resortAll()
    }

    private func resortAll() {
        let selected = selectedNodes()
        cachedRow = nil
        tree.withLock {
            for n in activeNodes() where n.isDir { n.children = buildChildren(n, order: sortedOrder(n)) }
        }
        if source.isList { sortListRoot() }
        outline.reloadData()
        restoreSelection(selected)
    }

    private func sortListRoot() {
        guard var kids = root.children else { return }
        let key = sortKey, asc = ascending
        let names = kids.map { $0.name(in: tree) }
        let (sizes, mtimes) = tree.withLock { (kids.map { valueSize($0) }, kids.map { values(for: $0).modified }) }
        var idx = Array(kids.indices)
        idx.sort { a, b in
            let order: ComparisonResult
            switch key {
            case .name: order = names[a].localizedStandardCompare(names[b])
            case .modified: order = mtimes[a] == mtimes[b] ? .orderedSame : (mtimes[a] < mtimes[b] ? .orderedAscending : .orderedDescending)
            default: order = sizes[a] == sizes[b] ? .orderedSame : (sizes[a] < sizes[b] ? .orderedAscending : .orderedDescending)
            }
            if order == .orderedSame { return a < b } // stable
            return (order == .orderedAscending) == asc
        }
        kids = idx.map { kids[$0] }
        root.children = kids
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        if let reused = outlineView.makeView(withIdentifier: HoverRowView.id, owner: nil) as? HoverRowView {
            return reused
        }
        let row = HoverRowView()
        row.identifier = HoverRowView.id
        return row
    }

    /// Rows that closed hold on to nothing: their children are built afresh
    /// if they open again (they would be anyway). Folder nodes live on in
    /// `dirNodes`, so folders left open inside keep their identity, which is
    /// how the outline remembers they were open. Lists keep nodes only in
    /// `children`, so a list folder with an open folder inside keeps them.
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let n = notification.userInfo?["NSObject"] as? Node, n.isDir, n !== root else { return }
        if !sharesDirNodes, holdsOpenFolder(n) { return }
        n.children = nil
        n.order = []
        n.moreNode = nil
        cachedRow = nil
    }

    /// Whether a folder somewhere below `n` is still open (the outline keeps
    /// a closed folder's open descendants open).
    private func holdsOpenFolder(_ n: Node) -> Bool {
        var stack = n.children ?? []
        while let c = stack.popLast() {
            guard c.isDir else { continue }
            if outline.isItemExpanded(c) { return true }
            stack.append(contentsOf: c.children ?? [])
        }
        return false
    }

    /// Lock not held. A row's values, computed once for all of its cells.
    private func rowValues(for n: Node) -> RowValues {
        if let cached = cachedRow, cached.node === n { return cached.values }
        let v = tree.withLock { values(for: n) }
        if cachedRow == nil {
            // Good for this pass only: next time the tree may have moved on.
            DispatchQueue.main.async { [weak self] in self?.cachedRow = nil }
        }
        cachedRow = (n, v)
        return v
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let n = node(item)
        let v = rowValues(for: n)
        switch id {
        case Self.nameColumn:
            let cell = outlineView.makeView(withIdentifier: NameCell.id, owner: nil) as? NameCell ?? NameCell()
            let name = n.name(in: tree)
            let icon = n.icon(in: tree) { [session] in session.path(n.ref) }
            cell.configure(node: n, name: name, image: icon, values: v)
            cell.onReveal = { [weak self] n in self?.session.reveal([n.ref]) }
            cell.onTrash = { [weak self] n in self?.session.moveToTrash([n.ref]) }
            cell.onMark = { [weak self] n in self?.session.toggleMarks([n.ref]) }
            return cell
        case Self.shareColumn:
            _ = n.name(in: tree) // decode once so the bar can color by type
            let cell = outlineView.makeView(withIdentifier: ShareCell.id, owner: nil) as? ShareCell ?? ShareCell()
            cell.apply(v, node: n)
            return cell
        case Self.locationColumn:
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? TextCell
                ?? TextCell(column: .location, identifier: id)
            cell.location = location(of: n)
            return cell
        default:
            let column: TextCell.Column = id == Self.sizeColumn ? .size : id == Self.itemsColumn ? .items : .modified
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? TextCell
                ?? TextCell(column: column, identifier: id)
            cell.apply(v, node: n)
            return cell
        }
    }

    /// Where a list hit lives. Rows nested under a hit (or a group) don't
    /// repeat it, except group members, whose locations are the point.
    private func location(of n: Node) -> String {
        if n.kind == .group { return "\(n.children?.count ?? 0) places" }
        guard n.isReal, n.parent === root || n.parent?.kind == .group else { return "" }
        let parentDir: UInt32 = tree.withLock { tree.entry(session.entryIndex(n.ref)).parent }
        if let hit = locationCache[parentDir] { return hit }
        let base = session.url.path
        var path = tree.withLock { tree.path(of: tree.dirEntry(parentDir)) }
        if path.hasPrefix(base) {
            path = String(path.dropFirst(base.count))
            if !path.hasPrefix("/") { path = "/" + path }
            path = session.title + (path == "/" ? "" : path)
        }
        path = path.replacingOccurrences(of: "/", with: " › ")
        locationCache[parentDir] = path
        return path
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let nodes = selectedNodes()
        session.selection = nodes.filter(\.isReal).map(\.ref)
        session.hiddenSelection = nodes.count == 1 && (nodes[0].kind == .unseen || nodes[0].kind == .hiddenPart)
            ? (nodes[0].partID ?? "all") : nil
        session.quickLook = { [weak self] in self?.toggleQuickLook() }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            quickLookURLs = session.urls(session.selection)
            QLPreviewPanel.shared().reloadData()
        }
    }

    // MARK: Live refresh

    /// Root plus every expanded folder that is actually on screen.
    private func activeNodes() -> [Node] {
        var result = [root]
        var stack = root.children ?? []
        while let n = stack.popLast() {
            guard n.isDir || n.kind == .group, outline.isItemExpanded(n) else { continue }
            if n.isDir { result.append(n) }
            stack.append(contentsOf: n.children ?? [])
        }
        return result
    }

    private func treeChanged() {
        guard outline.window != nil else { return }
        cachedRow = nil
        let now = CACurrentMediaTime()
        let active = activeNodes()
        let visible = visibleRows()
        var reloads: [(Node, [Node])] = []
        var relisted: [(Node, [Node])] = []
        var reordered: [(Node, [Node])] = []
        var bigSorts: [SortJob] = []
        var expandability: [Node] = []
        var nextDue = CFTimeInterval.infinity

        tree.withLock {
            for n in active {
                if n.kind == .list {
                    // Rebuild if any hit (or copy) is gone.
                    let dead = (n.children ?? []).contains { c in
                        c.kind == .group
                            ? (c.children ?? []).contains { !tree.isLive($0.entry) }
                            : c.isReal && !tree.isLive(session.entryIndex(c.ref))
                    }
                    if dead { reloads.append((n, buildList(n))) }
                    continue
                }
                guard n.isDir, tree.isLive(tree.dirEntry(n.dir)) else { continue }
                let d = tree.dir(n.dir)
                if let u = n.unseenNode, u.expandable == (session.hidden?.parts.isEmpty ?? true) {
                    u.expandable.toggle()
                    expandFlips.append(u)
                }
                if let u = n.unseenNode, outline.isItemExpanded(u),
                   (u.children ?? []).map(\.partID) != (session.hidden?.parts ?? []).map(\.id) {
                    reloads.append((u, hiddenParts(u)))
                }
                let hasUnseen = n.children?.contains { $0.kind == .unseen } ?? false
                let wantsUnseen = n.dir == 0 && !source.isList && session.isVolume && session.unseenBytes > 0
                let run = (d.first, d.count, d.version)
                let runChanged = n.stamp != run || hasUnseen != wantsUnseen
                let stamp = tree.stamp(of: n.dir)
                if !runChanged && n.sortedBy == sortTag {
                    // Only sizes, counts or dates below it can have moved, and
                    // only if its subtree stamp did. Names don't move without
                    // a relist. A re-sort waits max(0.4 s, 10× what the last
                    // one cost, rows included), so a huge busy folder can't
                    // hog the main thread.
                    guard sortKey != .name, stamp != n.subtreeStamp else { continue }
                    let due = n.sortedAt + max(0.4, 10 * n.sortCost)
                    if now < due {
                        nextDue = min(nextDue, due)
                        continue
                    }
                }
                if d.count > Self.unlockedSortMin {
                    bigSorts.append(SortJob(node: n, run: run, stamp: stamp, relisted: runChanged))
                    continue
                }
                let start = CACurrentMediaTime()
                let order = sortedOrder(n)
                if runChanged {
                    relisted.append((n, buildChildren(n, order: order)))
                } else if order != n.order {
                    reordered.append((n, buildChildren(n, order: order)))
                }
                n.sortCost = CACurrentMediaTime() - start
            }
            for (_, n) in visible where n.isDir && !outline.isItemExpanded(n) {
                let expandable = tree.dir(n.dir).count > 0
                if expandable != n.expandable {
                    n.expandable = expandable
                    expandFlips.append(n)
                }
            }
        }

        // Big folders sort outside the lock. One whose run changed meanwhile
        // is left for the next pass: the change that moved it brings one.
        for job in bigSorts {
            let n = job.node
            let sorted = sortUnlocked(job) { order in
                let start = CACurrentMediaTime()
                if job.relisted {
                    relisted.append((n, buildChildren(n, order: order)))
                } else if order != n.order {
                    reordered.append((n, buildChildren(n, order: order)))
                }
                n.sortCost += CACurrentMediaTime() - start
            }
            if !sorted { nextDue = min(nextDue, now + 0.4) }
        }
        scheduleResort(at: nextDue)

        if !reloads.isEmpty || !relisted.isEmpty || !reordered.isEmpty {
            let selected = selectedNodes()
            for (n, kids) in reloads {
                n.children = kids
                outline.reloadItem(n === root ? nil : n, reloadChildren: true)
            }
            // What a re-sort costs includes putting its rows on screen.
            for (n, kids) in relisted {
                let start = CACurrentMediaTime()
                applyRelist(n, to: kids)
                n.sortCost += CACurrentMediaTime() - start
            }
            for (n, kids) in reordered {
                let start = CACurrentMediaTime()
                applyReorder(n, to: kids)
                n.sortCost += CACurrentMediaTime() - start
            }
            restoreSelection(selected)
        }
        // Folders whose first listing landed since the outline last looked.
        // They're collapsed, so reloading "children" only re-asks whether
        // they expand.
        for (_, n) in visibleRows() where n.isDir && n.expandable != n.shownExpandable {
            expandability.append(n)
        }
        let flips = expandFlips
        expandFlips = []
        for n in expandability + flips where !outline.isItemExpanded(n) && outline.row(forItem: n) >= 0 {
            outline.reloadItem(n, reloadChildren: true)
        }
        updateVisibleValues()
        if !source.isList, let want = session.pendingSelect, want.isDir {
            session.pendingSelect = nil
            DispatchQueue.main.async { [weak self] in self?.select(want) }
        }
    }

    /// Arms the one-shot timer for the earliest re-sort pacing held back.
    private func scheduleResort(at due: CFTimeInterval) {
        guard due.isFinite, resortTimer == nil || due < resortDue else { return }
        resortTimer?.invalidate()
        resortDue = due
        let interval = max(0.01, due - CACurrentMediaTime())
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resortDueFired() }
        }
        timer.tolerance = interval * 0.15
        RunLoop.main.add(timer, forMode: .common)
        resortTimer = timer
    }

    private func resortDueFired() {
        resortTimer = nil
        resortDue = .infinity
        guard session.isAwake else { return } // waking brings a pass of its own
        treeChanged()
    }

    /// Applies a relisted folder's new rows. Entries joined or left, but
    /// rows still there keep their views, so a relist that changed little
    /// doesn't reload the folder: the same rows (their values update in
    /// place), the same rows reordered, or a few rows in or out. Anything
    /// bigger reloads, as does a run that moved, since every file in it
    /// then gets a new entry index and a new node.
    private func applyRelist(_ n: Node, to kids: [Node]) {
        let item: Any? = n === root ? nil : n
        // A folder removed by a relist above it this same pass is no longer
        // in the outline; its rows just wait for it to be shown again.
        guard n === root || (outline.isItemExpanded(n) && outline.row(forItem: n) >= 0) else {
            n.children = kids
            return
        }
        func reload() {
            n.children = kids
            outline.reloadItem(item, reloadChildren: true)
        }
        // Row-by-row updates need the outline to hold exactly the old rows.
        guard let current = n.children, outline.numberOfChildren(ofItem: item) == current.count else {
            return reload()
        }
        let oldIDs = current.map(ObjectIdentifier.init)
        let newIDs = kids.map(ObjectIdentifier.init)
        let oldSet = Set(oldIDs), newSet = Set(newIDs)
        // The "smaller items" row says how many it stands for, and that
        // count may have changed even when no row on show did.
        func refreshMore() {
            guard let m = n.moreNode, oldSet.contains(ObjectIdentifier(m)), newSet.contains(ObjectIdentifier(m)),
                  outline.row(forItem: m) >= 0 else { return }
            outline.reloadItem(m)
        }
        if oldIDs == newIDs {
            n.children = kids
            refreshMore()
            return
        }
        let removed = IndexSet(current.indices.filter { !newSet.contains(oldIDs[$0]) })
        let inserted = IndexSet(kids.indices.filter { !oldSet.contains(newIDs[$0]) })
        if removed.isEmpty && inserted.isEmpty {
            applyReorder(n, to: kids)
            refreshMore()
            return
        }
        guard removed.count + inserted.count <= Self.maxRowChanges else { return reload() }
        // Rows that stay must also end up in their new order; a few moves
        // are still cheaper than a reload.
        let survivors = current.filter { newSet.contains(ObjectIdentifier($0)) }
        let target = kids.filter { oldSet.contains(ObjectIdentifier($0)) }
        var moves: [(from: Int, to: Int)] = []
        if !zip(survivors, target).allSatisfy({ $0 === $1 }) {
            let budget = Self.maxRowChanges - removed.count - inserted.count
            guard let m = rowMoves(from: survivors, to: target, limit: budget) else { return reload() }
            moves = m
        }
        n.children = kids
        // All at once, like the reload this stands in for.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            outline.beginUpdates()
            if !removed.isEmpty { outline.removeItems(at: removed, inParent: item, withAnimation: []) }
            for m in moves { outline.moveItem(at: m.from, inParent: item, to: m.to, inParent: item) }
            if !inserted.isEmpty { outline.insertItems(at: inserted, inParent: item, withAnimation: []) }
            outline.endUpdates()
        }
        refreshMore()
    }

    /// Moves rows into their new order with animation when the change is
    /// small enough to read. Otherwise the rows jump there at once, as a
    /// reload would show it, moving only the ones that have to; if that's
    /// too many, it reloads.
    private func applyReorder(_ n: Node, to kids: [Node]) {
        let item: Any? = n === root ? nil : n
        // Gone from the outline with a relist above it this same pass.
        guard n === root || outline.row(forItem: n) >= 0 else {
            n.children = kids
            return
        }
        func reload() {
            n.children = kids
            outline.reloadItem(item, reloadChildren: true)
        }
        guard var current = n.children, current.count == kids.count else { return reload() }
        var animated = false
        if kids.count <= 400, Set(current.map(ObjectIdentifier.init)) == Set(kids.map(ObjectIdentifier.init)) {
            var moves = 0
            var probe = current
            for i in kids.indices where probe[i] !== kids[i] {
                guard let j = probe[(i + 1)...].firstIndex(where: { $0 === kids[i] }) else { continue }
                probe.insert(probe.remove(at: j), at: i)
                moves += 1
            }
            animated = moves <= 12
        }
        guard animated else {
            guard outline.numberOfChildren(ofItem: item) == current.count,
                  let moves = rowMoves(from: current, to: kids, limit: Self.maxRowChanges) else { return reload() }
            n.children = kids
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                outline.beginUpdates()
                for m in moves { outline.moveItem(at: m.from, inParent: item, to: m.to, inParent: item) }
                outline.endUpdates()
            }
            return
        }
        n.children = kids
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            outline.beginUpdates()
            for i in kids.indices where current[i] !== kids[i] {
                guard let j = current[(i + 1)...].firstIndex(where: { $0 === kids[i] }) else { continue }
                let moved = current.remove(at: j)
                current.insert(moved, at: i)
                outline.moveItem(at: j, inParent: item, to: i, inParent: item)
            }
            outline.endUpdates()
        }
    }

    private func visibleRows() -> [(Int, Node)] {
        let range = outline.rows(in: outline.visibleRect)
        guard range.length > 0 else { return [] }
        return (range.location..<(range.location + range.length)).compactMap { row in
            (outline.item(atRow: row) as? Node).map { (row, $0) }
        }
    }

    private func updateVisibleValues() {
        let rows = visibleRows()
        guard !rows.isEmpty else { return }
        let vals = tree.withLock { rows.map { values(for: $0.1) } }
        for (k, (row, n)) in rows.enumerated() {
            guard let rv = outline.rowView(atRow: row, makeIfNecessary: false) else { continue }
            for c in 0..<outline.numberOfColumns {
                (rv.view(atColumn: c) as? ValueCell)?.apply(vals[k], node: n)
            }
        }
    }

    // MARK: Selection

    func selectedNodes() -> [Node] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }
    }

    /// Reselects `nodes`. A file whose folder was relisted has a new node, so
    /// it is found again by name among its folder's new children.
    private func restoreSelection(_ nodes: [Node]) {
        var rows = IndexSet()
        for n in nodes {
            var row = outline.row(forItem: n)
            if row < 0, n.kind == .file, let kids = n.parent?.children {
                let name = n.name(in: tree)
                if let match = kids.first(where: { $0.kind == .file && $0.name(in: tree) == name }) {
                    row = outline.row(forItem: match)
                }
            }
            if row >= 0 { rows.insert(row) }
        }
        if rows != outline.selectedRowIndexes {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    /// Selects a folder and scrolls to it, opening its ancestors so the row
    /// exists.
    // MARK: Remembered state

    private var restored = false

    private func captureState() -> TreeState {
        var state = TreeState()
        for r in 0..<outline.numberOfRows {
            if let n = outline.item(atRow: r) as? Node, n.isDir, outline.isItemExpanded(n) { state.expanded.append(n.dir) }
        }
        state.selection = selectedNodes().filter(\.isReal).map(\.ref)
        let visible = outline.rows(in: scroll.contentView.bounds)
        if visible.length > 0, let n = outline.item(atRow: visible.location) as? Node, n.isReal { state.top = n.ref }
        return state
    }

    /// Reopens what was open when this location's tree was last shown. Rows
    /// are expanded outermost first, so each one's children exist in time.
    func restoreState() {
        guard !source.isList, !restored else { return }
        restored = true
        guard let state = session.treeStates[root.dir] else { return }
        guard !state.expanded.isEmpty || !state.selection.isEmpty else { return }
        _ = outline.numberOfRows // loads the top level
        for dir in state.expanded {
            guard let n = dirNodes[dir], !outline.isItemExpanded(n), outline.row(forItem: n) >= 0 else { continue }
            outline.expandItem(n)
        }
        let rows = IndexSet(state.selection.compactMap { row(of: $0) })
        if !rows.isEmpty { outline.selectRowIndexes(rows, byExtendingSelection: false) }
        if let top = state.top, let r = row(of: top) {
            outline.scroll(NSPoint(x: 0, y: outline.rect(ofRow: r).minY))
        } else if let r = rows.first {
            outline.scrollRowToVisible(r)
        }
    }

    /// The row showing `ref`, if it's in view of the tree right now.
    private func row(of ref: ItemRef) -> Int? {
        if ref.isDir {
            guard let n = dirNodes[ref.dir] else { return nil }
            let r = outline.row(forItem: n)
            return r >= 0 ? r : nil
        }
        let parent: UInt32? = tree.withLock { tree.isLive(ref.entry) ? tree.entry(ref.entry).parent : nil }
        guard let parent, let p = dirNodes[parent], outline.isItemExpanded(p) || p === root,
              let n = p.children?.first(where: { $0.kind == .file && $0.entry == ref.entry }) else { return nil }
        let r = outline.row(forItem: n)
        return r >= 0 ? r : nil
    }

    func select(_ ref: ItemRef) {
        guard ref.isDir else { return }
        var chain: [UInt32] = tree.withLock {
            var out: [UInt32] = []
            var d = ref.dir
            while d != NONE && d != root.dir {
                out.append(d)
                d = tree.entry(tree.dirEntry(d)).parent
            }
            return out
        }
        chain.reverse() // outermost first
        for d in chain.dropLast() {
            if let n = dirNodes[d], !outline.isItemExpanded(n) { outline.expandItem(n) }
        }
        guard let n = dirNodes[ref.dir] else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        outline.window?.makeFirstResponder(outline)
    }

    private func targetNodes() -> [Node] {
        let clicked = outline.clickedRow
        if clicked >= 0, !outline.selectedRowIndexes.contains(clicked), let n = outline.item(atRow: clicked) as? Node {
            return [n]
        }
        return selectedNodes()
    }

    // MARK: Actions

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? Node else { return }
        if n.isDir || n.kind == .group {
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        } else if n.isReal {
            session.reveal([n.ref])
        }
    }

    func toggleMarkOnSelection() {
        let refs = selectedNodes().filter(\.isReal).map(\.ref)
        guard !refs.isEmpty else { return }
        session.toggleMarks(refs)
    }

    func toggleQuickLook() {
        let panel = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        quickLookURLs = session.urls(selectedNodes().filter(\.isReal).map(\.ref))
        guard !quickLookURLs.isEmpty else { return }
        outline.window?.makeFirstResponder(outline)
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { quickLookURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { quickLookURLs[index] as NSURL }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard event.type == .keyDown else { return false }
            outline.keyDown(with: event)
            return true
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let nodes = targetNodes().filter(\.isReal)
        guard !nodes.isEmpty else { return }
        let refs = nodes.map(\.ref)
        let one = nodes.count == 1 ? nodes[0] : nil

        func item(_ title: String, _ symbol: String, key: String = "", mods: NSEvent.ModifierFlags = [.command],
                  _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, action: action)
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            i.keyEquivalent = key
            i.keyEquivalentModifierMask = mods
            menu.addItem(i)
        }

        item("Show in Finder", "arrow.up.right.square", key: "r") { [session] in session.reveal(refs) }
        if let one, one.isDir, !source.isList {
            item("Focus on “\(one.name(in: tree))”", "arrow.down.right.circle",
                 key: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))) { [session] in
                session.focus(on: one.ref)
            }
        } else if !(one?.isDir ?? false) {
            item("Open", "arrow.up.forward.app") { [session] in session.open(refs) }
        }
        item("Quick Look", "eye", key: " ", mods: []) { [weak self] in self?.toggleQuickLook() }
        item("Copy Path", "doc.on.doc", key: "c", mods: [.command, .option]) { [session] in session.copyPaths(refs) }
        if let one, one.isDir {
            menu.addItem(.separator())
            item("Rescan Folder", "arrow.clockwise") { [session] in session.rescan(one.ref) }
        }
        menu.addItem(.separator())
        let allMarked = refs.allSatisfy { session.isMarked($0) }
        item(allMarked ? "Remove from Cleanup" : "Mark for Cleanup", allMarked ? "minus.circle" : "checklist",
             key: "m", mods: []) { [session] in session.toggleMarks(refs) }
        item("Move to Trash", "trash", key: "\u{8}") { [session] in session.moveToTrash(refs) }
        item("Delete Immediately…", "xmark.bin", key: "\u{8}", mods: [.command, .option]) { [weak self, session] in
            session.deleteImmediately(refs, window: self?.outline.window)
        }
    }
}

/// The moves that turn `current` into `target` (the same rows in a new
/// order), each as (from, to) indices at the time it's made. Only rows
/// outside the longest run already in order move, and each goes straight
/// to its place. Nil if the rows differ or it would take more than
/// `limit` moves. Pure, so the tests can drive it.
func rowMoves<Row: AnyObject>(from current: [Row], to target: [Row], limit: Int) -> [(from: Int, to: Int)]? {
    guard current.count == target.count else { return nil }
    var at: [ObjectIdentifier: Int] = [:]
    at.reserveCapacity(current.count)
    for (i, n) in current.enumerated() { at[ObjectIdentifier(n)] = i }
    var was: [Int] = []
    was.reserveCapacity(target.count)
    for n in target {
        guard let i = at.removeValue(forKey: ObjectIdentifier(n)) else { return nil }
        was.append(i)
    }
    // Longest increasing run of old positions, by patience sorting: `ends`
    // holds, for each length, the index whose value ends the lowest run.
    var ends: [Int] = []
    var before = [Int](repeating: -1, count: was.count)
    for (i, v) in was.enumerated() {
        var lo = 0, hi = ends.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if was[ends[mid]] < v { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0 { before[i] = ends[lo - 1] }
        if lo == ends.count { ends.append(i) } else { ends[lo] = i }
    }
    guard was.count - ends.count <= limit else { return nil }
    var stays = [Bool](repeating: false, count: was.count)
    var k = ends.last ?? -1
    while k >= 0 {
        stays[k] = true
        k = before[k]
    }
    // Each row that moves goes right after the row that precedes it in
    // `target`, which by then is in place: it stays, or moved earlier.
    var work = current
    var out: [(from: Int, to: Int)] = []
    for i in target.indices where !stays[i] {
        guard let j = work.firstIndex(where: { $0 === target[i] }) else { return nil }
        let row = work.remove(at: j)
        var to = 0
        if i > 0 {
            guard let p = work.firstIndex(where: { $0 === target[i - 1] }) else { return nil }
            to = p + 1
        }
        work.insert(row, at: to)
        out.append((j, to))
    }
    return out
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

// MARK: SwiftUI bridge

struct TreeView: NSViewRepresentable {
    let session: Session
    let source: TreeSource

    func makeCoordinator() -> TreeController {
        TreeController(session: session, source: source)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        DispatchQueue.main.async {
            c.restoreState()
            // Take the keyboard only if nobody else has it: never out of the
            // search field while someone is typing.
            guard let window = c.outline.window else { return }
            let current = window.firstResponder
            if current == nil || current === window || current is NSOutlineView {
                window.makeFirstResponder(c.outline)
            }
        }
        return c.scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.setSource(source)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: TreeController) {
        coordinator.teardown()
    }
}
