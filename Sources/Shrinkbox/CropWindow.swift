import SwiftUI
import AppKit
import AVFoundation
import ImageIO

/// A named size or shape for cropping: "Open Graph" is 1200x630, "Square" is 1:1.
struct CropPreset: Identifiable, Hashable, Codable, Sendable {
    var name: String
    var spec: String
    var id: String { name + "|" + spec }
}

/// The sizes of the crop menu. They live in one setting as `Name|spec;Name|spec`, with a list of defaults to go back to.
enum CropPresets {
    static let defaults: [CropPreset] = [
        CropPreset(name: "Square", spec: "1:1"), CropPreset(name: "Landscape 16:9", spec: "16:9"), CropPreset(name: "Classic 4:3", spec: "4:3"), CropPreset(name: "Photo 3:2", spec: "3:2"),
        CropPreset(name: "Portrait 9:16", spec: "9:16"), CropPreset(name: "Link preview", spec: "1200x630"), CropPreset(name: "YouTube thumbnail", spec: "1280x720"),
        CropPreset(name: "Instagram post", spec: "1080x1350"), CropPreset(name: "Story or Reel", spec: "1080x1920"), CropPreset(name: "X header", spec: "1500x500"),
        CropPreset(name: "Google Play screenshot", spec: "1080x1920"), CropPreset(name: "App Store screenshot", spec: "1290x2796"), CropPreset(name: "Full HD", spec: "1920x1080"),
        CropPreset(name: "Long edge 1600", spec: "1600"),
    ]

    /// Paper and devices, offered in the window next to the saved sizes.
    static let references: [CropPreset] = [
        CropPreset(name: "A4 at 150 dpi", spec: "1240x1754"), CropPreset(name: "A5 at 150 dpi", spec: "874x1240"), CropPreset(name: "US Letter at 150 dpi", spec: "1275x1650"),
        CropPreset(name: "iPhone 15 Pro", spec: "1179x2556"), CropPreset(name: "iPhone 15 Pro Max", spec: "1290x2796"), CropPreset(name: "iPad Pro 13-inch", spec: "2064x2752"),
        CropPreset(name: "MacBook Air 13-inch", spec: "2560x1664"), CropPreset(name: "4K", spec: "3840x2160"), CropPreset(name: "Favicon", spec: "512x512"),
    ]

    static func load() -> [CropPreset] {
        let text = Prefs.string("cropPresets")
        guard !text.isEmpty else { return defaults }
        let list = text.split(separator: ";").compactMap { chunk -> CropPreset? in
            let p = chunk.split(separator: "|", maxSplits: 1).map(String.init)
            guard p.count == 2, CropSpec.parse(p[1]) != nil else { return nil }
            return CropPreset(name: p[0], spec: p[1])
        }
        return list.isEmpty ? defaults : list
    }

    static func save(_ list: [CropPreset]) {
        let text = list.map { "\($0.name.replacingOccurrences(of: ";", with: " ").replacingOccurrences(of: "|", with: " "))|\($0.spec)" }.joined(separator: ";")
        Prefs.set("cropPresets", text)
    }

    static func reset() { Prefs.reset("cropPresets") }
}

/// Crop and resize one result: a size or a shape, with a live preview and the sizes you saved.
@MainActor
enum CropWindow {
    private static var windows: [NSWindow] = []

