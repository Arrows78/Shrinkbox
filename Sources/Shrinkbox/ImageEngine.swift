import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Vision

/// A crop request: an exact size, a long edge, or a shape.
struct CropSpec: Equatable, Sendable {
    var width: Int?
    var height: Int?
    var longEdge: Int?
    var aspect: Double?        // width / height
    var smart = false

    /// "1200x630", "1200", "x630", "16:9", "1.91:1".
    static func parse(_ text: String, longEdge: Bool = false, smart: Bool = false) -> CropSpec? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        var spec = CropSpec(smart: smart)
        if t.contains(":") {
            let p = t.split(separator: ":").compactMap { Double($0) }
            guard p.count == 2, p[0] > 0, p[1] > 0 else { return nil }
            spec.aspect = p[0] / p[1]
        } else if t.contains("x") {
            let p = t.split(separator: "x", omittingEmptySubsequences: false).map { Int($0) }
            guard p.count == 2, p[0] != nil || p[1] != nil else { return nil }
            spec.width = p[0]; spec.height = p[1]
            if longEdge, let w = p[0] ?? p[1] { spec.longEdge = w; spec.width = nil; spec.height = nil }
        } else if let n = Int(t), n > 0 {
            if longEdge { spec.longEdge = n } else { spec.width = n }
        } else { return nil }
        return spec
    }

    /// For file names: "1200x630", "16:9", "1920".
    var label: String {
        if let a = aspect { return String(format: "%g:1", (a * 100).rounded() / 100) }
        if let l = longEdge { return "\(l)" }
        return [width.map(String.init), height.map(String.init)].compactMap { $0 }.joined(separator: "x")
    }
}

struct ImageJob: Sendable {
    var level: Level = .value(30)
    var adaptive = false
    var downscale: Double?
    var crop: CropSpec?
    var stripMetadata = true
    var preserveColor = true
    var targetExtension: String?
    var gifDropFrames = true
    var gifKeepDuration = false
    var aggressive = false
}

enum ImageEngine {
    // MARK: Formats

    static func destinationType(for ext: String) -> String? {
        let e = Media.canonical(ext)
        let candidates: [String: String] = ["jpeg": "public.jpeg", "png": "public.png", "gif": "com.compuserve.gif", "heic": "public.heic",
                                            "heif": "public.heif", "tiff": "public.tiff", "bmp": "com.microsoft.bmp", "avif": "public.avif", "jxl": "public.jpeg-xl", "webp": "org.webmproject.webp"]
        guard let id = candidates[e] else { return nil }
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return supported.contains(id) ? id : nil
    }

    /// Whether Shrinkbox can write this extension, with macOS alone or with an installed tool.
    static func canWrite(_ ext: String) -> Bool {
        let e = Media.canonical(ext)
        if destinationType(for: e) != nil { return true }
        if e == "webp" { return Tool.cwebp.available }
        if e == "avif" { return Tool.heifEnc.available }
        return false
    }

    // MARK: Entry point

    /// Processes one image into the workspace and returns the new file.
    static func process(_ src: URL, job: ImageJob) async throws -> URL {
        let srcExt = src.pathExtension
        var outExt = job.targetExtension.map { Media.canonical($0) } ?? Media.canonical(srcExt)
        if outExt == "jpeg" && (job.targetExtension != nil || srcExt.lowercased() == "jpg") { outExt = "jpg" }   // "jpg" is what people expect
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { throw ShrinkError.failed(L("Cannot read %@", src.lastPathComponent)) }
        let frames = CGImageSourceGetCount(source)

        // Animated GIFs keep their frames.
        if frames > 1 && Media.canonical(srcExt) == "gif" && Media.canonical(outExt) == "gif" {
            return try await processGIF(src, source: source, job: job)
        }
        if frames > 1 && Media.canonical(srcExt) == "webp" && Media.canonical(outExt) == "webp" {
            throw ShrinkError.unsupported(L("Animated WebP files are left as they are"))
        }

        var image = try loadOriented(source)
        let originalSize = (image.width, image.height)
        let hasAlpha = Self.hasAlpha(image)

        // Adaptive: photographs go to JPEG, flat graphics to PNG.
        if job.adaptive && job.targetExtension == nil {
            let photo = isPhotographic(image)
            if photo && !hasAlpha && outExt == "png" { outExt = "jpg" }
            else if !photo && outExt.hasPrefix("jp") && !hasAlpha { outExt = "png" }
        }

        if let crop = job.crop { image = try apply(crop, to: image) }
        if let f = job.downscale, f > 0, f < 1 { image = resize(image, to: (max(1, Int(Double(image.width) * f)), max(1, Int(Double(image.height) * f)))) ?? image }

        let properties = job.stripMetadata ? [:] : keptProperties(source)
        let out = Workspace.temp(ext: outExt, name: src.deletingPathExtension().lastPathComponent)
        try await encode(image, ext: outExt, level: job.level, aggressive: job.aggressive, properties: properties, hasAlpha: hasAlpha, to: out)
        _ = originalSize
        return out
    }

