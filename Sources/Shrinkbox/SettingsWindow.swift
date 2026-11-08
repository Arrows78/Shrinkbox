import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var pane: SettingsPane

    init(pane: SettingsPane = .general) { _pane = State(initialValue: pane) }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(pane: $pane)
            Divider().overlay(Color.white.opacity(0.08))
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 800, height: 600)
        .background(Color(nsColor: SettingsStyle.window))
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var page: some View {
        switch pane {
        case .automation: AutomationPane()
        case .shortcuts: ShortcutsPane()
        case .agents: AgentsPane()
        case .tools: ToolsPane()
        case .about: AboutPane()
        default: PrefGroupPage(pane: pane)
        }
    }
}

// MARK: Automation

/// Steps to insert into a pipeline, with the text they add.
enum StepTemplates {
    static let all: [(title: String, text: String)] = [
        ("Optimise", "optimise"), ("Optimise, aggressively", "optimise(encoder: aggressive)"), ("Downscale to half", "downscale(factor: 0.5)"),
        ("Crop to a long edge of 1600", "crop(longEdge: 1600)"), ("Crop to 16:9", "crop(aspectRatio: 16:9)"), ("Convert to WebP", "convert(to: webp)"),
        ("Convert to JPEG", "convert(to: jpeg)"), ("Convert to MP4", "convert(to: mp4)"), ("Convert to GIF", "convert(to: gif)"), ("Convert to MP3", "convert(to: mp3)"),
        ("Fit under 10 MB", "targetSize(size: 10MB)"), ("Strip metadata", "stripExif"), ("Remove the audio", "removeAudio"), ("Double the speed", "changeSpeed(factor: 2.0, frames: drop)"),
        ("Watermark", "watermark(image: \"%P/watermark.png\")"), ("Only if the name matches", "if(regex: \"^IMG\")"), ("Only for some formats", "if(types: jpeg png)"),
        ("Move to a folder", "move(to: \"~/Pictures/Optimised/\")"), ("Copy to a folder", "copy(to: \"~/Pictures/Backup/\")"), ("Rename", "rename(to: \"%f-%y%m%d\")"),
        ("Copy the path to the clipboard", "copyToClipboard(format: path)"), ("Keep a second card", "fork"), ("Run a Shortcut", "runShortcut(name: \"My shortcut\")"),
    ]
}

struct AutomationPane: View {
    @State private var library = Library.load()
    @State private var editing: String?
    @State private var name = ""
    @State private var steps = ""
    @State private var type: MediaKind?
    @State private var skip = false
    @State private var error: String?

    var body: some View {
        SettingsPage(pane: .automation) {
            pipelinesCard
            editorCard
            AutomationsCard(library: $library)
            PresetZonesCard(library: $library)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryChanged)) { _ in library = Library.load() }
    }

    private var pipelinesCard: some View {
        SettingsCard(title: "Saved pipelines") {
            if library.pipelines.isEmpty {
                SettingsRow(title: "No saved pipeline", subtitle: "A pipeline chains steps like crop, convert and move. Save one below, or with the command line.") { EmptyView() }
            }
            ForEach(library.pipelines) { p in
                SettingsRow(title: LocalizedStringKey(p.name), subtitle: LocalizedStringKey(p.steps)) {
                    HStack(spacing: 10) {
                        Picker("", selection: Binding(get: { p.fileType }, set: { retype(p, $0) })) {
                            Text("Any").tag(MediaKind?.none)
                            ForEach(MediaKind.allCases, id: \.self) { Text(verbatim: $0.title).tag(MediaKind?.some($0)) }
                        }.labelsHidden().frame(width: 110).help(L("Move this pipeline to another file type"))
                        Button { edit(p) } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(SettingsStyle.dim)
                        Button { remove { $0.pipelines.removeAll { $0.id == p.id } } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(SettingsStyle.dim)
                    }
                }
            }
        }
    }

    private var editorCard: some View {
        SettingsCard(title: editing == nil ? "New pipeline" : "Edit the pipeline") {
            SettingsRow(title: "Name") { TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 260) }
            SettingsRow(title: "Steps") {
                HStack {
                    TextField(String("crop(longEdge: 1600) -> convert(to: webp)"), text: $steps).textFieldStyle(.roundedBorder).frame(width: 330)
                    Menu {
                        ForEach(StepTemplates.all, id: \.text) { t in Button(LocalizedStringKey(t.title)) { steps += (steps.isEmpty ? "" : " -> ") + t.text } }
                    } label: { Label("Add a step", systemImage: "plus") }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            SettingsRow(title: "For files of type") {
                Picker("", selection: $type) {
                    Text("Any").tag(MediaKind?.none)
                    ForEach(MediaKind.allCases, id: \.self) { Text(verbatim: $0.title).tag(MediaKind?.some($0)) }
                }.labelsHidden().frame(width: 140)
            }
            SettingsToggle("Skip the optimisation", "Otherwise files are optimised first, then the steps run.", isOn: $skip)
            SettingsRow(title: "") {
                HStack {
                    if let e = error { Text(verbatim: e).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2) }
                    if editing != nil { Button("Cancel") { reset() }.controlSize(.small) }
                    Button(editing == nil ? "Save pipeline" : "Update the pipeline") { save() }.disabled(name.isEmpty || steps.isEmpty).controlSize(.small)
                }
            }
        }
    }

    private func edit(_ p: SavedPipeline) { editing = p.name; name = p.name; steps = p.steps; type = p.fileType; skip = p.skipOptimisation; error = nil }
    private func reset() { editing = nil; name = ""; steps = ""; type = nil; skip = false; error = nil }

    private func retype(_ p: SavedPipeline, _ kind: MediaKind?) {
        remove { lib in if let i = lib.pipelines.firstIndex(where: { $0.id == p.id }) { lib.pipelines[i].fileType = kind } }
    }

    private func remove(_ change: @escaping (inout Library.Content) -> Void) {
        try? Library.update { change(&$0) }
        library = Library.load()
    }

    private func save() {
        do {
            _ = try PipelineParser.parse(steps)
            try Library.update { lib in
                if let old = editing { lib.pipelines.removeAll { $0.name.caseInsensitiveCompare(old) == .orderedSame } }
                lib.pipelines.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                lib.pipelines.append(SavedPipeline(name: name, fileType: type, steps: steps, skipOptimisation: skip))
            }
            reset(); library = Library.load()
        } catch { self.error = error.localizedDescription }
    }
}

