import Foundation
import UniformTypeIdentifiers

/// The four kinds of file Shrinkbox knows how to shrink.
enum MediaKind: String, CaseIterable, Codable, Sendable {
    case image, video, pdf, audio

    var title: String {
        switch self {
        case .image: L("Images")
        case .video: L("Videos")
        case .pdf: L("PDFs")
        case .audio: L("Audio")
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .pdf: "doc.richtext"
        case .audio: "waveform"
        }
    }
}

enum Media {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "jxl", "bmp", "tif", "tiff"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "m2v", "avi", "mpg", "mpeg"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "caf"]

    static func kind(ofExtension ext: String) -> MediaKind? {
        let e = ext.lowercased()
        if imageExtensions.contains(e) { return .image }
        if videoExtensions.contains(e) { return .video }
        if audioExtensions.contains(e) { return .audio }
        if e == "pdf" { return .pdf }
        return nil
    }

    static func kind(of url: URL) -> MediaKind? { kind(ofExtension: url.pathExtension) }

    /// "jpg" and "jpeg", "tif" and "tiff" are one format.
    static func canonical(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg": "jpeg"
        case "tif": "tiff"
        case "aif": "aiff"
        case "mpeg": "mpg"
        case let e: e
        }
    }

    static func sameFormat(_ a: String, _ b: String) -> Bool { canonical(a) == canonical(b) }

    /// Files to process from a mix of files and folders, optionally recursing and filtering by type.
    static func collect(_ inputs: [URL], recursive: Bool, kinds: Set<MediaKind>? = nil, extensions: Set<String>? = nil, excludedExtensions: Set<String> = []) -> [URL] {
        var out: [URL] = []
        func accept(_ u: URL) -> Bool {
            let ext = canonical(u.pathExtension)
            guard let k = kind(of: u) else { return false }
            if excludedExtensions.contains(ext) { return false }
            if let kinds, !kinds.contains(k) { return false }
            if let extensions, !extensions.contains(ext) { return false }
            return true
        }
        for url in inputs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey]
                let options: FileManager.DirectoryEnumerationOptions = recursive ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
                if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: options) {
                    for case let f as URL in e where accept(f) { out.append(f) }
                }
            } else if accept(url) {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }
}

/// How hard to compress, on the scale of the settings: 5 (best quality) to 100 (smallest file).
enum Level: Equatable, Sendable {
    case lossless
    case adaptive
    case value(Int)

    static let fast = Level.value(30)
    static let smaller = Level.value(70)

    /// "adaptive", "lossless", "fast", "smaller", "<0-100>", "custom:<0-100>" or "<tier>:<0-100>".
    init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "adaptive": self = .adaptive
        case "lossless": self = .lossless
        case "fast": self = .fast
        case "smaller": self = .smaller
        default:
            let tail = t.split(separator: ":").last.map(String.init) ?? t
            guard let n = Int(tail), (0...100).contains(n) else { return nil }
            self = .value(max(5, n))
        }
    }

    var description: String {
        switch self {
        case .lossless: "lossless"
        case .adaptive: "adaptive"
        case .value(let n): "\(n)"
        }
    }

    /// 0 (no loss) ... 1 (strongest compression).
    var strength: Double {
        switch self {
        case .lossless: 0
        case .adaptive: 0.4
        case .value(let n): Double(min(max(n, 0), 100)) / 100
        }
    }

    /// JPEG/HEIC/WebP quality in 0...1.
    var imageQuality: Double {
        switch self {
        case .lossless: 1
        default: max(0.2, 1 - 0.8 * strength)
        }
    }
}

/// Where a processed file goes.
enum Placement: Equatable, Sendable {
    case inPlace
    case sameFolder
    case temporary
    case folder(String)   // a path template

    init(_ text: String) {
        switch text.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
        case "inplace": self = .inPlace
        case "samefolder": self = .sameFolder
        case "temp", "temporary", "temporaryfolder": self = .temporary
        default: self = .folder(text)
        }
    }
}

