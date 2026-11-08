import Foundation

/// One setting: where it lives, what it is, and how it is shown. The same table feeds the settings window,
/// the `settings` command of the CLI and the agents' tools.
struct Pref: Sendable {
    enum Kind: Sendable {
        case bool
        case int(ClosedRange<Int>)
        case double(ClosedRange<Double>)
        case text
        case choice([String])
        case multi([String])       // a list of values out of a fixed set, stored comma separated
        case paths                 // a list of folders, stored comma separated
    }

    var key: String
    var title: String
    var help: String = ""
    var group: String
    var section: String
    var kind: Kind
    var defaultValue: String
}

enum Prefs {
    static let placements = ["temporary", "inPlace", "sameFolder", "specificFolder"]
    static let compressionHelp = "adaptive, lossless, fast, smaller, custom:<5-100>, <tier>:<5-100> or <5-100>"
    static let imageFormats = ["webp", "avif", "heic", "jxl", "bmp", "tiff", "png", "jpeg", "gif"]
    static let videoFormats = ["mov", "mp4", "webm", "mkv", "m2v", "avi", "m4v", "mpg"]
    static let audioFormats = ["wav", "aiff", "flac", "ogg"]
    static let corners = ["bottomRight", "bottomLeft", "topRight", "topLeft"]
    static let actionIDs = ["downscale", "compression", "crop", "share", "restoreOptimise", "aggressiveOptimisation", "copyToClipboard", "showInFinder", "quickLook", "saveAs", "targetSize", "airDrop", "addToShelf", "uploadWithDropshare", "compare"]

