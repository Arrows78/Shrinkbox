import AppKit
import AVFoundation
import PDFKit
import ImageIO

/// One file on its way through Shrinkbox, as the floating results show it.
@MainActor
final class ResultItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case waiting
        case running(Double)
        case done
        case failed(String)
        case skipped(String)
        case restored
    }

    let id = UUID()
    let source: PipelineSource
    let file: URL
    let kind: MediaKind
    var isClipboard = false
    var fromPhotos = false
    var createdAt = Date()
    @Published var state: State = .waiting
    @Published var outcome: Outcome?
    @Published var thumbnail: NSImage?
    @Published var label: String?            // what a re-run is doing, "Downscaling to 50%"
    var task: Task<Void, Never>?
    var hideTask: Task<Void, Never>?

    init(file: URL, kind: MediaKind, source: PipelineSource) { self.file = file; self.kind = kind; self.source = source }

    /// The file as it is now.
    var current: URL { outcome?.output ?? file }
    var isBusy: Bool { switch state { case .waiting, .running: true; default: false } }
    var progress: Double? { if case .running(let p) = state { p } else { nil } }
}

@MainActor
final class ResultsModel: ObservableObject {
    static let shared = ResultsModel()
    @Published var items: [ResultItem] = []
    /// The card under the pointer, for the keys that act on it.
    var hovered: UUID?
    /// Called after each change so the panel can resize and place itself.
    var changed: (() -> Void)?

    var compact: Bool { Prefs.bool("alwaysShowCompactResults") || items.count > 5 }

    // MARK: Adding work

