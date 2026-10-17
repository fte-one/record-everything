import AppKit
import SwiftUI

/// Creates and reuses the app's SwiftUI windows by id.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var windows: [String: NSWindow] = [:]
    private var closeHandlers: [String: () -> Void] = [:]

    struct Style {
        var size: NSSize
        var minSize: NSSize? = nil
        var resizable = false
        var titled = true
        var transparentTitlebar = true
        var floating = false
    }

    @discardableResult
    func show<V: View>(id: String, title: String, style: Style, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> V) -> NSWindow {
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return w
        }
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if style.resizable { mask.insert(.resizable) }
        if style.transparentTitlebar { mask.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: style.size), styleMask: mask, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = style.transparentTitlebar
        if style.transparentTitlebar { window.titleVisibility = .hidden }
        window.backgroundColor = NSColor(Theme.background)
        window.contentViewController = NSHostingController(rootView: content().environment(\.colorScheme, .dark).tint(Theme.accent))
        window.setContentSize(style.size)
        if let min = style.minSize { window.contentMinSize = min }
        if style.floating { window.level = .floating }
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.center()
        windows[id] = window
        if let onClose { closeHandlers[id] = onClose }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    func window(_ id: String) -> NSWindow? { windows[id] }

    func close(_ id: String) { windows[id]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        // Tearing down the hosting controller lets SwiftUI run onDisappear (stops camera, microphone, players).
        window.contentViewController = nil
        closeHandlers.removeValue(forKey: id)?()
    }
}
