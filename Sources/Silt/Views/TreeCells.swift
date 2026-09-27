import AppKit
import SiltCore

/// Everything a row displays that can change while it is on screen.
struct RowValues {
    var size: Int64 = 0
    /// What the percentage is "of".
    var parentSize: Int64 = 0
    /// What the bar is scaled to (the parent, or a list's largest row).
    var barBase: Int64 = 0
    /// Rows standing for several identical files.
    var copies = 0
    /// Marked for cleanup itself, or inside a marked folder.
    var marked = false
    var covered = false
    var guidance: Guidance?
    /// Change since the last scan, when it's worth pointing out.
    var growth: Int64?
    var items: Int = 0
    var modified: UInt32 = 0
    var flags: UInt8 = 0
    var growing = false
    var isDir = false
    var hasItems = false

    var share: Double { parentSize > 0 ? min(1, max(0, Double(size) / Double(parentSize))) : 0 }
    var bar: Double { barBase > 0 ? min(1, max(0, Double(size) / Double(barBase))) : 0 }
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
    private let revealButton = NameCell.makeButton("arrow.up.right.square", tip: "Show in Finder")
    private let markButton = NameCell.makeButton("checklist", tip: "Mark for Cleanup (M)")
    private let trashButton = NameCell.makeButton("trash", tip: "Move to Trash")
    private var name = ""
    private var hovered = false
    private weak var node: Node?
    var onReveal: ((Node) -> Void)?
    var onTrash: ((Node) -> Void)?
    var onMark: ((Node) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        label.cell?.truncatesLastVisibleLine = true
        badge.font = .systemFont(ofSize: 11)
        badge.textColor = .secondaryLabelColor
        badge.isHidden = true
        for v in [icon, label, badge, revealButton, markButton, trashButton] as [NSView] { addSubview(v) }
        imageView = icon
        textField = label
        revealButton.target = self
        revealButton.action = #selector(reveal)
        trashButton.target = self
        trashButton.action = #selector(trash)
        markButton.target = self
        markButton.action = #selector(mark)
        revealButton.isHidden = true
        markButton.isHidden = true
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
        self.name = name
        lastStyle = nil
        let actionable = node.isReal
        if !actionable { setHovered(false) }
        apply(values, node: node)
        needsLayout = true
    }

    private var lastStyle: (NSColor, Bool)?

