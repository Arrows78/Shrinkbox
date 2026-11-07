import AppKit

/// Reads and writes what the clipboard holds: image data, file lists, text.
@MainActor
enum Clipboard {
    /// Puts a result on the clipboard as a file, image data or a Markdown link.
    static func copy(_ url: URL, format: String, relativeTo: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var path = url.path
        if let base = relativeTo {
            let b = (base as NSString).expandingTildeInPath
            if path.hasPrefix(b) { path = String(path.dropFirst(b.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        }
        switch format {
        case "imageData":
            if let image = NSImage(contentsOf: url) { pb.writeObjects([image]); pb.writeObjects([url as NSURL]) } else { pb.writeObjects([url as NSURL]) }
        case "markdown":
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            pb.setString("![\(url.deletingPathExtension().lastPathComponent)](\(encoded))", forType: .string)
        default:
            pb.writeObjects([url as NSURL])
            pb.setString(url.path, forType: .string)
        }
    }

    static func copy(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }
}
