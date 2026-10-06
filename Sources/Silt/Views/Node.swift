import AppKit
import SiltCore
import UniformTypeIdentifiers

/// An outline row. Folder nodes are cached per controller by dir id, so
/// NSOutlineView's expansion and selection (which key on object identity)
/// survive refreshes. File nodes are recreated when their folder is relisted.
final class Node: NSObject {
    enum Kind { case file, dir, more, unseen, hiddenPart, list, group }

    let kind: Kind
    /// Files: fixed entry index. Folders: resolved through `dir`.
    let entry: UInt32
    let dir: UInt32
    let nameOffset: UInt32
    let nameLength: UInt16
    let entryKind: UInt8
    weak var parent: Node?

    var children: [Node]?
    /// The folder's run as last built: a change in any part means entries
    /// joined or left it.
    var stamp: (first: UInt32, count: UInt32, version: UInt32) = (NONE, 0, 0)
    var order: [UInt32] = []
    /// Folders: what `order` was last sorted against. The subtree stamp
    /// (`Tree.stamp(of:)`) says whether anything under the folder changed
    /// since; the key says what it was sorted by; the time and cost pace
    /// the next re-sort.
    var subtreeStamp: UInt32?
    var sortedBy = -1
    var sortedAt: CFTimeInterval = -.infinity
    var sortCost: CFTimeInterval = 0
    var expandable = false
    /// What the outline last asked about, so changes can be pushed to it.
    var shownExpandable = false

    // Summary rows.
    var moreCount = 0
    var moreBytes: Int64 = 0
    /// Synthetic children, kept so the outline sees the same objects.
    var moreNode: Node?
    var unseenNode: Node?
    /// Largest-files groups: same name and size in several places.
    var groupKey: String?
    /// Hidden-space parts: which `HiddenSpace.Part` this row stands for.
    var partID: String?
    var partTitle = ""
    var partKind: HiddenSpace.Part.Kind = .unreadable
    /// Guide.classify, computed once (nil inside means "nothing to say").
    var guidance: Guidance??

    private var cachedName: String?
    private var cachedIcon: NSImage?
    private var cachedCategory: FileCategory?

    init(entry: UInt32, value e: silt_entry, parent: Node?) {
        self.entry = entry
        kind = e.isDir ? .dir : .file
        dir = e.isDir ? e.aux : NONE
        nameOffset = e.name
        nameLength = e.name_len
        entryKind = e.kind
        self.parent = parent
    }

    /// A row standing for several copies of one file; `first` supplies the name.
    init(groupOf first: Node, key: String, parent: Node?) {
        kind = .group
        entry = first.entry
        dir = NONE
        nameOffset = first.nameOffset
        nameLength = first.nameLength
        entryKind = first.entryKind
        groupKey = key
        self.parent = parent
    }

    init(summary kind: Kind, parent: Node?) {
        self.kind = kind
        entry = NONE
        dir = NONE
        nameOffset = 0
        nameLength = 0
        entryKind = 0
        self.parent = parent
    }

    var isDir: Bool { kind == .dir }

    /// The kind of file, for coloring by type. Worked out once the name has
    /// been decoded; until then it's `.other`, and not remembered.
    var category: FileCategory {
        if let cachedCategory { return cachedCategory }
        guard let cachedName else { return .other }
        let c = FileCategory.of(name: cachedName)
        cachedCategory = c
        return c
    }

    var isReal: Bool { kind == .file || kind == .dir }
    var ref: ItemRef { ItemRef(entry: entry, dir: dir) }

    /// Names are immutable once written and the arena never moves, so this
    /// needs no lock.
    func name(in tree: Tree) -> String {
        if kind == .more { return "\(Fmt.count(moreCount)) smaller items" }
        if let cachedName { return cachedName }
        let s: String
        switch kind {
        case .more: s = ""
        case .unseen: s = "System & hidden space"
        case .hiddenPart: s = partTitle
        case .list: s = ""
        default:
            let buf = UnsafeBufferPointer(start: silt_name_ptr(tree.raw, nameOffset), count: Int(nameLength))
            s = String(decoding: buf, as: UTF8.self)
        }
        cachedName = s
        return s
    }

    func icon(in tree: Tree, path: () -> String) -> NSImage {
        if let cachedIcon { return cachedIcon }
        let image: NSImage
        switch kind {
        case .more: image = Icons.symbol("ellipsis.circle")
        case .unseen: image = Icons.symbol("lock.circle")
        case .hiddenPart:
            let symbol = switch partKind {
            case .purgeable: "clock.arrow.circlepath"
            case .held: "clock.badge.checkmark"
            case .volume: "internaldrive"
            case .unmounted: "externaldrive.badge.minus"
            case .unreadable: "lock"
            }
            image = Icons.symbol(symbol)
        case .list: image = NSImage()
        case .dir: image = Icons.folder(name: name(in: tree), path: path)
        case .file, .group: image = Icons.file(name: name(in: tree), symlink: entryKind == UInt8(SILT_KIND_SYMLINK))
        }
        cachedIcon = image
        return image
    }
}

enum Icons {
    private static var byType: [String: NSImage] = [:]
    private static var byPath: [String: NSImage] = [:]
    private static let genericFolder: NSImage = {
        let i = NSWorkspace.shared.icon(for: .folder)
        i.size = NSSize(width: 16, height: 16)
        return i
    }()
    private static let special: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
        "Public", "Developer", "System", "Users", "Utilities",
    ]

    static func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    static func folder(name: String, path: () -> String) -> NSImage {
        // Bundles and a few well-known folders get their real icon; everything
        // else shares one image so rows stay cheap.
        let ext = (name as NSString).pathExtension.lowercased()
        let bundle = !ext.isEmpty
            && (UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false)
        guard bundle || special.contains(name) else { return genericFolder }
        let p = path()
        if let hit = byPath[p] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: p)
        icon.size = NSSize(width: 16, height: 16)
        byPath[p] = icon
        return icon
    }

    static func file(name: String, symlink: Bool) -> NSImage {
        let ext = symlink ? "\u{0}link" : (name as NSString).pathExtension.lowercased()
        if let hit = byType[ext] { return hit }
        let type: UTType = symlink ? .symbolicLink : (UTType(filenameExtension: ext) ?? .data)
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 16, height: 16)
        byType[ext] = icon
        return icon
    }
}

/// The icons of particular files and folders, which NSWorkspace reads from
/// disk. The inspector, Duplicates and the cleanup review redraw often, so
/// each path is looked up once per size rather than on every redraw.
enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 1_000
        return c
    }()

    static func icon(forFile path: String, size: CGFloat) -> NSImage {
        let key = "\(Int(size))\u{0}\(path)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: size, height: size)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