    @discardableResult
    func enqueue(_ urls: [URL], source: PipelineSource, copiedBy: String? = nil, forceTemporary: Bool = false, clipboard: Bool = false,
                 completion: (@MainActor (ResultItem, Outcome) -> Void)? = nil) -> [ResultItem] {
        if urls.count > Prefs.int("batchModeFileCountThreshold"), Prefs.bool("useBatchMode"), !clipboard {
            BatchManager.shared.start(urls, source: source)
            return []
        }
        var created: [ResultItem] = []
        for (i, url) in urls.enumerated() {
            guard let kind = Media.kind(of: url) else { continue }
            let item = ResultItem(file: url, kind: kind, source: source)
            item.isClipboard = clipboard
            items.append(item)
            created.append(item)
            Thumbnails.make(for: url, kind: kind) { [weak item] image in item?.thumbnail = image }
            item.task = Task { [weak self, weak item] in
                guard let item else { return }
                do {
                    item.state = .running(0)
                    let outcome = try await Optimiser.run(url, source: source, copiedBy: copiedBy, forceTemporary: forceTemporary, counter: i + 1) { p in
                        Task { @MainActor in if case .running = item.state { item.state = .running(p) } }
                    }
                    item.outcome = outcome
                    item.state = outcome.skipped && !outcome.changed ? .skipped(outcome.notes.first ?? L("Nothing to change")) : .done
                    if outcome.output != url { Thumbnails.make(for: outcome.output, kind: item.kind) { [weak item] image in item?.thumbnail = image ?? item?.thumbnail } }
                    completion?(item, outcome)
                } catch is CancellationError {
                    item.state = .failed(L("Cancelled"))
                } catch {
                    item.state = .failed(error.localizedDescription)
                    Log.write("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                self?.scheduleHide(item)
                self?.changed?()
            }
        }
        changed?()
        return created
    }

    /// Runs a given pipeline (a preset zone) on files and shows each one like any other result.
    func enqueuePipeline(_ urls: [URL], pipeline: Pipeline, source: PipelineSource, copyWhenDone: Bool) {
        var items: [ResultItem] = []
        for (i, url) in urls.enumerated() {
            guard let kind = Media.kind(of: url) else { continue }
            let item = ResultItem(file: url, kind: kind, source: source)
            self.items.append(item); items.append(item)
            Thumbnails.make(for: url, kind: kind) { [weak item] image in item?.thumbnail = image }
            item.task = Task { [weak self, weak item] in
                guard let item else { return }
                do {
                    item.state = .running(0)
                    var ctx = RunContext(source: source); ctx.counter = i + 1
                    ctx.progress = { p in Task { @MainActor in if case .running = item.state { item.state = .running(p) } } }
                    let o = try await Runner.run(url, pipeline, context: ctx)
                    Protection.shared.mark(o.output)
                    item.outcome = o
                    item.state = .done
                    Thumbnails.make(for: o.output, kind: kind) { [weak item] image in item?.thumbnail = image ?? item?.thumbnail }
                } catch { item.state = .failed(error.localizedDescription) }
                self?.scheduleHide(item)
                self?.changed?()
                if copyWhenDone, let s = self, s.items.allSatisfy({ !$0.isBusy }) { Clipboard.copy(s.items.compactMap { $0.outcome?.output }) }
            }
        }
        changed?()
    }

    /// Like `enqueuePipeline`, for results that go to the clipboard: the cards are returned and `done` runs when all have finished.
    @discardableResult
    func enqueuePipelineItems(_ urls: [URL], pipeline: Pipeline, source: PipelineSource, clipboard: Bool, done: @escaping @MainActor ([ResultItem]) -> Void) -> [ResultItem] {
        var created: [ResultItem] = []
        for (i, url) in urls.enumerated() {
            guard let kind = Media.kind(of: url) else { continue }
            let item = ResultItem(file: url, kind: kind, source: source)
            item.isClipboard = clipboard
            items.append(item); created.append(item)
            Thumbnails.make(for: url, kind: kind) { [weak item] image in item?.thumbnail = image }
            item.task = Task { [weak self, weak item] in
                guard let item else { return }
                do {
                    item.state = .running(0)
                    var ctx = RunContext(source: source); ctx.counter = i + 1; ctx.forceTemporary = clipboard
                    ctx.progress = { p in Task { @MainActor in if case .running = item.state { item.state = .running(p) } } }
                    let o = try await Runner.run(url, pipeline, context: ctx)
                    Protection.shared.mark(o.output)
                    item.outcome = o
                    item.state = .done
                    Thumbnails.make(for: o.output, kind: kind) { [weak item] image in item?.thumbnail = image ?? item?.thumbnail }
                } catch { item.state = .failed(error.localizedDescription) }
                self?.scheduleHide(item)
                self?.changed?()
                if created.allSatisfy({ !$0.isBusy }) { done(created) }
            }
        }
        changed?()
        return created
    }

    // MARK: Hiding

    func scheduleHide(_ item: ResultItem) {
        item.hideTask?.cancel()
        guard Prefs.bool("autoHideFloatingResults") else { return }
        let seconds = Prefs.int(item.isClipboard ? "autoHideClipboardResultAfter" : "autoHideFloatingResultsAfter")
        item.hideTask = Task { [weak self, weak item] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled, let item, !item.isBusy else { return }
            self?.dismiss(item)
        }
    }

    func holdOpen(_ item: ResultItem) { item.hideTask?.cancel() }

    func dismiss(_ item: ResultItem) {
        item.task?.cancel(); item.hideTask?.cancel()
        items.removeAll { $0.id == item.id }
        changed?()
    }

    /// Stops everything that runs and dismisses every card.
    func stopAll() {
        for i in items { i.task?.cancel() }
        clearAll()
    }

    func clearAll() {
        for i in items { i.task?.cancel(); i.hideTask?.cancel() }
        items.removeAll()
        changed?()
    }

    func copyAll() { Clipboard.copy(items.compactMap { $0.outcome?.output }) }

    // MARK: Actions on a result

    /// Runs steps on the original again, after putting the original back when it was replaced.
    func rerun(_ item: ResultItem, steps: [Step], label: String) {
        guard !item.isBusy else { return }
        holdOpen(item)
        item.label = label
        item.state = .running(0)
        let previous = item.outcome
        item.task = Task { [weak self, weak item] in
            guard let item else { return }
            do {
                if let p = previous {
                    if p.backup != nil { try Runner.restore(p) }
                    else if p.output.path != p.original.path { try? FileManager.default.trashItem(at: p.output, resultingItemURL: nil) }
                }
                var ctx = RunContext(source: item.source)
                ctx.forceTemporary = item.isClipboard
                ctx.progress = { p in Task { @MainActor in if case .running = item.state { item.state = .running(p) } } }
                let o = try await Runner.run(item.file, Pipeline(steps: steps), context: ctx)
                Protection.shared.mark(o.output)
                item.outcome = o
                item.state = .done
                Thumbnails.make(for: o.output, kind: item.kind) { [weak item] image in item?.thumbnail = image ?? item?.thumbnail }
            } catch {
                item.state = .failed(error.localizedDescription)
            }
            item.label = nil
            self?.scheduleHide(item)
            self?.changed?()
        }
    }

    /// Runs a built-in or saved pipeline on a result, from the original.
    func runPipeline(_ item: ResultItem, _ name: String) {
        guard let (pipeline, saved) = try? Library.resolve(name) else { item.state = .failed(L("No saved pipeline with this name")); return }
        var steps = pipeline.steps
        if let s = saved, !s.skipOptimisation { steps.insert(.optimise(encoder: nil, compression: nil, adaptive: nil, dpi: nil, location: nil), at: 0) }
        rerun(item, steps: steps, label: Builtins.find(name)?.title ?? name)
    }

    func downscale(_ item: ResultItem, factor: Double) {
        guard item.kind != .pdf else { return }
        let text = Int((factor * 100).rounded())
        let loc = Library.placementText(Prefs.placement(optimised: item.kind))
        rerun(item, steps: [.downscale(factor: factor, location: loc)], label: L("Downscaling to %d%%", text))
    }

    func compress(_ item: ResultItem, aggressive: Bool) {
        let loc = Library.placementText(Prefs.placement(optimised: item.kind))
        rerun(item, steps: [.optimise(encoder: aggressive ? "aggressive" : nil, compression: nil, adaptive: nil, dpi: nil, location: loc)], label: L(aggressive ? "Optimising aggressively" : "Optimising"))
    }

    func crop(_ item: ResultItem, spec: String, longEdge: Bool = false, smart: Bool? = nil) {
        guard item.kind == .image || item.kind == .video || item.kind == .pdf, CropSpec.parse(spec, longEdge: longEdge) != nil else { return }
        let loc = Library.placementText(Prefs.placement(optimised: item.kind))
        let oriented = item.fromPhotos ? PhotosBridge.orient(spec, as: Prefs.string("photoCropOrientation")) : spec
        rerun(item, steps: [.crop(spec: oriented, longEdge: longEdge, smart: smart ?? (item.kind == .image), location: loc)], label: L("Cropping to %@", oriented))
    }

    /// Changes the playback speed of a video or an audio file, from the original: 1 gives the normal speed back.
    func changeSpeed(_ item: ResultItem, factor: Double) {
        guard item.kind == .video || item.kind == .audio else { return }
        let loc = Library.placementText(Prefs.placement(optimised: item.kind))
        var steps: [Step] = []
        if factor != 1 { steps.append(.changeSpeed(factor: factor, frames: nil)) }
        steps.append(.optimise(encoder: nil, compression: nil, adaptive: nil, dpi: nil, location: loc))
        rerun(item, steps: steps, label: factor == 1 ? L("Reverting to original speed") : L("Changing speed to %@×", String(format: "%g", factor)))
    }

    /// Saves the cover art of an audio file next to it, as a JPEG.
    func extractCover(_ item: ResultItem) {
        Task {
            if let url = await AudioEngine.extractCover(item.current) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { item.state = .failed(L("No cover art in this file")); changed?() }
        }
    }

    func fit(_ item: ResultItem, bytes: Int64) {
        let loc = Library.placementText(Prefs.placement(optimised: item.kind))
        rerun(item, steps: [.targetSize(bytes: bytes, location: loc ?? "inPlace")], label: L("Fitting under %@", Files.human(bytes)))
    }

    func restore(_ item: ResultItem) {
        guard let o = item.outcome, !item.isBusy else { return }
        do {
            if o.backup != nil { try Runner.restore(o) }
            else if o.output.path != o.original.path { try? FileManager.default.trashItem(at: o.output, resultingItemURL: nil) }
            item.state = .restored
            item.thumbnail = nil
            Thumbnails.make(for: item.file, kind: item.kind) { [weak item] image in item?.thumbnail = image }
            holdOpen(item)
        } catch { item.state = .failed(error.localizedDescription) }
        changed?()
    }

    func optimiseAgain(_ item: ResultItem) {
        let loc = Library.placementText(Prefs.placement(optimised: item.kind))
        rerun(item, steps: [.optimise(encoder: nil, compression: nil, adaptive: nil, dpi: nil, location: loc)], label: L("Optimising"))
    }

    /// Converts the current file; the result is placed with the manual conversion behaviour.
    func convert(_ item: ResultItem, to ext: String) {
        guard !item.isBusy else { return }
        holdOpen(item)
        item.label = L("Converting to %@", ext.uppercased())
        item.state = .running(0)
        let source = item.current
        let loc = Library.placementText(Prefs.placement(converted: item.kind, manual: true))
        item.task = Task { [weak self, weak item] in
            guard let item else { return }
            do {
                let o = try await Runner.run(source, Pipeline(steps: [.convert(to: ext, location: loc ?? "inPlace")]))
                Protection.shared.mark(o.output)
                var merged = item.outcome ?? o
                merged.output = o.output; merged.newSize = o.newSize
                item.outcome = merged
                item.state = .done
                Thumbnails.make(for: o.output, kind: item.kind) { [weak item] image in item?.thumbnail = image ?? item?.thumbnail }
            } catch { item.state = .failed(error.localizedDescription) }
            item.label = nil
            self?.scheduleHide(item)
            self?.changed?()
        }
    }

    func saveAs(_ item: ResultItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.current.lastPathComponent
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: item.current, to: url)
    }

    func showInFinder(_ item: ResultItem) { NSWorkspace.shared.activateFileViewerSelecting([item.current]) }
    func copy(_ item: ResultItem) { Clipboard.copy(item.current, format: item.kind == .image ? "imageData" : "path", relativeTo: nil) }

    func stop(_ item: ResultItem) { item.task?.cancel() }

    /// A result handed to a shelf app or an uploader goes away when the setting says so.
    func sentAway(_ item: ResultItem) { if Prefs.bool("dismissResultOnUpload") { dismiss(item) } }
}

/// Small previews of the files.
enum Thumbnails {
    @MainActor
    static func make(for url: URL, kind: MediaKind, completion: @escaping @MainActor (NSImage?) -> Void) {
        Task.detached(priority: .utility) {
            let image: NSImage?
            switch kind {
            case .image:
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary) {
                    image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                } else { image = nil }
            case .video:
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 160, height: 160)
                if let cg = try? await gen.image(at: .zero).image { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) } else { image = nil }
            case .pdf:
                if let page = PDFDocument(url: url)?.page(at: 0) { image = page.thumbnail(of: CGSize(width: 160, height: 160), for: .cropBox) } else { image = nil }
            case .audio:
                image = nil
            }
            await MainActor.run { completion(image) }
        }
    }
}
