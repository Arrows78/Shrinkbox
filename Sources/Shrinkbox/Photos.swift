import AppKit

/// Images copied from Photos.app are small previews. With this on, Shrinkbox asks Photos (through Apple events, which
/// needs your permission once) for the originals of the selection and optimises those instead.
@MainActor
enum PhotosBridge {
    static let bundleID = "com.apple.Photos"

    static var enabled: Bool { Prefs.bool("enablePhotosIntegration") }

    /// Whether the app in front is Photos.
    static var frontmostIsPhotos: Bool { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID }

    /// AppleScript that exports the originals of the first `count` selected photos into `folder`.
    static func script(folder: String, count: Int) -> String {
        """
        tell application "Photos"
            set sel to selection
            if (count of sel) is 0 then return 0
            set n to (count of sel)
            if n > \(count) then set n to \(count)
            set outFolder to POSIX file "\(folder)" as alias
            export (items 1 thru n of sel) to outFolder with using originals
            return n
        end tell
        """
    }

    /// Exports the selection into a new folder of the workspace and returns the files. Empty when nothing is selected or
    /// the permission was refused.
    static func exportSelection() async -> [URL] {
        let folder = Workspace.temp(ext: "", name: "photos").deletingLastPathComponent()
        let source = script(folder: folder.path, count: max(1, Prefs.int("maxCopiedPhotosCount")))
        let ok: Bool = await Task.detached {
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
            return error == nil
        }.value
        guard ok, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { Media.kind(of: $0) == .image }.sorted { $0.path < $1.path }
    }

    /// The steps that go before the usual optimisation: the longest side is limited when a maximum length is set.
    static func steps() -> [Step] {
        let length = Prefs.int("maxPhotosLength")
        return length > 0 ? [.crop(spec: String(length), longEdge: true, smart: false, location: nil)] : []
    }

    /// "16:9" becomes "9:16" when the setting says portrait, and the other way round.
    static func orient(_ spec: String, as orientation: String, size: (Int, Int)? = nil) -> String {
        guard spec.contains(":"), let parsed = CropSpec.parse(spec), let ratio = parsed.aspect else { return spec }
        let wantsLandscape: Bool
        switch orientation {
        case "landscape": wantsLandscape = true
        case "portrait": wantsLandscape = false
        default: wantsLandscape = size.map { $0.0 >= $0.1 } ?? (ratio >= 1)
        }
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 2 else { return spec }
        let isLandscape = ratio >= 1
        return wantsLandscape == isLandscape ? spec : "\(parts[1]):\(parts[0])"
    }
}
