import AppKit
import Quartz
import SiltCore
import SwiftUI

enum TreeSource: Equatable {
    /// A folder's contents, drillable.
    case folder(UInt32)
    /// A flat, precomputed list of entries (largest files, search results…).
    case list(id: String, entries: [UInt32])

    static func == (a: TreeSource, b: TreeSource) -> Bool {
        switch (a, b) {
        case let (.folder(x), .folder(y)): x == y
        case let (.list(x, _), .list(y, _)): x == y
        default: false
        }
    }
}

final class SiltOutlineView: NSOutlineView {
    weak var controller: TreeController?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            controller?.toggleQuickLook()
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
    private var dirNodes: [UInt32: Node] = [:]
    private var sortKey: SortKey = .size
    private var ascending = false
    private var lastReorder: CFTimeInterval = 0
    private var quickLookURLs: [URL] = []
    /// Folders that became expandable while being rebuilt; the outline must
    /// be told or it keeps showing them without a disclosure triangle.
    private var expandFlips: [Node] = []
    private var tree: Tree { session.tree }
    private static let maxChildren = 20_000

    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let shareColumn = NSUserInterfaceItemIdentifier("share")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    private static let itemsColumn = NSUserInterfaceItemIdentifier("items")
    private static let modifiedColumn = NSUserInterfaceItemIdentifier("modified")
    private static let locationColumn = NSUserInterfaceItemIdentifier("location")

    init(session: Session, source: TreeSource) {
        self.session = session
        self.source = source
        root = Node(summary: .more, parent: nil)
        super.init()
        root = makeRoot(for: source)
        configureOutline()
        session.addListener(self) { [weak self] in self?.treeChanged() }
    }

