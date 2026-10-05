// Renders Silt's app icon — layered river sediment — in light and dark.
//   swift scripts/make-icon.swift
//
// Resources/AppIcon.icon  Icon Composer document holding full-bleed light and
//                         dark artwork. build-app.sh compiles it into
//                         Assets.car, which macOS 26 draws the icon from.
// Resources/AppIcon.png   the framed light icon, kept beside the .icns (which a
//                         webview can't render) so tools that show a project's
//                         icon (atrium's picker) have a PNG to offer.
// build/AppIcon.iconset   framed light slices; iconutil turns them into
//                         Resources/AppIcon.icns, the icon macOS 15 uses.
import AppKit

let size: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Strata, top to bottom. Each band is a gentle wave filled to the bottom, so
// later (deeper) bands cover the ones above.
struct Band {
    let top: CGFloat    // fraction of body height from the bottom
    let amp: CGFloat
    let phase: CGFloat
    let freq: CGFloat
}
let bands = [
    Band(top: 0.62, amp: 20, phase: 0.2, freq: 1.1),
    Band(top: 0.50, amp: 24, phase: 1.9, freq: 0.9),
    Band(top: 0.385, amp: 18, phase: 3.1, freq: 1.25),
    Band(top: 0.27, amp: 22, phase: 4.4, freq: 0.95),
    Band(top: 0.155, amp: 16, phase: 5.6, freq: 1.15),
]

struct Palette {
    let base: UInt32
    let sky: (UInt32, UInt32)       // top of the sky, then the horizon
    let bands: [(UInt32, UInt32)]   // one gradient per band, top to bottom
    let bandShadow: (UInt32, CGFloat)
    let sheen: (CGFloat, CGFloat)   // top-edge highlight on the first band, less per band below
    let grain: UInt32
    let gloss: CGFloat
}

// Warm paper over sand and clay.
let light = Palette(
    base: 0xF3E4C4,
    sky: (0xFBF3E2, 0xF1DFBA),
    bands: [(0xEDCB8A, 0xE3B66C), (0xDFA152, 0xD18D3C), (0xC4733A, 0xB2622F),
            (0x94502E, 0x7F4228), (0x5C3526, 0x45281F)],
    bandShadow: (0x3A1F14, 0.18),
    sheen: (0.22, 0.03),
    grain: 0xCF8F42,
    gloss: 0.28
)

// The same riverbed after dark: a night sky warming toward the horizon, the
// strata dimmed but still lightest on top, and the grains lit like embers.
let dark = Palette(
    base: 0x1E1814,
    sky: (0x14110F, 0x2E241D),
    bands: [(0xC39A5E, 0xAE8549), (0x9E6B35, 0x8A5A2B), (0x7A4427, 0x68391F),
            (0x51301E, 0x422717), (0x2C1D15, 0x201610)],
    bandShadow: (0x000000, 0.38),
    sheen: (0.14, 0.02),
    grain: 0xE8A650,
    gloss: 0.05
)

