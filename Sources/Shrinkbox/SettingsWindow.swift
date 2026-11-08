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

struct AutomationPane: View {
    @State private var library = Library.load()
    @State private var name = ""
    @State private var steps = ""
    @State private var type: MediaKind?
    @State private var error: String?

    var body: some View {
        SettingsPage(pane: .automation) {
            SettingsCard(title: "Saved pipelines") {
                if library.pipelines.isEmpty {
                    SettingsRow(title: "No saved pipeline", subtitle: "A pipeline chains steps like crop, convert and move. Save one below, or with the command line.") { EmptyView() }
                }
                ForEach(library.pipelines) { p in
                    SettingsRow(title: LocalizedStringKey(p.name), subtitle: LocalizedStringKey(p.steps)) {
                        HStack {
                            if let t = p.fileType { Image(systemName: t.symbol).foregroundStyle(SettingsStyle.dim) }
                            Button { remove { $0.pipelines.removeAll { $0.id == p.id } } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(SettingsStyle.dim)
                        }
                    }
                }
            }
            SettingsCard(title: "New pipeline") {
                SettingsRow(title: "Name") { TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 240) }
                SettingsRow(title: "Steps", subtitle: "For example: crop(longEdge: 1600) -> convert(to: webp)") { TextField("", text: $steps).textFieldStyle(.roundedBorder).frame(width: 340) }
                SettingsRow(title: "For files of type") {
                    Picker("", selection: $type) {
                        Text("Any").tag(MediaKind?.none)
                        ForEach(MediaKind.allCases, id: \.self) { Text(verbatim: $0.title).tag(MediaKind?.some($0)) }
                    }.labelsHidden().frame(width: 140)
                }
                SettingsRow(title: "") {
                    HStack {
                        if let e = error { Text(verbatim: e).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2) }
                        Button("Save pipeline") { save() }.disabled(name.isEmpty || steps.isEmpty).controlSize(.small)
                    }
                }
            }
            SettingsCard(title: "Automations") {
                if library.attachments.isEmpty {
                    SettingsRow(title: "No automation", subtitle: "Attach a pipeline to a folder, the clipboard or the drop zone with “shrinkbox pipeline attach”.") { EmptyView() }
                }
                ForEach(Array(library.attachments.enumerated()), id: \.offset) { i, a in
                    SettingsRow(title: LocalizedStringKey("\((a.source as NSString).abbreviatingWithTildeInPath) · \(a.type.rawValue)"), subtitle: LocalizedStringKey(a.pipeline)) {
                        Button { remove { $0.attachments.remove(at: i) } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(SettingsStyle.dim)
                    }
                }
            }
            SettingsCard(title: "Preset zones") {
                if library.zones.isEmpty {
                    SettingsRow(title: "No preset zone", subtitle: "Hold Control while dragging a file to the drop zone to see them.") { EmptyView() }
                }
                ForEach(library.zones) { z in
                    SettingsRow(title: LocalizedStringKey(z.name), subtitle: LocalizedStringKey(z.pipeline)) {
                        HStack {
                            Image(systemName: z.icon).foregroundStyle(SettingsStyle.dim)
                            Button { remove { $0.zones.removeAll { $0.id == z.id } } } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(SettingsStyle.dim)
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryChanged)) { _ in library = Library.load() }
    }

    private func remove(_ change: @escaping (inout Library.Content) -> Void) {
        try? Library.update { change(&$0) }
        library = Library.load()
    }

    private func save() {
        do {
            _ = try PipelineParser.parse(steps)
            try Library.update { lib in
                lib.pipelines.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                lib.pipelines.append(SavedPipeline(name: name, fileType: type, steps: steps))
            }
            name = ""; steps = ""; error = nil; library = Library.load()
        } catch { self.error = error.localizedDescription }
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
                SettingsRow(title: "Make it available as “shrinkbox”", subtitle: "Homebrew does this by itself. Otherwise, run the copied command in the Terminal.") {
                    CopyButton { "sudo ln -sf '\(executable)' /usr/local/bin/shrinkbox" }
                }
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
