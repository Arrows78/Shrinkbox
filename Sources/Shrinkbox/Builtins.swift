import AppKit

/// A ready-made pipeline, shown in the menus and available as a button on a result.
struct BuiltinPipeline: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let kind: MediaKind
    let steps: String
    let about: String
}

enum Builtins {
    static let all: [BuiltinPipeline] = [
        BuiltinPipeline(id: "builtin-image-webp", title: L("Convert to WebP"), symbol: "globe", kind: .image, steps: "convert(to: webp)", about: L("Smaller images for the web")),
        BuiltinPipeline(id: "builtin-image-sort-screenshots", title: L("Sort screenshots"), symbol: "camera.viewfinder", kind: .image,
                        steps: "if(regex: \"^(screen ?shot|capture|cleanshot)\") -> optimise -> move(to: \"~/Pictures/Screenshots/%y/%m/\")", about: L("Move screenshots into Pictures/Screenshots by year and month")),
        BuiltinPipeline(id: "builtin-image-half", title: L("Half size"), symbol: "arrow.down.right.and.arrow.up.left", kind: .image, steps: "downscale(factor: 0.5)", about: L("Scale the image down to half its size")),
        BuiltinPipeline(id: "builtin-image-watermark", title: L("Watermark"), symbol: "drop.halffull", kind: .image, steps: "watermark(image: \"%P/watermark.png\", position: bottomRight) -> optimise", about: L("Overlay watermark.png from the same folder")),
        BuiltinPipeline(id: "builtin-video-1080p", title: L("1080p"), symbol: "tv", kind: .video, steps: "crop(width: 1920) -> optimise", about: L("Resize to 1920 pixels wide and optimise")),
        BuiltinPipeline(id: "builtin-video-to-gif", title: L("Video to GIF"), symbol: "photo.stack", kind: .video, steps: "crop(longEdge: 800) -> convert(to: gif)", about: L("Crop to 800px and convert to an animated GIF")),
        BuiltinPipeline(id: "builtin-video-2x-silent", title: L("2× and silent"), symbol: "forward.fill", kind: .video, steps: "changeSpeed(factor: 2.0, frames: drop) -> removeAudio -> optimise", about: L("Double the playback speed and remove the audio")),
        BuiltinPipeline(id: "builtin-video-half", title: L("Half size"), symbol: "arrow.down.right.and.arrow.up.left", kind: .video, steps: "downscale(factor: 0.5)", about: L("Scale the video down to half its size")),
        BuiltinPipeline(id: "builtin-video-watermark", title: L("Watermark"), symbol: "drop.halffull", kind: .video, steps: "watermark(image: \"%P/watermark.png\", position: bottomRight) -> optimise", about: L("Overlay watermark.png from the same folder")),
        BuiltinPipeline(id: "builtin-pdf-as-images", title: L("Pages as images"), symbol: "doc.on.doc", kind: .pdf, steps: "extractPagesAsImages(format: jpeg, quality: high)", about: L("Render each page to a JPEG")),
        BuiltinPipeline(id: "builtin-audio-to-mp3", title: L("Convert to MP3"), symbol: "music.note", kind: .audio, steps: "convert(to: mp3) -> lowerBitrate(kbps: 128)", about: L("Convert any audio file to MP3 at 128 kbps")),
    ]

    static func find(_ id: String) -> BuiltinPipeline? { all.first { $0.id == id } }
    static func pipelines(for kind: MediaKind) -> [BuiltinPipeline] { all.filter { $0.kind == kind } }

    /// "pipeline:image=builtin-image-webp" and "pipeline:video=My pipeline" are the ids of a button of a result.
    static func actionID(kind: MediaKind, pipeline: String) -> String { "pipeline:\(kind.rawValue)=\(pipeline)" }

    static func parseAction(_ id: String) -> (kind: MediaKind, pipeline: String)? {
        guard id.hasPrefix("pipeline:") else { return nil }
        let body = id.dropFirst("pipeline:".count)
        guard let eq = body.firstIndex(of: "="), let kind = MediaKind(rawValue: String(body[..<eq])) else { return nil }
        return (kind, String(body[body.index(after: eq)...]))
    }

    /// Every id a button of a result can take, the built-in pipelines and the saved ones included.
    static func buttonOptions() -> [String] {
        var ids = Prefs.actionIDs
        ids += all.map { actionID(kind: $0.kind, pipeline: $0.id) }
        for p in Library.load().pipelines {
            let kinds: [MediaKind] = p.fileType.map { [$0] } ?? MediaKind.allCases
            for k in kinds { ids.append(actionID(kind: k, pipeline: p.name)) }
        }
        return ids
    }

    /// A readable name for a button id.
    static func label(forAction id: String) -> String? {
        guard let (kind, name) = parseAction(id) else { return nil }
        let title = find(name)?.title ?? name
        return "\(title) (\(kind.title.lowercased()))"
    }
}

/// Apps that keep files on a shelf while you drag them somewhere, and the one that uploads them.
enum ShelfApps {
    struct App: Identifiable, Hashable, Sendable {
        let name: String
        var id: String { name }
    }

    static let known = ["Yoink", "Dropover", "Dockside", "Atoll"]
    static let uploader = "Dropshare"

    private static func find(_ names: [String]) -> [String: URL] {
        var out: [String: URL] = [:]
        let folders = ["/Applications", "/Applications/Setapp", (NSHomeDirectory() as NSString).appendingPathComponent("Applications"), "/System/Applications"]
        for name in names {
            for dir in folders {
                for candidate in [name, "\(name) 5", "\(name) Demo"] {
                    let url = URL(fileURLWithPath: dir).appendingPathComponent(candidate + ".app")
                    if FileManager.default.fileExists(atPath: url.path) { out[name] = url; break }
                }
                if out[name] != nil { break }
            }
        }
        return out
    }

    static func installed() -> [String] { let f = find(known); return known.filter { f[$0] != nil } }
    static var dropshare: URL? { find([uploader])[uploader] }

    /// The shelf app set in the settings, or the first one installed.
    static var current: String? {
        let chosen = Prefs.string("shelfApp")
        let apps = installed()
        if !chosen.isEmpty, apps.contains(chosen) { return chosen }
        return apps.first
    }

    @MainActor
    static func shelve(_ files: [URL], with name: String? = nil) {
        guard let app = (name ?? current).flatMap({ find([$0])[$0] }) else { return }
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @MainActor
    static func upload(_ files: [URL]) {
        guard let app = dropshare else { return }
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Opens files with a named app, whether it is a shelf app, the uploader or any app on the Mac.
    @MainActor
    static func open(_ files: [URL], with name: String) {
        let found = find([name, name.replacingOccurrences(of: " ", with: "")])
        if let url = found.values.first { NSWorkspace.shared.open(files, withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration()); return }
        Task { _ = try? await Run.process(URL(fileURLWithPath: "/usr/bin/open"), ["-a", name] + files.map(\.path)) }
    }
}

@MainActor
enum AirDrop {
    static func send(_ files: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else { NSSound.beep(); return }
        service.perform(withItems: files)
    }
}