/// `framed` is the classic macOS icon (an inset squircle with a drop shadow,
/// gloss and hairline) for the .icns and PNG. Unframed is full-bleed artwork
/// for an Icon Composer layer, which macOS 26 masks and edges itself.
func render(_ p: Palette, framed: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let inset: CGFloat = framed ? 100 : 0 // macOS icon grid: 824pt body on a 1024 canvas
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let k = body.width / 824 // the artwork is drawn to the 824pt body; scale it up for full bleed
    let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    if framed {
        // Soft drop shadow under the body.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
        ctx.addPath(squircle)
        ctx.setFillColor(color(p.base))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(squircle)
        ctx.clip()
    } else {
        ctx.setFillColor(color(p.base))
        ctx.fill(body)
        ctx.saveGState()
    }

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let sky = CGGradient(colorsSpace: space, colors: [color(p.sky.0), color(p.sky.1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])

    for (i, b) in bands.enumerated() {
        let colors = p.bands[i]
        let amp = b.amp * k
        let path = CGMutablePath()
        let baseY = body.minY + body.height * b.top
        let steps = 120
        path.move(to: CGPoint(x: body.minX - 10 * k, y: body.minY - 10 * k))
        for s in 0...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let x = body.minX - 10 * k + (body.width + 20 * k) * t
            let y = baseY + amp * sin(t * .pi * 2 * b.freq + b.phase) + amp * 0.35 * sin(t * .pi * 5.3 + b.phase * 1.7)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: body.maxX + 10 * k, y: body.minY - 10 * k))
        path.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6 * k), blur: 14 * k,
                      color: color(p.bandShadow.0, p.bandShadow.1 + 0.04 * CGFloat(i)))
        ctx.addPath(path)
        ctx.setFillColor(color(colors.0))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [color(colors.0), color(colors.1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: baseY + amp), end: CGPoint(x: 0, y: baseY - body.height * 0.14),
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()

        // A thin sheen along the top edge of each layer.
        let edge = CGMutablePath()
        for s in 0...steps {
            let t = CGFloat(s) / CGFloat(steps)
            let x = body.minX - 10 * k + (body.width + 20 * k) * t
            let y = baseY + amp * sin(t * .pi * 2 * b.freq + b.phase) + amp * 0.35 * sin(t * .pi * 5.3 + b.phase * 1.7)
            if s == 0 { edge.move(to: CGPoint(x: x, y: y - 3 * k)) } else { edge.addLine(to: CGPoint(x: x, y: y - 3 * k)) }
        }
        ctx.addPath(edge)
        ctx.setStrokeColor(color(0xFFFFFF, p.sheen.0 - p.sheen.1 * CGFloat(i)))
        ctx.setLineWidth(4 * k)
        ctx.strokePath()
    }

    // Grains of silt drifting down onto the top layer.
    let grains: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (0.66, 0.875, 7, 0.35), (0.625, 0.815, 9, 0.55), (0.595, 0.75, 12, 0.85),
    ]
    for (gx, gy, r, a) in grains {
        let c = CGPoint(x: body.minX + body.width * gx, y: body.minY + body.height * gy)
        ctx.setFillColor(color(p.grain, a))
        ctx.fillEllipse(in: CGRect(x: c.x - r * k, y: c.y - r * k, width: 2 * r * k, height: 2 * r * k))
    }

    // Glassy top highlight.
    let gloss = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, p.gloss), color(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.maxY - 220 * k),
                           options: [])
    ctx.restoreGState()

    if framed {
        // Hairline edge.
        ctx.addPath(squircle)
        ctx.setStrokeColor(color(0x000000, 0.12))
        ctx.setLineWidth(2)
        ctx.strokePath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let master = png(render(light, framed: true))
try! master.write(to: root.appendingPathComponent("Resources/AppIcon.png"))

// actool ignores image-name-specializations, so each appearance ships as its
// own layer and hides in the other one (the same fix Spake's icon needed).
let iconDoc = root.appendingPathComponent("Resources/AppIcon.icon")
let iconAssets = iconDoc.appendingPathComponent("Assets")
try! FileManager.default.createDirectory(at: iconAssets, withIntermediateDirectories: true)
try! png(render(light, framed: false)).write(to: iconAssets.appendingPathComponent("light.png"))
try! png(render(dark, framed: false)).write(to: iconAssets.appendingPathComponent("dark.png"))
let iconJSON = """
    {
      "fill" : "none",
      "groups" : [
        {
          "layers" : [
            {
              "glass" : false,
              "hidden-specializations" : [
                { "value" : false },
                { "appearance" : "dark", "value" : true }
              ],
              "image-name" : "light.png",
              "name" : "Light",
              "opacity" : 1
            },
            {
              "glass" : false,
              "hidden-specializations" : [
                { "value" : true },
                { "appearance" : "dark", "value" : false }
              ],
              "image-name" : "dark.png",
              "name" : "Dark",
              "opacity" : 1
            }
          ],
          "shadow" : { "kind" : "none", "opacity" : 0 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0 }
        }
      ],
      "supported-platforms" : { "squares" : "shared" }
    }

    """
try! Data(iconJSON.utf8).write(to: iconDoc.appendingPathComponent("icon.json"))

let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
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
