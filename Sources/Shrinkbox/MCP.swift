import Foundation

/// Tools for AI agents, served over MCP on stdio (`shrinkbox mcp`). Reading is always allowed; anything that changes
/// files or settings needs "Accept changes from agents" in the settings, and script steps need their own switch.
enum MCPServer {
    static func tool(_ name: String, _ description: String, _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }

    static let pathsProperty: [String: Any] = ["type": "array", "items": ["type": "string"], "description": "Files or folders"]

    static let tools: [[String: Any]] = [
        tool("optimise_files", "Make images, videos, PDFs and audio files smaller. Replaces the originals unless `output` is given.",
             ["paths": pathsProperty, "compression": ["type": "string", "description": "adaptive, lossless, fast, smaller or 5-100 (higher is smaller)"], "output": ["type": "string", "description": "Output path template, for example ~/Desktop/%f-small.%e"], "recursive": ["type": "boolean"]], required: ["paths"]),
        tool("crop_files", "Crop and resize images, videos and PDFs to a size (1200x630, 1920) or a ratio (16:9).",
             ["paths": pathsProperty, "size": ["type": "string"], "long_edge": ["type": "boolean"], "smart_crop": ["type": "boolean"], "output": ["type": "string"]], required: ["paths", "size"]),
        tool("downscale_files", "Scale images and videos down by a factor; for audio the factor applies to the bitrate.",
             ["paths": pathsProperty, "factor": ["type": "number", "description": "0.1 to 1, default 0.5"], "output": ["type": "string"]], required: ["paths"]),
        tool("convert_files", "Convert images, videos and audio files to another format (webp, avif, heic, jpeg, png, gif, mp4, mp3, m4a…).",
             ["paths": pathsProperty, "to": ["type": "string"], "output": ["type": "string"]], required: ["paths", "to"]),
        tool("strip_metadata", "Remove EXIF and GPS metadata from images and videos.", ["paths": pathsProperty], required: ["paths"]),
        tool("run_pipeline", "Run a saved pipeline (by name) or inline steps on files. Call get_pipeline_guide first for the syntax.",
             ["pipeline": ["type": "string"], "paths": pathsProperty], required: ["pipeline", "paths"]),
        tool("save_pipeline", "Save a pipeline under a name, to run it from the app or the CLI.", ["name": ["type": "string"], "steps": ["type": "string"], "file_type": ["type": "string", "enum": ["image", "video", "pdf", "audio"]]], required: ["name", "steps"]),
        tool("list_pipelines", "List the saved pipelines, the automations and the preset zones."),
        tool("get_pipeline_guide", "The reference of the pipeline language: steps, parameters, filters and examples."),
        tool("get_settings", "Read every setting with its current value and allowed values."),
        tool("set_setting", "Change one setting.", ["key": ["type": "string"], "value": ["type": "string"]], required: ["key", "value"]),
        tool("available_tools", "Which optional command-line tools are installed and what each one adds."),
    ]

    /// Tools that change files or settings.
    static let changing: Set<String> = ["optimise_files", "crop_files", "downscale_files", "convert_files", "strip_metadata", "run_pipeline", "save_pipeline", "set_setting"]

