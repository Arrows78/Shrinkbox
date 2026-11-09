import AppKit
import UniformTypeIdentifiers

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
            pb.writeObjects([imageItem(url)])
        case "markdown":
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            pb.setString("![\(url.deletingPathExtension().lastPathComponent)](\(encoded))", forType: .string)
        default:
            pb.writeObjects([url as NSURL])
            pb.setString(url.path, forType: .string)
        }
    }

    /// One pasteboard item holding the file and its optimised bytes, so the clipboard keeps a single entry
    /// and pastes the compressed data rather than a TIFF re-encoding.
    static func imageItem(_ url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        guard let data = try? Data(contentsOf: url), let type = UTType(filenameExtension: url.pathExtension) else { return item }
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        // Apps that cannot read WebP, AVIF or HEIC still get something to paste.
        if !type.conforms(to: .png), !type.conforms(to: .jpeg), let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        return item
    }

    static func copy(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }
}
