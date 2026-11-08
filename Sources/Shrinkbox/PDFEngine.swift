import Foundation
import PDFKit
import CoreGraphics
import Quartz

struct PDFJob: Sendable {
    var level: Level = .value(50)
    var dpi: Int?                 // nil: picked from the level
    var aggressive = false
    var crop: CropSpec?
}

enum PDFEngine {
    static let dpiChoices = [300, 250, 200, 150, 100, 72, 48]

    /// 300 dpi leaves images alone, 48 is the smallest.
    static func dpi(for level: Level, aggressive: Bool) -> Int {
        if aggressive { return 100 }
        switch level {
        case .lossless: return 300
        case .adaptive: return 150
        case .value(let n):
            let index = min(dpiChoices.count - 1, max(0, Int((Double(n) / 100 * Double(dpiChoices.count)).rounded(.down))))
            return dpiChoices[index]
        }
    }

    // MARK: Optimise

    static func process(_ src: URL, job: PDFJob) async throws -> URL {
        let out = Workspace.temp(ext: "pdf", name: src.deletingPathExtension().lastPathComponent)
        let dpi = job.dpi ?? Self.dpi(for: job.level, aggressive: job.aggressive)
        var input = src
        if let crop = job.crop {
            input = try applyCrop(crop, to: src)   // a real crop box, then compressed
        }
        defer { if input != src { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) } }
        if let gs = Tool.gs.url {
            let quality = max(20, 90 - Int(job.level.strength * 60))
            let args = ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6", "-dDownsampleColorImages=true", "-dColorImageResolution=\(dpi)",
                        "-dDownsampleGrayImages=true", "-dGrayImageResolution=\(dpi)", "-dDownsampleMonoImages=true", "-dMonoImageResolution=\(max(dpi, 150))",
                        "-dJPEGQ=\(quality)", "-dDetectDuplicateImages=true", "-dCompressFonts=true", "-sOutputFile=\(out.path)", input.path]
            let r = try await Run.process(gs, args)
            if r.status == 0, Files.size(out) > 0 { return out }
        }
        try filtered(input, dpi: dpi, quality: max(0.2, 1 - 0.7 * job.level.strength), to: out)
        return out
    }

    /// Re-draws every page through a Quartz filter that downsamples and recompresses images; text stays vector.
    static func filtered(_ src: URL, dpi: Int, quality: Double, to out: URL) throws {
        guard let doc = CGPDFDocument(src as CFURL) else { throw ShrinkError.failed(L("Cannot read %@", src.lastPathComponent)) }
        if doc.isEncrypted && !doc.unlockWithPassword("") { throw ShrinkError.unsupported(L("The PDF is password protected")) }
        let filterURL = try writeFilter(dpi: dpi, quality: quality)
        defer { try? FileManager.default.removeItem(at: filterURL) }
        guard let filter = QuartzFilter(url: filterURL) else { throw ShrinkError.failed(L("Cannot load the compression filter")) }
        var first = doc.page(at: 1)?.getBoxRect(.mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(out as CFURL, mediaBox: &first, [kCGPDFContextCreator: "Shrinkbox"] as CFDictionary) else { throw ShrinkError.failed(L("Cannot write %@", out.lastPathComponent)) }
        filter.apply(to: ctx)
        for i in 1...max(1, doc.numberOfPages) {
            guard let page = doc.page(at: i) else { continue }
            var box = page.getBoxRect(.mediaBox)
            let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.drawPDFPage(page)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// A Quartz filter with the same layout as the one macOS ships for "Reduce File Size": images are scaled to `dpi`
    /// and recompressed as JPEG.
    private static func writeFilter(dpi: Int, quality: Double) throws -> URL {
        let plist: [String: Any] = [
            "Name": "Shrinkbox",
            "FilterType": 1,
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": quality,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true, "ImageSizeMax": dpi * 10, "ImageSizeMin": 0] as [String: Any],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
        let url = Workspace.temp(ext: "qfilter", name: "shrinkbox")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return url
    }

    // MARK: Crop

    /// A non-destructive crop: the crop box of each page is set, the content stays in the file.
    static func applyCrop(_ crop: CropSpec, to src: URL) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw ShrinkError.failed(L("Cannot read %@", src.lastPathComponent)) }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let media = page.bounds(for: .mediaBox)
            let size = (Int(media.width), Int(media.height))
            guard let p = ImageEngine.plan(crop, for: size) else { continue }
            var r = p.region
            // PDF coordinates have the origin at the bottom left; centre the box.
            r.origin.x = media.minX + (media.width - r.width) / 2
            r.origin.y = media.minY + (media.height - r.height) / 2
            page.setBounds(r, for: .cropBox)
        }
        let out = Workspace.temp(ext: "pdf", name: src.deletingPathExtension().lastPathComponent)
        guard doc.write(to: out) else { throw ShrinkError.failed(L("Cannot write %@", out.lastPathComponent)) }
        return out
    }

    /// Brings back the original page size.
    static func uncrop(_ src: URL) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw ShrinkError.failed(L("Cannot read %@", src.lastPathComponent)) }
        for i in 0..<doc.pageCount { if let p = doc.page(at: i) { p.setBounds(p.bounds(for: .mediaBox), for: .cropBox) } }
        let out = Workspace.temp(ext: "pdf", name: src.deletingPathExtension().lastPathComponent)
        guard doc.write(to: out) else { throw ShrinkError.failed(L("Cannot write %@", out.lastPathComponent)) }
        return out
    }

    // MARK: Pages as images

    /// Renders each page to JPEG or PNG into a new folder next to the result.
    static func extractPages(_ src: URL, format: String, scale: Double, into folder: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: src) else { throw ShrinkError.failed(L("Cannot read %@", src.lastPathComponent)) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var out: [URL] = []
        let ext = format.lowercased() == "png" ? "png" : "jpg"
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let size = CGSize(width: box.width * scale, height: box.height * scale)
            let image = page.thumbnail(of: size, for: .cropBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let url = folder.appendingPathComponent(String(format: "%@ page %03d.%@", src.deletingPathExtension().lastPathComponent, i + 1, ext))
            try ImageEngine.writeImageIO(cg, type: ext == "png" ? "public.png" : "public.jpeg", properties: [:], quality: 0.85, to: url)
            out.append(url)
        }
        return out
    }
}
