import Foundation

/// A pipeline saved by name.
struct SavedPipeline: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var fileType: MediaKind?
    var steps: String
    var skipOptimisation = false
    var hideResult = false
    var id: String { name.lowercased() }
}

/// A pipeline that runs by itself on files from a source.
struct Attachment: Codable, Equatable, Sendable {
    var source: String          // "clipboard", "dropZone" or a folder path
    var type: MediaKind
    var pipeline: String        // a saved pipeline's name, or inline steps
    var inline: Bool
    var skipOptimisation = false
    var hideResult = false
}

/// A zone shown when dragging a file with Control held; dropping on it runs its pipeline.
struct PresetZone: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var pipeline: String
    var inline: Bool
    var type: MediaKind?
    var icon = "wand.and.stars"
    var skipOptimisation = false
    var hideResult = false
    var id: String { name.lowercased() + "/" + (type?.rawValue ?? "all") }
}

/// The library lives in one JSON file so the CLI, the app and the agents' tools all see the same thing.
enum Library {
    struct Content: Codable, Sendable {
        var pipelines: [SavedPipeline] = []
        var attachments: [Attachment] = []
        var zones: [PresetZone] = []
    }

    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["SHRINKBOX_LIBRARY"] { return URL(fileURLWithPath: p) }
        return URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Shrinkbox/library.json"))
    }

    static func load() -> Content {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Content.self, from: d) else { return Content() }
        return c
    }

    static func save(_ c: Content) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(c).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
    }

    static func update(_ change: (inout Content) throws -> Void) throws {
        var c = load()
        try change(&c)
        try save(c)
    }

    /// A pipeline given by name or id, or inline steps.
    static func resolve(_ text: String, library: Content = load()) throws -> (pipeline: Pipeline, saved: SavedPipeline?) {
        if let s = library.pipelines.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) { return (try PipelineParser.parse(s.steps), s) }
        if let b = Builtins.find(text) { return (try PipelineParser.parse(b.steps), SavedPipeline(name: b.id, fileType: b.kind, steps: b.steps, skipOptimisation: true)) }
        return (try PipelineParser.parse(text), nil)
    }

    /// The pipelines that run on its own for a file coming from a source.
    static func attached(to source: PipelineSource, kind: MediaKind, library: Content = load()) -> [Attachment] {
        let key: String
        switch source {
        case .clipboard: key = "clipboard"
        case .dropZone: key = "dropzone"
        case .folder(let p): key = (p as NSString).standardizingPath.lowercased()
        default: return []
        }
        return library.attachments.filter {
            $0.type == kind && (($0.source as NSString).expandingTildeInPath as NSString).standardizingPath.lowercased() == key || ($0.type == kind && $0.source.lowercased() == key)
        }
    }

    /// The steps a file gets from a source: the implicit optimisation (and auto-conversion), then attached pipelines.
    static func pipelines(for file: URL, kind: MediaKind, source: PipelineSource) -> [(Pipeline, Bool)] {
        var out: [(Pipeline, Bool)] = []
        let attached = attached(to: source, kind: kind)
        let ext = Media.canonical(file.pathExtension)
        var implicit: [Step] = []
        // Formats that many apps cannot open are converted before they are optimised.
        switch kind {
        case .image:
            if Prefs.list("formatsToConvertToJPEG").contains(ext) { implicit.append(.convert(to: "jpeg", location: placementText(Prefs.placement(converted: .image, manual: false)))) }
            else if Prefs.list("formatsToConvertToPNG").contains(ext) { implicit.append(.convert(to: "png", location: placementText(Prefs.placement(converted: .image, manual: false)))) }
        case .video:
            if Prefs.list("formatsToConvertToMP4").contains(ext) { implicit.append(.convert(to: "mp4", location: placementText(Prefs.placement(converted: .video, manual: false)))) }
        case .audio:
            if Prefs.list("formatsToConvertToMP3").contains(ext) { implicit.append(.convert(to: "mp3", location: placementText(Prefs.placement(converted: .audio, manual: false)))) }
            else if Prefs.list("formatsToConvertToAAC").contains(ext) { implicit.append(.convert(to: "m4a", location: placementText(Prefs.placement(converted: .audio, manual: false)))) }
        case .pdf: break
        }
        let skip = !attached.isEmpty && attached.allSatisfy { $0.skipOptimisation }
        if !skip {
            let placement = Prefs.placement(optimised: kind)
            implicit.append(.optimise(encoder: nil, compression: nil, adaptive: nil, dpi: nil, location: placementText(placement)))
            out.append((Pipeline(steps: implicit), false))
        } else if !implicit.isEmpty { out.append((Pipeline(steps: implicit), false)) }
        for a in attached {
            if let r = try? resolve(a.pipeline) { out.append((r.pipeline, a.hideResult)) }
        }
        return out
    }

    static func placementText(_ p: Placement) -> String? {
        switch p {
        case .inPlace: return nil
        case .sameFolder: return "sameFolder"
        case .temporary: return "temporary"
        case .folder(let t): return t
        }
    }
}

extension Notification.Name {
    static let libraryChanged = Notification.Name("shrinkbox.libraryChanged")
}