    // MARK: Decode

    /// The image with its orientation applied, at full size.
    static func loadOriented(_ source: CGImageSource) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1), kCGImageSourceShouldCacheImmediately: true]
        if let img = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return img }
        if let img = CGImageSourceCreateImageAtIndex(source, 0, nil) { return img }
        throw ShrinkError.failed(L("Cannot decode the image"))
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Metadata worth keeping when the user asked not to strip it (EXIF, GPS, TIFF, IPTC), without the orientation
    /// that has been applied to the pixels already.
    static func keptProperties(_ source: CGImageSource) -> [CFString: Any] {
        guard var p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyOrientation, kCGImagePropertyFileSize, kCGImagePropertyDepth, kCGImagePropertyHasAlpha] { p[k] = nil }
        if var tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { tiff[kCGImagePropertyTIFFOrientation] = nil; p[kCGImagePropertyTIFFDictionary] = tiff }
        return p
    }

    /// A rough photograph test: many distinct colours in a small thumbnail.
    static func isPhotographic(_ image: CGImage) -> Bool {
        let n = 48
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data else { return true }
        let px = data.bindMemory(to: UInt8.self, capacity: n * n * 4)
        var seen = Set<UInt16>()
        for i in 0..<(n * n) {
            let r = UInt16(px[i * 4] >> 4), g = UInt16(px[i * 4 + 1] >> 4), b = UInt16(px[i * 4 + 2] >> 4)
            seen.insert(r << 8 | g << 4 | b)
        }
        return seen.count > 350
    }

    // MARK: Geometry

    static func resize(_ image: CGImage, to size: (Int, Int)) -> CGImage? {
        guard size.0 > 0, size.1 > 0 else { return nil }
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info = hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1))
        return ctx.makeImage()
    }

    /// The pixel size a crop request gives for an image, and the region of the source it keeps.
    static func plan(_ crop: CropSpec, for size: (Int, Int)) -> (region: CGRect, output: (Int, Int))? {
        let w = Double(size.0), h = Double(size.1)
        var region = CGRect(x: 0, y: 0, width: w, height: h)
        var target: (Int, Int) = size
        if let a = crop.aspect {
            let landscape = a >= 1
            // A ratio wider than tall gives a landscape result, taller than wide a portrait one.
            let ratio = landscape ? max(a, 1 / a) : min(a, 1 / a)
            if w / h > ratio { region.size.width = (h * ratio).rounded() } else { region.size.height = (w / ratio).rounded() }
            target = (Int(region.width), Int(region.height))
        } else if let l = crop.longEdge {
            let scale = Double(l) / max(w, h)
            guard scale < 1 else { return nil }
            target = (max(1, Int((w * scale).rounded())), max(1, Int((h * scale).rounded())))
        } else if let cw = crop.width, let ch = crop.height {
            let ratio = Double(cw) / Double(ch)
            if w / h > ratio { region.size.width = (h * ratio).rounded() } else { region.size.height = (w / ratio).rounded() }
            let scale = min(1, Double(cw) / region.width)
            target = (max(1, Int((region.width * scale).rounded())), max(1, Int((region.height * scale).rounded())))
        } else if let cw = crop.width {
            guard Double(cw) < w else { return nil }
            target = (cw, max(1, Int((h * Double(cw) / w).rounded())))
        } else if let ch = crop.height {
            guard Double(ch) < h else { return nil }
            target = (max(1, Int((w * Double(ch) / h).rounded())), ch)
        } else { return nil }
        if target == size && region.size == CGSize(width: w, height: h) { return nil }
        return (region, target)
    }

    static func apply(_ crop: CropSpec, to image: CGImage) throws -> CGImage {
        guard let p = plan(crop, for: (image.width, image.height)) else { return image }
        var region = p.region
        if region.width < Double(image.width) || region.height < Double(image.height) {
            let centre = crop.smart ? (salientCentre(of: image) ?? CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2)) : CGPoint(x: Double(image.width) / 2, y: Double(image.height) / 2)
            region.origin.x = min(max(0, centre.x - region.width / 2), Double(image.width) - region.width)
            region.origin.y = min(max(0, centre.y - region.height / 2), Double(image.height) - region.height)
        }
        // CGImage crops in top-left coordinates.
        guard var cropped = image.cropping(to: region.integral) else { throw ShrinkError.failed(L("Cannot crop the image")) }
        if (cropped.width, cropped.height) != p.output { cropped = resize(cropped, to: p.output) ?? cropped }
        return cropped
    }

    /// Where the eye goes: the centre of the salient regions, in image pixels with the origin at the top left.
    static func salientCentre(of image: CGImage) -> CGPoint? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first, let objects = obs.salientObjects, !objects.isEmpty else { return nil }
        var union = objects[0].boundingBox
        for o in objects.dropFirst() { union = union.union(o.boundingBox) }
        // Vision boxes are normalised with the origin at the bottom left.
        return CGPoint(x: union.midX * Double(image.width), y: (1 - union.midY) * Double(image.height))
    }

    // MARK: Encode

    static func encode(_ image: CGImage, ext: String, level: Level, aggressive: Bool, properties: [CFString: Any], hasAlpha: Bool, to out: URL) async throws {
        let e = Media.canonical(ext)
        var props = properties
        let quality = aggressive ? max(0.2, level.imageQuality - 0.2) : level.imageQuality

        switch e {
        case "webp":
            let cwebp = try Tools.require(.cwebp, for: L("to write WebP images"))
            let png = Workspace.temp(ext: "png", name: "webp-source")
            try writeImageIO(image, type: "public.png", properties: props, quality: 1, to: png)
            var args = ["-quiet", "-metadata", properties.isEmpty ? "none" : "all", "-q", String(Int(quality * 100)), "-m", "6"]
            if level == .lossless { args = ["-quiet", "-lossless", "-z", "9", "-metadata", properties.isEmpty ? "none" : "all"] }
            args += [png.path, "-o", out.path]
            let r = try await Run.process(cwebp, args)
            try? FileManager.default.removeItem(at: png.deletingLastPathComponent())
            guard r.status == 0 else { throw ShrinkError.failed(r.error.isEmpty ? L("WebP encoding failed") : r.error) }
        case "avif" where destinationType(for: "avif") == nil:
            let heif = try Tools.require(.heifEnc, for: L("to write AVIF images"))
            let png = Workspace.temp(ext: "png", name: "avif-source")
            try writeImageIO(image, type: "public.png", properties: props, quality: 1, to: png)
            let r = try await Run.process(heif, ["--avif", "-q", String(Int(quality * 100)), "-o", out.path, png.path])
            try? FileManager.default.removeItem(at: png.deletingLastPathComponent())
            guard r.status == 0 else { throw ShrinkError.failed(r.error.isEmpty ? L("AVIF encoding failed") : r.error) }
        default:
            guard let type = destinationType(for: e) else { throw ShrinkError.unsupported(L("Shrinkbox cannot write %@ files", e.uppercased())) }
            if e == "jpeg" || e == "heic" || e == "heif" || e == "avif" || e == "jxl" { props[kCGImageDestinationLossyCompressionQuality] = quality }
            try writeImageIO(image, type: type, properties: props, quality: quality, to: out)
            if e == "png" {
                if Tool.pngquant.available { try await shrinkPNG(out, level: level, aggressive: aggressive) }
                else if level != .lossless, !hasAlpha, let q = Quantizer.quantize(image, colors: Quantizer.colors(for: level, aggressive: aggressive), dither: level.strength < 0.85) {
                    // Keep the palette version only when it is really smaller.
                    let tmp = Workspace.temp(ext: "png", name: "indexed")
                    try writeImageIO(q, type: type, properties: [:], quality: 1, to: tmp)
                    if Files.size(tmp) < Files.size(out) { try? FileManager.default.removeItem(at: out); try FileManager.default.moveItem(at: tmp, to: out) }
                    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
                } else { try await shrinkPNG(out, level: level, aggressive: aggressive) }
            }
            if e == "jpeg" { try await shrinkJPEG(out, level: level) }
        }
    }

    static func writeImageIO(_ image: CGImage, type: String, properties: [CFString: Any], quality: Double, to out: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else { throw ShrinkError.failed(L("Cannot write %@", out.lastPathComponent)) }
        var props = properties
        if type == "public.jpeg" || type == "public.heic" || type == "public.avif" { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ShrinkError.failed(L("Cannot write %@", out.lastPathComponent)) }
    }

    /// pngquant (lossy) or oxipng (lossless), when installed.
    static func shrinkPNG(_ url: URL, level: Level, aggressive: Bool) async throws {
        if level != .lossless, let q = Tool.pngquant.url {
            let minQ = max(0, 90 - Int(level.strength * 90)), maxQ = min(100, minQ + 25)
            let tmp = Workspace.temp(ext: "png", name: "quant")
            let r = try await Run.process(q, ["--quality=\(minQ)-\(maxQ)", "--speed", aggressive ? "1" : "3", "--strip", "--force", "--output", tmp.path, url.path])
            if r.status == 0, Files.size(tmp) > 0, Files.size(tmp) < Files.size(url) { try? FileManager.default.removeItem(at: url); try FileManager.default.moveItem(at: tmp, to: url) }
            try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
        } else if let o = Tool.oxipng.url {
            _ = try await Run.process(o, ["-o", aggressive ? "6" : "3", "--strip", "safe", "-q", url.path])
        }
    }

    static func shrinkJPEG(_ url: URL, level: Level) async throws {
        guard let j = Tool.jpegoptim.url else { return }
        _ = try await Run.process(j, ["--strip-all", "--all-progressive", "-q", url.path])
    }

    // MARK: GIF

    static func processGIF(_ src: URL, source: CGImageSource, job: ImageJob) async throws -> URL {
        let out = Workspace.temp(ext: "gif", name: src.deletingPathExtension().lastPathComponent)
        if let g = Tool.gifsicle.url {
            var args = ["-O3", "--no-comments", "--no-names", "--no-extensions"]
            if job.level != .lossless { args.append("--lossy=\(Int(job.level.strength * 120))") }
            if let f = job.downscale, f < 1 { args += ["--scale", String(f)] }
            args += [src.path, "-o", out.path]
            let r = try await Run.process(g, args)
            if r.status == 0, Files.size(out) > 0 { return out }
        }
        let count = CGImageSourceGetCount(source)
        // Strong compression drops every 4th, 3rd or 2nd frame.
        let strength = job.level.strength
        let skipEvery = job.gifDropFrames ? (strength > 0.9 ? 2 : strength > 0.85 ? 3 : strength > 0.8 ? 4 : 0) : 0
        var kept: [(CGImage, Double)] = []
        for i in 0..<count {
            if skipEvery > 0 && (i + 1) % skipEvery == 0 {
                if job.gifKeepDuration, !kept.isEmpty { kept[kept.count - 1].1 += Self.delay(source, i) }
                continue
            }
            guard let img = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            var frame = img
            if let c = job.crop { frame = (try? apply(c, to: frame)) ?? frame }
            if let f = job.downscale, f < 1 { frame = resize(frame, to: (max(1, Int(Double(frame.width) * f)), max(1, Int(Double(frame.height) * f)))) ?? frame }
            var d = Self.delay(source, i)
            if skipEvery > 0 && !job.gifKeepDuration { d = d * Double(skipEvery - 1) / Double(skipEvery) }
            kept.append((frame, d))
        }
        guard !kept.isEmpty, let dest = CGImageDestinationCreateWithURL(out as CFURL, "com.compuserve.gif" as CFString, kept.count, nil) else { throw ShrinkError.failed(L("Cannot write the GIF")) }
        CGImageDestinationSetProperties(dest, [kGIFFileProperties: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (img, d) in kept { CGImageDestinationAddImage(dest, img, [kGIFFileProperties2: [kCGImagePropertyGIFDelayTime: max(0.02, d)]] as CFDictionary) }
        guard CGImageDestinationFinalize(dest) else { throw ShrinkError.failed(L("Cannot write the GIF")) }
        return out
    }

    private static let kGIFFileProperties = kCGImagePropertyGIFDictionary
    private static let kGIFFileProperties2 = kCGImagePropertyGIFDictionary

    static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
    }

    // MARK: Metadata

    /// Removes EXIF, GPS, XMP and IPTC from a copy of the file without re-encoding the pixels.
    static func stripMetadata(_ src: URL, preserveColor: Bool = true) async throws -> URL {
        // exiftool removes every tag, the ones ImageIO leaves in some formats included.
        if let exif = Tool.exiftool.url {
            let out = Workspace.temp(ext: src.pathExtension, name: src.deletingPathExtension().lastPathComponent)
            try FileManager.default.copyItem(at: src, to: out)
            var args = ["-all=", "-overwrite_original", "-q"]
            if preserveColor { args += ["-tagsfromfile", "@", "-icc_profile"] }
            let r = try await Run.process(exif, args + [out.path])
            if r.status == 0 { return out }
        }
        return try stripWithImageIO(src, preserveColor: preserveColor)
    }

    static func stripWithImageIO(_ src: URL, preserveColor: Bool = true) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil), let type = CGImageSourceGetType(source) else { throw ShrinkError.failed(L("Cannot read %@", src.lastPathComponent)) }
        let out = Workspace.temp(ext: src.pathExtension, name: src.deletingPathExtension().lastPathComponent)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw ShrinkError.failed(L("Cannot write %@", out.lastPathComponent)) }
        let options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true, kCGImageMetadataShouldExcludeXMP: true, kCGImageDestinationMetadata: CGImageMetadataCreateMutable(), kCGImageDestinationMergeMetadata: false]
        var error: Unmanaged<CFError>?
        if !CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) {
            throw ShrinkError.failed((error?.takeRetainedValue() as Error?)?.localizedDescription ?? L("Cannot remove the metadata"))
        }
        return out
    }
}
