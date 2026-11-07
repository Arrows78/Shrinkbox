import Foundation
import AppKit
import ImageIO
import PDFKit
import AVFoundation

enum PipelineSource: Equatable, Sendable {
    case manual, cli, dropZone, clipboard, folder(String)
}

struct RunContext: Sendable {
    var source: PipelineSource = .manual
    var copiedBy: String?
    var progress: (@Sendable (Double) -> Void)?
    var counter = 1
    /// Set by the clipboard watcher: the result is placed, not written over anything.
    var forceTemporary = false
}

struct Outcome: Sendable {
    var original: URL
    var output: URL
    var forks: [URL] = []
    var kind: MediaKind
    var originalSize: Int64
    var newSize: Int64
    var notes: [String] = []
    var skipped = false              // stopped by a filter, or already as small as it can be
    var backup: URL?                 // the original, kept to restore it
    var changed: Bool { output.path != original.path || newSize != originalSize }
    var saved: Int64 { max(0, originalSize - newSize) }
    var percent: Int { originalSize > 0 ? Int((Double(saved) / Double(originalSize) * 100).rounded()) : 0 }
}

/// Everything the consecutive content steps ask for, merged so the file is encoded once.
private struct Pass {
    var level: Level?
    var adaptive: Bool?
    var encoder: String?
    var dpi: Int?
    var downscale: Double?
    var crop: CropSpec?
    var targetExtension: String?
    var removeAudio = false
    var speed: Double?
    var frames: String?
    var capFPS: Double?
    var kbps: Int?
    var aggressive = false
    var placement: Placement = .inPlace
    var placementSet = false
    var template: String?
    var isConversion = false
    var count = 0
    var changesContent: Bool { downscale != nil || crop != nil || targetExtension != nil || removeAudio || speed != nil || capFPS != nil || kbps != nil }
}

enum Runner {
    // MARK: Entry