    static let all: [Pref] = {
        var p: [Pref] = []
        func add(_ key: String, _ title: String, group: String, section: String, _ kind: Pref.Kind, _ def: String, help: String = "") {
            p.append(Pref(key: key, title: title, help: help, group: group, section: section, kind: kind, defaultValue: def))
        }
        // General
        add("stripMetadata", "Strip EXIF metadata", group: "General", section: "Optimisation", .bool, "true", help: "Delete identifiable metadata such as the camera, the location and the date")
        add("preserveColorMetadata", "Preserve color profile metadata", group: "General", section: "Optimisation", .bool, "true", help: "Keep color profile tags when stripping metadata")
        add("preserveDates", "Preserve file creation and modification dates", group: "General", section: "Optimisation", .bool, "true", help: "The optimised file keeps the dates of the original")
        add("optimisedFileProtectionMs", "Re-optimisation loop detection window", group: "General", section: "Optimisation", .int(0...30_000), "3000", help: "In milliseconds. Increase it if files on iCloud Drive get optimised twice")
        add("workdir", "Working directory path", group: "General", section: "Working directory", .text, "", help: "Empty: ~/Library/Caches/Shrinkbox")
        add("workdirCleanupDays", "Delete working files older than", group: "General", section: "Working directory", .int(0...365), "7", help: "In days. 0 keeps everything")
        add("showMenubarIcon", "Menu bar icon", group: "General", section: "Appearance", .bool, "true")
        add("pauseAutomations", "Pause automatic optimisations", group: "General", section: "Appearance", .bool, "false")
        add("allowShrinkboxInScreenshots", "Show Shrinkbox in screenshots", group: "General", section: "Appearance", .bool, "false", help: "Otherwise its windows stay out of screenshots and screen sharing")
        // Clipboard
        add("enableClipboardOptimiser", "Enable clipboard optimiser", group: "Clipboard", section: "Clipboard", .bool, "true", help: "Watch copied data and optimise it automatically")
        add("optimiseTIFF", "TIFF data", group: "Clipboard", section: "Clipboard", .bool, "true", help: "Often from design apps, sometimes better left alone")
        add("optimiseHEICAVIFClipboard", "HEIC and AVIF data", group: "Clipboard", section: "Clipboard", .bool, "false")
        add("optimiseImagePathClipboard", "Image files", group: "Clipboard", section: "Clipboard", .bool, "false", help: "Copying images in the Finder gives file paths instead of image data")
        add("optimiseVideoClipboard", "Video files", group: "Clipboard", section: "Clipboard", .bool, "false")
        add("optimiseAudioClipboard", "Audio files", group: "Clipboard", section: "Clipboard", .bool, "false")
        add("optimisePDFClipboard", "PDF files", group: "Clipboard", section: "Clipboard", .bool, "false")
        add("appendClipboardResults", "Keep all clipboard results", group: "Clipboard", section: "Clipboard", .bool, "false", help: "Show each result instead of replacing the previous one")
        add("accumulateClipboardImages", "Accumulate optimised images in the clipboard", group: "Clipboard", section: "Clipboard", .bool, "true", help: "Each new image is added to a file list so you can paste them all at once")
        add("clipboardAccumulationTimeout", "Accumulation timeout", group: "Clipboard", section: "Clipboard", .int(5...600), "30", help: "In seconds")
        add("useClipboardNameTemplate", "Use a name template for clipboard images", group: "Clipboard", section: "File names", .bool, "false")
        add("clipboardNameTemplate", "Name template for clipboard images", group: "Clipboard", section: "File names", .text, "", help: "Tokens: %y %m %d %H %M %S %r %i")
        add("ignoredApps", "Ignored apps", group: "Clipboard", section: "Ignored apps", .text, "", help: "Bundle identifiers, comma separated. Clipboard optimisation is skipped while one of them is in front")
        // File handling
        for (kind, label) in [("Image", "Images"), ("Video", "Videos"), ("Audio", "Audio"), ("PDF", "PDF")] {
            let g = "File handling"
            add("optimised\(kind)Behaviour", "Optimised file placement", group: g, section: label, .choice(placements), "inPlace", help: "Where the smaller file is saved, and whether it replaces the original")
            if kind != "PDF" {
                add("converted\(kind)Behaviour", "Auto-conversion behaviour", group: g, section: label, .choice(placements), kind == "Image" ? "sameFolder" : "inPlace", help: "Formats that many apps cannot open are converted first")
                add("manualConverted\(kind)Behaviour", "Manual conversion behaviour", group: g, section: label, .choice(placements), "sameFolder", help: "When you pick a new format on a result")
            }
            add("sameFolderNameTemplate\(kind)", "Name template for the same folder", group: g, section: label, .text, "%f-optimised")
            add("specificFolderNameTemplate\(kind)", "Path template for a specific folder", group: g, section: label, .text, "%P/optimised/%f")
            if kind != "PDF" {
                add("convertedSameFolderNameTemplate\(kind)", "Converted name template for the same folder", group: g, section: label, .text, "%f")
                add("convertedSpecificFolderNameTemplate\(kind)", "Converted path template for a specific folder", group: g, section: label, .text, "%P/converted/%f")
            }
        }
        // Images
        add("imageCompression", "Compression", group: "Images", section: "Optimisation rules", .text, "custom:30", help: compressionHelp)
        add("gifFrameDropBehaviour", "GIF frame dropping", group: "Images", section: "Optimisation rules", .choice(["playFaster", "keepDuration"]), "playFaster", help: "Compression above 80% drops every 4th, 3rd or 2nd frame of animated GIFs")
        add("copyImageFilePath", "Copy image paths", group: "Images", section: "File names", .bool, "true", help: "When copying optimised image data, also copy the file path")
        add("formatsToConvertToJPEG", "Convert to JPEG", group: "Images", section: "Compatibility", .multi(["webp", "avif", "heic", "jxl", "bmp", "tiff"]), "avif,bmp,heic,webp")
        add("formatsToConvertToPNG", "Convert to PNG", group: "Images", section: "Compatibility", .multi(["webp", "avif", "heic", "jxl", "bmp", "tiff"]), "tiff")
        add("imageFormatsToSkip", "Ignore images with extension", group: "Images", section: "Watched file filters", .multi(imageFormats), "tiff")
        add("minImageSizeKB", "Minimum file size (KB)", group: "Images", section: "Watched file filters", .int(0...1_000_000), "50")
        add("maxImageSizeMB", "Maximum file size (MB)", group: "Images", section: "Watched file filters", .int(0...100_000), "50")
        add("minImageResolution", "Minimum width and height", group: "Images", section: "Watched file filters", .int(0...20_000), "20")
        add("maxImageResolution", "Maximum width and height (0: none)", group: "Images", section: "Watched file filters", .int(0...100_000), "0")
        add("maxImageFileCount", "Skip when more than this many images arrive at once", group: "Images", section: "Watched file filters", .int(1...10_000), "4")
        add("enableAutomaticImageOptimisations", "Enable image auto-optimiser", group: "Images", section: "Watch paths", .bool, "true")
        add("imageWatchPaths", "Watched folders", group: "Images", section: "Watch paths", .paths, "", help: "Images are optimised as they appear in these folders")
        add("cropPresets", "Crop sizes", group: "Hidden", section: "Crop sizes", .text, "")
        add("shelfApp", "Shelf app", group: "General", section: "Edit with external app", .text, "", help: "Yoink, Dropover, Dockside or Atoll: the one that receives files from “Add to shelf”. Empty: the first one installed")
        add("editorAppImage", "Edit images with", group: "General", section: "Edit with external app", .text, "")
        // Video
        add("videoCompression", "Compression", group: "Video", section: "Optimisation rules", .text, "fast:50", help: compressionHelp)
        add("removeAudioFromVideos", "Remove audio on optimised videos", group: "Video", section: "Optimisation rules", .bool, "false")
        add("capVideoFPS", "Cap frames per second", group: "Video", section: "Optimisation rules", .bool, "true")
        add("targetVideoFPS", "Maximum frame rate", group: "Video", section: "Optimisation rules", .double(1...240), "60")
        add("minVideoFPS", "But no less than", group: "Video", section: "Optimisation rules", .double(1...240), "30")
        add("playbackSpeedFrameBehaviour", "Playback speed change", group: "Video", section: "Optimisation rules", .choice(["keepFrames", "dropFrames"]), "keepFrames", help: "Whether changing speed drops frames or re-times them")
        add("convertAudioToAAC", "Convert audio to AAC", group: "Video", section: "Compatibility", .bool, "false")
        add("formatsToConvertToMP4", "Convert to MP4", group: "Video", section: "Compatibility", .multi(["mov", "webm", "mkv", "m2v", "avi", "m4v", "mpg"]), "m2v,mov,mpg,webm")
        add("videoFormatsToSkip", "Ignore videos with extension", group: "Video", section: "Watched file filters", .multi(videoFormats), "m4v,mkv")
        add("minVideoSizeKB", "Minimum file size (KB)", group: "Video", section: "Watched file filters", .int(0...1_000_000), "200")
        add("maxVideoSizeMB", "Maximum file size (MB)", group: "Video", section: "Watched file filters", .int(0...100_000), "500")
        add("maxVideoFileCount", "Skip when more than this many videos arrive at once", group: "Video", section: "Watched file filters", .int(1...10_000), "1")
        add("enableAutomaticVideoOptimisations", "Enable video auto-optimiser", group: "Video", section: "Watch paths", .bool, "true")
        add("videoWatchPaths", "Watched folders", group: "Video", section: "Watch paths", .paths, "")
        add("editorAppVideo", "Edit videos with", group: "General", section: "Edit with external app", .text, "")
        // Audio
        add("audioCompression", "Compression", group: "Audio", section: "Optimisation rules", .text, "custom:34", help: "WAV, AIFF and FLAC are lossless: the factor does not apply to them")
        add("audioCoverArt", "Cover art", group: "Audio", section: "Optimisation rules", .choice(["optimise", "remove", "keep"]), "optimise")
        add("formatsToConvertToAAC", "Convert to AAC (M4A)", group: "Audio", section: "Compatibility", .multi(audioFormats), "aiff,flac,wav")
        add("formatsToConvertToMP3", "Convert to MP3", group: "Audio", section: "Compatibility", .multi(audioFormats), "wav")
        add("minAudioSizeKB", "Minimum file size (KB)", group: "Audio", section: "Watched file filters", .int(0...1_000_000), "0")
        add("maxAudioSizeMB", "Maximum file size (MB)", group: "Audio", section: "Watched file filters", .int(0...100_000), "100")
        add("maxAudioFileCount", "Skip when more than this many files arrive at once", group: "Audio", section: "Watched file filters", .int(1...10_000), "2")
        add("enableAutomaticAudioOptimisations", "Enable audio auto-optimiser", group: "Audio", section: "Watch paths", .bool, "false")
        add("audioWatchPaths", "Watched folders", group: "Audio", section: "Watch paths", .paths, "")
        add("editorAppAudio", "Edit audio with", group: "General", section: "Edit with external app", .text, "")
        // PDF
        add("pdfDPI", "Image resolution (0: automatic)", group: "PDF", section: "Optimisation rules", .int(0...600), "0", help: "300 leaves images alone, 72 suits screens, 48 is the smallest")
        add("minPDFSizeKB", "Minimum file size (KB)", group: "PDF", section: "Watched file filters", .int(0...1_000_000), "0")
        add("maxPDFSizeMB", "Maximum file size (MB)", group: "PDF", section: "Watched file filters", .int(0...100_000), "100")
        add("maxPDFFileCount", "Skip when more than this many PDFs arrive at once", group: "PDF", section: "Watched file filters", .int(1...10_000), "2")
        add("enableAutomaticPDFOptimisations", "Enable PDF auto-optimiser", group: "PDF", section: "Watch paths", .bool, "true")
        add("pdfWatchPaths", "Watched folders", group: "PDF", section: "Watch paths", .paths, "")
        add("editorAppPDF", "Edit PDFs with", group: "General", section: "Edit with external app", .text, "")
        // Drop zone
        add("enableDropZone", "Enable drop zone", group: "Drop Zone", section: "Drop zone", .bool, "true", help: "Drag files, paths and links to a global drop zone")
        add("onlyShowDropZoneOnOption", "Require pressing ⌥ Option to show the drop zone", group: "Drop Zone", section: "Drop zone", .bool, "false")
        add("autoCopyToClipboard", "Copy optimised files to the clipboard", group: "Drop Zone", section: "Drop zone", .bool, "true", help: "So they can be pasted right after the optimisation ends")
        add("useBatchMode", "Use batch mode for large drops", group: "Drop Zone", section: "Batch mode", .bool, "true", help: "Originals are backed up first and can be restored")
        add("batchModeFileCountThreshold", "Batch mode file threshold", group: "Drop Zone", section: "Batch mode", .int(2...1000), "30")
        add("onlyShowPresetZonesOnControlTapped", "Keep preset zones up after tapping Control", group: "Drop Zone", section: "Preset zones", .bool, "false")
        // Floating results
        add("enableFloatingResults", "Show floating results", group: "Floating Results", section: "Floating results", .bool, "true", help: "Off: Shrinkbox keeps optimising in the background without any window")
        add("floatingResultsCorner", "Position on screen", group: "Floating Results", section: "Layout", .choice(corners), "bottomRight")
        add("followCursorScreen", "Follow the cursor across screens", group: "Floating Results", section: "Layout", .bool, "true")
        add("alwaysShowCompactResults", "Always use the compact layout", group: "Floating Results", section: "Layout", .bool, "false", help: "Otherwise it switches to compact with more than 5 results")
        add("hideFloatingResultTooltips", "Hide button tooltips", group: "Floating Results", section: "Layout", .bool, "false")
        add("autoHideFloatingResults", "Auto hide floating results", group: "Floating Results", section: "Timing", .bool, "true")
        add("autoHideFloatingResultsAfter", "Hide file results after", group: "Floating Results", section: "Timing", .int(2...3600), "30", help: "In seconds")
        add("autoHideClipboardResultAfter", "Hide clipboard results after", group: "Floating Results", section: "Timing", .int(2...3600), "10", help: "In seconds")
        add("autoClearAllCompactResultsAfter", "Clear all compact results after", group: "Floating Results", section: "Timing", .int(5...7200), "120", help: "In seconds")
        add("floatingResultActions", "Action buttons", group: "Floating Results", section: "Buttons", .multi(actionIDs), "downscale,compression,crop,share,restoreOptimise")
        // Agents
        add("mcpAcceptChanges", "Accept changes from agents", group: "Agents", section: "MCP", .bool, "true", help: "Optimising files, changing settings, saving pipelines. Reading stays allowed either way")
        add("mcpAllowScriptSteps", "Allow agents to write script steps", group: "Agents", section: "MCP", .bool, "false", help: "A script step runs arbitrary code")
        return p
    }()

