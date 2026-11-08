import AppKit
import SwiftUI

@MainActor
final class BatchItem: ObservableObject, Identifiable {
    enum Status: Equatable { case waiting, running, done, unchanged(String), failed(String), restored }
    let id = UUID()
    let file: URL
    let kind: MediaKind
    @Published var status: Status = .waiting
    @Published var outcome: Outcome?
    init(file: URL, kind: MediaKind) { self.file = file; self.kind = kind }

    var before: Int64 { outcome?.originalSize ?? Files.size(file) }
    var after: Int64? { outcome?.newSize }
    var saved: Int64 { outcome?.saved ?? 0 }
}

/// What the batch window lets you adjust before it starts. Left alone, files get what their source gives them.
struct BatchParams: Equatable {
    var customCompression = false
    var compression = 60.0
    var downscale = 1.0                // 1: unchanged
    var cropSpec = ""
    var convertImages = ""             // "", webp, jpeg…
    var convertVideos = ""
    var convertAudio = ""
    var removeAudio = false
    var speed = 1.0
    var bitrate = 0                    // kbps, 0: unchanged
    var aggressive = false

    var isDefault: Bool { self == BatchParams() }

    /// The steps these choices make, or nil when nothing was changed.
    func pipeline(for kind: MediaKind) -> Pipeline? {
        if isDefault { return nil }
        var steps: [Step] = []
        if !cropSpec.isEmpty, CropSpec.parse(cropSpec) != nil, kind != .audio {
            steps.append(.crop(spec: cropSpec, longEdge: !cropSpec.contains(":") && !cropSpec.contains("x"), smart: kind == .image, location: nil))
        }
        if downscale < 1, kind != .pdf { steps.append(.downscale(factor: downscale, location: nil)) }
        if speed != 1, kind == .video || kind == .audio { steps.append(.changeSpeed(factor: speed, frames: nil)) }
        if removeAudio, kind == .video { steps.append(.removeAudio) }
        if bitrate > 0, kind == .audio { steps.append(.lowerBitrate(kbps: bitrate, location: nil)) }
        let convert: String
        switch kind {
        case .image: convert = convertImages
        case .video: convert = convertVideos
        case .audio: convert = convertAudio
        case .pdf: convert = ""
        }
        if !convert.isEmpty { steps.append(.convert(to: convert, location: "sameFolder")) }
        let level: String? = customCompression ? String(Int(compression)) : nil
        steps.append(.optimise(encoder: aggressive ? "aggressive" : nil, compression: level, adaptive: nil, dpi: nil, location: Library.placementText(Prefs.placement(optimised: kind))))
        return Pipeline(steps: steps)
    }
}

/// A large drop: every file is optimised in one window, with the originals backed up so they can be restored.
@MainActor
final class BatchModel: ObservableObject {
    enum Phase { case review, running }

    @Published var items: [BatchItem] = []
    @Published var phase = Phase.running
    @Published var finished = false
    @Published var stopped = false
    @Published var params = BatchParams()
    var source: PipelineSource = .dropZone
    var tasks: [Task<Void, Never>] = []

    var done: Int { items.filter { if case .waiting = $0.status { false } else if case .running = $0.status { false } else { true } }.count }
    var failures: [BatchItem] { items.filter { if case .failed = $0.status { true } else { false } } }
    var savedBytes: Int64 { items.reduce(0) { $0 + $1.saved } }
    var beforeBytes: Int64 { items.reduce(0) { $0 + $1.before } }
    var progress: Double { items.isEmpty ? 0 : Double(done) / Double(items.count) }
    var kinds: Set<MediaKind> { Set(items.map(\.kind)) }

    func load(_ urls: [URL], source: PipelineSource) {
        self.source = source
        items = urls.compactMap { u in Media.kind(of: u).map { BatchItem(file: u, kind: $0) } }
    }

    func remove(_ ids: Set<UUID>) { items.removeAll { ids.contains($0.id) } }

    func start() {
        phase = .running
        finished = false; stopped = false
        let params = self.params, source = self.source
        for item in items {
            let t = Task { [weak self, weak item] in
                guard let item else { return }
                item.status = .running
                do {
                    let o: Outcome
                    if let pipeline = params.pipeline(for: item.kind) { o = try await Optimiser.gated(item.kind) { try await Runner.run(item.file, pipeline, context: RunContext(source: source)) } }
                    else { o = try await Optimiser.run(item.file, source: source) }
                    Protection.shared.mark(o.output)
                    item.outcome = o
                    item.status = o.skipped && !o.changed ? .unchanged(o.notes.first ?? L("Nothing to change")) : .done
                } catch is CancellationError { item.status = .failed(L("Cancelled")) }
                catch { item.status = .failed(error.localizedDescription) }
                self?.checkFinished()
            }
            tasks.append(t)
        }
        if items.isEmpty { finished = true }
    }

