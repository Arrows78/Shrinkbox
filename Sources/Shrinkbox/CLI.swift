import Foundation

/// A tiny option parser: `--name value`, `-n value`, `--flag`, `--name=value`, and the rest as positional arguments.
struct Args {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    /// `valued` lists the options that take a value, long names and short aliases alike.
    init(_ argv: [String], valued: Set<String>, aliases: [String: String] = [:]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "--" { positional += argv[(i + 1)...]; break }
            if a.hasPrefix("-"), a.count > 1, !(a.dropFirst().first?.isNumber ?? false) {
                var name = a.drop(while: { $0 == "-" }).description
                var inline: String?
                if let eq = name.firstIndex(of: "=") { inline = String(name[name.index(after: eq)...]); name = String(name[..<eq]) }
                name = aliases[name] ?? name
                if valued.contains(name) {
                    if let v = inline { values[name] = v }
                    else if i + 1 < argv.count { values[name] = argv[i + 1]; i += 1 }
                } else { flags.insert(name) }
            } else { positional.append(a) }
            i += 1
        }
    }

    func has(_ n: String) -> Bool { flags.contains(n) }
    func value(_ n: String) -> String? { values[n] }
}

enum CLI {
    static var version: String { AppBundle.version }

    static let commands: Set<String> = ["optimise", "optimize", "crop", "downscale", "convert", "crop-pdf", "uncrop-pdf", "strip-exif", "clear", "pipeline", "settings", "mcp", "logs", "help", "--help", "-h", "version", "--version"]

    static func isCommand(_ argv: [String]) -> Bool {
        guard argv.count > 1 else { return false }
        return commands.contains(argv[1])
    }

    static let usage = """
    Shrinkbox: optimise, crop, downscale and convert images, videos, audio files and PDFs.

    USAGE: shrinkbox <command> [options] [files or folders or links]

    COMMANDS
      optimise [image|video|pdf|audio]   Make files smaller.
      crop                               Crop and resize to a size or an aspect ratio.
      downscale                          Scale down by a factor (for audio: the bitrate).
      convert [image|video|audio]        Change the format.
      crop-pdf / uncrop-pdf              Crop PDF pages without losing content, and undo it.
      strip-exif                         Remove EXIF and GPS metadata.
      clear                              Dismiss the floating results of the running app.
      pipeline                           Saved pipelines, automations and preset zones.
      settings                           Read and change the settings.
      mcp                                Serve the tools to AI agents over MCP (stdio).
      logs                               Print the log.

    Common options: -r recurse into folders, -c copy the result to the clipboard, -s skip errors,
    -j JSON output, -n no progress, -o output template (tokens: %f name, %e extension, %P folder,
    %y %m %d %H %M %S date, %r random, %i counter, %z crop size, %s scale).
    """

    static func run(_ argv: [String]) async -> Int32 {
        AppBundle.shareSettingsWithApp()
        let rest = Array(argv.dropFirst(2))
        switch argv[1] {
        case "help", "--help", "-h": print(usage); return 0
        case "version", "--version": print("Shrinkbox \(version)"); return 0
        case "optimise", "optimize": return await optimise(rest)
        case "crop": return await crop(rest)
        case "downscale": return await downscale(rest)
        case "convert": return await convert(rest)
        case "crop-pdf": return await cropPDF(rest, undo: false)
        case "uncrop-pdf": return await cropPDF(rest, undo: true)
        case "strip-exif": return await stripEXIF(rest)
        case "clear": DistributedNotificationCenter.default().postNotificationName(.clearResults, object: nil); return 0
        case "pipeline": return await PipelineCLI.run(rest)
        case "settings": return SettingsCLI.run(rest)
        case "logs": print(Log.read()); return 0
        case "mcp": MCPServer.run(); return 0
        default: fputs("unknown command\n", stderr); return 64
        }
    }

    // MARK: Shared pieces

    static let valued: Set<String> = ["output", "behaviour", "auto-convert-behaviour", "same-folder-template", "specific-folder-template", "compression", "downscale-factor", "crop", "size", "factor",
                                      "encoder", "playback-speed-factor", "playback-speed-frames", "dpi", "bitrate", "types", "exclude-types", "to", "format", "quality", "pdf-dpi", "codec", "fps", "kbps"]
    static let aliases: [String: String] = ["o": "output", "s": "skip-errors", "c": "copy", "r": "recursive", "j": "json", "n": "no-progress", "a": "aggressive", "g": "gui", "b": "bitrate",
                                            "l": "long-edge", "f": "format", "q": "quality"]

