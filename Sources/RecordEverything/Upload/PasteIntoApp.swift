import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// An app the annotation editor pastes the image into, with its shortcut inside the editor.
struct PasteTarget: Codable, Equatable, Identifiable {
    var id = UUID()
    var bundleID: String
    var name: String
    var shortcut: HotKeyCombo?

    /// Claude, Codex and T3 Code if installed, on ⌘1, ⌘2, ⌘3.
    @MainActor
    static func installedDefaults() -> [PasteTarget] {
        let known = [("com.anthropic.claudefordesktop", "Claude"), ("com.openai.codex", "Codex"), ("com.t3tools.t3code", "T3 Code")]
        let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3]
        var targets: [PasteTarget] = []
        for (bundleID, name) in known where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            let n = targets.count
            targets.append(PasteTarget(bundleID: bundleID, name: name,
                                       shortcut: HotKeyCombo(keyCode: UInt32(digitKeys[n]), modifiers: NSEvent.ModifierFlags.command.rawValue,
                                                             keyLabel: "\(n + 1)")))
        }
        return targets
    }
}

/// Remembers the last app in front that is not Record Everything: where ⌘X in the editor pastes.
@MainActor
final class FrontmostAppTracker {
    static let shared = FrontmostAppTracker()
    private(set) var lastExternal: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        note(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { FrontmostAppTracker.shared.note(app) }
        }
    }

    /// Lets the self-test pretend another app was in front.
    func override(_ app: NSRunningApplication?) { lastExternal = app }

    private func note(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular else { return }
        lastExternal = app
    }
}

/// Copies the image, brings an app to the front and presses ⌘V there (needs Accessibility access).
@MainActor
enum PasteIntoApp {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    private static var askedThisLaunch = false

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func displayName(of app: NSRunningApplication) -> String {
        app.localizedName ?? app.bundleIdentifier ?? "App"
    }

    static func icon(bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Pastes into a running app (the one in front before the screenshot) or the app with this bundle ID
    /// (launched if needed). The image stays on the clipboard either way.
    @discardableResult
    static func paste(_ image: CGImage, into running: NSRunningApplication?, bundleID: String?, name: String) async -> Bool {
        Screenshots.copy(image)
        guard await activate(running, bundleID: bundleID) != nil else {
            Toast.shared.show(String(format: L("Could not open %@"), name), detail: L("The image is on the clipboard."),
                              symbol: "exclamationmark.triangle.fill", style: .error, duration: 4)
            return false
        }
        guard isTrusted else {
            Toast.shared.show(L("Image copied – press ⌘V"), detail: L("Allow Accessibility access to paste automatically."),
                              symbol: "doc.on.clipboard.fill", style: .success, duration: 4)
            if !askedThisLaunch {
                askedThisLaunch = true
                requestPermission()
            }
            return false
        }
        postCommandV()
        return true
    }

    private static func activate(_ running: NSRunningApplication?, bundleID: String?) async -> NSRunningApplication? {
        var app = running.flatMap { $0.isTerminated ? nil : $0 }
            ?? bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        var launched = false
        if app == nil, let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            app = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            launched = app != nil
        }
        guard let app else { return nil }
        if app.isHidden { app.unhide() }
        NSApp.yieldActivation(to: app)
        app.activate()
        let deadline = Date().addingTimeInterval(launched ? 10 : 2)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return nil }
        // Give the app a moment to make its window key and focus the text field it remembers.
        try? await Task.sleep(for: .milliseconds(launched ? 1500 : 220))
        return app
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down) else { continue }
            event.flags = .maskCommand
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(0x76)]) // "v" on any layout
            event.post(tap: .cghidEventTap)
        }
    }
}
