import SwiftUI
import AppKit
import QuickLookUI

extension MediaKind {
    /// The colour of a kind of file: its thumbnail ring, its progress bar, its dot in the compact list.
    var tint: Color {
        switch self {
        case .image: Color(red: 0.36, green: 0.55, blue: 1.0)
        case .video: Color(red: 1.0, green: 0.42, blue: 0.40)
        case .audio: Color(red: 1.0, green: 0.68, blue: 0.20)
        case .pdf: Color(red: 0.93, green: 0.36, blue: 0.55)
        }
    }
}

enum CardStyle {
    static let radius: CGFloat = 20
    static let dim = Color.white.opacity(0.62)

    /// Dark glass: readable over any wallpaper.
    static func glass<S: InsettableShape>(_ shape: S) -> some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.58))
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0)], startPoint: .top, endPoint: .center))
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
        }
    }
}

/// The floating stack of results: full cards, or one line each when there are many.
struct ResultsView: View {
    @ObservedObject var model = ResultsModel.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if model.items.count > 1 { StackHeader(count: model.items.count) }
            ForEach(model.items.suffix(8)) { item in
                row(item).transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.92))))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: model.items.map(\.id))
        .padding(12)
        .frame(width: model.compact ? 320 : 388, alignment: .trailing)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func row(_ item: ResultItem) -> some View {
        if model.compact { CompactRow(item: item) } else { ResultCard(item: item) }
    }
}

/// "3 files · saved 12 MB" with Copy all and Clear all.
private struct StackHeader: View {
    let count: Int
    @ObservedObject var model = ResultsModel.shared

    private var saved: Int64 { model.items.compactMap { $0.outcome?.saved }.reduce(0, +) }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: saved > 0 ? L("%d files · saved %@", count, Files.human(saved)) : L("%d files", count))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(CardStyle.dim)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(CardStyle.glass(Capsule()))
            Spacer(minLength: 0)
            HeaderButton(symbol: "doc.on.doc", title: "Copy all") { model.copyAll() }
            HeaderButton(symbol: "xmark", title: "Clear all") { model.clearAll() }
        }
    }
}

private struct HeaderButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(CardStyle.glass(Capsule()))
                .overlay(Capsule().fill(Color.white.opacity(hover ? 0.12 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A thumbnail with a ring in the colour of its kind and a check when it is done.
struct Thumb: View {
    @ObservedObject var item: ResultItem
    var size: CGFloat

    private var done: Bool { if case .done = item.state { true } else { false } }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        ZStack {
            if let t = item.thumbnail {
                Image(nsImage: t).resizable().scaledToFill().frame(width: size, height: size).clipShape(shape)
            } else {
                shape.fill(LinearGradient(colors: [item.kind.tint.opacity(0.55), item.kind.tint.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: item.kind.symbol).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
            }
            shape.strokeBorder(item.kind.tint.opacity(0.55), lineWidth: 1.2)
            if done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: size * 0.3)).symbolRenderingMode(.palette).foregroundStyle(.white, Color.green)
                    .frame(width: size, height: size, alignment: .bottomTrailing).offset(x: 4, y: 4)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}

/// "-75%" in a coloured capsule, then the sizes.
struct SizeLine: View {
    @ObservedObject var item: ResultItem

    var body: some View {
        switch item.state {
        case .waiting: Text("Waiting").foregroundStyle(CardStyle.dim)
        case .running(let p): RunningLine(item: item, progress: p)
        case .done: if let o = item.outcome { DoneLine(outcome: o) }
        case .skipped(let m): Label(m, systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(CardStyle.dim)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
        case .restored: Label("Original restored", systemImage: "arrow.uturn.backward").font(.system(size: 11)).foregroundStyle(CardStyle.dim)
        }
    }
}

private struct DoneLine: View {
    let outcome: Outcome

    private var tint: Color {
        if outcome.percent > 0 { return .green }
        return outcome.newSize > outcome.originalSize ? .orange : Color.white.opacity(0.6)
    }

    var body: some View {
        let fraction: Double = outcome.originalSize > 0 ? Double(outcome.newSize) / Double(outcome.originalSize) : 1
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(verbatim: outcome.changeLabel).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(tint)
                    .padding(.horizontal, 8).padding(.vertical, 2).background(tint.opacity(0.18), in: Capsule())
                Text(verbatim: "\(Files.human(outcome.originalSize)) → \(Files.human(outcome.newSize))").font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(CardStyle.dim)
            }
            SavingBar(fraction: fraction, tint: tint)
        }
    }
}

/// How much of the original is left, as a thin bar.
private struct SavingBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(tint.opacity(0.85)).frame(width: max(4, g.size.width * min(1, fraction)))
            }
        }.frame(height: 3)
    }
}

private struct RunningLine: View {
    @ObservedObject var item: ResultItem
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: item.label ?? L("Optimising…")).font(.system(size: 11)).foregroundStyle(CardStyle.dim)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    if progress > 0 { Capsule().fill(item.kind.tint).frame(width: max(6, g.size.width * progress)) }
                    else { IndeterminateBar(tint: item.kind.tint, width: g.size.width) }
                }
            }.frame(height: 4)
        }
    }
}

