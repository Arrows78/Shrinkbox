import AppKit
import CoreServices
import ImageIO

/// Watches folders with FSEvents and hands new files to the optimiser once they stop growing.
@MainActor
final class FolderWatcher {
    static let shared = FolderWatcher()
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var pending: [String: (size: Int64, since: Date)] = [:]
    private var settle: Timer?
    private var recent: [(Date, MediaKind)] = []

    func start() {
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { _ in MainActor.assumeIsolated { FolderWatcher.shared.reload() } }
        NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { _ in MainActor.assumeIsolated { FolderWatcher.shared.reload() } }
        reload()
        settle = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in MainActor.assumeIsolated { FolderWatcher.shared.checkPending() } }
    }

    static func folders() -> [String] {
        var all = Set<String>()
        for k in MediaKind.allCases { for p in Prefs.watchPaths(k) { all.insert((p as NSString).expandingTildeInPath) } }
        for a in Library.load().attachments where !["clipboard", "dropzone"].contains(a.source.lowercased()) { all.insert((a.source as NSString).expandingTildeInPath) }
        return all.sorted()
    }

    func reload() {
        let folders = Self.folders().filter { FileManager.default.fileExists(atPath: $0) }
        guard folders != watched else { return }
        watched = folders
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        guard !folders.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            var changed: [String] = []
            for i in 0..<count {
                let f = flags[i]
                if f & UInt32(kFSEventStreamEventFlagItemIsFile) != 0, f & (UInt32(kFSEventStreamEventFlagItemCreated) | UInt32(kFSEventStreamEventFlagItemRenamed) | UInt32(kFSEventStreamEventFlagItemModified)) != 0 { changed.append(list[i]) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { me.saw(changed) } }
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, folders as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let s = stream { FSEventStreamSetDispatchQueue(s, .main); FSEventStreamStart(s) }
    }

    private func saw(_ paths: [String]) {
        for p in paths where pending[p] == nil && FileManager.default.fileExists(atPath: p) { pending[p] = (-1, Date()) }
    }

    /// A file is ready when its size has not moved since the last look: downloads and screenshots are written in pieces.
    private func checkPending() {
        guard !pending.isEmpty else { return }
        var ready: [URL] = []
        for (path, info) in pending {
            let size = Files.size(URL(fileURLWithPath: path))
            if !FileManager.default.fileExists(atPath: path) { pending[path] = nil; continue }
            if size == info.size, size > 0 { ready.append(URL(fileURLWithPath: path)); pending[path] = nil }
            else if Date().timeIntervalSince(info.since) > 600 { pending[path] = nil }
            else { pending[path] = (size, info.since) }
        }
        guard !ready.isEmpty, !Prefs.bool("pauseAutomations") else { return }
        handle(ready)
    }

    private func handle(_ urls: [URL]) {
        // Group by folder and kind: "N files at once" is a limit per kind.
        var byKind: [MediaKind: [(URL, String)]] = [:]
        for u in urls {
            guard !u.lastPathComponent.hasPrefix("."), let kind = Media.kind(of: u), !Protection.shared.isProtected(u) else { continue }
            guard let folder = watchedFolder(containing: u) else { continue }
            guard Prefs.bool("enableAutomatic\(Prefs.kindName(kind))Optimisations") || hasAttachment(folder: folder, kind: kind) else { continue }
            guard Prefs.watchPaths(kind).map({ ($0 as NSString).expandingTildeInPath }).contains(folder) || hasAttachment(folder: folder, kind: kind) else { continue }
            byKind[kind, default: []].append((u, folder))
        }
        for (kind, list) in byKind {
            let files = list.map(\.0).filter { passesFilters($0, kind: kind) }
            guard !files.isEmpty, files.count <= Prefs.int("max\(Prefs.kindName(kind))FileCount") || Prefs.int("max\(Prefs.kindName(kind))FileCount") == 0 else { continue }
            let folder = list[0].1
            ResultsModel.shared.enqueue(files, source: .folder(folder))
        }
    }

    private func watchedFolder(containing u: URL) -> String? {
        let p = u.deletingLastPathComponent().path
        return watched.filter { p == $0 || p.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    private func hasAttachment(folder: String, kind: MediaKind) -> Bool {
        !Library.attached(to: .folder(folder), kind: kind).isEmpty
    }

    /// Size and resolution bounds, and the extensions to leave alone.
    func passesFilters(_ url: URL, kind: MediaKind) -> Bool {
        let name = Prefs.kindName(kind)
        let ext = Media.canonical(url.pathExtension)
        if Prefs.list("\(kind.rawValue)FormatsToSkip").contains(ext) || Prefs.list("\(name.lowercased())FormatsToSkip").contains(ext) { return false }
        let size = Files.size(url)
        let minKB = Int64(Prefs.int("min\(name)SizeKB")), maxMB = Int64(Prefs.int("max\(name)SizeMB"))
        if size < minKB * 1000 { return false }
        if maxMB > 0, size > maxMB * 1_000_000 { return false }
        if kind == .image || kind == .video {
            if kind == .image, let src = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
                let minR = Prefs.int("minImageResolution"), maxR = Prefs.int("maxImageResolution")
                if min(w, h) < minR { return false }
                if maxR > 0, max(w, h) > maxR { return false }
            }
        }
        return true
    }
}

/// Looks at the pasteboard for something to optimise: image data, or copied files when allowed.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var accumulated: [URL] = []
    private var lastAccumulation = Date.distantPast
    private var ownChange = -1

    func start() { timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { ClipboardWatcher.shared.tick() } } }

    /// Puts files on the clipboard without Shrinkbox looking at them again.
    func write(_ urls: [URL], image: NSImage?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let image, urls.count == 1 { pb.writeObjects([image]) }
        pb.writeObjects(urls as [NSURL])
        ownChange = pb.changeCount; lastChange = pb.changeCount
    }

    private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard pb.changeCount != ownChange, Prefs.bool("enableClipboardOptimiser"), !Prefs.bool("pauseAutomations") else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if Prefs.list("ignoredApps").contains(front) { return }
        let copiedBy = NSWorkspace.shared.frontmostApplication?.localizedName
        let types = pb.types ?? []
        // Files copied in the Finder.
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            let allowed = files.filter { u in
                guard let k = Media.kind(of: u), !Protection.shared.isProtected(u) else { return false }
                switch k {
                case .image: return Prefs.bool("optimiseImagePathClipboard")
                case .video: return Prefs.bool("optimiseVideoClipboard")
                case .audio: return Prefs.bool("optimiseAudioClipboard")
                case .pdf: return Prefs.bool("optimisePDFClipboard")
                }
            }
            if !allowed.isEmpty {
                ResultsModel.shared.enqueue(allowed, source: .clipboard, copiedBy: copiedBy, forceTemporary: true, clipboard: true) { _, _ in
                    let outs = ResultsModel.shared.items.filter { $0.isClipboard }.compactMap { $0.outcome?.output }
                    ClipboardWatcher.shared.write(outs, image: nil)
                }
            }
            return
        }
        // Image data.
        let image: (NSPasteboard.PasteboardType, String)? = types.contains(.png) ? (.png, "png") : types.contains(.tiff) ? (.tiff, "tiff") : types.first(where: { $0.rawValue == "public.jpeg" }) != nil ? (NSPasteboard.PasteboardType("public.jpeg"), "jpg") : nil
        guard let (type, ext) = image, let data = pb.data(forType: type) else { return }
        if ext == "tiff", !Prefs.bool("optimiseTIFF") { return }
        let heic = types.contains(where: { $0.rawValue == "public.heic" || $0.rawValue == "public.avif" })
        if heic, !Prefs.bool("optimiseHEICAVIFClipboard") { return }
        let name = Prefs.bool("useClipboardNameTemplate") && !Prefs.string("clipboardNameTemplate").isEmpty
            ? NameTemplate.expand(Prefs.string("clipboardNameTemplate"), source: URL(fileURLWithPath: "/clipboard.\(ext)"))
            : "clipboard"
        let file = Workspace.temp(ext: ext == "tiff" ? "png" : ext, name: name)
        if ext == "tiff", let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: file) } else { try? data.write(to: file) }
        let accumulate = Prefs.bool("accumulateClipboardImages") && Date().timeIntervalSince(lastAccumulation) < Double(Prefs.int("clipboardAccumulationTimeout"))
        if !Prefs.bool("appendClipboardResults") { for old in ResultsModel.shared.items.filter({ $0.isClipboard && !$0.isBusy }) { ResultsModel.shared.dismiss(old) } }
        ResultsModel.shared.enqueue([file], source: .clipboard, copiedBy: copiedBy, forceTemporary: true, clipboard: true) { [weak self] item, outcome in
            guard let self else { return }
            if accumulate { self.accumulated.append(outcome.output) } else { self.accumulated = [outcome.output] }
            self.lastAccumulation = Date()
            let img = NSImage(contentsOf: outcome.output)
            self.write(Prefs.bool("accumulateClipboardImages") ? self.accumulated : [outcome.output], image: Prefs.bool("accumulateClipboardImages") && self.accumulated.count > 1 ? nil : img)
            if Prefs.bool("copyImageFilePath"), self.accumulated.count == 1 { NSPasteboard.general.setString(outcome.output.path, forType: .string); self.ownChange = NSPasteboard.general.changeCount; self.lastChange = self.ownChange }
        }
    }
}
