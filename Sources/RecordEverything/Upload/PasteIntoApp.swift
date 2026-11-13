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
    /// (launched if needed). `text` (the editor's note) follows the image in the same input field; then the
    /// text is what stays on the clipboard, otherwise the image.
    @discardableResult
    static func paste(_ image: CGImage, into running: NSRunningApplication?, bundleID: String?, name: String,
                      text: String? = nil) async -> Bool {
        await paste(image: image, text: text, into: running, bundleID: bundleID, name: name)
    }

    /// Pastes several images one after another, then the text (feedback prompt with attached screenshots).
    @discardableResult
    static func pasteImages(_ files: [URL], text: String, into running: NSRunningApplication?, bundleID: String?, name: String) async -> Bool {
        let images = files.compactMap(ImageFiles.load)
        guard let first = images.first else {
            return await pasteText(text, into: running, bundleID: bundleID, name: name)
        }
        Screenshots.copy(first)
        guard let app = await activate(running, bundleID: bundleID) else {
            Toast.shared.show(String(format: L("Could not open %@"), name), detail: L("The image is on the clipboard."),
                              symbol: "exclamationmark.triangle.fill", style: .error, duration: 4)
            return false
        }
        guard isTrusted else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.shared.show(L("Text copied – press ⌘V"), detail: L("Allow Accessibility access to paste automatically."),
                              symbol: "doc.on.clipboard.fill", style: .success, duration: 4)
            if !askedThisLaunch {
                askedThisLaunch = true
                requestPermission()
            }
            return false
        }
        await focusTextInput(in: app)
        for (index, image) in images.enumerated() {
            if index > 0 { Screenshots.copy(image) }
            pressPaste(in: app)
            // The app reads the clipboard asynchronously; give it time before the next image replaces it.
            try? await Task.sleep(for: .milliseconds(550))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pressPaste(in: app)
        return true
    }

    /// Pastes text only (the feedback prompt).
    @discardableResult
    static func pasteText(_ text: String, into running: NSRunningApplication?, bundleID: String?, name: String) async -> Bool {
        await paste(image: nil, text: text, into: running, bundleID: bundleID, name: name)
    }

    private static func paste(image: CGImage?, text: String?, into running: NSRunningApplication?, bundleID: String?,
                              name: String) async -> Bool {
        let text = text?.isEmpty == false ? text : nil
        guard image != nil || text != nil else { return false }   // never paste whatever was on the clipboard
        if let image {
            Screenshots.copy(image)
        } else if let text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        let copied = image != nil ? L("The image is on the clipboard.") : L("The text is on the clipboard.")
        guard let app = await activate(running, bundleID: bundleID) else {
            Toast.shared.show(String(format: L("Could not open %@"), name), detail: copied,
                              symbol: "exclamationmark.triangle.fill", style: .error, duration: 4)
            return false
        }
        guard isTrusted else {
            Toast.shared.show(image != nil ? L("Image copied – press ⌘V") : L("Text copied – press ⌘V"),
                              detail: L("Allow Accessibility access to paste automatically."),
                              symbol: "doc.on.clipboard.fill", style: .success, duration: 4)
            if !askedThisLaunch {
                askedThisLaunch = true
                requestPermission()
            }
            return false
        }
        await focusTextInput(in: app)
        pressPaste(in: app)
        if image != nil, let text {
            // Let the app take the image before the clipboard changes under it.
            try? await Task.sleep(for: .milliseconds(450))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            pressPaste(in: app)
        }
        return true
    }

    private static func pressPaste(in app: NSRunningApplication) {
        if !pressPasteMenuItem(of: app) { postCommandV() }
    }

    // MARK: Focusing the input field

    private static let textRoles: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]

    /// If no text field has focus in the app (say the user last clicked on a message), focuses its main input:
    /// the lowest text area or field in the front window that is not a search field – the chat box in Claude,
    /// Codex or T3 Code. Electron apps only build their accessibility tree once asked to (AXManualAccessibility).
    static func focusTextInput(in app: NSRunningApplication) async {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let focused: AXUIElement = attribute(axApp, kAXFocusedUIElementAttribute), isTextInput(focused), !isSearchField(focused) {
            return
        }
        for attempt in 0..<6 { // the tree may still be building right after AXManualAccessibility
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
            guard let input = mainTextInput(of: axApp) else { continue }
            AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(120))
            if let focused: AXUIElement = attribute(axApp, kAXFocusedUIElementAttribute), CFEqual(focused, input) { return }
            click(input) // some apps ignore AXFocused; a click into the field always works
            try? await Task.sleep(for: .milliseconds(150))
            return
        }
    }

    private static func mainTextInput(of axApp: AXUIElement) -> AXUIElement? {
        guard let window: AXUIElement = attribute(axApp, kAXFocusedWindowAttribute) ?? attribute(axApp, kAXMainWindowAttribute) else {
            return nil
        }
        let windowFrame = frame(of: window)
        var best: (element: AXUIElement, score: CGFloat)?
        var queue = [window], index = 0
        let deadline = Date().addingTimeInterval(0.8)
        while index < queue.count, index < 8000, Date() < deadline {
            let element = queue[index]
            index += 1
            let role: String = attribute(element, kAXRoleAttribute) ?? ""
            if textRoles.contains(role) {
                let box = frame(of: element)
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable)
                if settable.boolValue, !isSearchField(element), box.width >= 80, box.height > 0, windowFrame.intersects(box) {
                    // Lowest on screen wins (chat boxes sit at the bottom); a text area beats a one-line field.
                    let score = box.maxY + (role == kAXTextAreaRole ? 10_000 : 0)
                    if best == nil || score > best!.score { best = (element, score) }
                }
                continue
            }
            queue.append(contentsOf: children(element))
        }
        return best?.element
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        return textRoles.contains(role) || (attribute(element, "AXEditableAncestor") as AXUIElement?) != nil
    }

    private static func isSearchField(_ element: AXUIElement) -> Bool {
        if (attribute(element, kAXSubroleAttribute) as String?) == kAXSearchFieldSubrole { return true }
        let words = [kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXTitleAttribute]
            .compactMap { attribute(element, $0) as String? }.joined(separator: " ").lowercased()
        return ["such", "search", "find", "filter"].contains { words.contains($0) }
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let value: AXValue = attribute(element, kAXPositionAttribute) { AXValueGetValue(value, .cgPoint, &origin) }
        if let value: AXValue = attribute(element, kAXSizeAttribute) { AXValueGetValue(value, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }

    /// Clicks the middle of an element (screen coordinates, top-left origin) and puts the pointer back.
    private static func click(_ element: AXUIElement) {
        let box = frame(of: element)
        guard box.width > 0, box.height > 0 else { return }
        let point = CGPoint(x: box.midX, y: box.midY)
        let previous = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        if let previous { CGWarpMouseCursorPosition(previous) }
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

    /// Clicks the app's ⌘V menu item (Edit › Paste) through Accessibility: independent of the keyboard layout
    /// and of keys the user still holds. False if the app has no such enabled item.
    static func pressPasteMenuItem(of app: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar: AXUIElement = attribute(axApp, kAXMenuBarAttribute) else { return false }
        for barItem in children(menuBar) {
            for menu in children(barItem) {
                for item in children(menu) {
                    guard let char: String = attribute(item, kAXMenuItemCmdCharAttribute), char.uppercased() == "V",
                          let modifiers: Int = attribute(item, kAXMenuItemCmdModifiersAttribute), modifiers == 0 // ⌘ only
                    else { continue }
                    guard (attribute(item, kAXEnabledAttribute) as Bool?) ?? true else { return false }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    /// Fallback: a plain ⌘V keystroke. No unicode string on the event – with one, apps no longer treat it as ⌘V.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }
}
