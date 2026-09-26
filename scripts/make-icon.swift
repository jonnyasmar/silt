// Renders Silt's app icon — layered river sediment in a macOS squircle — to
// Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
import AppKit

let size: CGFloat = 1024
let inset: CGFloat = 100 // macOS icon grid: 824pt body on a 1024 canvas
let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let radius: CGFloat = 185

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Soft drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(squircle)
ctx.setFillColor(color(0xF3E4C4))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// Sky: warm paper.
let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFBF3E2), color(0xF1DFBA)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])

// Strata, top to bottom. Each band is a gentle wave filled to the bottom, so
// later (deeper) bands cover the ones above.
struct Band {
    let top: CGFloat    // fraction of body height from the bottom
    let amp: CGFloat
    let phase: CGFloat
    let freq: CGFloat
    let colors: (UInt32, UInt32)
}
let bands = [
    Band(top: 0.62, amp: 20, phase: 0.2, freq: 1.1, colors: (0xEDCB8A, 0xE3B66C)),
    Band(top: 0.50, amp: 24, phase: 1.9, freq: 0.9, colors: (0xDFA152, 0xD18D3C)),
    Band(top: 0.385, amp: 18, phase: 3.1, freq: 1.25, colors: (0xC4733A, 0xB2622F)),
    Band(top: 0.27, amp: 22, phase: 4.4, freq: 0.95, colors: (0x94502E, 0x7F4228)),
    Band(top: 0.155, amp: 16, phase: 5.6, freq: 1.15, colors: (0x5C3526, 0x45281F)),
]
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for (i, b) in bands.enumerated() {
    let path = CGMutablePath()
    let baseY = body.minY + body.height * b.top
    let steps = 120
    path.move(to: CGPoint(x: body.minX - 10, y: body.minY - 10))
    for s in 0...steps {
        let t = CGFloat(s) / CGFloat(steps)
        let x = body.minX - 10 + (body.width + 20) * t
        let y = baseY + b.amp * sin(t * .pi * 2 * b.freq + b.phase) + b.amp * 0.35 * sin(t * .pi * 5.3 + b.phase * 1.7)
        path.addLine(to: CGPoint(x: x, y: y))
    }
    path.addLine(to: CGPoint(x: body.maxX + 10, y: body.minY - 10))
    path.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 14, color: color(0x3A1F14, 0.18 + 0.04 * CGFloat(i)))
    ctx.addPath(path)
    ctx.setFillColor(color(b.colors.0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: space, colors: [color(b.colors.0), color(b.colors.1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: baseY + b.amp), end: CGPoint(x: 0, y: baseY - body.height * 0.14),
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // A thin sheen along the top edge of each layer.
    let edge = CGMutablePath()
    for s in 0...steps {
        let t = CGFloat(s) / CGFloat(steps)
        let x = body.minX - 10 + (body.width + 20) * t
        let y = baseY + b.amp * sin(t * .pi * 2 * b.freq + b.phase) + b.amp * 0.35 * sin(t * .pi * 5.3 + b.phase * 1.7)
        if s == 0 { edge.move(to: CGPoint(x: x, y: y - 3)) } else { edge.addLine(to: CGPoint(x: x, y: y - 3)) }
    }
    ctx.addPath(edge)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22 - 0.03 * CGFloat(i)))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

// Grains of silt drifting down onto the top layer.
let grains: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (0.66, 0.875, 7, 0.35), (0.625, 0.815, 9, 0.55), (0.595, 0.75, 12, 0.85),
]
for (gx, gy, r, a) in grains {
    let c = CGPoint(x: body.minX + body.width * gx, y: body.minY + body.height * gy)
    ctx.setFillColor(color(0xCF8F42, a))
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

// Glassy top highlight.
let gloss = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.maxY - 220), options: [])
ctx.restoreGState()

// Hairline edge.
ctx.addPath(squircle)
ctx.setStrokeColor(color(0x000000, 0.12))
ctx.setLineWidth(2)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = rep.representation(using: .png, properties: [:])!
let masterURL = root.appendingPathComponent("build/icon-1024.png")
try! master.write(to: masterURL)

for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for s in scales {
        let px = pt * s
        let name = s == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current!.imageInterpolation = .high
        let src = NSImage(data: master)!
        src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        try! out.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
print(iconset.path)
