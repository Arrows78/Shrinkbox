import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A borderless panel that never takes focus from the app in front.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Out of screenshots and screen sharing unless the user wants them.
        sharingType = Prefs.bool("allowShrinkboxInScreenshots") ? .readOnly : .none
    }
}

// MARK: Floating results

@MainActor
final class ResultsPanel {
    static let shared = ResultsPanel()
    private var panel: FloatingPanel?
    private var host: NSHostingView<ResultsView>?
    private var cursorTimer: Timer?

    func start() {
        ResultsModel.shared.changed = { [weak self] in ResultsModel.shared.objectWillChange.send(); self?.refresh() }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { ResultsPanel.shared.followCursor() } }
    }

    private var clearTask: Task<Void, Never>?

    /// With many results on screen (the compact layout), the whole stack goes after a quiet while.
    private func armClear() {
        clearTask?.cancel()
        guard ResultsModel.shared.compact, !ResultsModel.shared.items.isEmpty else { return }
        let seconds = Prefs.int("autoClearAllCompactResultsAfter")
        clearTask = Task { try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000); if !Task.isCancelled, ResultsModel.shared.items.allSatisfy({ !$0.isBusy }) { ResultsModel.shared.clearAll() } }
    }

    func refresh() {
        armClear()
        let items = ResultsModel.shared.items
        ResultKeys.shared.update(visible: Prefs.bool("enableFloatingResults") && !items.isEmpty)
        guard Prefs.bool("enableFloatingResults"), !items.isEmpty else { panel?.orderOut(nil); return }
        if panel == nil {
            let p = FloatingPanel(size: NSSize(width: 360, height: 200))
            let h = NSHostingView(rootView: ResultsView())
            h.sizingOptions = [.intrinsicContentSize]
            p.contentView = h
            panel = p; host = h
        }
        layout(on: screen())
        panel?.orderFrontRegardless()
    }

    private var currentScreen: NSScreen?

    private func screen() -> NSScreen {
        if let s = currentScreen { return s }
        return NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Moves the stack to the screen the cursor has stayed on for a while.
    private var pendingScreen: (NSScreen, Int)?
    func followCursor() {
        guard Prefs.bool("followCursorScreen"), panel?.isVisible == true,
              let under = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) else { return }
        if under == (currentScreen ?? screen()) { pendingScreen = nil; return }
        if let p = pendingScreen, p.0 == under {
            if p.1 >= 1 { currentScreen = under; pendingScreen = nil; layout(on: under) } else { pendingScreen = (under, p.1 + 1) }
        } else { pendingScreen = (under, 0) }
    }

    private func layout(on screen: NSScreen) {
        guard let p = panel, let h = host else { return }
        currentScreen = screen
        let size = h.fittingSize
        let width = max(300, size.width), height = min(size.height, screen.visibleFrame.height - 20)
        let v = screen.visibleFrame
        let margin: CGFloat = 8
        let corner = Prefs.string("floatingResultsCorner")
        let x = corner.hasSuffix("Left") ? v.minX + margin : v.maxX - width - margin
        let y = corner.hasPrefix("top") ? v.maxY - height - margin : v.minY + margin
        p.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}

// MARK: Drop zone

struct DropZoneView: View {
    @ObservedObject var state: DropZoneState
    @State private var march = false

    var body: some View {
        VStack(spacing: 12) {
            if state.showPresets { PresetZonesRow(state: state) }
            ZStack {
                glassBase
                VStack(spacing: 10) {
                    KindsRow(active: state.targeted)
                    Text("Drop to optimise").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(state.hint).font(.system(size: 11)).foregroundStyle(CardStyle.dim)
                }
            }
            .frame(width: 300, height: 156)
            .scaleEffect(state.targeted ? 1.05 : 1)
            .shadow(color: state.targeted ? Color.accentColor.opacity(0.5) : Color.black.opacity(0.35), radius: state.targeted ? 24 : 14, y: 6)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: state.targeted)
        }
        .padding(18)
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { march = true } }
    }

    /// Dark glass with a dashed border that marches when a file is over it.
    private var glassBase: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        let colour: Color = state.targeted ? Color.accentColor : Color.white.opacity(0.28)
        return ZStack {
            CardStyle.glass(shape)
            if state.targeted { shape.fill(Color.accentColor.opacity(0.16)) }
            shape.inset(by: 7).strokeBorder(colour, style: StrokeStyle(lineWidth: state.targeted ? 2 : 1.2, lineCap: .round, dash: [7, 6], dashPhase: march && state.targeted ? -26 : 0))
        }
    }
}

