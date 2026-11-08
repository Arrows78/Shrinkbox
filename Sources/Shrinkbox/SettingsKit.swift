import SwiftUI
import AppKit

/// The settings window's own look: a dark sidebar of tinted panes and, in each page, titled cards of explained rows.
enum SettingsStyle {
    static let window = NSColor(srgbRed: 0.106, green: 0.106, blue: 0.118, alpha: 1)
    static let accent = Color(red: 0.357, green: 0.549, blue: 1)
    static let dim = Color.white.opacity(0.45)
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, clipboard, fileHandling, images, video, audio, pdf, dropZone, results, automation, shortcuts, agents, tools, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .clipboard: "Clipboard"
        case .fileHandling: "File handling"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .dropZone: "Drop zone"
        case .results: "Floating results"
        case .automation: "Automation"
        case .shortcuts: "Shortcuts"
        case .agents: "Agents"
        case .tools: "Tools"
        case .about: "About"
        }
    }

    /// The `group` of the settings catalogue this pane shows.
    var group: String? {
        switch self {
        case .general: "General"
        case .clipboard: "Clipboard"
        case .fileHandling: "File handling"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .dropZone: "Drop Zone"
        case .results: "Floating Results"
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .fileHandling: "folder.fill"
        case .images: "photo.fill"
        case .video: "film.fill"
        case .audio: "waveform"
        case .pdf: "doc.richtext.fill"
        case .dropZone: "square.and.arrow.down.fill"
        case .results: "rectangle.stack.fill"
        case .automation: "wand.and.stars"
        case .shortcuts: "keyboard.fill"
        case .agents: "sparkles"
        case .tools: "wrench.and.screwdriver.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: Color(red: 0.557, green: 0.557, blue: 0.576)
        case .clipboard: Color(red: 0.173, green: 0.694, blue: 0.737)
        case .fileHandling: Color(red: 0.392, green: 0.455, blue: 0.545)
        case .images: Color(red: 0.357, green: 0.549, blue: 1)
        case .video: Color(red: 1, green: 0.353, blue: 0.322)
        case .audio: Color(red: 1, green: 0.624, blue: 0.04)
        case .pdf: Color(red: 0.898, green: 0.282, blue: 0.302)
        case .dropZone: Color(red: 0.188, green: 0.69, blue: 0.416)
        case .results: Color(red: 0.608, green: 0.42, blue: 1)
        case .automation: Color(red: 0.745, green: 0.353, blue: 0.949)
        case .shortcuts: Color(red: 1, green: 0.624, blue: 0.04)
        case .agents: Color(red: 0.945, green: 0.435, blue: 0.62)
        case .tools: Color(red: 0.188, green: 0.69, blue: 0.416)
        case .about: Color(red: 0.357, green: 0.549, blue: 1)
        }
    }
}

/// A titled, rounded group of rows. Each row draws the hairline above itself, so rows can come and go.
struct SettingsCard<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(SettingsStyle.dim).textCase(.uppercase).padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07)))
        }
    }
}

/// One setting: a title, an optional explanation and the control on the right.
struct SettingsRow<Control: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(SettingsStyle.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5).padding(.leading, 12) }
    }
}

struct SettingsToggle: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.title = title; self.subtitle = subtitle; self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(SettingsStyle.accent)
        }
    }
}

/// A footnote under a card.
struct SettingsNote: View {
    var text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View { Text(text).font(.system(size: 11)).foregroundStyle(SettingsStyle.dim).fixedSize(horizontal: false, vertical: true) }
}

/// A scrolling page with its tinted icon and title.
struct SettingsPage<Content: View>: View {
    var pane: SettingsPane
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: pane.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(pane.tint.gradient))
                    Text(pane.title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                }
                content
            }
            .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The sidebar: one tinted tile and a name per pane, the app's icon and version at the foot.
