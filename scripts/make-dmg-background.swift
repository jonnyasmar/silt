// Renders the disk image window's background in Silt's palette.
//   swift scripts/make-dmg-background.swift
//
// Resources/dmg-background.png     1x, the window's content size in points
// Resources/dmg-background@2x.png  2x; dmgbuild pairs the two into one HiDPI
//                                  .background.tiff
//
// Geometry comes from scripts/dmg/layout.json, the file dmgbuild reads for the
// icon positions, so the arrow always sits between the two icons. Finder draws
// the icons and their labels; this picture is only what's around them: warm
// paper, one ochre arrow, one line of instruction, and a low run of sediment
// along the bottom edge taken from the icon.
import AppKit

struct Layout: Decodable {
    struct Point: Decodable { let x: CGFloat; let y: CGFloat }
    struct Size: Decodable { let width: CGFloat; let height: CGFloat }
    let caption: String
    let captionY: CGFloat
    let window: Size
    let iconSize: CGFloat
    let app: Point
    let applications: Point
}

let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let resources = scripts.deletingLastPathComponent().appendingPathComponent("Resources")
let layout = try JSONDecoder().decode(
    Layout.self, from: Data(contentsOf: scripts.appendingPathComponent("dmg/layout.json")))

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// From make-icon.swift's light palette.
let paperTop: UInt32 = 0xFBF3E2
let paperBottom: UInt32 = 0xF3E4C4
let ochre: UInt32 = 0xD18D3C
let clay: UInt32 = 0xB2622F
let umber: UInt32 = 0x5C3526

// Bottom strata, back to front: (top edge above the bottom, amplitude, phase,
// frequency, colour, opacity). Faint on purpose; it's a signature, not a picture.
let strata: [(CGFloat, CGFloat, CGFloat, CGFloat, UInt32, CGFloat)] = [
    (40, 4.5, 0.2, 1.1, 0xEDCB8A, 0.40),
    (27, 4.0, 1.9, 0.9, 0xDFA152, 0.30),
    (15, 3.5, 3.1, 1.25, 0xC4733A, 0.22),
]

func render(scale: Int) -> Data {
    let w = layout.window.width, h = layout.window.height
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w) * scale, pixelsHigh: Int(h) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // Point size, so the 2x file is 144 dpi and the pair combines into one TIFF.
    // Set before the context exists, it also makes the context draw in points.
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // layout.json is top-left origin; CoreGraphics is bottom-left.
    func flip(_ y: CGFloat) -> CGFloat { h - y }

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let paper = CGGradient(colorsSpace: space, colors: [color(paperTop), color(paperBottom)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

    for (top, amp, phase, freq, hex, alpha) in strata {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -2, y: -2))
        let steps = 160
        for s in 0...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let y = top + amp * sin(t * .pi * 2 * freq + phase) + amp * 0.35 * sin(t * .pi * 5.3 + phase * 1.7)
            path.addLine(to: CGPoint(x: -2 + (w + 4) * t, y: y))
        }
        path.addLine(to: CGPoint(x: w + 2, y: -2))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color(hex, alpha))
        ctx.fillPath()
    }

    // The arrow: a rounded shaft and an open head on the icons' centre line,
    // clear of both icons.
    let y = flip(layout.app.y)
    let gap = layout.iconSize / 2 + 30
    let start = layout.app.x + gap, end = layout.applications.x - gap
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(3)
    ctx.setStrokeColor(color(ochre, 0.55))
    ctx.move(to: CGPoint(x: start, y: y))
    ctx.addLine(to: CGPoint(x: end - 3, y: y))
    ctx.strokePath()
    ctx.setStrokeColor(color(clay, 0.85))
    ctx.setLineWidth(3.5)
    ctx.move(to: CGPoint(x: end - 12, y: y + 10))
    ctx.addLine(to: CGPoint(x: end, y: y))
    ctx.addLine(to: CGPoint(x: end - 12, y: y - 10))
    ctx.strokePath()

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let caption = NSAttributedString(string: layout.caption, attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(cgColor: color(umber, 0.62))!,
        .kern: 0.2,
        .paragraphStyle: style,
    ])
    let lineHeight: CGFloat = 20
    caption.draw(in: CGRect(x: 0, y: flip(layout.captionY) - lineHeight / 2, width: w, height: lineHeight))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: resources.appendingPathComponent("dmg-background.png"), options: .atomic)
try render(scale: 2).write(to: resources.appendingPathComponent("dmg-background@2x.png"), options: .atomic)
print("rendered \(resources.path)/dmg-background.png and @2x")
