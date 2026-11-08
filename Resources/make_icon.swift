// Usage: swift make_icon.swift <output.png>   (renders the 1024px app icon: a card squeezed by four arrows)
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

// Gradient tile (teal to deep green) with a soft highlight.
ctx.saveGState()
ctx.addPath(tile); ctx.clip()
let g = CGGradient(colorsSpace: space, colors: [NSColor(srgbRed: 0.18, green: 0.80, blue: 0.62, alpha: 1).cgColor,
                                                NSColor(srgbRed: 0.05, green: 0.42, blue: 0.48, alpha: 1).cgColor] as CFArray, locations: nil)!
ctx.drawLinearGradient(g, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
let hl = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: nil)!
ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// The card: a photo with a sun and two hills, drawn small in the middle.
let card = CGRect(x: 292, y: 292, width: 440, height: 440)
let cardPath = CGPath(roundedRect: card, cornerWidth: 70, cornerHeight: 70, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.setFillColor(NSColor(white: 1, alpha: 0.96).cgColor)
ctx.addPath(cardPath); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(cardPath); ctx.clip()
ctx.setFillColor(NSColor(srgbRed: 0.12, green: 0.62, blue: 0.55, alpha: 1).cgColor)
let hills = CGMutablePath()
hills.move(to: CGPoint(x: card.minX, y: card.minY))
hills.addLine(to: CGPoint(x: card.minX, y: card.minY + 130))
hills.addQuadCurve(to: CGPoint(x: card.midX + 10, y: card.minY + 150), control: CGPoint(x: card.minX + 120, y: card.minY + 250))
hills.addQuadCurve(to: CGPoint(x: card.maxX, y: card.minY + 110), control: CGPoint(x: card.midX + 150, y: card.minY + 60))
hills.addLine(to: CGPoint(x: card.maxX, y: card.minY))
hills.closeSubpath()
ctx.addPath(hills); ctx.fillPath()
ctx.setFillColor(NSColor(srgbRed: 1.0, green: 0.74, blue: 0.22, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: card.maxX - 160, y: card.maxY - 160, width: 84, height: 84))
ctx.restoreGState()

// Four arrows closing in on the card from the corners.
func arrow(from a: CGPoint, to b: CGPoint) {
    let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
    let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
    let head: CGFloat = 70, half: CGFloat = 46, width: CGFloat = 26
    let neck = CGPoint(x: b.x - ux * head, y: b.y - uy * head)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: a.x + nx * width / 2, y: a.y + ny * width / 2))
    p.addLine(to: CGPoint(x: neck.x + nx * width / 2, y: neck.y + ny * width / 2))
    p.addLine(to: CGPoint(x: neck.x + nx * half, y: neck.y + ny * half))
    p.addLine(to: b)
    p.addLine(to: CGPoint(x: neck.x - nx * half, y: neck.y - ny * half))
    p.addLine(to: CGPoint(x: neck.x - nx * width / 2, y: neck.y - ny * width / 2))
    p.addLine(to: CGPoint(x: a.x - nx * width / 2, y: a.y - ny * width / 2))
    p.closeSubpath()
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.addPath(p); ctx.fillPath()
}
let c = CGPoint(x: 512, y: 512)
for (sx, sy) in [(-1.0, 1.0), (1.0, 1.0), (-1.0, -1.0), (1.0, -1.0)] {
    arrow(from: CGPoint(x: c.x + sx * 312, y: c.y + sy * 312), to: CGPoint(x: c.x + sx * 222, y: c.y + sy * 222))
}
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