private struct IndeterminateBar: View {
    let tint: Color
    let width: CGFloat
    @State private var run = false

    var body: some View {
        Capsule().fill(tint).frame(width: width * 0.3)
            .offset(x: run ? width * 0.7 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { run = true } }
    }
}

struct ResultCard: View {
    @ObservedObject var item: ResultItem
    @ObservedObject var model = ResultsModel.shared
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumb(item: item, size: 64).onDrag { NSItemProvider(object: item.current as NSURL) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: item.current.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    CloseButton(item: item, visible: hovering)
                }
                SizeLine(item: item)
                if !item.isBusy { ActionRow(item: item) }
            }
        }
        .padding(12)
        .background(CardStyle.glass(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous)))
        .shadow(color: .black.opacity(hovering ? 0.45 : 0.32), radius: hovering ? 16 : 10, y: hovering ? 8 : 5)
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0; if $0 { model.holdOpen(item) } else if !item.isBusy { model.scheduleHide(item) } }
        .contextMenu { ActionMenu(item: item) }
    }
}

private struct CloseButton: View {
    @ObservedObject var item: ResultItem
    let visible: Bool
    @ObservedObject var model = ResultsModel.shared

    var body: some View {
        Button { if item.isBusy { model.stop(item) } else { model.dismiss(item) } } label: {
            Image(systemName: item.isBusy ? "stop.fill" : "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(CardStyle.dim)
        .opacity(visible || item.isBusy ? 1 : 0.35)
        .help(item.isBusy ? L("Stop") : L("Dismiss"))
    }
}

struct CompactRow: View {
    @ObservedObject var item: ResultItem
    @ObservedObject var model = ResultsModel.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            if Prefs.bool("showCompactImages") { Thumb(item: item, size: 24) }
            else { Circle().fill(item.kind.tint).frame(width: 8, height: 8).padding(.leading, 2) }
            Text(verbatim: item.current.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            trailing
            Menu { ActionMenu(item: item) } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold)).frame(width: 20, height: 20).background(Color.white.opacity(hovering ? 0.14 : 0), in: Circle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(CardStyle.glass(Capsule()))
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: item.current as NSURL) }
    }

    @ViewBuilder private var trailing: some View {
        if let p = item.progress {
            ProgressView(value: p > 0 ? p : nil).progressViewStyle(.circular).controlSize(.small)
        } else if let o = item.outcome, case .done = item.state {
            Text(verbatim: o.changeLabel).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(changeTint(o))
        } else if case .failed = item.state {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func changeTint(_ o: Outcome) -> Color {
        if o.percent > 0 { return .green }
        return o.newSize > o.originalSize ? .orange : CardStyle.dim
    }
}

/// A round icon button that lights up under the pointer.
struct RoundIcon: View {
    let symbol: String
    let tip: String

    @State private var hover = false

    var body: some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(hover ? 1 : 0.78))
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(hover ? 0.2 : 0.09)))
            .scaleEffect(hover ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
            .onHover { hover = $0 }
            .help(Prefs.bool("hideFloatingResultTooltips") ? "" : tip)
    }
}

struct ActionRow: View {
    @ObservedObject var item: ResultItem
    @ObservedObject var model = ResultsModel.shared

    var body: some View {
        let ids = Prefs.list("floatingResultActions")
        HStack(spacing: 5) {
            ForEach(ids, id: \.self) { id in ActionButton(item: item, id: id) }
            Spacer(minLength: 0)
            Menu { ActionMenu(item: item) } label: { RoundIcon(symbol: "ellipsis", tip: L("More")) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            if item.kind != .audio { FormatMenu(item: item) }
        }
    }
}

/// The format of the file, to change by clicking.
struct FormatMenu: View {
    @ObservedObject var item: ResultItem
    @ObservedObject var model = ResultsModel.shared

    static func targets(for kind: MediaKind) -> [String] {
        switch kind {
        case .image: ["jpeg", "png", "webp", "avif", "heic", "gif"].filter { ImageEngine.canWrite($0) }
        case .video: ["mp4", "hevc", "gif", "webm"].filter { $0 != "webm" || Tool.ffmpeg.available }
        case .audio: ["m4a", "mp3", "flac", "wav"].filter { $0 != "mp3" || Tool.ffmpeg.available }
        case .pdf: []
        }
    }

    var body: some View {
        let ext = item.current.pathExtension.uppercased()
        let options = Self.targets(for: item.kind).filter { !Media.sameFormat($0, item.current.pathExtension) }
        if options.isEmpty { chip(ext, tint: Color.white.opacity(0.5)) }
        else {
            Menu {
                ForEach(options, id: \.self) { o in Button(o.uppercased()) { model.convert(item, to: o) } }
            } label: { chip(ext, tint: item.kind.tint) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("Change the format"))
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(verbatim: text).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4).background(tint.opacity(0.16), in: Capsule())
    }
}

struct ActionButton: View {
    @ObservedObject var item: ResultItem
    let id: String
    @ObservedObject var model = ResultsModel.shared