enum ShrinkError: Error, LocalizedError, Equatable {
    case unsupported(String)
    case missingTool(String, String)   // tool, what needs it
    case failed(String)
    case notSmaller
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupported(let m): m
        case .missingTool(let tool, let why): L("%@ is needed %@. Install it with Homebrew: brew install %@", tool, why, tool)
        case .failed(let m): m
        case .notSmaller: L("Already optimised")
        case .cancelled: L("Cancelled")
        }
    }
}

/// What a step produced.
struct StepOutput: Sendable {
    var url: URL
    var changed: Bool
}

/// Working folder for intermediate files.
enum Workspace {
    static var root: URL {
        if let p = ProcessInfo.processInfo.environment["SHRINKBOX_WORKDIR"] { return URL(fileURLWithPath: p, isDirectory: true) }
        let configured = Prefs.string("workdir")
        let path = configured.isEmpty ? (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/Shrinkbox") : (configured as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func temp(ext: String, name: String? = nil) -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent((name ?? "file") + (ext.isEmpty ? "" : "." + ext))
    }

    /// Deletes the working files older than `days` days. Only what Shrinkbox itself made goes (folders named by a UUID, and
    /// the same inside `backups`): the working directory can be any folder the user picked, with files of their own.
    static func clean(olderThanDays days: Int) {
        guard days > 0 else { return }
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-Double(days) * 86400)
        func sweep(_ folder: URL) {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for item in items where UUID(uuidString: item.lastPathComponent) != nil {
                if let d = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < limit { try? fm.removeItem(at: item) }
            }
        }
        sweep(root)
        sweep(root.appendingPathComponent("backups", isDirectory: true))
    }
}

/// `%f` name, `%e` extension, `%P` parent folder, `%F` full path, date and time tokens, `%r` random letters,
/// `%i` counter, `%z` crop size, `%s` scale factor.
enum NameTemplate {
    static func expand(_ template: String, source: URL, size: String = "", scale: String = "", date: Date = Date(), counter: Int = 1) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        let monthNames = DateFormatter().monthSymbols ?? []
        let weekdays = DateFormatter().weekdaySymbols ?? []
        let hour = c.hour ?? 0
        var out = ""
        var it = template.makeIterator()
        while let ch = it.next() {
            guard ch == "%", let t = it.next() else { out.append(ch); continue }
            switch t {
            case "f": out += source.deletingPathExtension().lastPathComponent
            case "e": out += source.pathExtension
            case "P": out += source.deletingLastPathComponent().path
            case "F": out += source.path
            case "y": out += String(c.year ?? 0)
            case "m": out += two(c.month)
            case "n": out += (c.month.map { monthNames[safe: $0 - 1] } ?? nil) ?? ""
            case "d": out += two(c.day)
            case "w": out += (c.weekday.map { weekdays[safe: $0 - 1] } ?? nil) ?? ""
            case "H": out += two(hour)
            case "M": out += two(c.minute)
            case "S": out += two(c.second)
            case "p": out += hour < 12 ? "AM" : "PM"
            case "r": out += String((0..<5).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement()! })
            case "i": out += String(counter)
            case "z": out += size
            case "s": out += scale
            case "%": out += "%"
            default: out.append("%"); out.append(t)
            }
        }
        return out
    }
}