    private func checkFinished() { if done == items.count { finished = true } }

    func stop() { stopped = true; for t in tasks { t.cancel() } }

    func restore(_ item: BatchItem) {
        guard let o = item.outcome, o.backup != nil || o.output.path != o.original.path else { return }
        do {
            if o.backup != nil { try Runner.restore(o) } else { try? FileManager.default.trashItem(at: o.output, resultingItemURL: nil) }
            item.status = .restored
        } catch { item.status = .failed(error.localizedDescription) }
    }

    func restoreAll() { for item in items { restore(item) } }
}

struct BatchView: View {
    @ObservedObject var model: BatchModel
    @State private var showFailures = false
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            Divider()
            HSplitView {
                table
                if model.phase == .review { BatchOptions(model: model).frame(minWidth: 250, idealWidth: 270, maxWidth: 320) }
            }
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: model.phase == .review ? 860 : 640, minHeight: 420)
        .sheet(isPresented: $showFailures) { failuresSheet }
    }

    private var title: String {
        if model.phase == .review { return L("Batch optimisation") }
        return model.finished ? L("Batch finished") : L("Optimising…")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.phase == .review { Text(verbatim: L("%d files · %@", model.items.count, Files.human(model.beforeBytes))).font(.system(size: 12)).foregroundStyle(.secondary) }
                else { Text(verbatim: L("%d of %d", model.done, model.items.count)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit() }
            }
            if model.phase == .running {
                ProgressView(value: model.progress).tint(SettingsStyle.accent)
                Text(verbatim: L("Saved %@ of %@", Files.human(model.savedBytes), Files.human(model.beforeBytes))).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("Adjust what the files get, or start with the defaults. Originals are backed up first and can be restored.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var table: some View {
        Table(model.items, selection: $selection) {
            TableColumn(L("Name")) { (i: BatchItem) in HStack { Image(systemName: i.kind.symbol).foregroundStyle(i.kind.tint); Text(i.file.lastPathComponent).lineLimit(1) } }.width(min: 220)
            TableColumn(L("Before")) { (i: BatchItem) in Text(Files.human(i.before)).monospacedDigit() }.width(80)
            TableColumn(L("After")) { (i: BatchItem) in Text(i.after.map(Files.human) ?? "–").monospacedDigit() }.width(80)
            TableColumn(L("Saved")) { (i: BatchItem) in Text(i.outcome?.changeLabel ?? "").monospacedDigit().foregroundStyle((i.outcome?.percent ?? 0) > 0 ? Color.green : Color.secondary) }.width(60)
            TableColumn(L("Status")) { (i: BatchItem) in BatchStatusText(item: i) }.width(min: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in rowMenu(ids) } primaryAction: { ids in
            if let r = model.items.first(where: { ids.contains($0.id) }) { QuickLook.show(r.outcome?.output ?? r.file) }
        }
        .onDeleteCommand { if model.phase == .review { model.remove(selection) } }
    }

    @ViewBuilder private func rowMenu(_ ids: Set<UUID>) -> some View {
        let rows = model.items.filter { ids.contains($0.id) }
        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(rows.map { $0.outcome?.output ?? $0.file }) }
        Button(L("Quick Look")) { if let r = rows.first { QuickLook.show(r.outcome?.output ?? r.file) } }
        if model.phase == .review {
            Divider()
            Button(L("Remove from batch")) { model.remove(ids) }
        } else {
            Button(L("Restore the original")) { for r in rows { model.restore(r) } }.disabled(rows.allSatisfy { $0.outcome == nil })
            Button(L("Compare before and after")) { if let r = rows.first, let o = r.outcome, o.backup != nil { CompareWindow.show(compareItem(r, o)) } }
        }
    }

    /// A card-like item for the compare window.
    private func compareItem(_ r: BatchItem, _ o: Outcome) -> ResultItem {
        let item = ResultItem(file: r.file, kind: r.kind, source: .manual)
        item.outcome = o
        return item
    }

    private var footer: some View {
        HStack {
            if model.phase == .review {
                Button(L("Cancel")) { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Optimise %d files", model.items.count)) { model.start() }.keyboardShortcut(.defaultAction).disabled(model.items.isEmpty)
            } else {
                if !model.finished { Button(L("Stop")) { model.stop() } }
                Button(L("Restore originals")) { model.restoreAll() }.disabled(!model.finished && !model.stopped)
                if !model.failures.isEmpty { Button(L("Show failures (%d)", model.failures.count)) { showFailures = true } }
                Spacer()
                Button(L("Close")) { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private var failuresSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Failures")).font(.headline)
            List(model.failures) { i in
                VStack(alignment: .leading) {
                    Text(i.file.lastPathComponent)
                    if case .failed(let m) = i.status { Text(m).font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(height: 240)
            HStack { Spacer(); Button(L("Close")) { showFailures = false } }
        }.padding(16).frame(width: 460)
    }
}

/// The adjustments of a batch, only for the kinds of file it holds.
private struct BatchOptions: View {
    @ObservedObject var model: BatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Adjustments").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Toggle("Choose the compression", isOn: $model.params.customCompression).toggleStyle(.switch).controlSize(.small)
                if model.params.customCompression {
                    HStack { Slider(value: $model.params.compression, in: 5...100, step: 5); Text(verbatim: "\(Int(model.params.compression))").monospacedDigit().frame(width: 30) }
                }
                Toggle("Aggressive optimisation", isOn: $model.params.aggressive).toggleStyle(.switch).controlSize(.small)
                if model.kinds.contains(where: { $0 != .pdf }) { downscaleRow }
                if model.kinds.contains(where: { $0 != .audio }) {
                    row("Crop to") { TextField("16:9, 1200x630, 1920", text: $model.params.cropSpec).textFieldStyle(.roundedBorder) }
                }
                if model.kinds.contains(.image) { convertRow("Convert images to", $model.params.convertImages, FormatMenu.targets(for: .image)) }
                if model.kinds.contains(.video) {
                    convertRow("Convert videos to", $model.params.convertVideos, FormatMenu.targets(for: .video))
                    Toggle("Remove the audio", isOn: $model.params.removeAudio).toggleStyle(.switch).controlSize(.small)
                }
                if model.kinds.contains(.video) || model.kinds.contains(.audio) { speedRow }
                if model.kinds.contains(.audio) {
                    convertRow("Convert audio to", $model.params.convertAudio, FormatMenu.targets(for: .audio))
                    bitrateRow
                }
                Button("Restore the defaults") { model.params = BatchParams() }.controlSize(.small).disabled(model.params.isDefault)
            }.padding(16)
        }
        .background(Color.white.opacity(0.03))
    }

    private var downscaleRow: some View {
        row("Downscale") {
            Picker("", selection: $model.params.downscale) {
                Text("None").tag(1.0); Text("75%").tag(0.75); Text("50%").tag(0.5); Text("33%").tag(0.33); Text("25%").tag(0.25)
            }.labelsHidden()
        }
    }

    private var speedRow: some View {
        row("Playback speed") {
            Picker("", selection: $model.params.speed) {
                ForEach([0.5, 1, 1.5, 2, 3, 4], id: \.self) { f in Text(verbatim: f == 1 ? L("Normal speed (1×)") : String(format: "%g×", f)).tag(f) }
            }.labelsHidden()
        }
    }

    private var bitrateRow: some View {
        row("Audio bitrate") {
            Picker("", selection: $model.params.bitrate) {
                Text("Unchanged").tag(0)
                ForEach([64, 96, 128, 192, 256], id: \.self) { k in Text(verbatim: "\(k) kbps").tag(k) }
            }.labelsHidden()
        }
    }

    private func row<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12)); control() }
    }

    private func convertRow(_ title: LocalizedStringKey, _ binding: Binding<String>, _ options: [String]) -> some View {
        row(title) {
            Picker("", selection: binding) {
                Text("Keep the format").tag("")
                ForEach(options, id: \.self) { o in Text(verbatim: o.uppercased()).tag(o) }
            }.labelsHidden()
        }
    }
}

private struct BatchStatusText: View {
    @ObservedObject var item: BatchItem
    var body: some View {
        switch item.status {
        case .waiting: Text(L("Waiting")).foregroundStyle(.secondary)
        case .running: HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Optimising…")) }
        case .done: Label(L("Done"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unchanged(let m): Text(m).foregroundStyle(.secondary)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(1)
        case .restored: Label(L("Restored"), systemImage: "arrow.uturn.backward").foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class BatchManager {
    static let shared = BatchManager()
    private var windows: [NSWindow] = []

    /// Opens the batch window. With `review` (or the setting) it waits for you to adjust the files and press the button.
    func start(_ urls: [URL], source: PipelineSource, review: Bool = false) {
        let model = BatchModel()
        model.load(urls, source: source)
        let reviewing = review || Prefs.bool("reviewBatchesFirst")
        model.phase = reviewing ? .review : .running
        let w = NSWindow(contentViewController: NSHostingController(rootView: BatchView(model: model)))
        w.title = L("Batch optimisation")
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: reviewing ? 900 : 720, height: 500))
        w.isReleasedWhenClosed = false
        w.center()
        windows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if !reviewing { model.start() }
    }
}
