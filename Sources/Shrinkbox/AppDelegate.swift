import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeys: [HotKey] = []
    private var monitors: [Any] = []
    private var cleanupTimer: Timer?
    private var controlTapped = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        ResultsPanel.shared.start()
        FolderWatcher.shared.start()
        ClipboardWatcher.shared.start()
        applyMenuBarIcon()
        registerHotkeys()
        setupDragMonitors()
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { n in MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.applyMenuBarIcon(); if (n.object as? String) == "triggerKeys" { ResultKeys.shared.reload() } } }
        NotificationCenter.default.addObserver(forName: .hotkeysChanged, object: nil, queue: .main) { _ in MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.registerHotkeys() } }
        DistributedNotificationCenter.default().addObserver(forName: .clearResults, object: nil, queue: .main) { _ in MainActor.assumeIsolated { ResultsModel.shared.clearAll() } }
        // Old working files go after a few days.
        Workspace.clean(olderThanDays: Prefs.int("workdirCleanupDays"))
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in Workspace.clean(olderThanDays: Prefs.int("workdirCleanupDays")) }
        handleLaunchArguments()
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { OnboardingWindow.show() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { SettingsWindow.show(); return true }

    // MARK: Debug aids

    private func handleLaunchArguments() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--open-settings") {
            let pane = a.indices.contains(i + 1) ? SettingsPane(rawValue: a[i + 1]) : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { SettingsWindow.show(pane: pane ?? .general) }
        }
        if a.contains("--open-dropzone") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { DropZone.state.showPresets = a.contains("--presets"); DropZone.show() } }
        if let i = a.firstIndex(of: "--optimise-demo"), a.indices.contains(i + 1) {
            let urls = a[(i + 1)...].map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ResultsModel.shared.enqueue(urls, source: .manual) }
        }
        if let i = a.firstIndex(of: "--open-batch") {
            let urls = a[(i + 1)...].map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { BatchManager.shared.start(urls, source: .dropZone, review: true) }
        }
        if let i = a.firstIndex(of: "--open-crop"), a.indices.contains(i + 1) {
            let url = URL(fileURLWithPath: a[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let kind = Media.kind(of: url) else { return }
                let item = ResultItem(file: url, kind: kind, source: .manual)
                CropWindow.show(item)
            }
        }
        if a.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.statusItem?.menu?.popUp(positioning: nil, at: NSPoint(x: 400, y: 900), in: nil) }
        }
    }

    // MARK: Menu bar

    /// The symbol of the menu bar icon, from the style setting.
    static var iconSymbol: String {
        switch Prefs.string("menubarIconStyle") {
        case "box": "shippingbox.fill"
        case "geometric": "square.on.circle"
        default: "arrow.down.right.and.arrow.up.left"
        }
    }

    func applyMenuBarIcon() {
        if Prefs.bool("showMenubarIcon") {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                item.button?.image = NSImage(systemSymbolName: Self.iconSymbol, accessibilityDescription: "Shrinkbox")
                let menu = NSMenu(); menu.delegate = self
                item.menu = menu
                statusItem = item
            }
            statusItem?.button?.image = NSImage(systemSymbolName: Self.iconSymbol, accessibilityDescription: "Shrinkbox")
            statusItem?.button?.appearsDisabled = Prefs.bool("pauseAutomations")
        } else if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild(menu) }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        func icon(_ s: String) -> NSImage? {
            let i = NSImage(systemSymbolName: s, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)); i?.isTemplate = true; return i
        }
        @discardableResult
        func add(_ title: String, _ symbol: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = .command, state: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods; item.image = icon(symbol); item.target = self; item.state = state ? .on : .off
            menu.addItem(item); return item
        }
        let paused = Prefs.bool("pauseAutomations")
        add(L(paused ? "Resume automatic optimisations" : "Pause automatic optimisations"), paused ? "play.fill" : "pause.fill", #selector(togglePause), state: paused)
        menu.addItem(.separator())
        add(L("Optimise files…"), "wand.and.stars", #selector(chooseFiles))
        add(L("Optimise the clipboard"), "doc.on.clipboard", #selector(optimiseClipboardNow))
        add(L("Optimise the clipboard aggressively"), "bolt.fill", #selector(optimiseClipboardAggressively))
        add(L("Show the drop zone"), "tray.and.arrow.down", #selector(showDropZone))
        menu.addItem(.separator())
        let results = ResultsModel.shared.items
        add(L("Clear the floating results"), "xmark.circle", #selector(clearResults)).isEnabled = !results.isEmpty
        if !results.isEmpty {
            let saved = results.compactMap { $0.outcome?.saved }.reduce(0, +)
            let line = NSMenuItem(title: L("Saved %@ in this session", Files.human(saved)), action: nil, keyEquivalent: ""); line.isEnabled = false; menu.addItem(line)
        }
        menu.addItem(.separator())
        add(L("Settings…"), "gearshape", #selector(openSettings), key: ",")
        add(L("Show the log"), "text.alignleft", #selector(showLog))
        let quit = NSMenuItem(title: L("Quit Shrinkbox"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); quit.image = icon("power"); quit.target = NSApp
        menu.addItem(quit)
    }

    @objc private func togglePause() {
        let paused = !Prefs.bool("pauseAutomations")
        Prefs.set("pauseAutomations", paused ? "true" : "false")
        OSD.show(L(paused ? "Optimisation paused" : "Optimisation resumed"), symbol: paused ? "pause.circle.fill" : "play.circle.fill")
    }
    @objc private func openSettings() { SettingsWindow.show() }
    @objc private func showDropZone() { DropZone.show() }
    @objc private func clearResults() { ResultsModel.shared.clearAll() }
    @objc private func showLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func optimiseClipboardNow() { optimiseClipboard() }
    @objc private func optimiseClipboardAggressively() { optimiseClipboard(aggressive: true) }

    @objc private func chooseFiles() {
        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { DropZone.process(p.urls) }
    }

    // MARK: Hotkeys

    func registerHotkeys() {
        for h in hotKeys { h.unregister() }
        hotKeys = []
        for (i, a) in HotkeyAction.allCases.enumerated() {
            guard let c = a.combo else { continue }
            hotKeys.append(HotKey(keyCode: c.keyCode, modifiers: c.modifiers, id: UInt32(100 + i)) { [weak self] in self?.run(a) })
        }
    }

    private func run(_ a: HotkeyAction) {
        switch a {
        case .optimiseClipboard: optimiseClipboard()
        case .optimiseClipboardAggressively: optimiseClipboard(aggressive: true)
        case .optimiseSelection: optimiseFinderSelection()
        case .togglePause: togglePause()
        case .skipNextClipboard: ClipboardWatcher.shared.skipNext(); OSD.show(L("The next clipboard copy will be ignored"), symbol: "forward.end.fill")
        case .stopAll: ResultsModel.shared.stopAll(); OSD.show(L("Everything stopped"), symbol: "stop.circle.fill")
        case .clearResults: ResultsModel.shared.clearAll()
        case .showDropZone: DropZone.show()
        }
    }

    /// Whatever the clipboard holds that Shrinkbox can read, now, whatever the clipboard settings say: image data, copied
    /// files, or a path or a link written as text.
    func optimiseClipboard(aggressive: Bool = false) {
        let pb = NSPasteboard.general
        func run(_ urls: [URL]) {
            if aggressive {
                let steps: [Step] = [.optimise(encoder: "aggressive", compression: nil, adaptive: nil, dpi: nil, location: nil)]
                ResultsModel.shared.enqueuePipeline(urls, pipeline: Pipeline(steps: steps), source: .manual, copyWhenDone: Prefs.bool("autoCopyToClipboard"))
            } else {
                ResultsModel.shared.enqueue(urls, source: .manual, forceTemporary: true, clipboard: true) { _, _ in
                    ClipboardWatcher.shared.write(ResultsModel.shared.items.filter { $0.isClipboard }.compactMap { $0.outcome?.output }, image: nil) }
            }
        }
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            let supported = Media.collect(files, recursive: false)
            if !supported.isEmpty { run(supported); return }
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
            let file = Workspace.temp(ext: "png", name: "clipboard")
            try? png.write(to: file)
            run([file]); return
        }
        // A path or a link copied as text.
        let texts = textPaths(pb)
        if !texts.isEmpty { DropZone.process(texts); return }
        OSD.show(L("Nothing to optimise on the clipboard"), symbol: "exclamationmark.circle")
    }

    /// The files selected in the Finder, through Apple events.
    func optimiseFinderSelection() {
        let script = NSAppleScript(source: "tell application \"Finder\" to get POSIX path of (selection as alias list)")
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error) else { NSSound.beep(); return }
        var urls: [URL] = []
        if result.numberOfItems > 0 { for i in 1...result.numberOfItems { if let p = result.atIndex(i)?.stringValue { urls.append(URL(fileURLWithPath: p)) } } }
        else if let p = result.stringValue { urls.append(URL(fileURLWithPath: p)) }
        DropZone.process(urls)
    }

    // MARK: Dragging

    private func setupDragMonitors() {
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { DropZone.mouseDown() } }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { e in
            let flags = e.modifierFlags
            DispatchQueue.main.async { MainActor.assumeIsolated { DropZone.dragMoved(control: flags.contains(.control), option: flags.contains(.option)) } }
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { DropZone.hide() } }
        } as Any)
        // A tap on Control keeps the preset zones up.
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard Prefs.bool("onlyShowPresetZonesOnControlTapped") else { return }
            let down = e.modifierFlags.contains(.control)
            DispatchQueue.main.async { MainActor.assumeIsolated { if !down, Date().timeIntervalSince(self?.controlTapped ?? .distantPast) < 0.4 { DropZone.state.showPresets.toggle() }; if down { self?.controlTapped = Date() } } }
        } as Any)
    }

    // MARK: Opening files, services and links

    func application(_ sender: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for u in urls {
            if u.scheme == "shrinkbox" { handleLink(u) } else { files.append(u) }
        }
        if !files.isEmpty { DropZone.process(files) }
    }

    /// `shrinkbox://optimise?path=…`, `…/pause`, `…/resume`, `…/settings`, `…/clear`, `…/convert?to=webp&path=…`.
    func handleLink(_ url: URL) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ n: String) -> String? { q.first { $0.name == n }?.value }
        let paths = q.filter { $0.name == "path" }.compactMap { $0.value }.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        switch url.host ?? "" {
        case "optimise", "optimize": DropZone.process(paths)
        case "convert":
            guard let to = value("to") else { return }
            let files = Media.collect(paths, recursive: false)
            let loc = Library.placementText(Prefs.placement(converted: .image, manual: true)) ?? "sameFolder"
            ResultsModel.shared.enqueuePipeline(files, pipeline: Pipeline(steps: [.convert(to: to, location: loc)]), source: .manual, copyWhenDone: false)
        case "review":
            let files = Media.collect(paths, recursive: true)
            if !files.isEmpty { BatchManager.shared.start(files, source: .dropZone, review: true) }
        case "pause": Prefs.set("pauseAutomations", "true")
        case "resume": Prefs.set("pauseAutomations", "false")
        case "clear": ResultsModel.shared.clearAll()
        case "settings": SettingsWindow.show()
        case "clipboard": optimiseClipboard()
        default: break
        }
    }

    func application(_ application: NSApplication, open urls: [URL], with: Any?) {}

    /// Services menu: "Optimise with Shrinkbox" on files, and "Strip EXIF Metadata".
    @objc func optimisationService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? textPaths(pboard)
        DispatchQueue.main.async { MainActor.assumeIsolated { DropZone.process(files) } }
    }

    @objc func stripEXIFService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        DispatchQueue.main.async { MainActor.assumeIsolated { ResultsModel.shared.enqueuePipeline(Media.collect(files, recursive: false), pipeline: Pipeline(steps: [.stripExif]), source: .manual, copyWhenDone: false) } }
    }

    func textPaths(_ pb: NSPasteboard) -> [URL] {
        (pb.string(forType: .string) ?? "").split(whereSeparator: \.isNewline).compactMap {
            let t = $0.trimmingCharacters(in: .whitespaces)
            if let u = URL(string: t), u.scheme?.hasPrefix("http") == true { return u }
            return FileManager.default.fileExists(atPath: (t as NSString).expandingTildeInPath) ? URL(fileURLWithPath: (t as NSString).expandingTildeInPath) : nil
        }
    }
}

/// First launch: what Shrinkbox does, in three lines.
enum OnboardingWindow {
    @MainActor static func show() { SettingsWindow.show(pane: .about) }
}