/// Pipelines that run by themselves on a folder, the clipboard or the drop zone.
private struct AutomationsCard: View {
    @Binding var library: Library.Content
    @State private var source = "clipboard"
    @State private var folder = ""
    @State private var type = MediaKind.image
    @State private var pipeline = ""
    @State private var error: String?

    private var choices: [(id: String, title: String)] {
        let built = Builtins.pipelines(for: type).map { (id: $0.id, title: $0.title) }
        let saved = library.pipelines.filter { $0.fileType == nil || $0.fileType == type }.map { (id: $0.name, title: $0.name) }
        return built + saved
    }

    var body: some View {
        SettingsCard(title: "Automations") {
            if library.attachments.isEmpty {
                SettingsRow(title: "No automation", subtitle: "Attach a pipeline to a folder, the clipboard or the drop zone below, or with “shrinkbox pipeline attach”.") { EmptyView() }
            }
            ForEach(Array(library.attachments.enumerated()), id: \.offset) { i, a in
                SettingsRow(title: LocalizedStringKey("\(label(a.source)) · \(a.type.title)"), subtitle: LocalizedStringKey(Builtins.find(a.pipeline)?.title ?? a.pipeline)) {
                    Button { remove(i) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(SettingsStyle.dim).help(L("Remove this folder from automation"))
                }
            }
            SettingsRow(title: "Add an automation") {
                HStack {
                    Picker("", selection: $source) { Text("Clipboard").tag("clipboard"); Text("Drop zone").tag("dropZone"); Text("Folder…").tag("folder") }.labelsHidden().frame(width: 120)
                    Picker("", selection: $type) { ForEach(MediaKind.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) } }.labelsHidden().frame(width: 100)
                }
            }
            SettingsRow(title: "Pipeline") {
                HStack {
                    Picker("", selection: $pipeline) { Text("Choose…").tag(""); ForEach(choices, id: \.id) { Text(verbatim: $0.title).tag($0.id) } }.labelsHidden().frame(width: 190)
                    Button("Add") { add() }.disabled(pipeline.isEmpty).controlSize(.small)
                }
            }
            if let e = error { SettingsRow(title: "") { Text(verbatim: e).font(.system(size: 11)).foregroundStyle(.orange) } }
        }
    }

    private func label(_ source: String) -> String {
        switch source.lowercased() {
        case "clipboard": L("Clipboard")
        case "dropzone": L("Drop zone")
        default: (source as NSString).abbreviatingWithTildeInPath
        }
    }

    private func remove(_ index: Int) {
        try? Library.update { lib in
            guard lib.attachments.indices.contains(index) else { return }
            let a = lib.attachments.remove(at: index)
            // The last automation of a folder also stops the watching of it for that kind.
            if !["clipboard", "dropzone"].contains(a.source.lowercased()), !lib.attachments.contains(where: { $0.source == a.source && $0.type == a.type }) {
                let key = "\(a.type.rawValue)WatchPaths"
                Prefs.set(key, Prefs.list(key).filter { $0 != a.source }.joined(separator: ","))
            }
        }
        library = Library.load()
    }