    func teardown() {
        session.removeListener(self)
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
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
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

        let isList: Bool
        if case .list = source { isList = true } else { isList = false }

        @discardableResult
        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat,
                    sortKey: String?, ascending: Bool = false, align: NSTextAlignment = .left) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title
            c.width = width
            c.minWidth = min
            c.headerCell.alignment = align
            if let sortKey { c.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: ascending) }
            outline.addTableColumn(c)
            return c
        }
        // Starts narrow; as the first column it absorbs whatever width is left.
        let name = column(Self.nameColumn, "Name", width: 200, min: 180, sortKey: "name", ascending: true)
        name.resizingMask = .autoresizingMask
        outline.outlineTableColumn = name
        column(Self.shareColumn, "Share", width: 130, min: 80, sortKey: "size")
        column(Self.sizeColumn, "Size", width: 84, min: 70, sortKey: "size", align: .right)
        if isList {
            column(Self.locationColumn, "Location", width: 280, min: 120, sortKey: nil)
        } else {
            column(Self.itemsColumn, "Items", width: 76, min: 56, sortKey: "items", align: .right)
        }
        column(Self.modifiedColumn, "Modified", width: 96, min: 70, sortKey: "modified", align: .right)
        outline.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
    }

    private func makeRoot(for source: TreeSource) -> Node {
        switch source {
        case .folder(let dir):
            return tree.withLock { dirNode(dir, entry: tree.dirEntry(dir), parent: nil) }
        case .list:
            return Node(summary: .list, parent: nil)
        }
    }

    func setSource(_ newSource: TreeSource) {
        guard newSource != source else { return }
        source = newSource
        root = makeRoot(for: newSource)
        outline.reloadData()
        outline.scrollRowToVisible(0)
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

    /// Lock held. Returns the display order for `node`'s children.
    private func sortedOrder(_ node: Node) -> [UInt32] {
        var order = tree.children(of: node.dir, key: sortKey)
        let flip = (sortKey == .name) == !ascending
        if flip { order.reverse() }
        return order
    }

    /// Lock held.
    private func buildChildren(_ node: Node, order fullOrder: [UInt32]) -> [Node] {
        let d = tree.dir(node.dir)
        node.stamp = (d.first, d.count)
        node.order = fullOrder
        var order = fullOrder[...]
        var more: Node?
        if order.count > Self.maxChildren {
            let rest = order[Self.maxChildren...]
            let m = Node(summary: .more, parent: node)
            m.moreCount = rest.count
            m.moreBytes = rest.reduce(0) { $0 + tree.entry($1).size }
            more = m
            order = order.prefix(Self.maxChildren)
        }
        var oldFiles: [UInt32: Node] = [:]
        for c in node.children ?? [] where c.kind == .file { oldFiles[c.entry] = c }
        var result: [Node] = []
        result.reserveCapacity(order.count + 2)
        for i in order {
            let e = tree.entry(i)
            let child: Node
            if e.isDir {
                child = dirNode(e.aux, entry: i, parent: node)
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
        if node.dir == 0, session.isVolume, session.unseenBytes > 0 {
            let u = Node(summary: .unseen, parent: node)
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
        guard case .list(_, let entries) = source else { return [] }
        var result: [Node] = []
        for i in entries where tree.isLive(i) {
            let e = tree.entry(i)
            if e.isDir {
                let n = dirNode(e.aux, entry: i, parent: node)
                n.expandable = tree.dir(e.aux).count > 0
                result.append(n)
            } else {
                result.append(Node(entry: i, value: e, parent: node))
            }
        }
        node.order = result.map(\.entry)
        return result
    }

    /// Lock held.
    private func loadChildren(_ node: Node) {
        if node.kind == .list {
            node.children = buildList(node)
        } else if node.isDir {
            node.children = buildChildren(node, order: sortedOrder(node))
        } else {
            node.children = []
        }
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
        case .list: 0
        }
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
        case .dir:
            let d = tree.dir(n.dir)
            let e = tree.entry(d.entry)
            v.size = e.size
            v.items = Int(d.items)
            v.modified = d.newest
            v.flags = e.flags
            v.growing = d.pending > 0
            v.isDir = true
            v.hasItems = true
        case .more:
            v.size = n.moreBytes
            v.items = n.moreCount
            v.hasItems = true
        case .unseen:
            v.size = session.unseenBytes
        case .list:
            break
        }
        if case .list = source {
            v.parentSize = tree.entry(tree.dirEntry(session.focus)).size
        } else if let p = n.parent {
            v.parentSize = valueSize(p)
            if p.kind == .dir && p.dir == 0 && session.isVolume, let cap = session.capacity {
                v.parentSize = max(v.parentSize, cap.total - cap.free)
            }
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
        n.shownExpandable = n.isDir && n.expandable
        return n.shownExpandable
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        // Always open onto fresh contents.
        let n = node(item)
        tree.withLock { loadChildren(n) }
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
        tree.withLock {
            for n in activeNodes() where n.kind != .list { n.children = buildChildren(n, order: sortedOrder(n)) }
        }
        if case .list = source {
            // Lists are sorted by size at the source; re-sort locally.
            sortListRoot()
        }
        outline.reloadData()
        restoreSelection(selected)
    }

    private func sortListRoot() {
        guard var kids = root.children else { return }
        let key = sortKey, asc = ascending
        let names = tree.withLock { kids.map { $0.name(in: tree) } }
        let sizes = tree.withLock { kids.map { valueSize($0) } }
        let mtimes = tree.withLock { kids.map { values(for: $0).modified } }
        var idx = Array(kids.indices)
        idx.sort { a, b in
            switch key {
            case .name: return (names[a].localizedStandardCompare(names[b]) == .orderedAscending) == asc
            case .modified: return (mtimes[a] < mtimes[b]) == asc
            default: return (sizes[a] < sizes[b]) == asc
            }
        }
        kids = idx.map { kids[$0] }
        root.children = kids
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        HoverRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let n = node(item)
        let v = tree.withLock { values(for: n) }
        switch id {
        case Self.nameColumn:
            let cell = outlineView.makeView(withIdentifier: NameCell.id, owner: nil) as? NameCell ?? NameCell()
            let name = n.name(in: tree)
            let icon = n.icon(in: tree) { [session] in session.path(n.ref) }
            cell.configure(node: n, name: name, image: icon, values: v)
            cell.onReveal = { [weak self] n in self?.session.reveal([n.ref]) }
            cell.onTrash = { [weak self] n in self?.session.moveToTrash([n.ref]) }
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

    private var locationCache: [UInt32: String] = [:]

    private func location(of n: Node) -> String {
        guard n.isReal else { return "" }
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
        session.selection = selectedNodes().filter(\.isReal).map(\.ref)
        session.quickLook = { [weak self] in self?.toggleQuickLook() }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            quickLookURLs = session.urls(session.selection)
            QLPreviewPanel.shared().reloadData()
        }
    }

    // MARK: Live refresh

    /// Root plus every expanded node that is actually on screen.
    private func activeNodes() -> [Node] {
        var result = [root]
        var stack = root.children ?? []
        while let n = stack.popLast() {
            guard n.isDir, outline.isItemExpanded(n) else { continue }
            result.append(n)
            stack.append(contentsOf: n.children ?? [])
        }
        return result
    }

    private func treeChanged() {
        guard outline.window != nil else { return }
        let now = CACurrentMediaTime()
        let scanning = session.phase == .scanning
        let reorderDue = sortKey != .name && now - lastReorder > (scanning ? 0.4 : 0)
        if reorderDue { lastReorder = now }

        let active = activeNodes()
        let visible = visibleRows()
        var structural: [(Node, [Node])] = []
        var reordered: [(Node, [Node])] = []
        var expandability: [Node] = []

        tree.withLock {
            for n in active {
                if n.kind == .list {
                    let live = n.children?.filter { !$0.isReal || tree.isLive(session.entryIndex($0.ref)) }
                    if let live, live.count != n.children?.count { structural.append((n, live)) }
                    continue
                }
                guard n.isDir, tree.isLive(tree.dirEntry(n.dir)) else { continue }
                let d = tree.dir(n.dir)
                let hasUnseen = n.children?.contains { $0.kind == .unseen } ?? false
                let wantsUnseen = n.dir == 0 && session.isVolume && session.unseenBytes > 0
                if d.first != n.stamp.first || d.count != n.stamp.count || hasUnseen != wantsUnseen {
                    structural.append((n, buildChildren(n, order: sortedOrder(n))))
                } else if reorderDue {
                    let order = sortedOrder(n)
                    if order != n.order { reordered.append((n, buildChildren(n, order: order))) }
                }
            }
            for (_, n) in visible where n.isDir && !outline.isItemExpanded(n) {
                let expandable = tree.dir(n.dir).count > 0
                if expandable != n.expandable {
                    n.expandable = expandable
                    expandFlips.append(n)
                }
            }
        }

        if !structural.isEmpty || !reordered.isEmpty {
            let selected = selectedNodes()
            for (n, kids) in structural {
                n.children = kids
                outline.reloadItem(n === root ? nil : n, reloadChildren: true)
            }
            for (n, kids) in reordered { applyReorder(n, to: kids) }
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
        debugExpandIfRequested()
    }

    // TEMP(debug): remove before shipping.
    private var debugDone = false
    private func debugExpandIfRequested() {
        guard !debugDone, session.phase == .live, ProcessInfo.processInfo.environment["SILT_DEBUG_EXPAND"] != nil,
              let first = outline.item(atRow: 0) as? Node else { return }
        debugDone = true
        outline.expandItem(first)
        if let inner = first.children?.first(where: { $0.isDir }) { outline.expandItem(inner) }
        outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    }

    /// Moves rows into their new order with animation when the change is
    /// small enough to read; otherwise just reloads.
    private func applyReorder(_ n: Node, to kids: [Node]) {
        let item: Any? = n === root ? nil : n
        guard var current = n.children, current.count == kids.count, kids.count <= 400 else {
            n.children = kids
            outline.reloadItem(item, reloadChildren: true)
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

    private func restoreSelection(_ nodes: [Node]) {
        let rows = IndexSet(nodes.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if rows != outline.selectedRowIndexes {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    func select(_ ref: ItemRef) {
        let n: Node? = ref.isDir ? dirNodes[ref.dir] : root.children?.first { $0.entry == ref.entry }
        guard let n else { return }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
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
        guard row >= 0, let n = outline.item(atRow: row) as? Node, n.isReal else { return }
        if n.isDir {
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        } else {
            session.reveal([n.ref])
        }
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

        item("Show in Finder", "magnifyingglass", key: "r") { [session] in session.reveal(refs) }
        if let one, one.isDir {
            item("Focus on “\(one.name(in: tree))”", "arrow.down.right.circle",
                 key: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))) { [session] in
                session.focus(on: one.ref)
            }
        } else {
            item("Open", "arrow.up.forward.app") { [session] in session.open(refs) }
        }
        item("Quick Look", "eye", key: " ", mods: []) { [weak self] in self?.toggleQuickLook() }
        item("Copy Path", "doc.on.doc", key: "c", mods: [.command, .option]) { [session] in session.copyPaths(refs) }
        if let one, one.isDir {
            menu.addItem(.separator())
            item("Rescan Folder", "arrow.clockwise") { [session] in session.rescan(one.ref) }
        }
        menu.addItem(.separator())
        item("Move to Trash", "trash", key: "\u{8}") { [session] in session.moveToTrash(refs) }
        item("Delete Immediately…", "xmark.bin", key: "\u{8}", mods: [.command, .option]) { [weak self, session] in
            session.deleteImmediately(refs, window: self?.outline.window)
        }
    }
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
            c.outline.window?.makeFirstResponder(c.outline)
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