    struct Common {
        var files: [URL]
        var json: Bool
        var quiet: Bool
        var skipErrors: Bool
        var copy: Bool
    }

    /// Files from paths, folders and links (links are downloaded).
    static func inputs(_ a: Args, defaultKinds: Set<MediaKind>? = nil) async throws -> [URL] {
        var urls: [URL] = []
        for p in a.positional {
            if let u = URL(string: p), let s = u.scheme, s.hasPrefix("http") {
                do { urls.append(try await Fetch.download(u)) }
                catch { if !a.has("skip-errors") { throw error } }
            } else { urls.append(URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) }
        }
        var kinds = defaultKinds
        func parse(_ s: String?) -> (Set<MediaKind>, Set<String>) {
            var k = Set<MediaKind>(), e = Set<String>()
            for t in (s ?? "").split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                if let kind = MediaKind(rawValue: t) { k.insert(kind) } else { e.insert(Media.canonical(t)) }
            }
            return (k, e)
        }
        let (typeKinds, typeExts) = parse(a.value("types"))
        let (exKinds, exExts) = parse(a.value("exclude-types"))
        if !typeKinds.isEmpty { kinds = (kinds ?? Set(MediaKind.allCases)).intersection(typeKinds) }
        var excluded = exExts
        for k in exKinds { for e in (Media.imageExtensions.union(Media.videoExtensions).union(Media.audioExtensions).union(["pdf"])) where Media.kind(ofExtension: e) == k { excluded.insert(Media.canonical(e)) } }
        let files = Media.collect(urls, recursive: a.has("recursive"), kinds: kinds, extensions: typeExts.isEmpty ? nil : typeExts, excludedExtensions: excluded)
        if files.isEmpty, !a.has("skip-errors") { throw ShrinkError.failed(L("No supported file found")) }
        return files
    }

    /// Runs the pipeline on every file, a few at a time, prints the results and returns the exit code.
    static func process(_ files: [URL], pipeline: Pipeline, a: Args, kindSpecific: Bool = false) async -> Int32 {
        let json = a.has("json"), quiet = a.has("no-progress")
        var results: [(URL, Outcome?, String?)] = []
        let limit = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        await withTaskGroup(of: (Int, URL, Outcome?, String?).self) { group in
            var next = 0
            func add(_ i: Int) {
                let f = files[i]
                group.addTask {
                    var ctx = RunContext(source: .cli); ctx.counter = i + 1
                    if !quiet && !json { ctx.progress = { p in fputs(String(format: "\r%@ %3d%%", f.lastPathComponent, Int(p * 100)), stderr) } }
                    do { return (i, f, try await Runner.run(f, pipeline, context: ctx), nil) }
                    catch { return (i, f, nil, error.localizedDescription) }
                }
            }
            while next < min(limit, files.count) { add(next); next += 1 }
            var collected: [(Int, URL, Outcome?, String?)] = []
            while let r = await group.next() {
                collected.append(r)
                if next < files.count { add(next); next += 1 }
            }
            results = collected.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2, $0.3) }
        }
        if !quiet && !json { fputs("\r\u{1B}[K", stderr) }
        var failed = 0
        var rows: [[String: Any]] = []
        var outputs: [URL] = []
        for (file, outcome, error) in results {
            if let o = outcome {
                outputs.append(o.output)
                rows.append(["file": file.path, "output": o.output.path, "originalSize": o.originalSize, "newSize": o.newSize, "saved": o.saved, "percent": o.percent, "skipped": o.skipped, "notes": o.notes])
                if !json {
                    let note = o.notes.isEmpty ? "" : "  (\(o.notes.joined(separator: ", ")))"
                    if o.skipped && !o.changed { print("\(file.lastPathComponent): \(Files.human(o.originalSize)), unchanged\(note)") }
                    else { print("\(o.output.lastPathComponent): \(Files.human(o.originalSize)) → \(Files.human(o.newSize)) (\(o.changeLabel))\(note)") }
                }
            } else {
                failed += 1
                rows.append(["file": file.path, "error": error ?? ""])
                if !json { fputs("\(file.lastPathComponent): \(error ?? "")\n", stderr) }
            }
        }
        if json, let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: d, as: UTF8.self)) }
        if a.has("copy") { await MainActor.run { Clipboard.copy(outputs) } }
        return failed > 0 && !a.has("skip-errors") ? 1 : 0
    }

    /// Placement of the optimised file from `--output` and `--behaviour`.
    static func location(_ a: Args, kind: MediaKind?) -> String? {
        if let o = a.value("output") { return o }
        guard let b = a.value("behaviour") else { return nil }
        switch b.lowercased() {
        case "inplace": return nil
        case "samefolder": return "sameFolder"
        case "temp", "temporary": return "temporary"
        case "specificfolder": return Prefs.specificFolder(kind ?? .image, converted: false)
        default: return nil
        }
    }

    static func compression(_ a: Args) -> String? { a.value("compression") }

    // MARK: Commands

    static func optimise(_ argv: [String]) async -> Int32 {
        var argv = argv
        var kinds: Set<MediaKind>?
        if let first = argv.first, let k = MediaKind(rawValue: first) { kinds = [k]; argv.removeFirst() }
        let a = Args(argv, valued: valued, aliases: aliases)
        do {
            let files = try await inputs(a, defaultKinds: kinds)
            var steps: [Step] = []
            if let c = a.value("crop") { guard CropSpec.parse(c) != nil else { throw PipelineError(L("Invalid crop size “%@”", c)) }; steps.append(.crop(spec: c, longEdge: false, smart: a.has("smart-crop"), location: nil)) }
            if let f = a.value("downscale-factor").flatMap(Double.init) { steps.append(.downscale(factor: f, location: nil)) }
            if let s = a.value("playback-speed-factor").flatMap(Double.init) { steps.append(.changeSpeed(factor: s, frames: a.value("playback-speed-frames"))) }
            if a.has("remove-audio") { steps.append(.removeAudio) }
            var encoder = a.value("encoder")
            if encoder == "hardware" { encoder = "fast" } else if encoder == "software" { encoder = "slowHighQuality" }
            if a.has("aggressive") { encoder = "aggressive" }
            var dpi = a.value("dpi").flatMap(Int.init)
            if dpi == nil, let d = a.value("pdf-dpi"), d != "adaptive" { dpi = Int(d) }
            let kind = kinds?.first
            if let kb = a.value("bitrate").flatMap(Int.init) { steps.append(.lowerBitrate(kbps: kb, location: nil)) }
            steps.append(.optimise(encoder: encoder, compression: compression(a), adaptive: a.has("adaptive-optimisation") ? true : nil, dpi: dpi, location: location(a, kind: kind)))
            return await process(files, pipeline: Pipeline(steps: steps), a: a)
        } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
    }

    static func crop(_ argv: [String]) async -> Int32 {
        let a = Args(argv, valued: valued, aliases: aliases)
        guard let size = a.value("size") else { fputs("--size is required (for example 1200x630, 1920 or 16:9)\n", stderr); return 64 }
        do {
            guard CropSpec.parse(size, longEdge: a.has("long-edge")) != nil else { throw PipelineError(L("Invalid crop size “%@”", size)) }
            let files = try await inputs(a, defaultKinds: [.image, .video, .pdf])
            // A crop already compresses; an optimise step is added only when asked for, in the same pass.
            var steps: [Step] = [.crop(spec: size, longEdge: a.has("long-edge"), smart: a.has("smart-crop"), location: location(a, kind: nil))]
            if a.value("compression") != nil || a.has("aggressive") || a.value("pdf-dpi") != nil {
                steps.append(.optimise(encoder: a.has("aggressive") ? "aggressive" : nil, compression: compression(a), adaptive: nil, dpi: a.value("pdf-dpi").flatMap(Int.init), location: nil))
            }
            return await process(files, pipeline: Pipeline(steps: steps), a: a)
        } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
    }

    static func downscale(_ argv: [String]) async -> Int32 {
        let a = Args(argv, valued: valued, aliases: aliases)
        do {
            let files = try await inputs(a, defaultKinds: [.image, .video, .audio])
            guard let f = Double(a.value("factor") ?? "0.5"), f > 0, f <= 1 else { throw PipelineError(L("downscale needs a factor between 0 and 1")) }
            let loc = location(a, kind: nil)
            var steps: [Step] = [.downscale(factor: f, location: loc)]
            if a.value("compression") != nil || a.has("aggressive") { steps.append(.optimise(encoder: a.has("aggressive") ? "aggressive" : nil, compression: compression(a), adaptive: nil, dpi: nil, location: nil)) }
            return await process(files, pipeline: Pipeline(steps: steps), a: a)
        } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
    }

    static func convert(_ argv: [String]) async -> Int32 {
        var argv = argv
        var kinds: Set<MediaKind>?
        if let first = argv.first, let k = MediaKind(rawValue: first), k != .pdf { kinds = [k]; argv.removeFirst() }
        let a = Args(argv, valued: valued, aliases: aliases)
        guard let to = (a.value("to") ?? a.value("format"))?.lowercased() else { fputs("--to is required (for example webp, jpeg, mp4, gif, mp3)\n", stderr); return 64 }
        do {
            let files = try await inputs(a, defaultKinds: kinds ?? [.image, .video, .audio])
            var q = a.value("compression") ?? a.value("quality")
            if let n = q.flatMap({ Int($0) }) { q = String(100 - n) }   // a quality is the opposite of a compression
            var steps: [Step] = []
            if let kb = a.value("bitrate").flatMap(Int.init) { steps.append(.lowerBitrate(kbps: kb, location: nil)) }
            steps.insert(.convert(to: to, location: location(a, kind: nil)), at: 0)
            if let q { steps.insert(.optimise(encoder: nil, compression: q, adaptive: nil, dpi: nil, location: nil), at: 0) }
            return await process(files, pipeline: Pipeline(steps: steps), a: a)
        } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
    }

    static func cropPDF(_ argv: [String], undo: Bool) async -> Int32 {
        let a = Args(argv, valued: valued, aliases: aliases)
        do {
            let files = try await inputs(a, defaultKinds: [.pdf])
            var code: Int32 = 0
            for f in files {
                do {
                    let produced: URL
                    if undo { produced = try PDFEngine.uncrop(f) }
                    else {
                        guard let s = a.value("size"), let spec = CropSpec.parse(s) else { throw PipelineError(L("--size is required")) }
                        produced = try PDFEngine.applyCrop(spec, to: f)
                    }
                    let dest = a.value("output").map { URL(fileURLWithPath: NameTemplate.expand(($0 as NSString).expandingTildeInPath, source: f)) } ?? f
                    try Output.commit(produced: produced, source: f, destination: dest, placement: dest == f ? .inPlace : .sameFolder, keepDates: Prefs.bool("preserveDates"))
                    print("\(dest.lastPathComponent): \(undo ? "restored" : "cropped")")
                } catch { fputs("\(f.lastPathComponent): \(error.localizedDescription)\n", stderr); code = 1 }
            }
            return code
        } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
    }

    static func stripEXIF(_ argv: [String]) async -> Int32 {
        let a = Args(argv, valued: valued, aliases: aliases)
        do {
            let files = try await inputs(a, defaultKinds: [.image, .video])
            return await process(files, pipeline: Pipeline(steps: [.stripExif]), a: a)
        } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
    }
}

