import SwiftUI
import AppKit
import QuickLookUI

/// The floating stack of results: full cards, or one line each when there are many.
struct ResultsView: View {
    @ObservedObject var model = ResultsModel.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if model.items.count > 1, Prefs.bool("showCopyClearButtons") || true {
                HStack(spacing: 6) {
                    Spacer()
                    Pill(title: "Copy all", symbol: "doc.on.doc") { model.copyAll() }
                    Pill(title: "Clear all", symbol: "xmark") { model.clearAll() }
                }
            }
            ForEach(model.items.suffix(8)) { item in
                if model.compact { CompactRow(item: item) } else { ResultCard(item: item) }
            }
        }
        .padding(10)
        .frame(width: model.compact ? 300 : 340, alignment: .trailing)
        .preferredColorScheme(.dark)
    }
}

private struct Pill: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule()).overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }
}

struct Thumb: View {
    @ObservedObject var item: ResultItem
    var size: CGFloat
    var body: some View {
        Group {
            if let t = item.thumbnail { Image(nsImage: t).resizable().scaledToFill() }
            else { Image(systemName: item.kind.symbol).font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.6)) }
        }
        .frame(width: size, height: size).background(Color.white.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// "12 MB → 3 MB  -75%"
struct SizeLine: View {
    @ObservedObject var item: ResultItem
    var body: some View {
        switch item.state {
        case .waiting: Text("Waiting").foregroundStyle(.secondary)
        case .running(let p):
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.label ?? L("Optimising…")).foregroundStyle(.secondary)
                ProgressView(value: p > 0 ? p : nil).progressViewStyle(.linear).tint(SettingsStyle.accent)
            }
        case .done:
            if let o = item.outcome {
                HStack(spacing: 6) {
                    Text(verbatim: "\(Files.human(o.originalSize)) → \(Files.human(o.newSize))").monospacedDigit()
                    Text(verbatim: o.percent > 0 ? "-\(o.percent)%" : "0%").fontWeight(.semibold).foregroundStyle(o.percent > 0 ? Color.green : .secondary)
                }
            }
        case .skipped(let m): Text(verbatim: m).foregroundStyle(.secondary)
        case .failed(let m): Text(verbatim: m).foregroundStyle(.orange).lineLimit(2)
        case .restored: Text("Original restored").foregroundStyle(.secondary)
        }
    }
}

struct ResultCard: View {
    @ObservedObject var item: ResultItem
    @ObservedObject var model = ResultsModel.shared
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumb(item: item, size: 56)
                .onDrag { NSItemProvider(object: item.current as NSURL) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: item.current.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if item.isBusy { Button { model.stop(item) } label: { Image(systemName: "stop.circle") }.buttonStyle(.plain).help(L("Stop")) }
                    else { Button { model.dismiss(item) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovering ? 1 : 0.4) }
                }
                SizeLine(item: item).font(.system(size: 11))
                if !item.isBusy { ActionRow(item: item) }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        .onHover { hovering = $0; if $0 { model.holdOpen(item) } else if !item.isBusy { model.scheduleHide(item) } }
    }
}

struct CompactRow: View {
    @ObservedObject var item: ResultItem
    @ObservedObject var model = ResultsModel.shared

