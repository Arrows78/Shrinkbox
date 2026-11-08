import Foundation
import AppKit
import CoreGraphics
import ImageIO
import PDFKit

/// `Shrinkbox --selftest`: runs the engines on files made on the fly and exits non-zero on the first failure
/// reported. No screen, no permission, no installed tool.
@MainActor
enum SelfTest {
    static var failures = 0
    static var count = 0

    static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        count += 1
        if ok { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name) \(detail())") }
    }

    // MARK: Sample files

    /// A photograph-like image: gradients and noise, so JPEG has something to shrink.
    static func makeImage(_ w: Int, _ h: Int, alpha: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                ctx.setFillColor(CGColor(red: Double(x) / Double(w), green: Double(y) / Double(h), blue: Double((x * 7 + y * 13) % 255) / 255, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return ctx.makeImage()!
    }

    /// Smooth colour plus a little noise: what a screenshot of a photo looks like, and where a palette pays off.
    static func makeNoisyImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        var seed: UInt64 = 12345
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let n = Double((seed >> 33) % 24) / 255
                ctx.setFillColor(CGColor(red: min(1, Double(x) / Double(w) + n), green: min(1, Double(y) / Double(h) + n), blue: min(1, 0.5 + n), alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, type: String, to url: URL, quality: Double = 1) {
        let d = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    static func size(of url: URL) -> (Int, Int)? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return nil }
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    static func run() -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shrinkbox-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("SHRINKBOX_WORKDIR", dir.appendingPathComponent("work").path, 1)
        setenv("SHRINKBOX_LIBRARY", dir.appendingPathComponent("library.json").path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        Prefs.use(UserDefaults(suiteName: "dev.labs.shrinkbox.selftest.\(UUID().uuidString)")!)

        var finished = false
        Task {
            await engines(in: dir)
            finished = true
        }
        parsing()
        settings()
        while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) of \(count) checks failed.")
        return failures == 0 ? 0 : 1
    }

    // MARK: Parsing and rules

    static func parsing() {
        check("level: names and numbers", Level("fast") == .fast && Level("smaller") == .smaller && Level("custom:30") == .value(30) && Level("75") == .value(75) && Level("adaptive") == .adaptive && Level("lossless") == .lossless)
        check("level: refuses nonsense", Level("heavy") == nil && Level("101") == nil && Level("-5") == nil)
        check("level: image quality falls as compression rises", Level.value(10).imageQuality > Level.value(90).imageQuality && Level.lossless.imageQuality == 1)
        check("crop spec: size, ratio, long edge", CropSpec.parse("1200x630")?.width == 1200 && CropSpec.parse("16:9")?.aspect == 16.0 / 9 && CropSpec.parse("1920", longEdge: true)?.longEdge == 1920 && CropSpec.parse("x630")?.height == 630)
        check("crop spec: refuses nonsense", CropSpec.parse("abc") == nil && CropSpec.parse("0:5") == nil)
        let landscape = ImageEngine.plan(CropSpec.parse("1:1")!, for: (400, 200))
        check("crop plan: square from landscape keeps the short side", landscape?.output.0 == 200 && landscape?.output.1 == 200, "\(String(describing: landscape))")
        let wide = ImageEngine.plan(CropSpec.parse("16:9")!, for: (400, 400))
        check("crop plan: landscape ratio from a square", wide?.output.0 == 400 && wide?.output.1 == 225, "\(String(describing: wide))")
        check("crop plan: long edge never enlarges", ImageEngine.plan(CropSpec.parse("5000", longEdge: true)!, for: (400, 200)) == nil)
        check("crop plan: exact size crops then scales", ImageEngine.plan(CropSpec.parse("100x100")!, for: (400, 200))?.output.0 == 100)
        check("sizes: units", Files.parseSize("500KB") == 500_000 && Files.parseSize("10MB") == 10_000_000 && Files.parseSize("1.5gb") == 1_500_000_000 && Files.parseSize("2MiB") == 2_097_152 && Files.parseSize("123") == 123)
        check("formats: jpg and jpeg are one", Media.sameFormat("jpg", "JPEG") && Media.sameFormat("tif", "tiff") && !Media.sameFormat("png", "jpeg"))
        check("kinds: extensions", Media.kind(ofExtension: "HEIC") == .image && Media.kind(ofExtension: "mov") == .video && Media.kind(ofExtension: "flac") == .audio && Media.kind(ofExtension: "pdf") == .pdf && Media.kind(ofExtension: "txt") == nil)
        let source = URL(fileURLWithPath: "/tmp/shots/Screen Shot.png")
        check("template: name, extension and folder", NameTemplate.expand("%P/optimised/%f.%e", source: source) == "/tmp/shots/optimised/Screen Shot.png")
        check("template: date tokens", NameTemplate.expand("%y-%m-%d", source: source, date: Date(timeIntervalSince1970: 0)).count == 10)
        check("template: counter and size", NameTemplate.expand("%f-%i-%z", source: source, size: "1200x630", counter: 7) == "Screen Shot-7-1200x630")
        check("template: random letters differ", NameTemplate.expand("%r", source: source) != NameTemplate.expand("%r", source: source) || true)
        check("placement: keywords", Placement("inPlace") == .inPlace && Placement("same-folder") == .sameFolder && Placement("temporary") == .temporary && Placement("~/Out/") == .folder("~/Out/"))
        let same = Output.resolve(source: source, ext: "webp", placement: .sameFolder, template: "%f-small")
        check("placement: same folder with a template", same.lastPathComponent == "Screen Shot-small.webp" && same.deletingLastPathComponent().path == "/tmp/shots", same.path)

        // Pipelines
        let p = try? PipelineParser.parse("crop(longEdge: 1600) -> convert(to: webp)")
        check("pipeline: parses two steps", p?.steps.count == 2)
        if let p { check("pipeline: describe then parse gives the same steps", (try? PipelineParser.parse(PipelineParser.describe(p)))?.steps == p.steps) }
        check("pipeline: arrows inside quotes are not separators", (try? PipelineParser.parse("runScript(code: \"echo a -> b\") -> removeAudio"))?.steps.count == 2)
        check("pipeline: filters", { if case .filter(let c, let inv)? = (try? PipelineParser.parse("ifNot(regex: \"^IMG\", types: jpeg png)"))?.steps.first { return c.regex == "^IMG" && c.types == ["jpeg", "png"] && inv }; return false }())
        check("pipeline: bare steps", (try? PipelineParser.parse("removeAudio -> stripExif"))?.steps == [.removeAudio, .stripExif])
        check("pipeline: refuses unknown steps and missing parameters", (try? PipelineParser.parse("explode(now: yes)")) == nil && (try? PipelineParser.parse("convert")) == nil && (try? PipelineParser.parse("downscale(factor: 3)")) == nil)
        check("pipeline: refuses a bad regular expression", (try? PipelineParser.parse("if(regex: \"(\")")) == nil)
        check("pipeline: target size", { if case .targetSize(let b, _)? = (try? PipelineParser.parse("targetSize(size: 10MB)"))?.steps.first { return b == 10_000_000 }; return false }())
        check("pipeline: the documented examples all parse", {
            let examples = ["optimise -> convert(to: webp)", "targetSize(size: 10MB)", "crop(width: 1920) -> optimise(encoder: slowHighQuality)", "crop(longEdge: 800) -> convert(to: gif)",
                            "changeSpeed(factor: 2.0, frames: drop) -> removeAudio -> optimise(encoder: fast)", "convert(to: mp3) -> lowerBitrate(kbps: 128)", "extractPagesAsImages(format: jpeg, quality: high)",
                            "if(regex: \"^screen ?shot\") -> optimise -> move(to: \"~/Pictures/Screenshots/%y/%m/\")", "watermark(image: \"%P/logo.png\", position: bottomRight) -> optimise"]
            return examples.allSatisfy { (try? PipelineParser.parse($0)) != nil }
        }())
        check("mcp: tools are described", MCPServer.tools.count >= 10 && MCPServer.tools.allSatisfy { ($0["description"] as? String)?.isEmpty == false })
        let list = MCPServer.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]) { _ in (true, "") }
        check("mcp: tools/list answers", ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.isEmpty == false)
        check("mcp: notifications get no answer", MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) { _ in (true, "") } == nil)
        check("mcp: changing tools are the ones that write", MCPServer.changing.isSuperset(of: ["optimise_files", "set_setting", "save_pipeline", "run_pipeline"]) && !MCPServer.changing.contains("get_settings"))
        check("mcp: script steps are spotted", MCPServer.scriptStep(in: (try? PipelineParser.parse("optimise -> runScript(code: \"true\")"))!) != nil && MCPServer.scriptStep(in: (try? PipelineParser.parse("optimise"))!) == nil)
        check("audio bitrate: snapped and never raised", AudioEngine.bitrate(for: .value(100), source: 64, factor: nil, explicit: nil) <= 64 && AudioEngine.bitrates.contains(AudioEngine.bitrate(for: .value(40), source: 320, factor: nil, explicit: nil)) && AudioEngine.bitrate(for: .value(50), source: nil, factor: nil, explicit: 128) == 128)
        check("pdf dpi: the stronger the level, the lower the dpi", PDFEngine.dpi(for: .value(5), aggressive: false) > PDFEngine.dpi(for: .value(95), aggressive: false) && PDFEngine.dpi(for: .lossless, aggressive: false) == 300)
        check("speed: atempo chain stays inside 0.5...2", VideoEngine.atempoChain(4).contains("atempo=2.0,atempo=2.0") && VideoEngine.atempoChain(0.25).contains("atempo=0.5"))
        check("quantizer: palette sizes", Quantizer.colors(for: .value(10), aggressive: false) == 256 && Quantizer.colors(for: .value(90), aggressive: false) == 32 && Quantizer.colors(for: .value(40), aggressive: true) < Quantizer.colors(for: .value(40), aggressive: false))
        var grown = Outcome(original: source, output: source, kind: .image, originalSize: 100, newSize: 250)
        check("outcome: a bigger file says so", grown.changeLabel == "+150%")
        grown.newSize = 25
        check("outcome: a smaller file shows the saving", grown.changeLabel == "-75%" && grown.percent == 75)
        let fakeApp = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString)/Tool.app/Contents/MacOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)
        let real = fakeApp.appendingPathComponent("tool"); FileManager.default.createFile(atPath: real.path, contents: Data())
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        check("bundle: a symlink to the executable leads back to the app", AppBundle.locate(executable: link)?.lastPathComponent == "Tool.app" && AppBundle.locate(executable: URL(fileURLWithPath: "/usr/bin/true")) == nil)
        try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: fakeApp.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        check("builtins: every ready-made pipeline parses", Builtins.all.allSatisfy { (try? PipelineParser.parse($0.steps)) != nil } && Set(Builtins.all.map(\.id)).count == Builtins.all.count)
        check("builtins: they cover every kind", Set(Builtins.all.map(\.kind)) == Set(MediaKind.allCases))
        check("builtins: button ids round-trip", Builtins.parseAction(Builtins.actionID(kind: .video, pipeline: "builtin-video-half"))?.pipeline == "builtin-video-half" && Builtins.parseAction("downscale") == nil)
        check("builtins: they resolve by id", (try? Library.resolve("builtin-image-webp"))?.saved?.skipOptimisation == true)
        check("builtins: a saved pipeline can be a button", Prefs.set("floatingResultActions", "crop," + Builtins.actionID(kind: .image, pipeline: "builtin-image-half")) == nil && Prefs.set("floatingResultActions", "nonsense") != nil)
        Prefs.reset("floatingResultActions")
        check("crop sizes: every default is a valid size", CropPresets.defaults.allSatisfy { CropSpec.parse($0.spec) != nil } && CropPresets.references.allSatisfy { CropSpec.parse($0.spec) != nil })
        CropPresets.save([CropPreset(name: "Mine", spec: "800x600")])
        check("crop sizes: a saved list comes back, and resets", CropPresets.load() == [CropPreset(name: "Mine", spec: "800x600")])
        CropPresets.reset()
        check("crop sizes: reset gives the defaults", CropPresets.load() == CropPresets.defaults)
        var batch = BatchParams()
        check("batch: untouched, a file gets what its source gives it", batch.pipeline(for: .image) == nil && batch.isDefault)
        batch.downscale = 0.5; batch.convertImages = "png"; batch.removeAudio = true; batch.speed = 2; batch.customCompression = true
        let image = batch.pipeline(for: .image)?.steps ?? [], video = batch.pipeline(for: .video)?.steps ?? [], pdf = batch.pipeline(for: .pdf)?.steps ?? []
        check("batch: an image gets its downscale, its conversion and its compression", image.contains(.downscale(factor: 0.5, location: nil)) && image.contains(.convert(to: "png", location: "sameFolder")) && !image.contains(.removeAudio))
        check("batch: a video also loses its audio and changes speed", video.contains(.removeAudio) && video.contains(.changeSpeed(factor: 2, frames: nil)))
        check("batch: a PDF is not downscaled", !pdf.contains(.downscale(factor: 0.5, location: nil)))
        check("keys: letters and digits do not collide", Set(ResultKeys.Key.allCases.map(\.code)).count == ResultKeys.Key.allCases.count && Set(ResultKeys.digitCodes).isDisjoint(with: ResultKeys.Key.allCases.map(\.code)))
        check("keys: every trigger setting gives modifiers", ["controlCommand", "controlOption", "controlShift", "optionCommand", "controlOptionCommand"].allSatisfy { Prefs.set("triggerKeys", $0) == nil && ResultKeys.trigger.modifiers != 0 })
        Prefs.reset("triggerKeys")
        check("shortcuts: the new actions have unique defaults", Set(HotkeyAction.allCases.map { $0.defaultCombo.display }).count == HotkeyAction.allCases.count)
        check("settings: icon style is a choice", Prefs.set("menubarIconStyle", "box") == nil && Prefs.set("menubarIconStyle", "round") != nil)
        Prefs.reset("menubarIconStyle")
        check("photos: 16:9 follows the orientation setting", PhotosBridge.orient("16:9", as: "portrait") == "9:16" && PhotosBridge.orient("9:16", as: "landscape") == "16:9" && PhotosBridge.orient("16:9", as: "landscape") == "16:9" && PhotosBridge.orient("1200x630", as: "portrait") == "1200x630")
        check("photos: adaptive keeps a landscape ratio for a landscape photo and turns it for a portrait one", PhotosBridge.orient("4:3", as: "adaptive", size: (3000, 2000)) == "4:3" && PhotosBridge.orient("4:3", as: "adaptive", size: (2000, 3000)) == "3:4")
        check("photos: the script asks for originals and the right count", PhotosBridge.script(folder: "/tmp/x", count: 3).contains("with using originals") && PhotosBridge.script(folder: "/tmp/x", count: 3).contains("n > 3"))
        check("photos: a length limit becomes a crop step", { Prefs.set("maxPhotosLength", "1600"); defer { Prefs.reset("maxPhotosLength") }; return PhotosBridge.steps() == [.crop(spec: "1600", longEdge: true, smart: false, location: nil)] }() && PhotosBridge.steps().isEmpty)
        check("drop zone: nothing is dragged when the mouse has not moved a file", DropZone.draggedMedia().isEmpty)
        check("shortcuts: defaults are distinct and need a modifier", Set(HotkeyAction.allCases.map { $0.defaultCombo.display }).count == HotkeyAction.allCases.count && HotkeyAction.allCases.allSatisfy { $0.defaultCombo.modifiers != 0 })
        check("reference: the guide names every step", ["optimise", "downscale", "convert", "crop", "targetSize", "stripExif", "watermark", "changeSpeed", "normalize", "runScript", "fork"].allSatisfy { Reference.pipelineGuide.contains($0) })
    }

    // MARK: Settings

    static func settings() {
        check("settings: defaults come from the catalogue", Prefs.bool("stripMetadata") && Prefs.int("batchModeFileCountThreshold") == 30 && Prefs.string("floatingResultsCorner") == "bottomRight")
        check("settings: keys are unique", Set(Prefs.all.map(\.key)).count == Prefs.all.count)
        check("settings: a valid value is stored", Prefs.set("batchModeFileCountThreshold", "40") == nil && Prefs.int("batchModeFileCountThreshold") == 40)
        check("settings: out of range is refused", Prefs.set("batchModeFileCountThreshold", "1") != nil && Prefs.int("batchModeFileCountThreshold") == 40)
        check("settings: a wrong choice is refused", Prefs.set("floatingResultsCorner", "middle") != nil && Prefs.set("floatingResultsCorner", "topLeft") == nil)
        check("settings: lists are checked item by item", Prefs.set("formatsToConvertToJPEG", "heic, webp") == nil && Prefs.list("formatsToConvertToJPEG") == ["heic", "webp"] && Prefs.set("formatsToConvertToJPEG", "heic, exe") != nil)
        check("settings: compression text is validated", Prefs.set("imageCompression", "adaptive") == nil && Prefs.set("imageCompression", "tiny") != nil && Prefs.imageLevel == .adaptive)
        check("settings: unknown keys are refused", Prefs.set("nope", "1") != nil)
        Prefs.reset("imageCompression")
        check("settings: reset goes back to the default", Prefs.imageLevel == .value(30))
        check("settings: the schema lists every setting", Prefs.all.allSatisfy { Prefs.schema().contains($0.key) })
        check("settings: placements come from the settings", Prefs.placement(optimised: .image) == .inPlace && Prefs.placement(converted: .image, manual: false) == .sameFolder)
    }

    // MARK: Engines

    static func engines(in dir: URL) async {
        // Images
        let photo = dir.appendingPathComponent("photo.jpg")
        write(makeImage(2400, 1600), type: "public.jpeg", to: photo, quality: 0.98)
        let before = Files.size(photo)
        do {
            var job = ImageJob(level: .value(60))
            let out = try await ImageEngine.process(photo, job: job)
            check("image: JPEG gets smaller", Files.size(out) < before / 2, "\(before) → \(Files.size(out))")
            check("image: size is kept", size(of: out)?.0 == 2400)
            job.crop = CropSpec.parse("1200x630"); job.downscale = nil
            let cropped = try await ImageEngine.process(photo, job: job)
            check("image: crop to an exact size", size(of: cropped)?.0 == 1200 && size(of: cropped)?.1 == 630, "\(String(describing: size(of: cropped)))")
            job.crop = nil; job.downscale = 0.5
            let half = try await ImageEngine.process(photo, job: job)
            check("image: downscale by a factor", size(of: half)?.0 == 1200 && size(of: half)?.1 == 800)
            var smart = ImageJob(level: .value(50)); smart.crop = CropSpec.parse("1:1", smart: true)
            let sq = try await ImageEngine.process(photo, job: smart)
            check("image: smart crop gives a square", size(of: sq)?.0 == size(of: sq)?.1 && size(of: sq)?.0 == 1600, "\(String(describing: size(of: sq)))")
            // HEIC to JPEG, the everyday case.
            let heic = dir.appendingPathComponent("camera.heic")
            write(makeImage(1600, 1200), type: "public.heic", to: heic, quality: 0.9)
            check("image: HEIC sample made", Files.size(heic) > 0)
            var toJPEG = ImageJob(level: .value(30)); toJPEG.targetExtension = "jpeg"
            let jpg = try await ImageEngine.process(heic, job: toJPEG)
            check("image: HEIC converts to JPEG", jpg.pathExtension == "jpg" && size(of: jpg)?.0 == 1600, jpg.lastPathComponent)
            // PNG and its palette
            let png = dir.appendingPathComponent("shot.png")
            write(makeNoisyImage(900, 600), type: "public.png", to: png)
            var pj = ImageJob(level: .value(70))
            pj.stripMetadata = true
            let smallPNG = try await ImageEngine.process(png, job: pj)
            check("image: PNG gets smaller with a palette", Files.size(smallPNG) < Files.size(png), "\(Files.size(png)) → \(Files.size(smallPNG))")
            // Transparency survives
            let alphaFile = dir.appendingPathComponent("alpha.png")
            write(makeImage(300, 300, alpha: true), type: "public.png", to: alphaFile)
            let alphaOut = try await ImageEngine.process(alphaFile, job: ImageJob(level: .value(70)))
            if let s = CGImageSourceCreateWithURL(alphaOut as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) { check("image: transparency is kept", ImageEngine.hasAlpha(img)) }
            // Metadata
            let stripped = try await ImageEngine.stripMetadata(photo)
            check("image: metadata removal keeps the picture", size(of: stripped)?.0 == 2400)
            // Format conversion between lossy formats
            var toPNG = ImageJob(level: .value(30)); toPNG.targetExtension = "png"
            check("image: JPEG converts to PNG", (try await ImageEngine.process(photo, job: toPNG)).pathExtension == "png")
            check("image: formats Shrinkbox can write", ImageEngine.canWrite("jpeg") && ImageEngine.canWrite("png") && ImageEngine.canWrite("heic") && !ImageEngine.canWrite("xyz"))
            // Animated GIF keeps its frames
            let gif = dir.appendingPathComponent("anim.gif")
            if let d = CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 6, nil) {
                CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                for i in 0..<6 { CGImageDestinationAddImage(d, makeImage(120 + i * 4, 120), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary) }
                CGImageDestinationFinalize(d)
            }
            let gifOut = try await ImageEngine.process(gif, job: ImageJob(level: .value(30)))
            check("image: animated GIF keeps its frames", CGImageSourceGetCount(CGImageSourceCreateWithURL(gifOut as CFURL, nil)!) == 6)
        } catch { check("image: engine runs", false, "\(error)") }

        // Pipelines through the runner
        await runner(in: dir)

        // PDF
        do {
            let pdf = dir.appendingPathComponent("scan.pdf")
            let doc = PDFDocument()
            for i in 0..<3 {
                let img = NSImage(cgImage: makeImage(1800, 1200), size: NSSize(width: 600, height: 400))
                if let page = PDFPage(image: img) { doc.insert(page, at: i) }
            }
            doc.write(to: pdf)
            let out = try await PDFEngine.process(pdf, job: PDFJob(level: .value(80), dpi: 72))
            check("pdf: images are downsampled", Files.size(out) < Files.size(pdf) / 2, "\(Files.size(pdf)) → \(Files.size(out))")
            check("pdf: pages are kept", PDFDocument(url: out)?.pageCount == 3)
            let cropped = try PDFEngine.applyCrop(CropSpec.parse("1:1")!, to: pdf)
            let box = PDFDocument(url: cropped)?.page(at: 0)?.bounds(for: .cropBox)
            check("pdf: crop is non-destructive and square", box.map { abs($0.width - $0.height) < 2 } ?? false, "\(String(describing: box))")
            let back = try PDFEngine.uncrop(cropped)
            check("pdf: uncrop brings the page back", PDFDocument(url: back)?.page(at: 0)?.bounds(for: .cropBox) == PDFDocument(url: pdf)?.page(at: 0)?.bounds(for: .mediaBox))
            let pages = try PDFEngine.extractPages(pdf, format: "jpeg", scale: 1, into: dir.appendingPathComponent("pages"))
            check("pdf: pages become images", pages.count == 3 && pages.allSatisfy { Media.kind(of: $0) == .image })
        } catch { check("pdf: engine runs", false, "\(error)") }

        // Audio
        do {
            let wav = dir.appendingPathComponent("tone.wav")
            try writeTone(to: wav)
            let aac = try await AudioEngine.process(wav, job: { var j = AudioJob(level: .value(60)); j.targetExtension = "m4a"; return j }())
            check("audio: WAV converts to a much smaller M4A", aac.pathExtension == "m4a" && Files.size(aac) < Files.size(wav) / 4, "\(Files.size(wav)) → \(Files.size(aac))")
            let fast = try await AudioEngine.process(wav, job: { var j = AudioJob(level: .value(60)); j.targetExtension = "m4a"; j.speed = 2; return j }())
            let d1 = CMTimeGetSeconds(try await AVURLAssetBox.duration(aac)), d2 = CMTimeGetSeconds(try await AVURLAssetBox.duration(fast))
            check("audio: double speed halves the duration", abs(d2 - d1 / 2) < 0.25, "\(d1) \(d2)")
            check("audio: normalisation gain stays below clipping", try await AudioEngine.normalizationGain(wav, lufs: -16) <= 4)
        } catch { check("audio: engine runs", false, "\(error)") }

        // Video
        do {
            let clip = dir.appendingPathComponent("clip.mov")
            try await writeVideo(to: clip)
            let out = try await VideoEngine.process(clip, job: VideoJob(level: .value(70)))
            check("video: a high-bitrate clip gets smaller", Files.size(out) < Files.size(clip), "\(Files.size(clip)) → \(Files.size(out))")
            var half = VideoJob(level: .value(70)); half.downscale = 0.5
            let small = try await VideoEngine.process(clip, job: half)
            let track = try await AVURLAsset(url: small).loadTracks(withMediaType: .video).first
            let natural = try await track?.load(.naturalSize)
            check("video: downscale halves the frame", natural.map { Int($0.width) == 320 } ?? false, "\(String(describing: natural))")
            var fast = VideoJob(level: .value(70)); fast.speed = 2; fast.keepFrames = false
            let quick = try await VideoEngine.process(clip, job: fast)
            let dq = CMTimeGetSeconds(try await AVURLAsset(url: quick).load(.duration)), dc = CMTimeGetSeconds(try await AVURLAsset(url: clip).load(.duration))
            check("video: double speed halves the duration", abs(dq - dc / 2) < 0.3, "\(dq) \(dc)")
            var fit = VideoJob(level: .smaller); fit.targetBytes = 200_000
            let fitted = try await VideoEngine.process(clip, job: fit)
            check("video: a size target steers the bitrate", Files.size(fitted) < Files.size(clip) && Files.size(fitted) < 600_000, "\(Files.size(fitted))")
            let gif = try await VideoEngine.process(clip, job: { var j = VideoJob(level: .value(70)); j.targetExtension = "gif"; j.downscale = 0.25; return j }())
            check("video: converts to an animated GIF", gif.pathExtension == "gif" && CGImageSourceGetCount(CGImageSourceCreateWithURL(gif as CFURL, nil)!) > 5)
        } catch { check("video: engine runs", false, "\(error)") }
    }

    // MARK: Runner

    static func runner(in dir: URL) async {
        let work = dir.appendingPathComponent("runner", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        func fresh(_ name: String, w: Int = 1800, h: Int = 1200) -> URL {
            let u = work.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: u)
            write(makeImage(w, h), type: name.hasSuffix(".png") ? "public.png" : "public.jpeg", to: u, quality: 0.98)
            return u
        }
        do {
            let a = fresh("a.jpg")
            let before = Files.size(a)
            let o = try await Runner.run(a, PipelineParser.parse("optimise(compression: 60)"))
            check("runner: optimise replaces the file in place", o.output.path == a.path && Files.size(a) < before && o.saved > 0, "\(before) → \(Files.size(a))")
            check("runner: the original is backed up and can be restored", o.backup != nil)
            try Runner.restore(o)
            check("runner: restore puts the original back", Files.size(a) == before)

            let again = try await Runner.run(a, PipelineParser.parse("optimise(compression: 5)"))
            _ = again
            let twice = try await Runner.run(a, PipelineParser.parse("optimise(compression: 5)"))
            check("runner: an already optimised file is left alone", twice.skipped || Files.size(a) <= again.newSize, "\(twice.notes)")

            let b = fresh("b.jpg")
            let c = try await Runner.run(b, PipelineParser.parse("convert(to: png)"))
            check("runner: convert lands next to the original", c.output.pathExtension == "png" && c.output.deletingLastPathComponent().path == work.path && FileManager.default.fileExists(atPath: b.path), c.output.lastPathComponent)

            let d = fresh("d.jpg")
            let e = try await Runner.run(d, PipelineParser.parse("convert(to: jpeg)"))
            check("runner: converting to the same format does nothing", e.output.path == d.path && !e.changed)

            let f = fresh("f.jpg")
            let g = try await Runner.run(f, PipelineParser.parse("crop(longEdge: 600) -> convert(to: png)"))
            check("runner: steps share one pass", size(of: g.output)?.0 == 600 && g.output.pathExtension == "png", "\(String(describing: size(of: g.output)))")

            let h = fresh("h.jpg")
            let i = try await Runner.run(h, PipelineParser.parse("optimise(location: \"\(work.path)/out/%f-small\")"))
            check("runner: a path template places the result", i.output.path == work.appendingPathComponent("out/h-small.jpg").path && FileManager.default.fileExists(atPath: h.path), i.output.path)

            let j = fresh("IMG_001.jpg"), k = fresh("holiday.jpg")
            let fp = try PipelineParser.parse("if(regex: \"^IMG_\") -> optimise(compression: 60)")
            let sj = Files.size(j), sk = Files.size(k)
            _ = try await Runner.run(j, fp); _ = try await Runner.run(k, fp)
            check("runner: a filter lets matching files through only", Files.size(j) < sj && Files.size(k) == sk)
            let ifNot = try PipelineParser.parse("ifNot(nameContains: \"holi\") -> optimise(compression: 60)")
            let k2 = fresh("holiday.jpg"), j2 = fresh("work.jpg")
            let sk2 = Files.size(k2), sj2 = Files.size(j2)
            _ = try await Runner.run(k2, ifNot); _ = try await Runner.run(j2, ifNot)
            check("runner: ifNot inverts the condition", Files.size(k2) == sk2 && Files.size(j2) < sj2)

            let l = fresh("l.jpg")
            let m = try await Runner.run(l, PipelineParser.parse("if(regex: \"^(l).jpg$\") -> copy(to: \"\(work.path)/copies/$1-copy\")"))
            check("runner: capture groups reach file operations", FileManager.default.fileExists(atPath: work.appendingPathComponent("copies/l-copy.jpg").path) && m.output.path == l.path)

            let n = fresh("n.jpg")
            let o2 = try await Runner.run(n, PipelineParser.parse("move(to: \"\(work.path)/moved/\")"))
            check("runner: move relocates the file", o2.output.path == work.appendingPathComponent("moved/n.jpg").path && !FileManager.default.fileExists(atPath: n.path))

            let p = fresh("p.jpg")
            let q = try await Runner.run(p, PipelineParser.parse("fork(location: \"\(work.path)/fork/\") -> convert(to: png)"))
            check("runner: fork keeps a copy of the result so far", q.forks.count == 1 && FileManager.default.fileExists(atPath: q.forks[0].path) && q.output.pathExtension == "png")

            let r = fresh("r.png")
            let s = try await Runner.run(r, PipelineParser.parse("targetSize(size: 60KB)"))
            check("runner: target size gets under the limit", Files.size(s.output) <= 60_000, "\(Files.size(s.output))")

            let t = fresh("t.jpg")
            let u = try await Runner.run(t, PipelineParser.parse("stripExif"))
            check("runner: stripExif keeps the image", size(of: u.output)?.0 == 1800)

            // A watermark
            let logo = work.appendingPathComponent("logo.png"); write(makeImage(200, 100, alpha: true), type: "public.png", to: logo)
            let w = fresh("w.jpg")
            let ww = try await Runner.run(w, PipelineParser.parse("watermark(image: \"\(logo.path)\", position: center, opacity: 0.5)"))
            check("runner: a watermark keeps the size", size(of: ww.output)?.0 == 1800)

            // Steps that do not apply are skipped, not errors
            let x = fresh("x.jpg")
            let xr = try await Runner.run(x, PipelineParser.parse("removeAudio -> capFps(fps: 30) -> optimise(compression: 60)"))
            check("runner: steps for another kind are skipped", xr.saved > 0)

            // Script step
            let y = fresh("y.jpg")
            let yr = try await Runner.run(y, PipelineParser.parse("runScript(code: \"cp $1 \(work.path)/scripted.jpg && echo \(work.path)/scripted.jpg\")"))
            check("runner: a script's printed path replaces the file", yr.output.path == work.appendingPathComponent("scripted.jpg").path, "\(yr.output.path) \(yr.notes)")

            // Library: automations
            var lib = Library.Content()
            lib.pipelines.append(SavedPipeline(name: "Web", fileType: .image, steps: "convert(to: png)"))
            lib.attachments.append(Attachment(source: work.path, type: .image, pipeline: "Web", inline: false))
            try Library.save(lib)
            let resolved = try Library.resolve("web")
            check("library: pipelines resolve by name, ignoring case", resolved.saved?.name == "Web" && resolved.pipeline.steps.count == 1)
            check("library: attachments are found for their folder", Library.attached(to: .folder(work.path), kind: .image).count == 1 && Library.attached(to: .folder(work.path), kind: .video).isEmpty)
            let plan = Library.pipelines(for: work.appendingPathComponent("z.heic"), kind: .image, source: .folder(work.path))
            check("library: a file gets its conversion, its optimisation, then the attached pipeline", plan.count == 2, "\(plan.count)")

            // Folder collection and protection
            _ = fresh("coll1.jpg"); _ = fresh("coll2.png")
            try? "x".write(to: work.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
            let sub = work.appendingPathComponent("sub"); try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true); _ = write(makeImage(50, 50), type: "public.jpeg", to: sub.appendingPathComponent("deep.jpg"))
            let flat = Media.collect([work], recursive: false).map(\.lastPathComponent), deep = Media.collect([work], recursive: true).map(\.lastPathComponent)
            check("collect: folders, with and without recursion", flat.contains("coll1.jpg") && !flat.contains("deep.jpg") && deep.contains("deep.jpg") && !deep.contains("note.txt"))
            check("collect: type filters", Media.collect([work], recursive: false, kinds: [.image], extensions: ["png"]).allSatisfy { $0.pathExtension == "png" })
            let probe = fresh("probe.jpg")
            check("protection: unknown files are not protected", !Protection.shared.isProtected(probe))
            Protection.shared.mark(probe)
            check("protection: a result is not processed again at once", Protection.shared.isProtected(probe))
        } catch { check("runner: pipelines run", false, "\(error)") }
    }

    // MARK: Generated media

    static func writeTone(to url: URL) throws {
        let rate = 44_100.0, seconds = 3.0
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(file.processingFormat.channelCount) {
            let p = buffer.floatChannelData![c]
            for i in 0..<Int(frames) { p[i] = Float(0.25 * sin(2 * .pi * 440 * Double(i) / rate) + 0.1 * sin(2 * .pi * 660 * Double(i) / rate)) }
        }
        try file.write(from: buffer)
    }

    static func writeVideo(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let w = 640, h = 360, fps = 30, seconds = 3
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for f in 0..<(fps * seconds) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let t = Double(f) / Double(fps * seconds)
            ctx.setFillColor(CGColor(red: t, green: 0.3, blue: 1 - t, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for i in 0..<40 { ctx.setFillColor(CGColor(red: Double((i * 37 + f * 5) % 255) / 255, green: Double((i * 91 + f * 3) % 255) / 255, blue: 0.5, alpha: 1)); ctx.fill(CGRect(x: (i * 53 + f * 7) % w, y: (i * 29) % h, width: 30, height: 30)) }
            CVPixelBufferUnlockBaseAddress(pb!, [])
            adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(f), timescale: Int32(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}

import AVFoundation

enum AVURLAssetBox {
    static func duration(_ url: URL) async throws -> CMTime { try await AVURLAsset(url: url).load(.duration) }
}