    static let byKey: [String: Pref] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    nonisolated(unsafe) private static var store: UserDefaults = .standard

    /// A test or a tool can point settings at another store.
    static func use(_ defaults: UserDefaults) { store = defaults }

    static func string(_ key: String) -> String {
        if let v = store.object(forKey: key) { return v as? String ?? "\(v)" }
        return byKey[key]?.defaultValue ?? ""
    }

    static func bool(_ key: String) -> Bool {
        if let v = store.object(forKey: key) as? Bool { return v }
        if let s = store.object(forKey: key) as? String { return s == "true" }
        return byKey[key]?.defaultValue == "true"
    }

    static func int(_ key: String) -> Int { Int(string(key)) ?? Int(byKey[key]?.defaultValue ?? "") ?? 0 }
    static func double(_ key: String) -> Double { Double(string(key)) ?? Double(byKey[key]?.defaultValue ?? "") ?? 0 }
    static func list(_ key: String) -> [String] { string(key).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    /// Validates against the setting's kind, then stores. Returns an error message when the value is refused.
    @discardableResult
    static func set(_ key: String, _ value: String) -> String? {
        guard let pref = byKey[key] else { return L("Unknown setting “%@”", key) }
        let v = value.trimmingCharacters(in: .whitespaces)
        switch pref.kind {
        case .bool:
            guard ["true", "false"].contains(v.lowercased()) else { return L("%@ must be true or false", key) }
            store.set(v.lowercased() == "true", forKey: key)
        case .int(let r):
            guard let n = Int(v), r.contains(n) else { return L("%@ must be a whole number from %d to %d", key, r.lowerBound, r.upperBound) }
            store.set(String(n), forKey: key)
        case .double(let r):
            guard let n = Double(v), r.contains(n) else { return L("%@ must be a number from %g to %g", key, r.lowerBound, r.upperBound) }
            store.set(String(n), forKey: key)
        case .choice(let options):
            guard options.contains(v) else { return L("%@ must be one of: %@", key, options.joined(separator: ", ")) }
            store.set(v, forKey: key)
        case .multi(let options):
            let items = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let extra = key == "floatingResultActions" ? Set(Builtins.buttonOptions()) : []
            if let bad = items.first(where: { !options.contains($0) && !extra.contains($0) }) { return L("%@: “%@” is not one of: %@", key, bad, options.joined(separator: ", ")) }
            store.set(items.joined(separator: ","), forKey: key)
        case .paths, .text:
            if key == "imageCompression" || key == "videoCompression" || key == "audioCompression", Level(v) == nil { return L("%@ must be %@", key, compressionHelp) }
            store.set(v, forKey: key)
        }
        NotificationCenter.default.post(name: .settingsChanged, object: key)
        return nil
    }

    static func reset(_ key: String) { store.removeObject(forKey: key); NotificationCenter.default.post(name: .settingsChanged, object: key) }
    static func resetAll() { for p in all { store.removeObject(forKey: p.key) }; NotificationCenter.default.post(name: .settingsChanged, object: nil) }

    /// A readable dump of every setting, grouped, for the `settings schema` command.
    static func schema() -> String {
        var out = ""
        for p in all {
            out += "\(p.title)  [\(p.group) > \(p.section)]\n"
            if !p.help.isEmpty { out += "  \(p.help)\n" }
            var options = ""
            switch p.kind {
            case .bool: options = "   one of: true, false"
            case .choice(let o), .multi(let o): options = "   one of: " + o.joined(separator: ", ")
            case .int(let r): options = "   \(r.lowerBound)...\(r.upperBound)"
            case .double(let r): options = "   \(r.lowerBound)...\(r.upperBound)"
            case .text, .paths: break
            }
            out += "  \(p.key) = \(string(p.key))\(options)\n\n"
        }
        return out
    }

    // MARK: Typed access used by the engines

    static var imageLevel: Level { Level(string("imageCompression")) ?? .value(30) }
    static var videoLevel: Level { Level(string("videoCompression")) ?? .value(50) }
    static var audioLevel: Level { Level(string("audioCompression")) ?? .value(34) }

    static func level(for kind: MediaKind) -> Level {
        switch kind { case .image: imageLevel; case .video: videoLevel; case .audio: audioLevel; case .pdf: .value(50) }
    }

    static func kindName(_ kind: MediaKind) -> String {
        switch kind { case .image: "Image"; case .video: "Video"; case .audio: "Audio"; case .pdf: "PDF" }
    }

    static func placement(optimised kind: MediaKind) -> Placement {
        Placement(string("optimised\(kindName(kind))Behaviour") == "specificFolder" ? specificFolder(kind, converted: false) : string("optimised\(kindName(kind))Behaviour"))
    }

    static func specificFolder(_ kind: MediaKind, converted: Bool) -> String {
        string((converted ? "convertedSpecificFolderNameTemplate" : "specificFolderNameTemplate") + kindName(kind))
    }

    static func placement(converted kind: MediaKind, manual: Bool) -> Placement {
        let key = (manual ? "manualConverted" : "converted") + kindName(kind) + "Behaviour"
        let v = string(key)
        return Placement(v == "specificFolder" ? specificFolder(kind, converted: true) : v)
    }

    static func nameTemplate(_ kind: MediaKind, converted: Bool) -> String {
        string((converted ? "convertedSameFolderNameTemplate" : "sameFolderNameTemplate") + kindName(kind))
    }

    static func watchPaths(_ kind: MediaKind) -> [String] { list("\(kind.rawValue)WatchPaths") }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("shrinkbox.settingsChanged")
}