struct SettingsSidebar: View {
    @Binding var pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPane.allCases) { p in
                Button { pane = p } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(p.tint.gradient))
                        Text(p.title).font(.system(size: 13)).foregroundStyle(.white.opacity(pane == p ? 1 : 0.8))
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(pane == p ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pane == p ? .isSelected : [])
                if p == .results || p == .agents { Spacer().frame(height: 6) }
            }
            Spacer()
            SettingsSidebarFooter()
        }
        .padding(.horizontal, 10).padding(.top, 38)
        .frame(width: 190)
        .background(Color.black.opacity(0.18))
    }
}

struct SettingsSidebarFooter: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 2).padding(.bottom, 10)
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Shrinkbox").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    Text(verbatim: L("Version %@", version)).font(.system(size: 11)).foregroundStyle(SettingsStyle.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.bottom, 12)
        }
    }
}

// MARK: Rows generated from the settings catalogue

/// One row for one setting, whatever its kind. It follows changes made elsewhere (the CLI, an agent).
struct PrefRow: View {
    let pref: Pref
    @State private var text = ""
    @State private var on = false
    @State private var number = 0.0

    var body: some View {
        Group {
            switch pref.kind {
            case .bool:
                SettingsToggle(LocalizedStringKey(pref.title), pref.help.isEmpty ? nil : LocalizedStringKey(pref.help), isOn: Binding(get: { on }, set: { on = $0; Prefs.set(pref.key, $0 ? "true" : "false") }))
            case .int(let r):
                SettingsRow(title: LocalizedStringKey(pref.title), subtitle: sub) {
                    HStack(spacing: 6) {
                        TextField("", value: Binding(get: { Int(number) }, set: { number = Double(min(max($0, r.lowerBound), r.upperBound)); Prefs.set(pref.key, String(Int(number))) }), format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                        Stepper("", value: Binding(get: { Int(number) }, set: { number = Double($0); Prefs.set(pref.key, String($0)) }), in: r).labelsHidden()
                    }
                }
            case .double(let r):
                SettingsRow(title: LocalizedStringKey(pref.title), subtitle: sub) {
                    HStack {
                        Slider(value: Binding(get: { number }, set: { number = $0; Prefs.set(pref.key, String(format: "%g", $0)) }), in: r).frame(width: 150)
                        Text(verbatim: String(format: "%g", number)).monospacedDigit().frame(width: 36, alignment: .trailing).foregroundStyle(SettingsStyle.dim)
                    }
                }
            case .text:
                SettingsRow(title: LocalizedStringKey(pref.title), subtitle: sub) {
                    TextField("", text: Binding(get: { text }, set: { text = $0 }), onCommit: { commitText() })
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
            case .choice(let options):
                SettingsRow(title: LocalizedStringKey(pref.title), subtitle: sub) {
                    Picker("", selection: Binding(get: { text }, set: { text = $0; Prefs.set(pref.key, $0) })) {
                        ForEach(options, id: \.self) { Text(Self.label($0)).tag($0) }
                    }.labelsHidden().frame(width: 170)
                }
            case .multi(let fixed):
                let options = pref.key == "floatingResultActions" ? Builtins.buttonOptions() : fixed
                SettingsRow(title: LocalizedStringKey(pref.title), subtitle: sub) {
                    Menu {
                        ForEach(options, id: \.self) { o in
                            Button { toggle(o) } label: { Text(verbatim: (selected.contains(o) ? "✓ " : "") + Self.label(o)) }
                        }
                    } label: { Text(verbatim: selected.isEmpty ? L("None") : selected.map(Self.label).joined(separator: ", ")).lineLimit(1) }
                        .menuStyle(.borderlessButton).frame(width: 190, alignment: .trailing)
                }
            case .paths:
                PathsRow(pref: pref)
            }
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: .settingsChanged)) { n in if n.object == nil || (n.object as? String) == pref.key { load() } }
    }

    private var sub: LocalizedStringKey? { pref.help.isEmpty ? nil : LocalizedStringKey(pref.help) }
    private var selected: [String] { text.split(separator: ",").map(String.init) }

    private func load() {
        switch pref.kind {
        case .bool: on = Prefs.bool(pref.key)
        case .int: number = Double(Prefs.int(pref.key))
        case .double: number = Prefs.double(pref.key)
        default: text = Prefs.string(pref.key)
        }
    }

    private func commitText() {
        if let e = Prefs.set(pref.key, text) { NSSound.beep(); Log.write(e); text = Prefs.string(pref.key) }
    }

    private func toggle(_ o: String) {
        var s = selected
        if let i = s.firstIndex(of: o) { s.remove(at: i) } else { s.append(o) }
        text = s.joined(separator: ","); Prefs.set(pref.key, text)
    }

    static func label(_ value: String) -> String {
        if let l = Builtins.label(forAction: value) { return l }
        switch value {
        case "airDrop": return L("AirDrop")
        case "addToShelf": return L("Add to shelf")
        case "uploadWithDropshare": return L("Upload with Dropshare")
        case "compare": return L("Compare before and after")
        default: return baseLabel(value)
        }
    }

    private static func baseLabel(_ value: String) -> String {
        switch value {
        case "temporary": L("Temporary folder")
        case "inPlace": L("Replace the original")
        case "sameFolder": L("Same folder, new name")
        case "specificFolder": L("A specific folder")
        case "playFaster": L("Play faster")
        case "keepDuration": L("Keep the duration")
        case "keepFrames": L("Keep every frame")
        case "dropFrames": L("Drop frames")
        case "optimise": L("Optimise")
        case "remove": L("Remove")
        case "keep": L("Keep")
        case "bottomRight": L("Bottom right")
        case "bottomLeft": L("Bottom left")
        case "topRight": L("Top right")
        case "topLeft": L("Top left")
        case "downscale": L("Downscale")
        case "compression": L("Compression")
        case "crop": L("Crop")
        case "share": L("Share")
        case "restoreOptimise": L("Restore or optimise")
        case "aggressiveOptimisation": L("Aggressive optimisation")
        case "copyToClipboard": L("Copy to the clipboard")
        case "showInFinder": L("Show in Finder")
        case "quickLook": L("Quick Look")
        case "saveAs": L("Save as…")
        case "targetSize": L("Target size")
        default: value.uppercased() == value || value.count <= 4 ? value.uppercased() : value
        }
    }
}

/// A list of folders with Add and Remove.
struct PathsRow: View {
    let pref: Pref
    @State private var paths: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: LocalizedStringKey(pref.title), subtitle: pref.help.isEmpty ? nil : LocalizedStringKey(pref.help)) {
                Button(L("Add folder…")) {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
                    if p.runModal() == .OK { for u in p.urls where !paths.contains(u.path) { paths.append(u.path) }; save() }
                }.controlSize(.small)
            }
            ForEach(paths, id: \.self) { path in
                HStack {
                    Image(systemName: "folder").foregroundStyle(SettingsStyle.dim)
                    Text(verbatim: (path as NSString).abbreviatingWithTildeInPath).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { paths.removeAll { $0 == path }; save() } label: { Image(systemName: "minus.circle.fill") }.buttonStyle(.plain).foregroundStyle(SettingsStyle.dim)
                }.padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .onAppear { paths = Prefs.list(pref.key) }
        .onReceive(NotificationCenter.default.publisher(for: .settingsChanged)) { _ in paths = Prefs.list(pref.key) }
    }

    private func save() { Prefs.set(pref.key, paths.joined(separator: ",")) }
}

/// Every card of a group of the catalogue, one per section.
struct PrefGroupPage: View {
    let pane: SettingsPane
    var body: some View {
        SettingsPage(pane: pane) {
            if let g = pane.group {
                let prefs = Prefs.all.filter { $0.group == g }
                let sections = prefs.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
                ForEach(sections, id: \.self) { s in
                    SettingsCard(title: LocalizedStringKey(s)) {
                        ForEach(prefs.filter { $0.section == s }, id: \.key) { PrefRow(pref: $0) }
                    }
                }
            }
        }
    }
}