extension Notification.Name {
    static let clearResults = Notification.Name("dev.labs.shrinkbox.clear")
}

// MARK: Pipelines

enum PipelineCLI {
    static let valued: Set<String> = ["source", "type", "file-type", "index", "icon", "types", "output"]

    static func run(_ argv: [String]) async -> Int32 {
        guard let sub = argv.first else { print(helpText); return 0 }
        var rest = Array(argv.dropFirst())
        // `preset add` and `preset remove` have a second word.
        var preset: String?
        if sub == "preset" { preset = rest.first; rest = Array(rest.dropFirst()) }
        let a = Args(rest, valued: valued, aliases: CLI.aliases.merging(["skip-optimisation": "skip-optimisation"]) { $1 })
        do {
            switch sub {
            case "list":
                let lib = Library.load()
                for p in lib.pipelines { print("\(p.name)\(p.fileType.map { " [\($0.rawValue)]" } ?? ""): \(p.steps)") }
                for t in lib.attachments { print("attached  \(t.source) (\(t.type.rawValue)): \(t.pipeline)") }
                for z in lib.zones { print("zone      \(z.name)\(z.type.map { " [\($0.rawValue)]" } ?? ""): \(z.pipeline)") }
            case "show":
                guard let name = a.positional.first, let p = Library.load().pipelines.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw ShrinkError.failed(L("No saved pipeline with this name")) }
                print(p.steps.replacingOccurrences(of: " -> ", with: "\n-> "))
            case "run":
                guard let text = a.positional.first else { throw ShrinkError.failed(L("Give a pipeline: a saved name or inline steps")) }
                let (pipeline, saved) = try Library.resolve(text)
                var steps = pipeline.steps
                if let s = saved, !s.skipOptimisation { steps.insert(.optimise(encoder: nil, compression: nil, adaptive: nil, dpi: nil, location: nil), at: 0) }
                let files = try await CLI.inputs(Args(Array(rest.dropFirst()), valued: CLI.valued.union(valued), aliases: CLI.aliases), defaultKinds: saved?.fileType.map { [$0] })
                return await CLI.process(files, pipeline: Pipeline(steps: steps), a: Args(rest, valued: CLI.valued.union(valued), aliases: CLI.aliases))
            case "add":
                guard a.positional.count >= 2 else { throw ShrinkError.failed(L("Usage: pipeline add [--file-type T] <name> '<steps>'")) }
                let name = a.positional[0], steps = a.positional[1]
                _ = try PipelineParser.parse(steps)
                try Library.update { lib in
                    if lib.pipelines.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                        guard a.has("force") else { throw ShrinkError.failed(L("A pipeline named “%@” exists: use --force to replace it", name)) }
                        lib.pipelines.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    }
                    lib.pipelines.append(SavedPipeline(name: name, fileType: a.value("file-type").flatMap(MediaKind.init(rawValue:)), steps: steps, skipOptimisation: a.has("skip-optimisation"), hideResult: a.has("hide-result")))
                }
                print("Saved “\(name)”")
            case "delete":
                guard let name = a.positional.first else { throw ShrinkError.failed(L("Give the name of a pipeline")) }
                try Library.update { $0.pipelines.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
            case "prompt": print(Reference.pipelineGuide)
            case "attach":
                guard let text = a.positional.first, let src = a.value("source"), let type = a.value("type").flatMap(MediaKind.init(rawValue:)) else { throw ShrinkError.failed(L("Usage: pipeline attach '<pipeline>' --source <clipboard|dropZone|folder> --type <image|video|pdf|audio>")) }
                let (_, saved) = try Library.resolve(text)
                try Library.update { lib in
                    lib.attachments.append(Attachment(source: src, type: type, pipeline: text, inline: saved == nil, skipOptimisation: a.has("skip-optimisation"), hideResult: a.has("hide-result")))
                    if src.lowercased() != "clipboard" && src.lowercased() != "dropzone" {
                        // Attaching to a folder also watches it.
                        let key = "\(type.rawValue)WatchPaths"
                        var paths = Prefs.list(key)
                        if !paths.contains(src) { paths.append(src); Prefs.set(key, paths.joined(separator: ",")) }
                        Prefs.set("enableAutomatic\(Prefs.kindName(type))Optimisations", "true")
                    }
                }
                print("Attached")
            case "detach":
                guard let src = a.value("source"), let type = a.value("type").flatMap(MediaKind.init(rawValue:)) else { throw ShrinkError.failed(L("Usage: pipeline detach --source <source> --type <type> (--all | --index <n>)")) }
                try Library.update { lib in
                    let idx = lib.attachments.indices.filter { lib.attachments[$0].source.caseInsensitiveCompare(src) == .orderedSame && lib.attachments[$0].type == type }
                    if a.has("all") { for i in idx.reversed() { lib.attachments.remove(at: i) } }
                    else if let n = a.value("index").flatMap(Int.init), idx.indices.contains(n) { lib.attachments.remove(at: idx[n]) }
                    else { throw ShrinkError.failed(L("Give --all or --index <n>")) }
                    if !lib.attachments.contains(where: { $0.source.caseInsensitiveCompare(src) == .orderedSame && $0.type == type }), src.lowercased() != "clipboard", src.lowercased() != "dropzone" {
                        let key = "\(type.rawValue)WatchPaths"
                        Prefs.set(key, Prefs.list(key).filter { $0 != src }.joined(separator: ","))
                    }
                }
            case "preset":
                switch preset {
                case "add":
                    guard a.positional.count >= 2 else { throw ShrinkError.failed(L("Usage: pipeline preset add '<name>' '<pipeline>' [--type T] [--icon SYMBOL]")) }
                    let name = a.positional[0], text = a.positional[1]
                    let (_, saved) = try Library.resolve(text)
                    let type = a.value("type").flatMap(MediaKind.init(rawValue:))
                    var zone = PresetZone(name: name, pipeline: text, inline: saved == nil, type: type, icon: a.value("icon") ?? "wand.and.stars", skipOptimisation: a.has("skip-optimisation"), hideResult: a.has("hide-result"))
                    zone.icon = a.value("icon") ?? zone.icon
                    try Library.update { lib in
                        if lib.zones.contains(where: { $0.id == zone.id }) {
                            guard a.has("force") else { throw ShrinkError.failed(L("A zone with this name exists: use --force to replace it")) }
                            lib.zones.removeAll { $0.id == zone.id }
                        }
                        lib.zones.append(zone)
                    }
                case "remove":
                    guard let name = a.positional.first else { throw ShrinkError.failed(L("Give the name of a zone")) }
                    let type = a.value("type").flatMap(MediaKind.init(rawValue:))
                    try Library.update { $0.zones.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.type == type } }
                default: print(helpText)
                }
            default: print(helpText)
            }
            return 0
        } catch { fputs("\(error.localizedDescription)\n", stderr); return 1 }
    }

    static let helpText = """
    shrinkbox pipeline <list | show <name> | run <name or steps> files… | add <name> '<steps>' | delete <name> |
                        prompt | attach '<pipeline>' --source S --type T | detach --source S --type T (--all | --index N) |
                        preset add '<name>' '<pipeline>' | preset remove '<name>'>
    """
}