    static func show(_ item: ResultItem) {
        let model = CropModel(item: item)
        let w = NSWindow(contentViewController: NSHostingController(rootView: CropView(model: model)))
        w.title = L("Crop and resize…")
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = SettingsStyle.window
        w.isReleasedWhenClosed = false
        w.center()
        windows.append(w)
        model.close = { [weak w] in w?.close() }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class CropModel: ObservableObject {
    enum Mode: String, CaseIterable { case size, ratio }

    let item: ResultItem
    @Published var mode = Mode.size
    @Published var width = ""
    @Published var height = ""
    @Published var ratio = "16:9"
    @Published var longEdge = false
    @Published var lockAspect = true
    @Published var smart = true
    @Published var frame = 0.0           // position in a video, 0...1
    @Published var preview: CGImage?
    @Published var presets = CropPresets.load()
    var source: (Int, Int) = (0, 0)
    var close: () -> Void = {}

    init(item: ResultItem) {
        self.item = item
        loadPreview()
    }

    var spec: String? {
        switch mode {
        case .ratio: return CropSpec.parse(ratio) != nil ? ratio : nil
        case .size:
            let w = Int(width), h = Int(height)
            if longEdge { return (w ?? h).map(String.init) }
            if let w, let h { return "\(w)x\(h)" }
            if let w { return String(w) }
            if let h { return "x\(h)" }
            return nil
        }
    }

    /// The pixel size the current choice gives, for the label under the preview.
    var result: (Int, Int)? {
        guard let s = spec, let crop = CropSpec.parse(s, longEdge: longEdge && mode == .size), source.0 > 0 else { return nil }
        return ImageEngine.plan(crop, for: source)?.output
    }

    func widthChanged() {
        guard mode == .size, lockAspect, !longEdge, source.0 > 0, let w = Int(width) else { return }
        height = String(max(1, Int((Double(w) * Double(source.1) / Double(source.0)).rounded())))
    }

    func heightChanged() {
        guard mode == .size, lockAspect, !longEdge, source.1 > 0, let h = Int(height) else { return }
        width = String(max(1, Int((Double(h) * Double(source.0) / Double(source.1)).rounded())))
    }

    func apply(_ preset: CropPreset) {
        if preset.spec.contains(":") { mode = .ratio; ratio = preset.spec; return }
        mode = .size
        let isEdge = !preset.spec.contains("x")
        longEdge = isEdge
        lockAspect = false
        if isEdge { width = preset.spec; height = "" }
        else { let p = preset.spec.split(separator: "x").map(String.init); width = p.first ?? ""; height = p.count > 1 ? p[1] : "" }
    }

    func savePreset(named name: String) {
        guard let s = spec, !name.isEmpty else { return }
        let value = longEdge && mode == .size ? s : s
        presets.append(CropPreset(name: name, spec: value))
        CropPresets.save(presets)
    }

    func resetPresets() { CropPresets.reset(); presets = CropPresets.load() }

    func loadPreview() {
        let url = item.current
        Task {
            var image: CGImage?
            switch item.kind {
            case .image: if let s = CGImageSourceCreateWithURL(url as CFURL, nil) { image = try? ImageEngine.loadOriented(s) }
            case .video:
                let asset = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: asset); gen.appliesPreferredTrackTransform = true
                let d = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
                image = try? await gen.image(at: CMTime(seconds: d * frame, preferredTimescale: 600)).image
            default: break
            }
            if let image { preview = image; source = (image.width, image.height); if width.isEmpty && height.isEmpty { width = String(image.width); height = String(image.height) } }
        }
    }

    func run() {
        guard let s = spec else { return }
        ResultsModel.shared.crop(item, spec: s, longEdge: longEdge && mode == .size, smart: smart)
        close()
    }
}

struct CropView: View {
    @ObservedObject var model: CropModel
    @State private var presetName = ""

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 10) {
                PreviewBox(model: model)
                if model.item.kind == .video {
                    HStack { Image(systemName: "film").foregroundStyle(CardStyle.dim); Slider(value: $model.frame, in: 0...1).onChange(of: model.frame) { _ in model.loadPreview() } }
                        .help(L("Choose the video frame used for the crop preview"))
                }
                Text(verbatim: sizeLine).font(.system(size: 11, design: .rounded)).foregroundStyle(CardStyle.dim).monospacedDigit()
            }.frame(width: 340).padding(20)
            Divider().overlay(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $model.mode) { Text("Size").tag(CropModel.Mode.size); Text("Aspect ratio").tag(CropModel.Mode.ratio) }.pickerStyle(.segmented).labelsHidden()
                if model.mode == .size { sizeFields } else { TextField("16:9", text: $model.ratio).textFieldStyle(.roundedBorder) }
                if model.item.kind == .image { Toggle("Smart crop", isOn: $model.smart).toggleStyle(.switch).controlSize(.small) }
                presetList
                HStack {
                    TextField("Name this size", text: $presetName).textFieldStyle(.roundedBorder)
                    Button("Save size") { model.savePreset(named: presetName); presetName = "" }.disabled(presetName.isEmpty || model.spec == nil).controlSize(.small)
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Bring back default sizes") { model.resetPresets() }.controlSize(.small)
                    Spacer()
                    Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                    Button("Crop") { model.run() }.keyboardShortcut(.defaultAction).disabled(model.spec == nil)
                }
            }.padding(20).frame(width: 340)
        }
        .frame(height: 440)
        .background(Color(nsColor: SettingsStyle.window))
        .preferredColorScheme(.dark)
    }

    private var sizeLine: String {
        guard let r = model.result else { return model.source.0 > 0 ? L("Already at this size") : "" }
        return "\(model.source.0)×\(model.source.1) → \(r.0)×\(r.1)"
    }

    private var sizeFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Width", text: $model.width).textFieldStyle(.roundedBorder).onChange(of: model.width) { _ in model.widthChanged() }
                Button { model.lockAspect.toggle() } label: { Image(systemName: model.lockAspect ? "lock.fill" : "lock.open") }.buttonStyle(.plain).disabled(model.longEdge)
                    .help(L(model.lockAspect ? "Aspect ratio locked, click to unlock" : "Aspect ratio unlocked, click to lock"))
                TextField("Height", text: $model.height).textFieldStyle(.roundedBorder).disabled(model.longEdge).onChange(of: model.height) { _ in model.heightChanged() }
            }
            Toggle("Resize over long edge", isOn: $model.longEdge).toggleStyle(.switch).controlSize(.small)
                .help(L("Resize images until the longest edge is equal or lower than the specified size."))
        }
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sizes").font(.system(size: 11, weight: .semibold)).foregroundStyle(CardStyle.dim).textCase(.uppercase)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.presets) { p in row(p, removable: true) }
                    Divider().padding(.vertical, 4)
                    Text("Paper size or device").font(.system(size: 10)).foregroundStyle(CardStyle.dim).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(CropPresets.references) { p in row(p, removable: false) }
                }
            }.frame(height: 150)
        }
    }

    private func row(_ p: CropPreset, removable: Bool) -> some View {
        HStack {
            Button { model.apply(p) } label: {
                HStack { Text(verbatim: L(p.name)); Spacer(); Text(verbatim: p.spec).foregroundStyle(CardStyle.dim).monospacedDigit() }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if removable { Button { model.presets.removeAll { $0.id == p.id }; CropPresets.save(model.presets) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(CardStyle.dim) }
        }.font(.system(size: 12)).padding(.vertical, 3).padding(.horizontal, 6)
    }
}

/// The image with the part that stays outlined and the rest dimmed.
private struct PreviewBox: View {
    @ObservedObject var model: CropModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35))
            if let cg = model.preview {
                GeometryReader { g in
                    let fit = min(g.size.width / CGFloat(cg.width), g.size.height / CGFloat(cg.height))
                    let w = CGFloat(cg.width) * fit, h = CGFloat(cg.height) * fit
                    ZStack {
                        Image(decorative: cg, scale: 1).resizable().frame(width: w, height: h)
                        cropOutline(w: w, h: h)
                    }.frame(width: g.size.width, height: g.size.height)
                }
            } else { Image(systemName: model.item.kind.symbol).font(.system(size: 34)).foregroundStyle(CardStyle.dim) }
        }.frame(height: 250)
    }

    @ViewBuilder private func cropOutline(w: CGFloat, h: CGFloat) -> some View {
        if let s = model.spec, let crop = CropSpec.parse(s, longEdge: model.longEdge && model.mode == .size), let plan = ImageEngine.plan(crop, for: model.source) {
            let r = plan.region
            let sx = w / CGFloat(max(1, model.source.0)), sy = h / CGFloat(max(1, model.source.1))
            Rectangle().strokeBorder(Color.white, lineWidth: 1.5).frame(width: r.width * sx, height: r.height * sy)
                .background(Color.white.opacity(0.08))
        }
    }
}
