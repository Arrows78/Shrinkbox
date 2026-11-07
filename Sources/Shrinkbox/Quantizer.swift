import Foundation
import CoreGraphics

/// Lossy PNG without any tool: the colours are reduced to a palette (median cut on a 15-bit histogram) and the
/// error is spread to the neighbouring pixels (Floyd–Steinberg), which keeps gradients and photos smooth.
enum Quantizer {
    /// Palette size for a compression level.
    static func colors(for level: Level, aggressive: Bool) -> Int {
        let s = aggressive ? min(1, level.strength + 0.25) : level.strength
        if s < 0.35 { return 256 }
        if s < 0.6 { return 128 }
        if s < 0.8 { return 64 }
        return 32
    }

    /// An 8-bit indexed copy of an opaque image, or nil when the image has transparency.
    static func quantize(_ image: CGImage, colors count: Int, dither: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, !ImageEngine.hasAlpha(image) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // Histogram of 5 bits per channel.
        var histogram = [Int](repeating: 0, count: 32768)
        pixels.withUnsafeBufferPointer { p in
            for i in stride(from: 0, to: w * h * 4, by: 4) { histogram[Int(p[i] >> 3) << 10 | Int(p[i + 1] >> 3) << 5 | Int(p[i + 2] >> 3)] += 1 }
        }
        let used = histogram.indices.filter { histogram[$0] > 0 }
        guard !used.isEmpty else { return nil }
        let n = min(max(2, count), 256)

        func channels(_ bin: Int) -> (Int, Int, Int) { (bin >> 10, (bin >> 5) & 31, bin & 31) }
        // Median cut.
        var boxes: [[Int]] = [used]
        while boxes.count < n {
            guard let target = boxes.indices.filter({ boxes[$0].count > 1 }).max(by: { weight(boxes[$0], histogram) < weight(boxes[$1], histogram) }) else { break }
            let box = boxes[target]
            var lo = (31, 31, 31), hi = (0, 0, 0)
            for b in box { let c = channels(b); lo = (min(lo.0, c.0), min(lo.1, c.1), min(lo.2, c.2)); hi = (max(hi.0, c.0), max(hi.1, c.1), max(hi.2, c.2)) }
            let ranges = (hi.0 - lo.0, hi.1 - lo.1, hi.2 - lo.2)
            let axis = ranges.0 >= ranges.1 && ranges.0 >= ranges.2 ? 0 : (ranges.1 >= ranges.2 ? 1 : 2)
            let sorted = box.sorted { a, b in
                let ca = channels(a), cb = channels(b)
                return axis == 0 ? ca.0 < cb.0 : (axis == 1 ? ca.1 < cb.1 : ca.2 < cb.2)
            }
            // Split at the weighted median.
            let half = weight(sorted, histogram) / 2
            var acc = 0, cut = 1
            for (i, b) in sorted.enumerated() { acc += histogram[b]; if acc >= half { cut = min(max(1, i + 1), sorted.count - 1); break } }
            boxes[target] = Array(sorted[..<cut])
            boxes.append(Array(sorted[cut...]))
        }
        // Palette: the average colour of each box, weighted by how many pixels use it.
        var palette: [(Int, Int, Int)] = []
        for box in boxes {
            var r = 0, g = 0, b = 0, total = 0
            for bin in box { let c = channels(bin), k = histogram[bin]; r += c.0 * k; g += c.1 * k; b += c.2 * k; total += k }
            func expand(_ v: Int) -> Int { let x = v / max(1, total); return (x << 3) | (x >> 2) }
            palette.append((expand(r), expand(g), expand(b)))
        }
        // Nearest palette entry of every used bin.
        var lookup = [UInt8](repeating: 0, count: 32768)
        for bin in used {
            let c = channels(bin)
            let r = (c.0 << 3) | (c.0 >> 2), g = (c.1 << 3) | (c.1 >> 2), b = (c.2 << 3) | (c.2 >> 2)
            var best = 0, bestD = Int.max
            for (i, p) in palette.enumerated() {
                let d = (p.0 - r) * (p.0 - r) + (p.1 - g) * (p.1 - g) + (p.2 - b) * (p.2 - b)
                if d < bestD { bestD = d; best = i }
            }
            lookup[bin] = UInt8(best)
        }
        // With dithering the adjusted colours can land in bins no pixel used: fill the rest lazily.
        func nearest(_ r: Int, _ g: Int, _ b: Int) -> Int {
            let bin = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
            if histogram[bin] > 0 { return Int(lookup[bin]) }
            var best = 0, bestD = Int.max
            for (i, p) in palette.enumerated() {
                let d = (p.0 - r) * (p.0 - r) + (p.1 - g) * (p.1 - g) + (p.2 - b) * (p.2 - b)
                if d < bestD { bestD = d; best = i }
            }
            histogram[bin] = 1; lookup[bin] = UInt8(best)
            return best
        }

        var indices = [UInt8](repeating: 0, count: w * h)
        if dither {
            var errCurrent = [Int](repeating: 0, count: (w + 2) * 3), errNext = [Int](repeating: 0, count: (w + 2) * 3)
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    let ex = (x + 1) * 3
                    let r = min(255, max(0, Int(pixels[o]) + errCurrent[ex] / 16)), g = min(255, max(0, Int(pixels[o + 1]) + errCurrent[ex + 1] / 16)), b = min(255, max(0, Int(pixels[o + 2]) + errCurrent[ex + 2] / 16))
                    let i = nearest(r, g, b)
                    indices[y * w + x] = UInt8(i)
                    let p = palette[i]
                    let dr = r - p.0, dg = g - p.1, db = b - p.2
                    for (dx, dy, k) in [(1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)] {
                        let nx = x + dx
                        guard nx >= 0, nx < w else { continue }
                        let idx = (nx + 1) * 3
                        if dy == 0 { errCurrent[idx] += dr * k; errCurrent[idx + 1] += dg * k; errCurrent[idx + 2] += db * k }
                        else { errNext[idx] += dr * k; errNext[idx + 1] += dg * k; errNext[idx + 2] += db * k }
                    }
                }
                swap(&errCurrent, &errNext)
                for i in errNext.indices { errNext[i] = 0 }
            }
        } else {
            for i in 0..<(w * h) { let o = i * 4; indices[i] = UInt8(nearest(Int(pixels[o]), Int(pixels[o + 1]), Int(pixels[o + 2]))) }
        }

        var table = [UInt8]()
        for p in palette { table += [UInt8(p.0), UInt8(p.1), UInt8(p.2)] }
        guard let indexed = CGColorSpace(indexedBaseSpace: space, last: palette.count - 1, colorTable: table),
              let provider = CGDataProvider(data: Data(indices) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: indexed, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func weight(_ bins: [Int], _ histogram: [Int]) -> Int { bins.reduce(0) { $0 + histogram[$1] } }
}