/// The app bundle the running executable belongs to. Through a symlink (the `shrinkbox` command of Homebrew) macOS
/// does not find it, so the version and the settings domain would be those of a bare tool.
enum AppBundle {
    /// The `.app` that contains `executable`, following symlinks.
    static func locate(executable: URL) -> URL? {
        var url = executable.resolvingSymlinksInPath()
        for _ in 0..<5 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    static var info: [String: Any]? {
        if let i = Bundle.main.infoDictionary, i["CFBundleIdentifier"] != nil { return i }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return locate(executable: exe).flatMap { Bundle(url: $0)?.infoDictionary }
    }

    static var version: String { info?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var identifier: String { info?["CFBundleIdentifier"] as? String ?? "dev.labs.shrinkbox" }

    /// Makes a command run through a symlink read and write the settings of the app.
    static func shareSettingsWithApp() {
        if Bundle.main.bundleIdentifier == nil, let d = UserDefaults(suiteName: identifier) { Prefs.use(d) }
    }
}

extension String {
    /// `~` expanded, keeping a trailing slash: it is what says "this is a folder".
    var expandingTilde: String {
        let e = (self as NSString).expandingTildeInPath
        return hasSuffix("/") && !e.hasSuffix("/") ? e + "/" : e
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

enum Files {
    static func size(_ url: URL) -> Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// `name`, then `name 2`, `name 3`… until free.
    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension(), ext = url.pathExtension
        var n = 2
        while true {
            let candidate = URL(fileURLWithPath: base.path + " \(n)" + (ext.isEmpty ? "" : "." + ext))
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    static func ensureParent(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func copyDates(from src: URL, to dst: URL) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: src.path) else { return }
        var set: [FileAttributeKey: Any] = [:]
        if let c = a[.creationDate] { set[.creationDate] = c }
        if let m = a[.modificationDate] { set[.modificationDate] = m }
        try? FileManager.default.setAttributes(set, ofItemAtPath: dst.path)
    }

    static func human(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "500KB", "10MB", "1.5gb", "123456" to bytes.
    static func parseSize(_ text: String) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(String, Double)] = [("gib", 1_073_741_824), ("mib", 1_048_576), ("kib", 1024), ("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("b", 1)]
        for (u, m) in units where t.hasSuffix(u) {
            if let n = Double(t.dropLast(u.count).trimmingCharacters(in: .whitespaces)) { return Int64(n * m) }
        }
        return Int64(t)
    }
}

/// Places a result next to, over, or away from its source.
enum Output {
    /// The final location of `produced` (a file in the workspace) for a given placement. `template` is a file name
    /// template for `sameFolder` and a path template for a specific folder; `ext` replaces the source's extension
    /// when the format changed.
    static func resolve(source: URL, ext: String, placement: Placement, template: String? = nil, size: String = "", scale: String = "", counter: Int = 1) -> URL {
        let name = source.deletingPathExtension().lastPathComponent
        switch placement {
        case .inPlace:
            // Same format: the file keeps its own name, whatever the case of its extension (IMG_1.JPG): on a
            // case-insensitive volume "IMG_1.jpg" is the file itself and moving the result there would fail.
            if Media.sameFormat(source.pathExtension, ext) { return source }
            return source.deletingPathExtension().appendingPathExtension(ext)
        case .sameFolder:
            let t = (template?.isEmpty == false) ? template! : "%f-optimised"
            var fileName = NameTemplate.expand(t, source: source, size: size, scale: scale, counter: counter)
            if (fileName as NSString).pathExtension.isEmpty { fileName += "." + ext }
            let url = source.deletingLastPathComponent().appendingPathComponent(fileName)
            return Files.uniqueURL(url)
        case .temporary:
            return Workspace.temp(ext: ext, name: name)
        case .folder(let path):
            let expanded = NameTemplate.expand(path.expandingTilde, source: source, size: size, scale: scale, counter: counter)
            var url = URL(fileURLWithPath: expanded)
            var isDir: ObjCBool = false
            if expanded.hasSuffix("/") || (FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue) {
                url = url.appendingPathComponent(name)
            }
            if url.pathExtension.isEmpty { url = url.appendingPathExtension(ext) }
            return Files.uniqueURL(url)
        }
    }

    /// Moves `produced` to `destination`. In place, the original goes to the Trash when the name differs and is replaced otherwise.
    @discardableResult
    static func commit(produced: URL, source: URL, destination: URL, placement: Placement, keepDates: Bool) throws -> URL {
        Files.ensureParent(destination)
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: source.path)   // read before an in-place replace changes the file
        defer {
            if keepDates, let a = attributes {
                var set: [FileAttributeKey: Any] = [:]
                if let c = a[.creationDate] { set[.creationDate] = c }
                if let m = a[.modificationDate] { set[.modificationDate] = m }
                try? fm.setAttributes(set, ofItemAtPath: destination.path)
            }
        }
        if placement == .inPlace {
            if destination.path == source.path {
                _ = try fm.replaceItemAt(source, withItemAt: produced)
            } else {
                try fm.moveItem(at: produced, to: destination)
                try? fm.trashItem(at: source, resultingItemURL: nil)
            }
        } else {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: produced, to: destination)
        }
        return destination
    }
}