    private func add() {
        var src = source
        if source == "folder" {
            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
            guard p.runModal() == .OK, let u = p.url else { return }
            src = u.path
        }
        let isSaved = library.pipelines.contains { $0.name == pipeline }
        do {
            try Library.update { lib in
                lib.attachments.append(Attachment(source: src, type: type, pipeline: pipeline, inline: !isSaved && Builtins.find(pipeline) == nil))
                if src != "clipboard", src != "dropZone" {
                    let key = "\(type.rawValue)WatchPaths"
                    var paths = Prefs.list(key)
                    if !paths.contains(src) { paths.append(src); Prefs.set(key, paths.joined(separator: ",")) }
                    Prefs.set("enableAutomatic\(Prefs.kindName(type))Optimisations", "true")
                }
            }
            error = nil; library = Library.load()
        } catch { self.error = error.localizedDescription }
    }
}

/// Zones that show up around the drop zone while Control is held.
private struct PresetZonesCard: View {
    @Binding var library: Library.Content
    @State private var name = ""
    @State private var pipeline = ""
    @State private var type: MediaKind?
    @State private var icon = "wand.and.stars"

    private static let icons = ["wand.and.stars", "bolt.fill", "globe", "photo", "film", "doc.richtext", "waveform", "square.fill", "arrow.down.right.and.arrow.up.left", "bubble.left.fill", "envelope.fill", "paperplane.fill"]

    private var choices: [(id: String, title: String)] {
        let built = Builtins.all.filter { type == nil || $0.kind == type }.map { (id: $0.id, title: $0.title) }
        let saved = library.pipelines.filter { type == nil || $0.fileType == nil || $0.fileType == type }.map { (id: $0.name, title: $0.name) }
        return built + saved
    }

    var body: some View {
        SettingsCard(title: "Preset zones") {
            if library.zones.isEmpty {
                SettingsRow(title: "No preset zone", subtitle: "Hold Control while dragging a file to the drop zone to see them.") { EmptyView() }
            }
            ForEach(library.zones) { z in
                SettingsRow(title: LocalizedStringKey(z.name), subtitle: LocalizedStringKey(Builtins.find(z.pipeline)?.title ?? z.pipeline)) {
                    HStack {
                        Image(systemName: z.icon).foregroundStyle(SettingsStyle.dim)
                        Button { try? Library.update { $0.zones.removeAll { $0.id == z.id } }; library = Library.load() } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(SettingsStyle.dim).help(L("Remove from zone"))
                    }
                }
            }
            SettingsRow(title: "Name") { TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 200) }
            SettingsRow(title: "Runs") {
                HStack {
                    Picker("", selection: $type) { Text("Any").tag(MediaKind?.none); ForEach(MediaKind.allCases, id: \.self) { Text(verbatim: $0.title).tag(MediaKind?.some($0)) } }.labelsHidden().frame(width: 100)
                    Picker("", selection: $pipeline) { Text("Choose…").tag(""); ForEach(choices, id: \.id) { Text(verbatim: $0.title).tag($0.id) } }.labelsHidden().frame(width: 170)
                }
            }
            SettingsRow(title: "Icon") {
                Picker("", selection: $icon) { ForEach(Self.icons, id: \.self) { Label($0, systemImage: $0).tag($0) } }.labelsHidden().frame(width: 200)
            }
            SettingsRow(title: "") { Button("Add the zone") { add() }.disabled(name.isEmpty || pipeline.isEmpty).controlSize(.small) }
        }
    }

    private func add() {
        let isSaved = library.pipelines.contains { $0.name == pipeline }
        let zone = PresetZone(name: name, pipeline: pipeline, inline: !isSaved && Builtins.find(pipeline) == nil, type: type, icon: icon)
        try? Library.update { lib in lib.zones.removeAll { $0.id == zone.id }; lib.zones.append(zone) }
        name = ""; pipeline = ""; library = Library.load()
    }
}

// MARK: Shortcuts

struct ShortcutsPane: View {
    var body: some View {
        SettingsPage(pane: .shortcuts) {
            SettingsCard {
                ForEach(HotkeyAction.allCases) { a in
                    SettingsRow(title: LocalizedStringKey(a.title)) { ShortcutField(action: a) }
                }
            }
            SettingsCard(title: "Keys of the floating results") {
                PrefRow(pref: Prefs.byKey["triggerKeys"]!)
                ForEach(ResultKeys.Key.allCases) { k in SettingsRow(title: LocalizedStringKey(k.title)) { Keycaps(ResultKeys.trigger.label + k.letter) } }
                SettingsRow(title: "Crop to the saved size number 1 to 9", subtitle: "The sizes are those of the crop menu.") { Keycaps(ResultKeys.trigger.label + "1…9") }
            }
            SettingsNote("These keys only work while results are on screen. They act on the result under the pointer, or on the latest one.")
            SettingsNote("Hold ⌥ Option while dragging files to show the drop zone when it is set to need it, and hold ⌃ Control to show the preset zones.")
        }
    }
}