/// The four kinds of file, lifting one after the other while a file is over the zone.
private struct KindsRow: View {
    let active: Bool
    @State private var lift = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(MediaKind.allCases.enumerated()), id: \.offset) { index, kind in
                Image(systemName: kind.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(kind.tint.opacity(active ? 0.9 : 0.55)))
                    .offset(y: active && lift ? -5 : 0)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(index) * 0.12), value: lift)
            }
        }
        .onChange(of: active) { on in lift = on }
        .onAppear { lift = active }
    }
}

private struct PresetZonesRow: View {
    @ObservedObject var state: DropZoneState

    var body: some View {
        let zones: [PresetZone] = Library.load().zones
        HStack(spacing: 8) {
            if zones.isEmpty {
                Text("No preset zone yet. Add one in Settings › Automation.").font(.system(size: 11)).foregroundStyle(CardStyle.dim).padding(.horizontal, 12).padding(.vertical, 8).background(CardStyle.glass(Capsule()))
            }
            ForEach(zones) { zone in PresetZoneCard(zone: zone, state: state) }
        }
    }
}

/// One preset zone: it lights up under a dragged file and runs its pipeline on a drop.
private struct PresetZoneCard: View {
    let zone: PresetZone
    @ObservedObject var state: DropZoneState

    private var hovered: Bool { state.hoveredZone == zone.id }

