import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Carbon global hotkey (works without any privacy permission).
@MainActor
final class HotKey {
    var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        if !Self.installed {
            Self.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handlers[hk.id]?() } }
                return noErr
            }, 1, &spec, nil, nil)
        }
        Self.handlers[id] = handler
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x53484B58), id: id), GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() { if let r = ref { UnregisterEventHotKey(r); ref = nil } }
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon flags
    var label: String

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + label.uppercased()
    }

    init(keyCode: UInt32, modifiers: UInt32, label: String) { self.keyCode = keyCode; self.modifiers = modifiers; self.label = label }

    init?(event: NSEvent) {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        // A shortcut needs a modifier, or it would steal normal typing.
        guard m != 0, let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m, label: chars)
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable {
    case optimiseClipboard, optimiseClipboardAggressively, optimiseSelection, togglePause, skipNextClipboard, stopAll, clearResults, showDropZone
    var id: String { rawValue }

    var title: String {
        switch self {
        case .optimiseClipboard: L("Optimise the clipboard")
        case .optimiseClipboardAggressively: L("Optimise the clipboard aggressively")
        case .skipNextClipboard: L("Skip the next clipboard optimisation")
        case .stopAll: L("Stop everything and clear the results")
        case .optimiseSelection: L("Optimise the Finder selection")
        case .togglePause: L("Pause or resume automatic optimisations")
        case .clearResults: L("Clear the floating results")
        case .showDropZone: L("Show the drop zone")
        }
    }

    var defaultCombo: KeyCombo {
        let m = UInt32(controlKey | optionKey | cmdKey)
        switch self {
        case .optimiseClipboard: return KeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: m, label: "O")
        case .optimiseClipboardAggressively: return KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: m, label: "A")
        case .skipNextClipboard: return KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: m, label: "S")
        case .stopAll: return KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: m, label: "X")
        case .optimiseSelection: return KeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: m, label: "F")
        case .togglePause: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: m, label: "P")
        case .clearResults: return KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: m, label: "C")
        case .showDropZone: return KeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: m, label: "D")
        }
    }

    var combo: KeyCombo? {
        get {
            guard let d = UserDefaults.standard.data(forKey: "hotkey.\(rawValue)") else { return defaultCombo }
            return try? JSONDecoder().decode(KeyCombo?.self, from: d)
        }
        nonmutating set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "hotkey.\(rawValue)")
            NotificationCenter.default.post(name: .hotkeysChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let hotkeysChanged = Notification.Name("shrinkbox.hotkeysChanged")
}

/// Click, then press the shortcut. Delete clears it, Esc cancels.
struct ShortcutField: View {
    let action: HotkeyAction
    @State private var recording = false
    @State private var combo: KeyCombo?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(verbatim: recording ? L("Press shortcut…") : (combo?.display ?? L("Not set"))).frame(minWidth: 110)
            }.controlSize(.small)
            if combo != action.defaultCombo { Button { action.combo = action.defaultCombo; combo = action.defaultCombo } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.plain).foregroundStyle(SettingsStyle.dim).help(L("Restore the default"))
            }
        }
        .onAppear { combo = action.combo }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeysChanged)) { _ in combo = action.combo }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch e.keyCode {
            case 53: break
            case 51, 117: action.combo = nil; combo = nil
            default:
                guard let c = KeyCombo(event: e) else { NSSound.beep(); return nil }
                // Two actions on the same keys would leave one of them dead: macOS registers only the first.
                if HotkeyAction.allCases.contains(where: { $0 != action && $0.combo == c }) { NSSound.beep(); return nil }
                action.combo = c; combo = c
            }
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
