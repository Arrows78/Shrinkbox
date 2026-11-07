// Usage: swift make_icon.swift <output.png>   (renders the 1024px app icon: a notch island hanging from a gradient tile)
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsctx
let ctx = nsctx.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(roundedRect: body, cornerWidth: 184, cornerHeight: 184, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.setFillColor(NSColor.black.cgColor)
ctx.addPath(tile); ctx.fillPath()
ctx.restoreGState()

// Gradient tile (warm, coral to orange) with a soft highlight.
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let g = CGGradient(colorsSpace: space, colors: [NSColor(srgbRed: 1.00, green: 0.42, blue: 0.45, alpha: 1).cgColor,
                                                NSColor(srgbRed: 1.00, green: 0.62, blue: 0.20, alpha: 1).cgColor] as CFArray, locations: nil)!
ctx.drawLinearGradient(g, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
let hl = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.20).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: nil)!
ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

// The island: flat on the top edge, round at the bottom, like an expanded notch.
let island = CGRect(x: 232, y: 454, width: 560, height: 470)
let r: CGFloat = 150
let p = CGMutablePath()
p.move(to: CGPoint(x: island.minX, y: island.maxY))
p.addLine(to: CGPoint(x: island.minX, y: island.minY + r))
p.addArc(tangent1End: CGPoint(x: island.minX, y: island.minY), tangent2End: CGPoint(x: island.minX + r, y: island.minY), radius: r)
p.addLine(to: CGPoint(x: island.maxX - r, y: island.minY))
p.addArc(tangent1End: CGPoint(x: island.maxX, y: island.minY), tangent2End: CGPoint(x: island.maxX, y: island.minY + r), radius: r)
p.addLine(to: CGPoint(x: island.maxX, y: island.maxY))
p.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: NSColor.black.withAlphaComponent(0.4).cgColor)
ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1).cgColor)
ctx.addPath(p); ctx.fillPath()
ctx.restoreGState()
ctx.restoreGState()

// Equalizer bars inside the island.
let heights: [CGFloat] = [120, 210, 290, 180, 240, 110]
let barW: CGFloat = 46, gap: CGFloat = 28
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = 512 - total / 2
let baseY: CGFloat = 520
let colors = [NSColor(srgbRed: 1.00, green: 0.42, blue: 0.45, alpha: 1), NSColor(srgbRed: 1.00, green: 0.62, blue: 0.20, alpha: 1)]
for (i, h) in heights.enumerated() {
    let t = CGFloat(i) / CGFloat(heights.count - 1)
    let c = NSColor(srgbRed: colors[0].redComponent + (colors[1].redComponent - colors[0].redComponent) * t,
                    green: colors[0].greenComponent + (colors[1].greenComponent - colors[0].greenComponent) * t,
                    blue: colors[0].blueComponent + (colors[1].blueComponent - colors[0].blueComponent) * t, alpha: 1)
    ctx.setFillColor(c.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: baseY, width: barW, height: h), cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.fillPath()
    x += barW + gap
}
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