    var body: some View {
        switch id {
        case "downscale" where item.kind != .pdf:
            Menu {
                ForEach([0.75, 0.5, 0.33, 0.25], id: \.self) { f in Button(L("Downscale to %d%%", Int(f * 100))) { model.downscale(item, factor: f) } }
            } label: { RoundIcon(symbol: "arrow.down.right.and.arrow.up.left", tip: L("Downscale")) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        case "compression":
            Button { model.compress(item, aggressive: false) } label: { RoundIcon(symbol: "wand.and.stars", tip: L("Optimise again")) }.buttonStyle(.plain)
        case "aggressiveOptimisation":
            Button { model.compress(item, aggressive: true) } label: { RoundIcon(symbol: "bolt.fill", tip: L("Aggressive optimisation")) }.buttonStyle(.plain)
        case "crop" where item.kind != .audio:
            Menu {
                ForEach(["1:1", "16:9", "4:3", "3:2", "9:16", "1200x630", "1920"], id: \.self) { s in Button(s) { model.crop(item, spec: s) } }
            } label: { RoundIcon(symbol: "crop", tip: L("Crop")) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        case "targetSize":
            Menu {
                ForEach([("500 KB", 500_000), ("1 MB", 1_000_000), ("10 MB", 10_000_000), ("16 MB", 16_000_000), ("25 MB", 25_000_000)], id: \.0) { l, b in Button(L("Fit under %@", l)) { model.fit(item, bytes: Int64(b)) } }
            } label: { RoundIcon(symbol: "scalemass", tip: L("Target size")) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        case "share":
            ShareLink(item: item.current) { RoundIcon(symbol: "square.and.arrow.up", tip: L("Share")) }.buttonStyle(.plain)
        case "restoreOptimise":
            if item.outcome?.backup != nil || item.state == .restored {
                Button { if item.state == .restored { model.optimiseAgain(item) } else { model.restore(item) } } label: {
                    RoundIcon(symbol: item.state == .restored ? "wand.and.stars" : "arrow.uturn.backward", tip: L(item.state == .restored ? "Optimise" : "Restore the original"))
                }.buttonStyle(.plain)
            }
        case "copyToClipboard": Button { model.copy(item) } label: { RoundIcon(symbol: "doc.on.doc", tip: L("Copy")) }.buttonStyle(.plain)
        case "showInFinder": Button { model.showInFinder(item) } label: { RoundIcon(symbol: "folder", tip: L("Show in Finder")) }.buttonStyle(.plain)
        case "quickLook": Button { QuickLook.show(item.current) } label: { RoundIcon(symbol: "eye", tip: L("Quick Look")) }.buttonStyle(.plain)
        case "saveAs": Button { model.saveAs(item) } label: { RoundIcon(symbol: "square.and.arrow.down", tip: L("Save as…")) }.buttonStyle(.plain)
        default: EmptyView()
        }
    }
}

struct ActionMenu: View {
    @ObservedObject var item: ResultItem
    @ObservedObject var model = ResultsModel.shared

    var body: some View {
        Button(L("Optimise again")) { model.optimiseAgain(item) }
        Button(L("Aggressive optimisation")) { model.compress(item, aggressive: true) }
        if item.outcome?.backup != nil { Button(L("Restore the original")) { model.restore(item) } }
        Divider()
        Menu(L("Downscale")) { ForEach([0.75, 0.5, 0.33, 0.25], id: \.self) { f in Button("\(Int(f * 100))%") { model.downscale(item, factor: f) } } }
        if item.kind != .audio { Menu(L("Crop")) { ForEach(["1:1", "16:9", "4:3", "3:2", "9:16", "1200x630", "1920"], id: \.self) { s in Button(s) { model.crop(item, spec: s) } } } }
        Menu(L("Convert to…")) { ForEach(FormatMenu.targets(for: item.kind), id: \.self) { o in Button(o.uppercased()) { model.convert(item, to: o) } } }
        Menu(L("Fit under…")) { ForEach([("500 KB", 500_000), ("1 MB", 1_000_000), ("10 MB", 10_000_000), ("25 MB", 25_000_000)], id: \.0) { l, b in Button(l) { model.fit(item, bytes: Int64(b)) } } }
        Divider()
        Button(L("Show in Finder")) { model.showInFinder(item) }
        Button(L("Quick Look")) { QuickLook.show(item.current) }
        Button(L("Save as…")) { model.saveAs(item) }
        Button(L("Copy")) { model.copy(item) }
        let app = Prefs.string("editorApp" + Prefs.kindName(item.kind))
        if !app.isEmpty {
            Button(L("Edit with %@", app)) { NSWorkspace.shared.open([item.current], withApplicationAt: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration()) }
        }
        Divider()
        Button(L("Dismiss")) { model.dismiss(item) }
    }
}

@MainActor
enum QuickLook {
    private static let source = QLSource()
    static func show(_ url: URL) {
        source.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = source
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    final class QLSource: NSObject, QLPreviewPanelDataSource {
        var url: URL?
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
    }
}