    var body: some View {
        HStack(spacing: 8) {
            if Prefs.bool("showCompactImages") { Thumb(item: item, size: 22) } else { Image(systemName: item.kind.symbol).foregroundStyle(.secondary).frame(width: 22) }
            Text(verbatim: item.current.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let p = item.progress { ProgressView(value: p > 0 ? p : nil).progressViewStyle(.circular).controlSize(.small) }
            else if let o = item.outcome, case .done = item.state { Text(verbatim: o.percent > 0 ? "-\(o.percent)%" : "0%").font(.system(size: 11, weight: .semibold)).foregroundStyle(o.percent > 0 ? Color.green : .secondary) }
            else if case .failed = item.state { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Menu { ActionMenu(item: item) } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .onDrag { NSItemProvider(object: item.current as NSURL) }
    }
}

struct ActionRow: View {
    @ObservedObject var item: ResultItem
    @ObservedObject var model = ResultsModel.shared

    var body: some View {
        let ids = Prefs.list("floatingResultActions")
        HStack(spacing: 4) {
            ForEach(ids, id: \.self) { id in ActionButton(item: item, id: id) }
            Spacer(minLength: 0)
            Menu { ActionMenu(item: item) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            if item.kind != .audio { FormatMenu(item: item) }
        }.font(.system(size: 11))
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
        if options.isEmpty { Text(verbatim: ext).foregroundStyle(.secondary) }
        else {
            Menu {
                ForEach(options, id: \.self) { o in Button(o.uppercased()) { model.convert(item, to: o) } }
            } label: { Text(verbatim: ext).font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.white.opacity(0.12), in: Capsule()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("Change the format"))
        }
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
            } label: { icon("arrow.down.right.and.arrow.up.left", L("Downscale")) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        case "compression":
            Button { model.compress(item, aggressive: false) } label: { icon("wand.and.stars", L("Optimise again")) }.buttonStyle(.plain)
        case "aggressiveOptimisation":
            Button { model.compress(item, aggressive: true) } label: { icon("bolt.fill", L("Aggressive optimisation")) }.buttonStyle(.plain)
        case "crop" where item.kind != .audio:
            Menu {
                ForEach(["1:1", "16:9", "4:3", "3:2", "9:16", "1200x630", "1920"], id: \.self) { s in Button(s) { model.crop(item, spec: s) } }
            } label: { icon("crop", L("Crop")) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        case "targetSize":
            Menu {
                ForEach([("500 KB", 500_000), ("1 MB", 1_000_000), ("10 MB", 10_000_000), ("16 MB", 16_000_000), ("25 MB", 25_000_000)], id: \.0) { l, b in Button(L("Fit under %@", l)) { model.fit(item, bytes: Int64(b)) } }
            } label: { icon("scalemass", L("Target size")) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        case "share":
            ShareLink(item: item.current) { icon("square.and.arrow.up", L("Share")) }.buttonStyle(.plain)
        case "restoreOptimise":
            if item.outcome?.backup != nil || item.state == .restored { Button { item.state == .restored ? model.optimiseAgain(item) : model.restore(item) } label: { icon(item.state == .restored ? "wand.and.stars" : "arrow.uturn.backward", L(item.state == .restored ? "Optimise" : "Restore the original")) }.buttonStyle(.plain) }
        case "copyToClipboard": Button { model.copy(item) } label: { icon("doc.on.doc", L("Copy")) }.buttonStyle(.plain)
        case "showInFinder": Button { model.showInFinder(item) } label: { icon("folder", L("Show in Finder")) }.buttonStyle(.plain)
        case "quickLook": Button { QuickLook.show(item.current) } label: { icon("eye", L("Quick Look")) }.buttonStyle(.plain)
        case "saveAs": Button { model.saveAs(item) } label: { icon("square.and.arrow.down", L("Save as…")) }.buttonStyle(.plain)
        default: EmptyView()
        }
    }

    private func icon(_ symbol: String, _ tip: String) -> some View {
        Image(systemName: symbol).frame(width: 24, height: 22).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous)).help(Prefs.bool("hideFloatingResultTooltips") ? "" : tip)
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
        if item.kind != .pdf && item.kind != .audio || item.kind == .audio {
            Menu(L("Downscale")) { ForEach([0.75, 0.5, 0.33, 0.25], id: \.self) { f in Button("\(Int(f * 100))%") { model.downscale(item, factor: f) } } }
        }
        if item.kind != .audio { Menu(L("Crop")) { ForEach(["1:1", "16:9", "4:3", "3:2", "9:16", "1200x630", "1920"], id: \.self) { s in Button(s) { model.crop(item, spec: s) } } } }
        Menu(L("Convert to…")) { ForEach(FormatMenu.targets(for: item.kind), id: \.self) { o in Button(o.uppercased()) { model.convert(item, to: o) } } }
        Menu(L("Fit under…")) { ForEach([("500 KB", 500_000), ("1 MB", 1_000_000), ("10 MB", 10_000_000), ("25 MB", 25_000_000)], id: \.0) { l, b in Button(l) { model.fit(item, bytes: Int64(b)) } } }
        Divider()
        Button(L("Show in Finder")) { model.showInFinder(item) }
        Button(L("Quick Look")) { QuickLook.show(item.current) }
        Button(L("Save as…")) { model.saveAs(item) }
        Button(L("Copy")) { model.copy(item) }
        if let app = Optional(Prefs.string("editorApp" + Prefs.kindName(item.kind))), !app.isEmpty {
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
