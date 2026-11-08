import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

// MARK: Launch at login

/// "Launch at login": the state lives in macOS, not in the settings, so it is read back every time.
struct LaunchAtLoginRow: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    @State private var needsApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var error: String?

    var body: some View {
        SettingsRow(title: "Launch at login", subtitle: LocalizedStringKey(subtitle)) {
            Toggle("", isOn: Binding(get: { on }, set: { set($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(SettingsStyle.accent)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var subtitle: String {
        if let error { return error }
        return needsApproval ? L("Allow Shrinkbox in System Settings > General > Login Items.") : L("Shrinkbox starts with your Mac, in the menu bar.")
    }

    private func refresh() {
        on = SMAppService.mainApp.status == .enabled
        needsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    private func set(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = error.localizedDescription }
        refresh()
    }
}

// MARK: Theme

enum Theme {
    /// The appearance the "Theme" setting asks for: nil follows the system.
    static var appearance: NSAppearance? {
        switch Prefs.string("appearance") {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
}

// MARK: Backup

/// Every setting that differs from its default, and the shortcuts, in one readable JSON file. Nothing secret lives in the
/// settings, and the switch that lets agents write script steps is never exported nor imported.
enum SettingsBackup {
    static let skipped: Set<String> = ["mcpAllowScriptSteps"]

    static func export() -> Data? {
        var settings: [String: String] = [:]
        for p in Prefs.all where !skipped.contains(p.key) && Prefs.isSet(p.key) { settings[p.key] = Prefs.string(p.key) }
        var shortcuts: [String: Any] = [:]
        for a in HotkeyAction.allCases where UserDefaults.standard.object(forKey: "hotkey.\(a.rawValue)") != nil {
            if let c = a.combo { shortcuts[a.rawValue] = ["keyCode": Int(c.keyCode), "modifiers": Int(c.modifiers), "label": c.label] } else { shortcuts[a.rawValue] = NSNull() }
        }
        let root: [String: Any] = ["app": "Shrinkbox", "format": 1, "version": AppBundle.version, "settings": settings, "shortcuts": shortcuts]
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Replaces the settings and the shortcuts with those of the file. Returns the number of settings applied and the keys
    /// that were refused, or nil when the file is not a backup of Shrinkbox (nothing is touched then).
    static func restore(_ data: Data) -> (applied: Int, refused: [String])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["app"] as? String == "Shrinkbox",
              let settings = root["settings"] as? [String: String] else { return nil }
        let shortcuts = root["shortcuts"] as? [String: Any] ?? [:]
        resetEverything()
        var applied = 0, refused: [String] = []
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            if skipped.contains(key) || Prefs.set(key, value) != nil { refused.append(key) } else { applied += 1 }
        }
        let allowed = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        for a in HotkeyAction.allCases {
            guard let entry = shortcuts[a.rawValue] else { continue }
            if let d = entry as? [String: Any], let code = d["keyCode"] as? Int, let mods = d["modifiers"] as? Int, let label = d["label"] as? String, code >= 0, mods > 0, UInt32(mods) & ~allowed == 0 {
                a.setCombo(KeyCombo(keyCode: UInt32(code), modifiers: UInt32(mods), label: label), notify: false)
            } else if entry is NSNull { a.setCombo(nil, notify: false) }
        }
        NotificationCenter.default.post(name: .hotkeysChanged, object: nil)
        return (applied, refused)
    }

    static func resetEverything() {
        Prefs.resetAll()
        for a in HotkeyAction.allCases { UserDefaults.standard.removeObject(forKey: "hotkey.\(a.rawValue)") }
        NotificationCenter.default.post(name: .hotkeysChanged, object: nil)
    }
}

private extension HotkeyAction {
    func setCombo(_ combo: KeyCombo?, notify: Bool) {
        UserDefaults.standard.set(try? JSONEncoder().encode(combo), forKey: "hotkey.\(rawValue)")
        if notify { NotificationCenter.default.post(name: .hotkeysChanged, object: nil) }
    }
}

struct BackupCard: View {
    var body: some View {
        SettingsCard(title: "Backup") {
            SettingsRow(title: "Export settings…", subtitle: "Saves your settings and shortcuts in a file. Pipelines and automations are not included.") {
                Button("Export…") { export() }.controlSize(.small)
            }
            SettingsRow(title: "Import settings…", subtitle: "Replaces your settings and shortcuts with those of a file saved by Shrinkbox.") {
                Button("Import…") { importFile() }.controlSize(.small)
            }
            SettingsRow(title: "Restore defaults…", subtitle: "Settings and shortcuts go back to their defaults. Your files, pipelines and automations are kept.") {
                Button("Restore…", role: .destructive) { restore() }.controlSize(.small)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Shrinkbox Settings.json"
        guard panel.runModal() == .OK, let url = panel.url, let data = SettingsBackup.export() else { return }
        do { try data.write(to: url, options: .atomic); OSD.show(L("Settings exported")) } catch { alert(L("The settings could not be saved"), error.localizedDescription) }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let result = SettingsBackup.restore(data) else {
            alert(L("This file is not a Shrinkbox backup"), L("Nothing was changed.")); return
        }
        if result.refused.isEmpty { OSD.show(L("Settings imported")) }
        else { alert(L("Settings imported"), L("These settings were not accepted: %@", result.refused.joined(separator: ", "))) }
    }

    private func restore() {
        let a = NSAlert()
        a.messageText = L("Restore default settings?")
        a.informativeText = L("Settings and shortcuts go back to their defaults. Your files, pipelines and automations are kept.")
        a.addButton(withTitle: L("Restore"))
        a.addButton(withTitle: L("Cancel"))
        a.alertStyle = .warning
        guard a.runModal() == .alertFirstButtonReturn else { return }
        SettingsBackup.resetEverything()
        OSD.show(L("Settings restored"))
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.alertStyle = .warning; a.runModal()
    }
}

// MARK: Permissions

/// What macOS lets Shrinkbox do. Nothing here asks for a permission by itself.
enum Permissions {
    enum State { case granted, denied, notAsked, unavailable }

    static let photosID = "com.apple.Photos"
    static let automationURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    static let foldersURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
    static let inputURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

    /// Whether Shrinkbox may drive an app with Apple events. The app has to be running to be asked.
    static func automation(_ bundleID: String, ask: Bool = false) -> State {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil,
              let target = NSAppleEventDescriptor(bundleIdentifier: bundleID).aeDesc else { return .unavailable }
        let status = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, ask)
        switch Int(status) {
        case 0: return .granted
        case -1743: return .denied
        case -1744: return .notAsked
        default: return .unavailable
        }
    }

    /// Only the "keep the preset zones up after tapping Control" setting listens to the keyboard of other apps.
    static var keyboardMonitoring: State { CGPreflightListenEventAccess() || AXIsProcessTrusted() ? .granted : .denied }

    static func word(_ s: State) -> String {
        switch s {
        case .granted: "granted"
        case .denied: "denied"
        case .notAsked: "not asked yet"
        case .unavailable: "unknown"
        }
    }

    /// Without personal data: only the states.
    static var summary: String {
        """
        Automation, Finder: \(word(automation("com.apple.finder")))
        Automation, Photos: \(word(automation(Permissions.photosID)))
        Keyboard monitoring: \(word(keyboardMonitoring))
        """
    }
}

private struct PermissionRow: View {
    var title: LocalizedStringKey
    var detail: LocalizedStringKey
    var state: Permissions.State
    var url: String
    var ask: (() -> Void)?

    var body: some View {
        SettingsRow(title: title, subtitle: detail) {
            HStack(spacing: 8) {
                switch state {
                case .granted: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .notAsked: Image(systemName: "questionmark.circle.fill").foregroundStyle(SettingsStyle.dim)
                case .unavailable: Image(systemName: "circle.dashed").foregroundStyle(SettingsStyle.dim)
                }
                if state == .notAsked, let ask { Button("Allow…") { ask() }.controlSize(.small) }
                if state != .granted { Button("Open System Settings") { open(url) }.controlSize(.small) }
            }
        }
    }

    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}

struct PermissionsPane: View {
    @State private var refresh = 0

    var body: some View {
        SettingsPage(pane: .permissions) {
            SettingsCard(title: "Used when you ask for it") {
                PermissionRow(title: "Finder", detail: "Needed by “Optimise the Finder selection” to know which files are selected.",
                              state: Permissions.automation("com.apple.finder"), url: Permissions.automationURL, ask: { ask("com.apple.finder") })
                PermissionRow(title: "Photos", detail: "Needed to optimise the originals of photos you copy from Photos. It is checked while Photos is open.",
                              state: Permissions.automation(Permissions.photosID), url: Permissions.automationURL, ask: { ask(Permissions.photosID) })
                SettingsRow(title: "Files and folders", subtitle: "macOS asks the first time Shrinkbox reads Downloads, Desktop or Documents, for example in a watched folder.") {
                    Button("Open System Settings") { if let u = URL(string: Permissions.foldersURL) { NSWorkspace.shared.open(u) } }.controlSize(.small)
                }
            }
            .id(refresh)
            SettingsCard(title: "Optional") {
                PermissionRow(title: "Keyboard monitoring", detail: "Only for “Keep preset zones up after tapping Control”, which watches the Control key in other apps.",
                              state: Permissions.keyboardMonitoring, url: Permissions.inputURL, ask: nil)
            }
            .id(refresh)
            SettingsNote("Shrinkbox needs no access to your screen, camera, microphone or contacts.")
            Button("Refresh") { refresh += 1 }.controlSize(.small)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }

    private func ask(_ bundleID: String) {
        Task.detached { _ = Permissions.automation(bundleID, ask: true); await MainActor.run { refresh += 1 } }
    }
}

// MARK: Diagnostics, updates and problem reports

enum Diagnostics {
    static var text: String {
        let info = AppBundle.info
        let build = info?["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let tools = Tool.allCases.map { "\($0.rawValue): \($0.available ? "yes" : "no")" }.joined(separator: ", ")
        return """
        Shrinkbox \(AppBundle.version) (\(build))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(arch)
        Tools: \(tools)
        \(Permissions.summary)
        """
    }
}

/// A GitHub "new issue" link prefilled with the diagnostics. Nothing is sent until you submit it in the browser.
enum ProblemReport {
    static func url() -> URL? {
        let body = "**What happened?**\n\n\n**Diagnostics**\n```\n\(Diagnostics.text)\n```\n"
        var c = URLComponents(string: "https://github.com/Arrows78/Shrinkbox/issues/new")
        c?.queryItems = [URLQueryItem(name: "title", value: "Problem: "), URLQueryItem(name: "body", value: body)]
        return c?.url
    }

    @MainActor static func open() { if let u = url() { NSWorkspace.shared.open(u) } }
}

/// Asks GitHub for the latest release, only when you click "Check for updates…". Installing stays manual.
enum UpdateCheck {
    static let releasesPage = "https://github.com/Arrows78/Shrinkbox/releases"

    /// True when `latest` is a newer version than `current` ("v1.2.0" and "1.2" are accepted).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @MainActor
    static func run() async {
        guard let url = URL(string: "https://api.github.com/repos/Arrows78/Shrinkbox/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        var tag: String?, page: URL?
        if let (data, response) = try? await URLSession.shared.data(for: req), (response as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            tag = json["tag_name"] as? String
            page = (json["html_url"] as? String).flatMap(URL.init(string:))
        }
        let current = AppBundle.version
        let alert = NSAlert()
        NSApp.activate(ignoringOtherApps: true)
        guard let tag else {
            alert.messageText = L("Could not check for updates")
            alert.informativeText = L("Check your connection, or look at the releases page.")
            alert.addButton(withTitle: L("Open the releases page")); alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() == .alertFirstButtonReturn, let u = URL(string: releasesPage) { NSWorkspace.shared.open(u) }
            return
        }
        guard isNewer(tag, than: current) else {
            alert.messageText = L("Shrinkbox %@ is up to date", current)
            alert.runModal()
            return
        }
        alert.messageText = L("Shrinkbox %@ is available", tag)
        alert.informativeText = L("You are using version %@.", current)
        alert.addButton(withTitle: L("View the release")); alert.addButton(withTitle: L("Later"))
        if alert.runModal() == .alertFirstButtonReturn, let u = page ?? URL(string: releasesPage) { NSWorkspace.shared.open(u) }
    }
}
