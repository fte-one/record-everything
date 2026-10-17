import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut (Carbon key code plus Cocoa modifier flags).
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    var keyLabel: String

    static let defaultStartPause = HotKeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "1")
    static let defaultStop = HotKeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "2")
    /// Screenshots: ⌘→ annotate, ⌘↑ upload and copy the link, ⌘↓ copy the image.
    static let defaultCaptureAnnotate = HotKeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "→")
    static let defaultCaptureUpload = HotKeyCombo(keyCode: UInt32(kVK_UpArrow), modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "↑")
    static let defaultCaptureCopy = HotKeyCombo(keyCode: UInt32(kVK_DownArrow), modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "↓")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// Display form, e.g. "⌘ + 1".
    var display: String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyLabel.uppercased())
        return parts.joined(separator: " + ")
    }

    init(keyCode: UInt32, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    /// Builds a combo from a key event; requires at least one of ⌘ ⌥ ⌃.
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !mods.intersection([.command, .option, .control]).isEmpty else { return nil }
        let label = Self.specialKeyLabels[Int(event.keyCode)]
            ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods.rawValue, keyLabel: label)
    }

    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    ]
}

/// Registers the global shortcuts through the Carbon hot key API (no accessibility permission needed).
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    enum Action: UInt32 { case startPause = 1, stop = 2, captureUpload = 3, captureAnnotate = 4, captureCopy = 5 }

    var handler: ((Action) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func reload() {
        installIfNeeded()
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        let settings = AppSettings.shared
        register(settings.startPauseHotKey, action: .startPause)
        register(settings.stopHotKey, action: .stop)
        register(settings.captureUploadHotKey, action: .captureUpload)
        register(settings.captureAnnotateHotKey, action: .captureAnnotate)
        register(settings.captureCopyHotKey, action: .captureCopy)
    }

    private func register(_ combo: HotKeyCombo, action: Action) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x52455645), id: action.rawValue) // "REVE"
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) } else { NSLog("Record Everything: hot key \(combo.display) not registered (\(status))") }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let action = HotKeyCenter.Action(rawValue: hk.id) {
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKeyCenter.shared.handler?(action) } }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Temporarily disables shortcuts, e.g. while the user records a new one.
    func suspend() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }
}