// MARK: Settings

enum SettingsCLI {
    static func run(_ argv: [String]) -> Int32 {
        guard let sub = argv.first else { print(Prefs.schema()); return 0 }
        switch sub {
        case "schema": print(Prefs.schema())
        case "get":
            guard let k = argv.dropFirst().first else { fputs("Give a setting name\n", stderr); return 64 }
            guard Prefs.byKey[k] != nil else { fputs(L("Unknown setting “%@”", k) + "\n", stderr); return 1 }
            print(Prefs.string(k))
        case "set":
            guard argv.count >= 3 else { fputs("Usage: settings set <setting> <value>\n", stderr); return 64 }
            if let e = Prefs.set(argv[1], argv[2...].joined(separator: " ")) { fputs(e + "\n", stderr); return 1 }
            print("\(argv[1]) = \(Prefs.string(argv[1]))")
        case "reset":
            if let k = argv.dropFirst().first { Prefs.reset(k) } else { Prefs.resetAll() }
        default:
            guard Prefs.byKey[sub] != nil else { fputs(L("Unknown setting “%@”", sub) + "\n", stderr); return 1 }
            if argv.count >= 2 { if let e = Prefs.set(sub, argv[1...].joined(separator: " ")) { fputs(e + "\n", stderr); return 1 } }
            print(Prefs.string(sub))
        }
        return 0
    }
}

// MARK: Support

enum Fetch {
    /// Downloads a link into the workspace; the extension comes from the link or the content type.
    static func download(_ url: URL) async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        var ext = url.pathExtension
        if ext.isEmpty, let mime = response.mimeType {
            ext = ["image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "image/heic": "heic", "video/mp4": "mp4", "video/quicktime": "mov", "application/pdf": "pdf", "audio/mpeg": "mp3"][mime] ?? ""
        }
        let name = url.deletingPathExtension().lastPathComponent.isEmpty ? "download" : url.deletingPathExtension().lastPathComponent
        let dest = Workspace.temp(ext: ext, name: name)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

enum Log {
    static var url: URL { URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/Shrinkbox/shrinkbox.log")) }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func read() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}