    func apply(_ values: RowValues, node: Node) {
        let f = values.flags
        let hidden = f & UInt8(SILT_FLAG_HIDDEN) != 0
        let primary = node.isReal || node.kind == .group
        var color: NSColor = primary ? (hidden ? .secondaryLabelColor : .labelColor) : .secondaryLabelColor
        if values.covered { color = values.marked ? .secondaryLabelColor : .tertiaryLabelColor }
        // Marked rows read as "going away": struck through, dimmed.
        if lastStyle == nil || lastStyle!.0 != color || lastStyle!.1 != values.covered {
            lastStyle = (color, values.covered)
            // No explicit color in the string: the label's text color lets
            // selected rows turn white like any other table text.
            var attrs: [NSAttributedString.Key: Any] = [.font: label.font!]
            if values.covered { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingMiddle
            attrs[.paragraphStyle] = para
            label.attributedStringValue = NSAttributedString(string: name, attributes: attrs)
            label.textColor = color
        }
        let text: String?
        var badgeColor = NSColor.secondaryLabelColor
        if f & UInt8(SILT_FLAG_DENIED) != 0 {
            text = "No access"
            badgeColor = .systemOrange
        } else if f & UInt8(SILT_FLAG_MOUNT) != 0 {
            text = "Other volume"
        } else if f & UInt8(SILT_FLAG_DATALESS) != 0 {
            text = "In iCloud"
        } else if values.marked {
            text = "Cleanup"
            badgeColor = Brand.ochre
        } else if values.covered {
            text = nil
        } else if let g = values.growth {
            text = (g > 0 ? "+" : "−") + Fmt.bytesShort(abs(g))
            badgeColor = g > 0 ? .systemOrange : .systemGreen
        } else if values.copies > 1 {
            text = "\(values.copies) copies"
        } else if f & UInt8(SILT_FLAG_CLONE) != 0 {
            text = "Clone"
        } else if f & UInt8(SILT_FLAG_HARDLINK) != 0 {
            text = "Hard link"
        } else if let g = values.guidance, !g.tag.isEmpty {
            text = g.tag
            switch g.safety {
            case .safe: badgeColor = .systemGreen
            case .review: badgeColor = .systemOrange
            case .keep: badgeColor = .secondaryLabelColor
            }
        } else {
            text = nil
        }
        let color_ = badgeColor
        if badge.stringValue != (text ?? "") || badge.isHidden != (text == nil) || badge.textColor != color_ {
            badge.stringValue = text ?? ""
            badge.textColor = color_
            badge.isHidden = text == nil
            needsLayout = true
        }
        let symbol = values.marked ? "minus.circle" : "checklist"
        if markButton.toolTip != (values.marked ? "Remove from Cleanup (M)" : "Mark for Cleanup (M)") {
            markButton.toolTip = values.marked ? "Remove from Cleanup (M)" : "Mark for Cleanup (M)"
            markButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: markButton.toolTip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        }
    }

    func setHovered(_ on: Bool) {
        let show = on && (node?.isReal ?? false)
        guard show != hovered else { return }
        hovered = show
        revealButton.isHidden = !show
        markButton.isHidden = !show
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
            markButton.frame = NSRect(x: right - 20, y: (h - 20) / 2, width: 20, height: 20)
            right -= 22
            revealButton.frame = NSRect(x: right - 20, y: (h - 20) / 2, width: 20, height: 20)
            right -= 24
        }
        // While hovered the buttons take the badge's place, so nothing jumps.
        badge.alphaValue = hovered ? 0 : 1
        if !badge.isHidden && !hovered {
            let w = ceil(badge.intrinsicContentSize.width)
            badge.frame = NSRect(x: right - w, y: (h - 15) / 2, width: w, height: 15)
            right -= w + 8
        }
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 22, y: (h - lh) / 2, width: max(0, right - 22), height: lh)
    }

    @objc private func reveal() { if let node { onReveal?(node) } }
    @objc private func trash() { if let node { onTrash?(node) } }
    @objc private func mark() { if let node { onMark?(node) } }
}

// MARK: Share bar

final class ShareCell: NSTableCellView, ValueCell {
    static let id = NSUserInterfaceItemIdentifier("share")

    private var fraction: Double = .nan // forces the first apply to draw
    private var bar: Double = 0
    private var color: NSColor = Brand.ochre
    private var growing = false
    private static let percentAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
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
        case .file, .group: c = FileCategory.of(name: node.nameForColor).nsColor
        case .more, .unseen, .hiddenPart, .list: c = .tertiaryLabelColor
        }
        let f = values.share
        if abs(f - fraction) < 0.0005 && abs(values.bar - bar) < 0.0005 && c == color && values.growing == growing {
            return
        }
        fraction = f
        bar = values.bar
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
        if bar > 0 {
            let w = max(barH, barW * CGFloat(bar))
            let rect = NSRect(x: barX, y: y, width: w, height: barH)
            let fill = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            if growing {
                // Still being scanned: a hatched bar, like an indeterminate
                // progress fill.
                color.withAlphaComponent(0.35).setFill()
                fill.fill()
                NSGraphicsContext.saveGraphicsState()
                fill.addClip()
                color.withAlphaComponent(0.9).setFill()
                var x = rect.minX - barH
                while x < rect.maxX {
                    let stripe = NSBezierPath()
                    stripe.move(to: NSPoint(x: x, y: rect.minY))
                    stripe.line(to: NSPoint(x: x + 2.5, y: rect.minY))
                    stripe.line(to: NSPoint(x: x + 2.5 + barH, y: rect.maxY))
                    stripe.line(to: NSPoint(x: x + barH, y: rect.maxY))
                    stripe.close()
                    stripe.fill()
                    x += 5
                }
                NSGraphicsContext.restoreGraphicsState()
            } else {
                color.withAlphaComponent(0.9).setFill()
                fill.fill()
            }
        }
        let text = Fmt.percent(fraction.isNaN ? 0 : fraction) as NSString
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
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            label.alignment = .right
        case .items, .modified:
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
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
            text = node.isReal || node.kind == .group ? Fmt.age(v.modified) : ""
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
