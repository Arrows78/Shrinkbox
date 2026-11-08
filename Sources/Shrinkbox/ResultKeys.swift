import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A short message in the middle of the lower screen: "Optimisation paused", "Next clipboard copy will be ignored".
@MainActor
enum OSD {
    private static var panel: FloatingPanel?
    private static var hide: Task<Void, Never>?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        let view = OSDView(message: message, symbol: symbol)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        if panel == nil { panel = FloatingPanel(size: size) }
        guard let p = panel, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        p.contentView = host
        p.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 120, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 0 }
            p.orderOut(nil)
        }
    }
}

private struct OSDView: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).symbolRenderingMode(.hierarchical)
            Text(verbatim: message).font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(CardStyle.glass(Capsule()))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(18)
        .preferredColorScheme(.dark)
    }
}

/// The keys of the floating results: hold the trigger keys and press a letter to act on the result under the pointer
/// (or the latest one), or a digit to crop it to a saved size. They are registered only while results are on screen,
/// so they never get in the way of other apps the rest of the time.
@MainActor
final class ResultKeys {
    static let shared = ResultKeys()

    enum Key: String, CaseIterable, Identifiable {
        case restore, optimise, aggressive, copy, saveAs, edit, quickLook, finder, compare, dismiss, stop
        var id: String { rawValue }

        var letter: String {
            switch self {
            case .restore: "R"; case .optimise: "O"; case .aggressive: "A"; case .copy: "C"; case .saveAs: "S"; case .edit: "E"
            case .quickLook: "Q"; case .finder: "F"; case .compare: "K"; case .dismiss: "D"; case .stop: "X"
            }
        }

        var code: Int {
            switch self {
            case .restore: kVK_ANSI_R; case .optimise: kVK_ANSI_O; case .aggressive: kVK_ANSI_A; case .copy: kVK_ANSI_C; case .saveAs: kVK_ANSI_S; case .edit: kVK_ANSI_E
            case .quickLook: kVK_ANSI_Q; case .finder: kVK_ANSI_F; case .compare: kVK_ANSI_K; case .dismiss: kVK_ANSI_D; case .stop: kVK_ANSI_X
            }
        }

        var title: String {
            switch self {
            case .restore: L("Restore the original")
            case .optimise: L("Optimise again")
            case .aggressive: L("Aggressive optimisation")
            case .copy: L("Copy")
            case .saveAs: L("Save as…")
            case .edit: L("Edit with an external app")
            case .quickLook: L("Quick Look")
            case .finder: L("Show in Finder")
            case .compare: L("Compare before and after")
            case .dismiss: L("Dismiss")
            case .stop: L("Stop")
            }
        }
    }

    static let digitCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// "⌃⌘" and the like, from the setting.
    static var trigger: (modifiers: UInt32, label: String) {
        switch Prefs.string("triggerKeys") {
        case "controlOption": return (UInt32(controlKey | optionKey), "⌃⌥")
        case "controlShift": return (UInt32(controlKey | shiftKey), "⌃⇧")
        case "optionCommand": return (UInt32(optionKey | cmdKey), "⌥⌘")
        case "controlOptionCommand": return (UInt32(controlKey | optionKey | cmdKey), "⌃⌥⌘")
        default: return (UInt32(controlKey | cmdKey), "⌃⌘")
        }
    }

    private var keys: [HotKey] = []
    private(set) var active = false

    /// Registers the keys while there is something to act on, and drops them when the stack is empty.
    func update(visible: Bool) {
        if visible == active { return }
        active = visible
        for k in keys { k.unregister() }
        keys = []
        guard visible else { return }
        let mods = Self.trigger.modifiers
        for (i, key) in Key.allCases.enumerated() {
            keys.append(HotKey(keyCode: UInt32(key.code), modifiers: mods, id: UInt32(300 + i)) { ResultKeys.shared.perform(key) })
        }
        for (i, code) in Self.digitCodes.enumerated() {
            keys.append(HotKey(keyCode: UInt32(code), modifiers: mods, id: UInt32(330 + i)) { ResultKeys.shared.crop(toPresetAt: i) })
        }
    }

    /// Called when the trigger keys change.
    func reload() { let was = active; active = !was; update(visible: was) }

    private var target: ResultItem? {
        let m = ResultsModel.shared
        if let id = m.hovered, let item = m.items.first(where: { $0.id == id }) { return item }
        return m.items.last
    }

    func perform(_ key: Key) {
        let m = ResultsModel.shared
        guard let item = target else { return }
        switch key {
        case .restore: if item.outcome?.backup != nil { m.restore(item) } else { m.optimiseAgain(item) }
        case .optimise: m.optimiseAgain(item)
        case .aggressive: m.compress(item, aggressive: true)
        case .copy: m.copy(item)
        case .saveAs: m.saveAs(item)
        case .edit:
            let app = Prefs.string("editorApp" + Prefs.kindName(item.kind))
            if !app.isEmpty { NSWorkspace.shared.open([item.current], withApplicationAt: URL(fileURLWithPath: app), configuration: NSWorkspace.OpenConfiguration()) } else { OSD.show(L("Choose an app to edit with in Settings"), symbol: "exclamationmark.circle") }
        case .quickLook: QuickLook.show(item.current)
        case .finder: m.showInFinder(item)
        case .compare: if item.outcome?.backup != nil { CompareWindow.show(item) }
        case .dismiss: m.dismiss(item)
        case .stop: if item.isBusy { m.stop(item) } else { m.dismiss(item) }
        }
    }

    func crop(toPresetAt index: Int) {
        let presets = CropPresets.load()
        guard presets.indices.contains(index), let item = target, item.kind != .audio else { return }
        let p = presets[index]
        ResultsModel.shared.crop(item, spec: p.spec, longEdge: !p.spec.contains(":") && !p.spec.contains("x"))
        OSD.show(L("Cropping to %@", p.spec), symbol: "crop")
    }
}