    static func run(_ file: URL, _ pipeline: Pipeline, context: RunContext = RunContext()) async throws -> Outcome {
        guard let kind = Media.kind(of: file) else { throw ShrinkError.unsupported(L("%@ is not a supported file", file.lastPathComponent)) }
        guard FileManager.default.fileExists(atPath: file.path) else { throw ShrinkError.failed(L("%@ does not exist", file.lastPathComponent)) }
        var out = Outcome(original: file, output: file, kind: kind, originalSize: Files.size(file), newSize: Files.size(file))
        var current = file
        var pass = Pass()
        var groups: [String] = []          // capture groups of the last regex filter
        let keepDates = Prefs.bool("preserveDates")
        var stepIndex = 0
        let steps = pipeline.steps

        func flush(nextIsHard: Bool = false) async throws {
            guard pass.count > 0 else { return }
            defer { pass = Pass() }
            let before = Files.size(current)
            let produced = try await execute(pass, on: current, kind: kind, context: context)
            // Never keep a result that is not smaller when nothing about the content was asked to change.
            if !pass.changesContent, Files.size(produced) >= before, pass.placement == .inPlace {
                try? FileManager.default.removeItem(at: produced.deletingLastPathComponent())
                out.notes.append(L("Already optimised"))
                out.skipped = (current.path == file.path)
                return
            }
            let ext = produced.pathExtension
            var placement = pass.placement
            if context.forceTemporary { placement = .temporary }
            let sizeLabel = pass.crop?.label ?? ""
            let scaleLabel = pass.downscale.map { String(format: "%g", $0) } ?? ""
            let template = pass.template ?? Prefs.nameTemplate(kind, converted: pass.isConversion)
            let destination = Output.resolve(source: current, ext: ext, placement: placement, template: template, size: sizeLabel, scale: scaleLabel, counter: context.counter)
            if placement == .inPlace, out.backup == nil, current.path == file.path { out.backup = try? backup(of: file) }
            current = try Output.commit(produced: produced, source: current, destination: destination, placement: placement, keepDates: keepDates)
            try? FileManager.default.removeItem(at: produced.deletingLastPathComponent())
        }

        for step in steps {
            stepIndex += 1
            try Task.checkCancellation()
            if step.isProcessing, applies(step, to: kind) {
                let explicit = locationOf(step).map { placementFrom($0, kind: kind, converted: isConvert(step)) }
                var isEnd = false
                switch step {
                case .optimise(let enc, let comp, let adaptive, let dpi, _):
                    if let comp { guard let l = Level(comp) else { throw PipelineError(L("Invalid compression “%@”", comp)) }; pass.level = l }
                    pass.adaptive = adaptive ?? pass.adaptive; pass.encoder = enc ?? pass.encoder; pass.dpi = dpi ?? pass.dpi
                    if enc == "aggressive" { pass.aggressive = true; if comp == nil { pass.level = .smaller } }
                    if enc == "lossless" { pass.level = .lossless }
                case .downscale(let f, _): pass.downscale = (pass.downscale ?? 1) * f
                case .lowerBitrate(let k, _): pass.kbps = k
                case .convert(let to, _):
                    if Media.sameFormat(to, current.pathExtension), pass.count == 0 { continue }   // already that format
                    pass.targetExtension = to; pass.isConversion = true
                case .crop(let spec, let long, let smart, _):
                    guard let c = CropSpec.parse(spec, longEdge: long, smart: smart) else { throw PipelineError(L("Invalid crop size “%@”", spec)) }
                    pass.crop = c
                case .removeAudio: pass.removeAudio = true
                case .changeSpeed(let f, let fr): pass.speed = f; pass.frames = fr
                case .capFps(let f): pass.capFPS = f
                default: break
                }
                if let e = explicit { pass.placement = e; pass.placementSet = true }
                // A conversion lands next to the original unless told otherwise.
                if isConvert(step), explicit == nil, !pass.placementSet { pass.placement = .sameFolder }
                isEnd = pass.placement != .inPlace
                pass.count += 1
                if isEnd { try await flush() }
                continue
            }
            if step.isProcessing { continue }   // a step that does not apply to this kind is skipped
            try await flush()
            switch step {
            case .filter(let c, let invert):
                let (ok, g) = try await evaluate(c, file: current, kind: kind, context: context)
                if !g.isEmpty { groups = g }
                if ok == invert { out.skipped = true; out.output = current; out.newSize = Files.size(current); return out }
            case .targetSize(let bytes, let loc):
                let produced = try await fit(current, kind: kind, bytes: bytes)
                if Files.size(produced) < Files.size(current) || Files.size(current) > bytes {
                    let placement = loc.map { placementFrom($0, kind: kind, converted: false) } ?? .inPlace
                    let dest = Output.resolve(source: current, ext: produced.pathExtension, placement: context.forceTemporary ? .temporary : placement, counter: context.counter)
                    if placement == .inPlace, out.backup == nil, current.path == file.path { out.backup = try? backup(of: file) }
                    current = try Output.commit(produced: produced, source: current, destination: dest, placement: context.forceTemporary ? .temporary : placement, keepDates: keepDates)
                    try? FileManager.default.removeItem(at: produced.deletingLastPathComponent())
                }
            case .stripExif:
                let produced: URL?
                switch kind {
                case .image: produced = try ImageEngine.stripMetadata(current, preserveColor: Prefs.bool("preserveColorMetadata"))
                case .video: produced = try await VideoEngine.stripMetadata(current)
                default: produced = nil
                }
                if let p = produced {
                    if out.backup == nil, current.path == file.path, !context.forceTemporary { out.backup = try? backup(of: file) }
                    let dest = context.forceTemporary ? Output.resolve(source: current, ext: p.pathExtension, placement: .temporary) : current
                    current = try Output.commit(produced: p, source: current, destination: dest, placement: context.forceTemporary ? .temporary : .inPlace, keepDates: keepDates)
                    try? FileManager.default.removeItem(at: p.deletingLastPathComponent())
                }
            case .extractPagesAsImages(let format, let quality, let loc):
                guard kind == .pdf else { break }
                let scale = ["low": 1.0, "medium": 2.0, "high": 3.0][quality.lowercased()] ?? 2.0
                let placement = loc.map { placementFrom($0, kind: kind, converted: false) } ?? .sameFolder
                let base = Output.resolve(source: current, ext: "", placement: placement, template: "%f pages", counter: context.counter)
                let folder = base.pathExtension.isEmpty ? base : base.deletingPathExtension()
                let images = try PDFEngine.extractPages(current, format: format, scale: scale, into: folder)
                guard let first = images.first else { throw ShrinkError.failed(L("The PDF has no page")) }
                out.forks.append(contentsOf: images.dropFirst())
                current = first
            case .watermark(let image, let pos, let opacity, let scale, let loc):
                let wm = URL(fileURLWithPath: NameTemplate.expand((image as NSString).expandingTildeInPath, source: current))
                let produced = try await watermark(current, kind: kind, image: wm, position: pos, opacity: opacity, scale: scale)
                let placement = loc.map { placementFrom($0, kind: kind, converted: false) } ?? .inPlace
                if placement == .inPlace, out.backup == nil, current.path == file.path { out.backup = try? backup(of: file) }
                let dest = Output.resolve(source: current, ext: produced.pathExtension, placement: context.forceTemporary ? .temporary : placement, counter: context.counter)
                current = try Output.commit(produced: produced, source: current, destination: dest, placement: context.forceTemporary ? .temporary : placement, keepDates: keepDates)
                try? FileManager.default.removeItem(at: produced.deletingLastPathComponent())
            case .normalize(let lufs):
                guard kind == .audio || kind == .video else { break }
                var job = AudioJob(level: Prefs.audioLevel); job.normalizeLUFS = lufs
                if kind == .audio {
                    let produced = try await AudioEngine.process(current, job: job)
                    if out.backup == nil, current.path == file.path, !context.forceTemporary { out.backup = try? backup(of: file) }
                    current = try Output.commit(produced: produced, source: current, destination: current.deletingPathExtension().appendingPathExtension(produced.pathExtension), placement: .inPlace, keepDates: keepDates)
                }
            case .copy(let to), .move(let to), .rename(let to):
                current = try fileOperation(step, to: to, current: current, groups: groups, original: file, context: context)
            case .delete(let path):
                let target = path == "sourceFile" ? file : URL(fileURLWithPath: expand(path, source: current, groups: groups, counter: context.counter))
                try? FileManager.default.trashItem(at: target, resultingItemURL: nil)
                if target.path == current.path { current = file == target ? current : current }
            case .runScript(let s, let isCode):
                if let replaced = try await runScript(s, isCode: isCode, file: current) { current = replaced }
            case .runShortcut(let name):
                guard let sc = URL(string: "file:///usr/bin/shortcuts") else { break }
                let r = try await Run.process(sc, ["run", name, "--input-path", current.path])
                if r.status != 0 { out.notes.append(L("Shortcut “%@” failed", name)) }
            case .copyToClipboard(let format, let relative):
                await MainActor.run { Clipboard.copy(current, format: format, relativeTo: relative) }
            case .fork(let loc):
                let copy = Workspace.temp(ext: current.pathExtension, name: current.deletingPathExtension().lastPathComponent)
                try FileManager.default.copyItem(at: current, to: copy)
                if let l = loc {
                    let dest = Output.resolve(source: current, ext: current.pathExtension, placement: Placement(l), counter: context.counter)
                    Files.ensureParent(dest)
                    try FileManager.default.moveItem(at: copy, to: dest)
                    out.forks.append(dest)
                } else { out.forks.append(copy) }
            case .openWith(let app), .shelveWith(let app), .uploadWith(let app):
                _ = try? await Run.process(URL(fileURLWithPath: "/usr/bin/open"), ["-a", app, current.path])
            default: break
            }
        }
        try await flush()
        out.output = current
        out.newSize = Files.size(current)
        return out
    }