    static func call(_ name: String, _ args: [String: Any]) async -> (ok: Bool, text: String) {
        if changing.contains(name), !Prefs.bool("mcpAcceptChanges") {
            return (false, "Shrinkbox is not accepting changes from agents. Turn on “Accept changes from agents” in Settings › Agents.")
        }
        func paths() -> [URL] {
            let list = (args["paths"] as? [String]) ?? []
            return Media.collect(list.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }, recursive: (args["recursive"] as? Bool) ?? false)
        }
        func finish(_ pipeline: Pipeline, files: [URL]) async -> (Bool, String) {
            guard !files.isEmpty else { return (false, "No supported file found") }
            var lines: [String] = []
            var ok = true
            for (i, f) in files.enumerated() {
                var ctx = RunContext(source: .cli); ctx.counter = i + 1
                do {
                    let o = try await Runner.run(f, pipeline, context: ctx)
                    lines.append("\(o.output.path): \(Files.human(o.originalSize)) → \(Files.human(o.newSize)) (\(o.changeLabel))" + (o.notes.isEmpty ? "" : " [\(o.notes.joined(separator: ", "))]"))
                } catch { ok = false; lines.append("\(f.path): \(error.localizedDescription)") }
            }
            return (ok, lines.joined(separator: "\n"))
        }
        switch name {
        case "optimise_files":
            let comp = args["compression"] as? String
            if let c = comp, Level(c) == nil { return (false, "compression must be \(Prefs.compressionHelp)") }
            return await finish(Pipeline(steps: [.optimise(encoder: nil, compression: comp, adaptive: nil, dpi: nil, location: args["output"] as? String)]), files: paths())
        case "crop_files":
            guard let size = args["size"] as? String, CropSpec.parse(size, longEdge: (args["long_edge"] as? Bool) ?? false) != nil else { return (false, "size must look like 1200x630, 1920 or 16:9") }
            let loc = args["output"] as? String
            return await finish(Pipeline(steps: [.crop(spec: size, longEdge: (args["long_edge"] as? Bool) ?? false, smart: (args["smart_crop"] as? Bool) ?? false, location: loc)]), files: paths())
        case "downscale_files":
            let f = (args["factor"] as? Double) ?? 0.5
            guard f > 0, f <= 1 else { return (false, "factor must be between 0 and 1") }
            return await finish(Pipeline(steps: [.downscale(factor: f, location: args["output"] as? String)]), files: paths())
        case "convert_files":
            guard let to = args["to"] as? String, !to.isEmpty else { return (false, "to is required") }
            return await finish(Pipeline(steps: [.convert(to: to.lowercased(), location: args["output"] as? String)]), files: paths())
        case "strip_metadata":
            return await finish(Pipeline(steps: [.stripExif]), files: paths())
        case "run_pipeline":
            guard let text = args["pipeline"] as? String else { return (false, "pipeline is required") }
            do {
                let (pipeline, saved) = try Library.resolve(text)
                if let bad = scriptStep(in: pipeline), !Prefs.bool("mcpAllowScriptSteps") { return (false, "The pipeline has a script step (\(bad)). Turn on “Allow agents to write script steps” in Settings › Agents to run it.") }
                var steps = pipeline.steps
                if let s = saved, !s.skipOptimisation { steps.insert(.optimise(encoder: nil, compression: nil, adaptive: nil, dpi: nil, location: nil), at: 0) }
                return await finish(Pipeline(steps: steps), files: paths())
            } catch { return (false, error.localizedDescription) }
        case "save_pipeline":
            guard let n = args["name"] as? String, !n.isEmpty, let s = args["steps"] as? String else { return (false, "name and steps are required") }
            do {
                let p = try PipelineParser.parse(s)
                if let bad = scriptStep(in: p), !Prefs.bool("mcpAllowScriptSteps") { return (false, "The pipeline has a script step (\(bad)). Turn on “Allow agents to write script steps” in Settings › Agents to save it.") }
                try Library.update { lib in
                    lib.pipelines.removeAll { $0.name.caseInsensitiveCompare(n) == .orderedSame }
                    lib.pipelines.append(SavedPipeline(name: n, fileType: (args["file_type"] as? String).flatMap(MediaKind.init(rawValue:)), steps: s))
                }
                return (true, "Saved “\(n)”")
            } catch { return (false, error.localizedDescription) }
        case "list_pipelines":
            let lib = Library.load()
            var out = lib.pipelines.map { "\($0.name): \($0.steps)" }
            out += lib.attachments.map { "attached to \($0.source) (\($0.type.rawValue)): \($0.pipeline)" }
            out += lib.zones.map { "zone \($0.name): \($0.pipeline)" }
            return (true, out.isEmpty ? "No saved pipeline" : out.joined(separator: "\n"))
        case "get_pipeline_guide": return (true, Reference.pipelineGuide)
        case "get_settings": return (true, Prefs.schema())
        case "set_setting":
            guard let k = args["key"] as? String, let v = args["value"] as? String else { return (false, "key and value are required") }
            if let e = Prefs.set(k, v) { return (false, e) }
            return (true, "\(k) = \(Prefs.string(k))")
        case "available_tools":
            return (true, Tool.allCases.map { "\($0.rawValue): \($0.available ? "installed" : "not installed (brew install \($0.formula))") — \($0.purpose)" }.joined(separator: "\n"))
        default: return (false, "Unknown tool")
        }
    }

    static func scriptStep(in p: Pipeline) -> String? {
        for s in p.steps { if case .runScript = s { return "runScript" }; if case .runShortcut = s { return "runShortcut" } }
        return nil
    }

    /// The response for one request, nil for a notification (no `id`).
    static func handle(_ req: [String: Any], call: ([String: Any]) -> (ok: Bool, text: String)) -> [String: Any]? {
        guard let method = req["method"] as? String, let id = req["id"] else { return nil }
        func ok(_ r: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": r] }
        switch method {
        case "initialize":
            let v = (req["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2024-11-05"
            return ok(["protocolVersion": v, "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "shrinkbox", "version": CLI.version]])
        case "ping": return ok([:])
        case "tools/list": return ok(["tools": tools])
        case "tools/call":
            let p = req["params"] as? [String: Any] ?? [:]
            guard let name = p["name"] as? String, tools.contains(where: { $0["name"] as? String == name }) else {
                return ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool"]]
            }
            let r = call(["name": name, "arguments": p["arguments"] as? [String: Any] ?? [:]])
            return ok(["content": [["type": "text", "text": r.text]], "isError": !r.ok])
        default: return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    /// Reads requests on stdin until it closes. Nothing else may ever be written to stdout.
    static func run() {
        AppBundle.shareSettingsWithApp()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let resp = handle(obj) { request in
                let box = ResultBox()
                let sem = DispatchSemaphore(value: 0)
                Task.detached {
                    let r = await call(request["name"] as? String ?? "", request["arguments"] as? [String: Any] ?? [:])
                    box.value = r; sem.signal()
                }
                sem.wait()
                return box.value
            }
            if let resp, let data = try? JSONSerialization.data(withJSONObject: resp), let s = String(data: data, encoding: .utf8) { print(s); fflush(stdout) }
        }
    }

    static func configuration(executable: String) -> String {
        let obj: [String: Any] = ["mcpServers": ["shrinkbox": ["command": executable, "args": ["mcp"]]]]
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: (ok: Bool, text: String) = (false, "")
}
