import SwiftUI
import AppKit
import AVKit
import PDFKit

/// Before and after, side by side: a draggable divider for images, two synchronised players for video, an A/B switch
/// for audio, two pages for a PDF.
@MainActor
enum CompareWindow {
    private static var windows: [NSWindow] = []

    static func show(_ item: ResultItem) {
        guard let original = item.outcome?.backup else { return }
        let view = CompareView(kind: item.kind, before: original, after: item.current)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = L("Compare before and after")
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = SettingsStyle.window
        w.setContentSize(NSSize(width: 860, height: 600))
        w.isReleasedWhenClosed = false
        w.center()
        windows.append(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

struct CompareView: View {
    let kind: MediaKind
    let before: URL
    let after: URL

    var body: some View {
        VStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(Color(nsColor: SettingsStyle.window))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .image: ImageCompare(before: before, after: after)
        case .video: VideoCompare(before: before, after: after)
        case .audio: AudioCompare(before: before, after: after)
        case .pdf: PDFCompare(before: before, after: after)
        }
    }

    private var footer: some View {
        let b = Files.size(before), a = Files.size(after)
        let saved = b > 0 ? Int((Double(b - a) / Double(b) * 100).rounded()) : 0
        return HStack {
            Label(L("Original %@", Files.human(b)), systemImage: "doc").foregroundStyle(CardStyle.dim)
            Spacer()
            Text(verbatim: saved > 0 ? "-\(saved)%" : (a > b ? "+\(Int((Double(a - b) / Double(max(1, b)) * 100).rounded()))%" : "0%"))
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(saved > 0 ? Color.green : Color.orange)
            Spacer()
            Label(L("Optimised %@", Files.human(a)), systemImage: "wand.and.stars").foregroundStyle(CardStyle.dim)
        }
        .font(.system(size: 12)).padding(.horizontal, 20).padding(.vertical, 12)
    }
}

// MARK: Images

private struct ImageCompare: View {
    let before: URL
    let after: URL
    @State private var split = 0.5

    var body: some View {
        let b = NSImage(contentsOf: before), a = NSImage(contentsOf: after)
        GeometryReader { g in
            ZStack {
                if let b { Image(nsImage: b).resizable().scaledToFit().frame(width: g.size.width, height: g.size.height) }
                if let a {
                    Image(nsImage: a).resizable().scaledToFit().frame(width: g.size.width, height: g.size.height)
                        .mask(alignment: .trailing) { Rectangle().frame(width: g.size.width * (1 - split)) }
                }
                Handle().position(x: g.size.width * split, y: g.size.height / 2)
                tag(L("Original"), alignment: .topLeading)
                tag(L("Optimised"), alignment: .topTrailing)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(1, max(0, $0.location.x / max(1, g.size.width))) })
        }
        .help(L("Drag across the preview to move the split divider"))
    }

    private func tag(_ text: String, alignment: Alignment) -> some View {
        Text(verbatim: text).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.6))).padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private struct Handle: View {
        var body: some View {
            ZStack {
                Rectangle().fill(Color.white).frame(width: 2).shadow(radius: 3)
                Image(systemName: "arrow.left.and.right.circle.fill").font(.system(size: 26)).foregroundStyle(.white, Color.black.opacity(0.55)).shadow(radius: 4)
            }
        }
    }
}

// MARK: Videos

private struct VideoCompare: View {
    let before: URL
    let after: URL
    @StateObject private var sync = PlayerPair()

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                pane(sync.left, title: L("Original"))
                pane(sync.right, title: L("Optimised"))
            }.padding(12)
            HStack {
                Button { sync.toggle() } label: { Label(sync.playing ? L("Pause both videos") : L("Play both videos"), systemImage: sync.playing ? "pause.fill" : "play.fill") }
                Slider(value: Binding(get: { sync.position }, set: { sync.seek($0) }), in: 0...max(0.1, sync.duration))
            }.padding(.horizontal, 16).padding(.bottom, 10)
        }
        .onAppear { sync.load(before, after) }
        .onDisappear { sync.stop() }
    }

    private func pane(_ player: AVPlayer, title: String) -> some View {
        ZStack(alignment: .topLeading) {
            VideoPlayer(player: player).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(verbatim: title).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.black.opacity(0.6))).padding(10)
        }
    }
}

/// Two players that start, stop and seek together.
@MainActor
final class PlayerPair: ObservableObject {
    let left = AVPlayer(), right = AVPlayer()
    @Published var playing = false
    @Published var position = 0.0
    @Published var duration = 1.0
    private var observer: Any?

    func load(_ a: URL, _ b: URL) {
        left.replaceCurrentItem(with: AVPlayerItem(url: a)); right.replaceCurrentItem(with: AVPlayerItem(url: b))
        left.isMuted = false; right.isMuted = true
        Task { duration = max(0.1, CMTimeGetSeconds((try? await AVURLAsset(url: a).load(.duration)) ?? .zero)) }
        observer = left.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.position = CMTimeGetSeconds(t) }
        }
    }

    func toggle() {
        playing.toggle()
        if playing { left.play(); right.play() } else { left.pause(); right.pause() }
    }

    func seek(_ seconds: Double) {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        left.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero); right.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        position = seconds
    }

    func stop() {
        left.pause(); right.pause(); playing = false
        if let o = observer { left.removeTimeObserver(o); observer = nil }
    }
}

// MARK: Audio

private struct AudioCompare: View {
    let before: URL
    let after: URL
    @StateObject private var sync = PlayerPair()
    @State private var hearing = 0   // 0 original, 1 optimised

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform").font(.system(size: 54, weight: .semibold)).foregroundStyle(MediaKind.audio.tint)
            Picker("", selection: Binding(get: { hearing }, set: { hearing = $0; sync.left.isMuted = $0 != 0; sync.right.isMuted = $0 != 1 })) {
                Text("Original").tag(0)
                Text("Optimised").tag(1)
            }.pickerStyle(.segmented).frame(width: 260).labelsHidden()
            HStack {
                Button { sync.toggle() } label: { Image(systemName: sync.playing ? "pause.fill" : "play.fill").frame(width: 22) }
                Slider(value: Binding(get: { sync.position }, set: { sync.seek($0) }), in: 0...max(0.1, sync.duration))
            }.frame(width: 420)
        }
        .onAppear { sync.load(before, after); sync.left.isMuted = false; sync.right.isMuted = true }
        .onDisappear { sync.stop() }
    }
}

// MARK: PDF

private struct PDFCompare: View {
    let before: URL
    let after: URL

    var body: some View {
        HStack(spacing: 8) {
            PDFPane(url: before, title: L("Original"))
            PDFPane(url: after, title: L("Optimised"))
        }.padding(12)
    }

    private struct PDFPane: NSViewRepresentable {
        let url: URL
        let title: String
        func makeNSView(context: Context) -> PDFView {
            let v = PDFView(); v.document = PDFDocument(url: url); v.autoScales = true; v.displayMode = .singlePageContinuous; return v
        }
        func updateNSView(_ v: PDFView, context: Context) {}
    }
}