    // MARK: Helpers

    static func applies(_ step: Step, to kind: MediaKind) -> Bool {
        switch step {
        case .lowerBitrate: kind == .audio
        case .removeAudio, .capFps: kind == .video
        case .changeSpeed: kind == .video || kind == .audio
        case .crop: kind != .audio
        case .downscale: kind != .pdf
        default: true
        }
    }

    private static func locationOf(_ step: Step) -> String? {
        switch step {
        case .optimise(_, _, _, _, let l), .downscale(_, let l), .lowerBitrate(_, let l), .crop(_, _, _, let l), .convert(_, let l): l
        default: nil
        }
    }

    private static func isConvert(_ step: Step) -> Bool { if case .convert = step { return true }; return false }

    /// A location written in a pipeline or in the settings: a keyword, or a path template. "specificFolder" is the
    /// folder template of the settings.
    static func placementFrom(_ text: String, kind: MediaKind, converted: Bool) -> Placement {
        text.lowercased() == "specificfolder" ? .folder(Prefs.specificFolder(kind, converted: converted)) : Placement(text)
    }

    /// A copy of the original, so the optimisation can be undone.
    static func backup(of file: URL) throws -> URL {
        let dir = Workspace.root.appendingPathComponent("backups", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    /// Puts the backup back where the file was.
    static func restore(_ outcome: Outcome) throws {
        guard let b = outcome.backup else { throw ShrinkError.failed(L("No backup of the original")) }
        let fm = FileManager.default
        if fm.fileExists(atPath: outcome.output.path), outcome.output.path != outcome.original.path { try? fm.trashItem(at: outcome.output, resultingItemURL: nil) }
        if fm.fileExists(atPath: outcome.original.path) { try fm.removeItem(at: outcome.original) }
        try fm.copyItem(at: b, to: outcome.original)
    }

    static func expand(_ template: String, source: URL, groups: [String], counter: Int) -> String {
        var s = NameTemplate.expand((template as NSString).expandingTildeInPath, source: source, counter: counter)
        for (i, g) in groups.enumerated() { s = s.replacingOccurrences(of: "$\(i + 1)", with: g) }
        return s
    }

    private static func fileOperation(_ step: Step, to: String, current: URL, groups: [String], original: URL, context: RunContext) throws -> URL {
        let fm = FileManager.default
        let expanded = expand(to, source: current, groups: groups, counter: context.counter)
        var dest = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        if expanded.hasSuffix("/") || (fm.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue) { dest = dest.appendingPathComponent(current.lastPathComponent) }
        if case .rename = step { dest = current.deletingLastPathComponent().appendingPathComponent(expanded) }
        if dest.pathExtension.isEmpty { dest = dest.appendingPathExtension(current.pathExtension) }
        dest = Files.uniqueURL(dest)
        Files.ensureParent(dest)
        switch step {
        case .copy: try fm.copyItem(at: current, to: dest); return current
        default: try fm.moveItem(at: current, to: dest); return dest
        }
    }

    private static func runScript(_ s: String, isCode: Bool, file: URL) async throws -> URL? {
        let env = ["SHRINKBOX_INPUT_FILE": file.path, "SHRINKBOX_BIN": Tools.searchPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin"]
        let zsh = URL(fileURLWithPath: "/bin/zsh")
        let r: ProcessResult
        if isCode { r = try await Run.process(zsh, ["-c", s, "shrinkbox", file.path], environment: env) }
        else { r = try await Run.process(URL(fileURLWithPath: (s as NSString).expandingTildeInPath), [file.path], environment: env) }
        guard r.status == 0 else { throw ShrinkError.failed(String(r.error.suffix(300))) }
        let last = r.output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return (!last.isEmpty && FileManager.default.fileExists(atPath: last)) ? URL(fileURLWithPath: last) : nil
    }

    // MARK: Passes

    private static func execute(_ pass: Pass, on file: URL, kind: MediaKind, context: RunContext) async throws -> URL {
        switch kind {
        case .image:
            var j = ImageJob(level: pass.level ?? Prefs.imageLevel)
            j.adaptive = pass.adaptive ?? false
            j.downscale = pass.downscale; j.crop = pass.crop
            j.stripMetadata = Prefs.bool("stripMetadata"); j.preserveColor = Prefs.bool("preserveColorMetadata")
            j.targetExtension = pass.targetExtension
            j.gifKeepDuration = Prefs.string("gifFrameDropBehaviour") == "keepDuration"
            j.aggressive = pass.aggressive
            return try await ImageEngine.process(file, job: j)
        case .video:
            var j = VideoJob(level: pass.level ?? Prefs.videoLevel)
            switch pass.encoder ?? "fast" {
            case "slowHighQuality", "software": j.encoder = .software
            case "visuallyLossless": j.encoder = .visuallyLossless
            default: j.encoder = .hardware
            }
            if let t = pass.targetExtension {
                switch t {
                case "hevc": j.codec = .hevc; j.targetExtension = "mp4"
                case "x265": j.codec = .hevc; j.encoder = .software; j.targetExtension = "mp4"
                case "av1": j.codec = .av1; j.targetExtension = "mp4"
                case "webm": j.codec = .vp9; j.targetExtension = "webm"
                default: j.targetExtension = t
                }
            } else if !VideoEngine.canRead(file.pathExtension) { j.targetExtension = "mp4" }
            j.downscale = pass.downscale; j.crop = pass.crop
            j.removeAudio = pass.removeAudio || Prefs.bool("removeAudioFromVideos")
            j.speed = pass.speed
            j.keepFrames = (pass.frames ?? (Prefs.string("playbackSpeedFrameBehaviour") == "keepFrames" ? "keep" : "drop")) == "keep"
            j.capFPS = pass.capFPS ?? (Prefs.bool("capVideoFPS") ? Prefs.double("targetVideoFPS") : nil)
            j.minFPS = Prefs.double("minVideoFPS")
            j.stripMetadata = Prefs.bool("stripMetadata"); j.audioToAAC = Prefs.bool("convertAudioToAAC")
            return try await VideoEngine.process(file, job: j, progress: context.progress)
        case .pdf:
            var j = PDFJob(level: pass.level ?? .value(50))
            let d = pass.dpi ?? (Prefs.int("pdfDPI") > 0 ? Prefs.int("pdfDPI") : nil)
            j.dpi = d; j.aggressive = pass.aggressive; j.crop = pass.crop
            if pass.encoder == "aggressive" { j.aggressive = true }
            if pass.encoder == "lossless" { j.dpi = 300 }
            return try await PDFEngine.process(file, job: j)
        case .audio:
            var j = AudioJob(level: pass.level ?? Prefs.audioLevel)
            j.bitrateKbps = pass.kbps; j.targetExtension = pass.targetExtension; j.speed = pass.speed
            j.coverArt = Prefs.string("audioCoverArt"); j.stripMetadata = Prefs.bool("stripMetadata")
            j.downscale = pass.downscale
            if pass.targetExtension == nil, AudioEngine.lossless.contains(Media.canonical(file.pathExtension)), pass.level == nil, pass.kbps == nil, pass.downscale == nil {
                // Lossless files keep their format: nothing to gain without a conversion.
                j.level = .lossless
            }
            return try await AudioEngine.process(file, job: j, progress: context.progress)
        }
    }

    /// Makes a file fit under a size: compression first, then smaller dimensions.
    static func fit(_ file: URL, kind: MediaKind, bytes: Int64) async throws -> URL {
        if Files.size(file) <= bytes { let c = Workspace.temp(ext: file.pathExtension, name: file.deletingPathExtension().lastPathComponent); try FileManager.default.copyItem(at: file, to: c); return c }
        var best: URL?
        switch kind {
        case .image:
            var ext: String? = nil
            if Media.canonical(file.pathExtension) == "png" || Media.canonical(file.pathExtension) == "tiff" || Media.canonical(file.pathExtension) == "bmp" { ext = "jpg" }
            var scale = 1.0
            for step in 0..<12 {
                var j = ImageJob(level: .value(min(100, 40 + step * 8)))
                j.targetExtension = ext
                if step >= 4 { scale = max(0.1, scale * 0.85); j.downscale = scale }
                let out = try await ImageEngine.process(file, job: j)
                if let b = best { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
                best = out
                if Files.size(out) <= bytes { return out }
            }
        case .video:
            var budget = 1.0
            for _ in 0..<4 {
                var j = VideoJob(level: .smaller); j.targetBytes = bytes; j.budgetScale = budget
                j.stripMetadata = true
                if !VideoEngine.canRead(file.pathExtension) { j.targetExtension = "mp4" }
                let out = try await VideoEngine.process(file, job: j)
                if let b = best { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
                best = out
                if Files.size(out) <= bytes { return out }
                budget *= Double(bytes) / Double(max(1, Files.size(out))) * 0.9
            }
        case .pdf:
            for dpi in PDFEngine.dpiChoices {
                var j = PDFJob(level: .smaller); j.dpi = dpi
                let out = try await PDFEngine.process(file, job: j)
                if let b = best { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
                best = out
                if Files.size(out) <= bytes { return out }
            }
        case .audio:
            let duration = (try? await Self.duration(of: file)) ?? 0
            var kbps = duration > 0 ? Int(Double(bytes) * 8 / duration / 1000 * 0.95) : 128
            for _ in 0..<4 {
                var j = AudioJob(level: .smaller); j.bitrateKbps = max(32, kbps)
                if AudioEngine.lossless.contains(Media.canonical(file.pathExtension)) { j.targetExtension = "m4a" }
                let out = try await AudioEngine.process(file, job: j)
                if let b = best { try? FileManager.default.removeItem(at: b.deletingLastPathComponent()) }
                best = out
                if Files.size(out) <= bytes { return out }
                kbps = Int(Double(kbps) * 0.8)
            }
        }
        guard let b = best else { throw ShrinkError.failed(L("Cannot reach the target size")) }
        return b
    }

    private static func duration(of url: URL) async throws -> Double {
        CMTimeGetSeconds(try await AVURLAsset(url: url).load(.duration))
    }

    // MARK: Watermark

    static func watermark(_ file: URL, kind: MediaKind, image: URL, position: WatermarkPosition, opacity: Double, scale: Double) async throws -> URL {
        guard FileManager.default.fileExists(atPath: image.path) else { throw ShrinkError.failed(L("The watermark image %@ does not exist", image.lastPathComponent)) }
        switch kind {
        case .image:
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), let base = try? ImageEngine.loadOriented(src),
                  let wsrc = CGImageSourceCreateWithURL(image as CFURL, nil), let mark = CGImageSourceCreateImageAtIndex(wsrc, 0, nil) else { throw ShrinkError.failed(L("Cannot read the image")) }
            let space = base.colorSpace ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ShrinkError.failed(L("Cannot draw the watermark")) }
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            let w = Double(base.width) * scale, h = w * Double(mark.height) / Double(mark.width)
            let margin = Double(base.width) * 0.02
            let x: Double, y: Double
            switch position {
            case .bottomRight: x = Double(base.width) - w - margin; y = margin
            case .bottomLeft: x = margin; y = margin
            case .topRight: x = Double(base.width) - w - margin; y = Double(base.height) - h - margin
            case .topLeft: x = margin; y = Double(base.height) - h - margin
            case .center: x = (Double(base.width) - w) / 2; y = (Double(base.height) - h) / 2
            }
            ctx.setAlpha(opacity)
            ctx.draw(mark, in: CGRect(x: x, y: y, width: w, height: h))
            guard let result = ctx.makeImage() else { throw ShrinkError.failed(L("Cannot draw the watermark")) }
            let ext = file.pathExtension
            let out = Workspace.temp(ext: ext, name: file.deletingPathExtension().lastPathComponent)
            try await ImageEngine.encode(result, ext: ext, level: .value(15), aggressive: false, properties: [:], hasAlpha: ImageEngine.hasAlpha(base), to: out)
            return out
        case .video:
            let ff = try Tools.require(.ffmpeg, for: L("to watermark videos"))
            let out = Workspace.temp(ext: file.pathExtension, name: file.deletingPathExtension().lastPathComponent)
            let pad = "main_w*0.02"
            let pos: String = switch position {
            case .bottomRight: "x=main_w-overlay_w-\(pad):y=main_h-overlay_h-\(pad)"
            case .bottomLeft: "x=\(pad):y=main_h-overlay_h-\(pad)"
            case .topRight: "x=main_w-overlay_w-\(pad):y=\(pad)"
            case .topLeft: "x=\(pad):y=\(pad)"
            case .center: "x=(main_w-overlay_w)/2:y=(main_h-overlay_h)/2"
            }
            let filter = "[1]format=rgba,colorchannelmixer=aa=\(opacity)[w];[w][0]scale2ref=w=iw*\(scale):h=ow/mdar[w2][v];[v][w2]overlay=\(pos)"
            let r = try await Run.process(ff, ["-y", "-loglevel", "error", "-i", file.path, "-i", image.path, "-filter_complex", filter, "-c:a", "copy", out.path])
            guard r.status == 0 else { throw ShrinkError.failed(String(r.error.suffix(300))) }
            return out
        default:
            throw ShrinkError.unsupported(L("Watermarks apply to images and videos"))
        }
    }

    // MARK: Conditions

    static func evaluate(_ c: Condition, file: URL, kind: MediaKind, context: RunContext) async throws -> (Bool, [String]) {
        var groups: [String] = []
        let name = file.lastPathComponent
        if let pattern = c.regex {
            let smart = pattern == pattern.lowercased() ? [NSRegularExpression.Options.caseInsensitive] : []
            guard let re = try? NSRegularExpression(pattern: pattern, options: NSRegularExpression.Options(smart)) else { throw PipelineError(L("Invalid regular expression “%@”", pattern)) }
            let range = NSRange(name.startIndex..., in: name)
            guard let m = re.firstMatch(in: name, range: range) else { return (false, []) }
            for i in 1..<max(1, m.numberOfRanges) { if let r = Range(m.range(at: i), in: name) { groups.append(String(name[r])) } }
        }
        if !c.types.isEmpty {
            let ext = Media.canonical(file.pathExtension)
            let ok = c.types.contains(ext) || c.types.contains(kind.rawValue)
            if !ok { return (false, groups) }
        }
        if let s = c.nameContains, !name.localizedCaseInsensitiveContains(s) { return (false, groups) }
        if let s = c.nameIs, name != s { return (false, groups) }
        let size = Files.size(file)
        if let v = c.fileSizeGreaterThan, size <= v { return (false, groups) }
        if let v = c.fileSizeLowerThan, size >= v { return (false, groups) }
        if let v = c.minFileSize, size < v { return (false, groups) }
        if kind == .image {
            if let src = CGImageSourceCreateWithURL(file as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
                if let v = c.widthGreaterThan, w <= v { return (false, groups) }
                if let v = c.widthLowerThan, w >= v { return (false, groups) }
                if let v = c.heightGreaterThan, h <= v { return (false, groups) }
                if let v = c.heightLowerThan, h >= v { return (false, groups) }
                if let r = c.minResolution {
                    let p = r.lowercased().split(separator: "x").compactMap { Int($0) }
                    if p.count == 2, w < p[0] || h < p[1] { return (false, groups) }
                }
                let dpi = Int((p[kCGImagePropertyDPIWidth] as? Double) ?? 72)
                if let v = c.dpiGreaterThan, dpi <= v { return (false, groups) }
                if let v = c.dpiLowerThan, dpi >= v { return (false, groups) }
            }
        }
        if let app = c.copiedBy {
            guard let by = context.copiedBy, by.localizedCaseInsensitiveContains(app) else { return (false, groups) }
        }
        return (true, groups)
    }
}