    private func setTargeted(_ on: Bool) {
        if on { state.hoveredZone = zone.id } else if hovered { state.hoveredZone = nil }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let tint: Color = hovered ? Color.accentColor.opacity(0.55) : Color.clear
        VStack(spacing: 5) {
            Image(systemName: zone.icon).font(.system(size: 19, weight: .semibold))
            Text(verbatim: zone.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .frame(width: 80, height: 66)
        .background(CardStyle.glass(shape))
        .overlay(shape.fill(tint))
        .scaleEffect(hovered ? 1.1 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovered)
        .onDrop(of: [.fileURL], isTargeted: Binding<Bool>(get: { hovered }, set: { setTargeted($0) })) { providers in
            DropZone.handle(providers, zone: zone)
            return true
        }
    }
}

@MainActor
final class DropZoneState: ObservableObject {
    @Published var targeted = false
    @Published var showPresets = false
    @Published var hoveredZone: String?
    var hint: String { showPresets ? L("Or drop on a preset above") : L("Photos, videos, audio, PDFs and folders · hold ⌃ for presets") }
}

@MainActor
enum DropZone {
    static let state = DropZoneState()
    private static var panel: FloatingPanel?
    private static var hideTask: Task<Void, Never>?

    /// What was dropped: files, folders, or links to download.
    static func handle(_ providers: [NSItemProvider], zone: PresetZone? = nil) {
        let group = DispatchGroup()
        let collected = Box()
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { collected.add(url) }; group.leave() }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { collected.add(url) }; group.leave() }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { process(collected.urls, zone: zone) }
        }
    }

    static func process(_ inputs: [URL], zone: PresetZone? = nil) {
        Task {
            var files: [URL] = []
            var remote: [URL] = []
            for u in inputs { if let s = u.scheme, s.hasPrefix("http") { remote.append(u) } else { files.append(u) } }
            for u in remote { if let d = try? await Fetch.download(u) { files.append(d) } }
            let supported = Media.collect(files, recursive: true)
            guard !supported.isEmpty else { return }
            hide()
            if let z = zone {
                let pipelineText = z.pipeline
                guard let (p, saved) = try? Library.resolve(pipelineText) else { return }
                var steps = p.steps
                if !z.skipOptimisation, saved?.skipOptimisation != true { steps.insert(.optimise(encoder: nil, compression: nil, adaptive: nil, dpi: nil, location: nil), at: 0) }
                ResultsModel.shared.enqueuePipeline(supported.filter { z.type == nil || Media.kind(of: $0) == z.type }, pipeline: Pipeline(steps: steps), source: .dropZone, copyWhenDone: Prefs.bool("autoCopyToClipboard"))
            } else {
                ResultsModel.shared.enqueue(supported, source: .dropZone) { _, _ in
                    if Prefs.bool("autoCopyToClipboard") { Clipboard.copy(ResultsModel.shared.items.compactMap { $0.outcome?.output }) }
                }
            }
        }
    }

    private final class Box: @unchecked Sendable {
        private var list: [URL] = []; private let lock = NSLock()
        func add(_ u: URL) { lock.lock(); list.append(u); lock.unlock() }
        var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
    }

    // MARK: Showing while dragging

    private static var dragCount = 0

    /// The drag pasteboard keeps what the last drag put on it, so only a change since the mouse went down means a drag
    /// that started now carries something.
    private static var downCount = NSPasteboard(name: .drag).changeCount

    static func mouseDown() { downCount = NSPasteboard(name: .drag).changeCount }

    /// The files a drag in progress carries that Shrinkbox can optimise: nothing for a window, a selection of text or a
    /// file of another kind.
    static func draggedMedia() -> [URL] {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != downCount,
              let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return [] }
        return urls.filter { u in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return true }   // a folder may hold some
            return Media.kind(of: u) != nil
        }
    }

    /// Called by the app's mouse monitors while files are dragged.
    static func dragMoved(control: Bool, option: Bool) {
        guard Prefs.bool("enableDropZone"), !draggedMedia().isEmpty else { return }
        if Prefs.bool("onlyShowDropZoneOnOption") && !option && panel?.isVisible != true { return }
        state.showPresets = control || (Prefs.bool("onlyShowPresetZonesOnControlTapped") && state.showPresets)
        show()
    }

    static func show() {
        hideTask?.cancel()
        if panel == nil {
            let p = FloatingPanel(size: NSSize(width: 320, height: 260))
            p.ignoresMouseEvents = false
            let host = DropHost(rootView: DropZoneView(state: state))
            p.contentView = host
            panel = p
        }
        guard let p = panel, let s = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = (p.contentView as? NSHostingView<DropZoneView>)?.fittingSize ?? NSSize(width: 320, height: 260)
        let corner = Prefs.string("floatingResultsCorner")
        let v = s.visibleFrame
        let x = corner.hasSuffix("Left") ? v.minX + 12 : v.maxX - size.width - 12
        let y = corner.hasPrefix("top") ? v.maxY - size.height - 12 : v.minY + 12
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        // Gone when the drag ends.
        hideTask = Task { try? await Task.sleep(nanoseconds: 6_000_000_000); if !Task.isCancelled { hide() } }
    }

    static func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        state.showPresets = false; state.targeted = false; state.hoveredZone = nil
    }
}

/// The drop target of the main zone: it also takes folders, links and plain text paths.
final class DropHost: NSHostingView<DropZoneView> {
    required init(rootView: DropZoneView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }
    @MainActor required init?(coder: NSCoder) { fatalError() }
    @MainActor required init(rootView: DropZoneView, hosting: Bool) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { DropZone.state.targeted = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { DropZone.state.targeted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var urls = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        // A path or a link typed as text.
        if urls.isEmpty, let s = pb.string(forType: .string) {
            for line in s.split(whereSeparator: \.isNewline) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if let u = URL(string: t), u.scheme?.hasPrefix("http") == true { urls.append(u) }
                else if FileManager.default.fileExists(atPath: (t as NSString).expandingTildeInPath) { urls.append(URL(fileURLWithPath: (t as NSString).expandingTildeInPath)) }
            }
        }
        DropZone.state.targeted = false
        DropZone.process(urls)
        return !urls.isEmpty
    }
}
