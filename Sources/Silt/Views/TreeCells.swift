import AppKit
import SiltCore

/// Everything a row displays that can change while it is on screen.
struct RowValues {
    var size: Int64 = 0
    var parentSize: Int64 = 0
    var items: Int = 0
    var modified: UInt32 = 0
    var flags: UInt8 = 0
    var growing = false
    var isDir = false
    var hasItems = false

    var share: Double { parentSize > 0 ? min(1, max(0, Double(size) / Double(parentSize))) : 0 }
}

protocol ValueCell: AnyObject {
    func apply(_ values: RowValues, node: Node)
}

// MARK: Row view

final class HoverRowView: NSTableRowView {
    private var tracking: NSTrackingArea?
    private(set) var hovered = false {
        didSet {
            guard hovered != oldValue else { return }
            (view(atColumn: 0) as? NameCell)?.setHovered(hovered)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovered = false
    }
}

// MARK: Name

final class NameCell: NSTableCellView, ValueCell {
    static let id = NSUserInterfaceItemIdentifier("name")

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let revealButton = NameCell.makeButton("magnifyingglass", tip: "Show in Finder")
    private let trashButton = NameCell.makeButton("trash", tip: "Move to Trash")
    private var hovered = false
    private weak var node: Node?
    var onReveal: ((Node) -> Void)?
    var onTrash: ((Node) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        label.cell?.truncatesLastVisibleLine = true
        badge.font = .systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.isHidden = true
        for v in [icon, label, badge, revealButton, trashButton] as [NSView] { addSubview(v) }
        imageView = icon
        textField = label
        revealButton.target = self
        revealButton.action = #selector(reveal)
        trashButton.target = self
        trashButton.action = #selector(trash)
        revealButton.isHidden = true
        trashButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func makeButton(_ symbol: String, tip: String) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        let b = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        b.isBordered = false
        b.bezelStyle = .inline
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        return b
    }

    func configure(node: Node, name: String, image: NSImage, values: RowValues) {
        self.node = node
        icon.image = image
        label.stringValue = name
        let actionable = node.isReal
        if !actionable { setHovered(false) }
        apply(values, node: node)
        needsLayout = true
    }

    func apply(_ values: RowValues, node: Node) {
        let f = values.flags
        let hidden = f & UInt8(SILT_FLAG_HIDDEN) != 0
        label.textColor = node.isReal ? (hidden ? .secondaryLabelColor : .labelColor) : .secondaryLabelColor
        let text: String?
        var color = NSColor.secondaryLabelColor
        if f & UInt8(SILT_FLAG_DENIED) != 0 {
            text = "No access"
            color = .systemOrange
        } else if f & UInt8(SILT_FLAG_MOUNT) != 0 {
            text = "Other volume"
        } else if f & UInt8(SILT_FLAG_DATALESS) != 0 {
            text = "In iCloud"
        } else if f & UInt8(SILT_FLAG_HARDLINK) != 0 {
            text = "Hard link"
        } else {
            text = nil
        }
        if badge.stringValue != (text ?? "") || badge.isHidden != (text == nil) {
            badge.stringValue = text ?? ""
            badge.textColor = color
            badge.isHidden = text == nil
            needsLayout = true
        }
    }

    func setHovered(_ on: Bool) {
        let show = on && (node?.isReal ?? false)
        guard show != hovered else { return }
        hovered = show
        revealButton.isHidden = !show
        trashButton.isHidden = !show
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 1, y: (h - 16) / 2, width: 16, height: 16)
        var right = bounds.width - 2
        if hovered {
            trashButton.frame = NSRect(x: right - 20, y: (h - 20) / 2, width: 20, height: 20)
            right -= 22
            revealButton.frame = NSRect(x: right - 20, y: (h - 20) / 2, width: 20, height: 20)
            right -= 24
        }
        if !badge.isHidden {
            let w = ceil(badge.intrinsicContentSize.width)
            badge.frame = NSRect(x: right - w, y: (h - 15) / 2, width: w, height: 15)
            right -= w + 8
        }
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 22, y: (h - lh) / 2, width: max(0, right - 22), height: lh)
    }

    @objc private func reveal() { if let node { onReveal?(node) } }
    @objc private func trash() { if let node { onTrash?(node) } }
}

// MARK: Share bar

final class ShareCell: NSTableCellView, ValueCell {
    static let id = NSUserInterfaceItemIdentifier("share")

    private var fraction: Double = 0
    private var color: NSColor = Brand.ochre
    private var growing = false
    private var visible = true
    private static let percentAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ values: RowValues, node: Node) {
        let c: NSColor
        switch node.kind {
        case .dir: c = Brand.ochre
        case .file: c = FileCategory.of(name: node.nameForColor).nsColor
        case .more, .unseen, .list: c = .tertiaryLabelColor
        }
        let f = values.share
        if abs(f - fraction) < 0.0005 && c == color && values.growing == growing { return }
        fraction = f
        color = c
        growing = values.growing
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let pctWidth: CGFloat = 40
        let barX: CGFloat = 4
        let barW = max(0, bounds.width - pctWidth - barX - 6)
        let barH: CGFloat = 6
        let y = (bounds.height - barH) / 2
        let track = NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: barW, height: barH), xRadius: 3, yRadius: 3)
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        track.fill()
        if fraction > 0 {
            let w = max(barH, barW * CGFloat(fraction))
            let fill = NSBezierPath(roundedRect: NSRect(x: barX, y: y, width: w, height: barH), xRadius: 3, yRadius: 3)
            color.withAlphaComponent(growing ? 0.5 : 0.9).setFill()
            fill.fill()
        }
        let text = Fmt.percent(fraction) as NSString
        let size = text.size(withAttributes: Self.percentAttrs)
        text.draw(at: NSPoint(x: bounds.width - size.width - 2, y: (bounds.height - size.height) / 2),
                  withAttributes: Self.percentAttrs)
    }
}

// MARK: Numbers and text

final class TextCell: NSTableCellView, ValueCell {
    enum Column { case size, items, modified, location }

    let column: Column
    private let label = NSTextField(labelWithString: "")

    init(column: Column, identifier: NSUserInterfaceItemIdentifier) {
        self.column = column
        super.init(frame: .zero)
        self.identifier = identifier
        switch column {
        case .size:
            label.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
            label.alignment = .right
        case .items, .modified:
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.alignment = .right
            label.textColor = .secondaryLabelColor
        case .location:
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingHead
        }
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError() }

    var location: String? {
        didSet { if column == .location { label.stringValue = location ?? "" } }
    }

    func apply(_ v: RowValues, node: Node) {
        let text: String
        switch column {
        case .size:
            text = Fmt.bytes(v.size)
            label.textColor = v.growing ? .tertiaryLabelColor : .labelColor
        case .items:
            text = v.hasItems ? Fmt.count(v.items) : ""
        case .modified:
            text = node.isReal ? Fmt.age(v.modified) : ""
        case .location:
            return
        }
        if label.stringValue != text { label.stringValue = text }
    }

    override func layout() {
        super.layout()
        let h = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 2, y: (bounds.height - h) / 2, width: bounds.width - 6, height: h)
    }
}