// MARK: Agents

struct AgentsPane: View {
    private var executable: String { Bundle.main.executablePath ?? "/Applications/Shrinkbox.app/Contents/MacOS/Shrinkbox" }

    var body: some View {
        SettingsPage(pane: .agents) {
            SettingsCard(title: "MCP") {
                ForEach(Prefs.all.filter { $0.group == "Agents" }, id: \.key) { PrefRow(pref: $0) }
                SettingsRow(title: "MCP configuration", subtitle: "Paste it into the settings of your AI app to let it use Shrinkbox.") { CopyButton { MCPServer.configuration(executable: executable) } }
                SettingsRow(title: "Pipeline guide", subtitle: "The reference of the pipeline language, for an agent to read.") { CopyButton { Reference.pipelineGuide } }
            }
            SettingsCard(title: "Command line") {
                SettingsRow(title: "Path", subtitle: LocalizedStringKey(executable)) { CopyButton { executable } }
                CommandInstallRow()
            }
        }
    }
}

/// "Install the command": links shrinkbox on the PATH, or removes the link.
struct CommandInstallRow: View {
    @State private var location = CLIInstaller.installedAt
    @State private var error: String?

    var body: some View {
        SettingsRow(title: "The shrinkbox command", subtitle: LocalizedStringKey(error ?? location.map { L("Installed at %@", $0) } ?? L("Not installed. Homebrew installs it by itself."))) {
            if location == nil {
                Button("Install the command") { switch CLIInstaller.install() { case .success(let p): location = p; error = nil; case .failure(let e): error = e.localizedDescription } }.controlSize(.small)
            } else {
                Button("Remove") { if case .failure(let e) = CLIInstaller.uninstall() { error = e.localizedDescription } else { location = nil; error = nil } }.controlSize(.small)
            }
        }
    }
}

// MARK: Tools

struct ToolsPane: View {
    @State private var refresh = 0

    var body: some View {
        SettingsPage(pane: .tools) {
            SettingsCard(title: "Optional tools") {
                ForEach(Tool.allCases, id: \.rawValue) { t in
                    SettingsRow(title: LocalizedStringKey(t.rawValue), subtitle: LocalizedStringKey(t.purpose)) {
                        HStack(spacing: 8) {
                            if t.available { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            else { CopyButton(label: "Copy install command") { "brew install \(t.formula)" } }
                        }
                    }
                }
            }
            .id(refresh)
            SettingsNote("Shrinkbox works without any of them. They are used when installed, from Homebrew or from the bin folder of ~/Library/Application Support/Shrinkbox.")
            Button("Check again") { Tools.resetCache(); refresh += 1 }.controlSize(.small)
        }
    }
}

// MARK: About

struct AboutPane: View {
    private var version: String { AppBundle.version }

    var body: some View {
        SettingsPage(pane: .about) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Shrinkbox").font(.system(size: 18, weight: .bold))
                    Text(verbatim: L("Version %@", version)).font(.system(size: 12)).foregroundStyle(SettingsStyle.dim)
                }
            }
            SettingsCard(title: "What leaves your Mac") {
                SettingsRow(title: "Nothing", subtitle: "Files are processed on your Mac. The only network use is downloading a link you drop on the drop zone.") { EmptyView() }
            }
            SettingsCard {
                SettingsRow(title: "Source code and releases") {
                    Button("Open on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/Arrows78/Shrinkbox")!) }.controlSize(.small)
                }
                SettingsRow(title: "Log", subtitle: "What Shrinkbox did, one line per file.") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.url]) }.controlSize(.small)
                }
                SettingsRow(title: "Restore default settings") {
                    Button("Restore") { Prefs.resetAll() }.controlSize(.small)
                }
            }
        }
    }
}

/// "Copy" that turns into "Copied" for a moment.
struct CopyButton: View {
    var label: LocalizedStringKey = "Copy"
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button(copied ? LocalizedStringKey("Copied") : label) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }.controlSize(.small)
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    static func show(pane: SettingsPane = .general) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(pane: pane)))
            w.title = "Shrinkbox Settings"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = SettingsStyle.window
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center(); window?.makeKeyAndOrderFront(nil)
    }
}

/// A shortcut drawn as keycaps.
struct Keycaps: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(String(k)).font(.system(size: 12, weight: .medium, design: .rounded)).frame(minWidth: 22, minHeight: 22)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}
