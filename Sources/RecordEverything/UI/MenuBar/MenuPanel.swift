import AppKit
import SwiftUI

/// The menu bar menu as a panel below the menu bar. Unlike NSPopover it does not depend on where macOS
/// parks the status item: with a full menu bar the item may sit off screen (overflow), which pushed the
/// popover above the top edge. Horizontally it follows the visible item, otherwise the click position.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    private var panel: MenuPanel?
    private var sticky = false
    private var lastAutoClose = Date.distantPast

    var isShown: Bool { panel?.isVisible ?? false }
    var windowNumber: Int? { isShown ? panel?.windowNumber : nil }

    func toggle(anchor: NSStatusBarButton?, sticky: Bool = false) {
        if isShown {
            close()
            return
        }
        // A click on the menu bar icon first closes the panel through resignKey; do not reopen it right away.
        if Date().timeIntervalSince(lastAutoClose) < 0.3 { return }
        show(anchor: anchor, sticky: sticky)
    }

    func show(anchor: NSStatusBarButton?, sticky: Bool = false) {
        self.sticky = sticky
        let mouse = NSEvent.mouseLocation
        let anchorFrame = anchor?.window?.frame
        let anchorScreen = anchorFrame.flatMap { f in NSScreen.screens.first { $0.frame.contains(CGPoint(x: f.midX, y: f.midY)) } }
        let screen = anchorScreen ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        let anchorX = anchorScreen != nil ? anchorFrame!.midX : mouse.x
        let visible = screen.visibleFrame

        // The list shrinks on small screens so the whole menu stays visible.
        let listHeight = min(300, max(110, visible.height - 16 - 430))
        let host = KeyCatchingHostingView(rootView: StatusPopoverView(listHeight: listHeight) { [weak self] in self?.close() }
            .environment(\.colorScheme, .dark)
            .tint(Theme.accent))
        host.onEscape = { [weak self] in self?.close() }
        var size = host.fittingSize
        size.height = min(size.height, visible.height - 8)

        var x = anchorX - size.width / 2
        x = min(max(x, visible.minX + 6), visible.maxX - size.width - 6)
        let frame = NSRect(x: x, y: visible.maxY - size.height - 4, width: size.width, height: size.height)

        let panel = self.panel ?? MenuPanel()
        panel.delegate = self
        panel.contentView = host
        panel.setFrame(frame, display: true)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(host)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !sticky, isShown else { return }
        lastAutoClose = Date()
        close()
    }
}

final class MenuPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
}
