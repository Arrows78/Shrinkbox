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

/// A large drop: every file is optimised in one window, with the originals backed up so they can be restored.
@MainActor
final class BatchModel: ObservableObject {
    @Published var items: [BatchItem] = []
    @Published var finished = false
    @Published var stopped = false
    var tasks: [Task<Void, Never>] = []

    var done: Int { items.filter { if case .waiting = $0.status { false } else if case .running = $0.status { false } else { true } }.count }
    var failures: [BatchItem] { items.filter { if case .failed = $0.status { true } else { false } } }
    var savedBytes: Int64 { items.reduce(0) { $0 + $1.saved } }
    var beforeBytes: Int64 { items.reduce(0) { $0 + $1.before } }
    var progress: Double { items.isEmpty ? 0 : Double(done) / Double(items.count) }

    func run(_ urls: [URL], source: PipelineSource) {
        items = urls.compactMap { u in Media.kind(of: u).map { BatchItem(file: u, kind: $0) } }
        finished = false; stopped = false
        for item in items {
            let t = Task { [weak self, weak item] in
                guard let item else { return }
                item.status = .running
                do {
                    let o = try await Optimiser.run(item.file, source: source)
                    item.outcome = o
                    item.status = o.skipped && !o.changed ? .unchanged(o.notes.first ?? L("Nothing to change")) : .done
                } catch is CancellationError { item.status = .failed(L("Cancelled")) }
                catch { item.status = .failed(error.localizedDescription) }
                self?.checkFinished()
            }
            tasks.append(t)
        }
    }

    private func checkFinished() { if done == items.count { finished = true } }

    func stop() { stopped = true; for t in tasks { t.cancel() } }

    func restoreAll() {
        for item in items {
            guard let o = item.outcome, o.backup != nil || o.output.path != o.original.path else { continue }
            do {
                if o.backup != nil { try Runner.restore(o) } else { try? FileManager.default.trashItem(at: o.output, resultingItemURL: nil) }
                item.status = .restored
            } catch { item.status = .failed(error.localizedDescription) }
        }
    }
}

struct BatchView: View {
    @ObservedObject var model: BatchModel
    @State private var showFailures = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.finished ? L("Batch finished") : L("Optimising…")).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(verbatim: L("%d of %d", model.done, model.items.count)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: model.progress).tint(SettingsStyle.accent)
                HStack {
                    Text(verbatim: L("Saved %@ of %@", Files.human(model.savedBytes), Files.human(model.beforeBytes))).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
            }.padding(16)
            Divider()
            Table(model.items) {
                TableColumn(L("Name")) { (i: BatchItem) in HStack { Image(systemName: i.kind.symbol).foregroundStyle(.secondary); Text(i.file.lastPathComponent).lineLimit(1) } }
                TableColumn(L("Before")) { (i: BatchItem) in Text(Files.human(i.before)).monospacedDigit() }.width(80)
                TableColumn(L("After")) { (i: BatchItem) in Text(i.after.map(Files.human) ?? "–").monospacedDigit() }.width(80)
                TableColumn(L("Saved")) { (i: BatchItem) in Text(i.outcome?.changeLabel ?? "").monospacedDigit().foregroundStyle((i.outcome?.percent ?? 0) > 0 ? Color.green : Color.secondary) }.width(60)
                TableColumn(L("Status")) { (i: BatchItem) in BatchStatusText(item: i) }.width(min: 120)
            }
            Divider()
            HStack {
                if !model.finished { Button(L("Stop")) { model.stop() } }
                Button(L("Restore originals")) { model.restoreAll() }.disabled(!model.finished && !model.stopped)
                if !model.failures.isEmpty { Button(L("Show failures (%d)", model.failures.count)) { showFailures = true } }
                Spacer()
                Button(L("Close")) { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
            }.padding(12)
        }
        .frame(minWidth: 640, minHeight: 420)
        .sheet(isPresented: $showFailures) {
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

    func start(_ urls: [URL], source: PipelineSource) {
        let model = BatchModel()
        let w = NSWindow(contentViewController: NSHostingController(rootView: BatchView(model: model)))
        w.title = L("Batch optimisation")
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 720, height: 480))
        w.isReleasedWhenClosed = false
        w.center()
        windows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        model.run(urls, source: source)
    }
}
