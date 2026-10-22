import AppKit
import SwiftUI

/// Large drop area right below the menu bar icon. It opens while files are dragged toward the icon (or onto it),
/// so a drop neither has to hit the small icon nor the screen edge, and it covers what lies below the menu bar
/// there, such as a browser's tab bar that would otherwise react to the files passing over it.
@MainActor
final class DropZone {
    static let shared = DropZone()

    private static let size = NSSize(width: 300, height: 132)
    private let model = DropZoneModel()
    private var panel: NSPanel?
    private var anchor: () -> CGRect? = { nil }
    private var onVisible: (Bool) -> Void = { _ in }
    private var onDrop: ([URL]) -> Void = { _ in }
    private var dragCount = 0
    private var fileDrag = false
    private var endTimer: Timer?
    private var releasedAt: Date?

    var isShown: Bool { panel?.isVisible ?? false }
    var isTargeted: Bool { model.targeted }
    /// The visible zone's window (self test).
    var window: NSWindow? { isShown ? panel : nil }

    /// `anchor` gives the menu bar icon's screen frame, `onVisible` follows the zone, `onDrop` receives the files.
    func start(anchor: @escaping () -> CGRect?, onVisible: @escaping (Bool) -> Void, onDrop: @escaping ([URL]) -> Void) {
        self.anchor = anchor
        self.onVisible = onVisible
        self.onDrop = onDrop
        dragCount = NSPasteboard(name: .drag).changeCount
        // Mouse events of other apps can be watched without any permission. A press ends the previous drag; a drag
        // that put file URLs on the drag pasteboard is a file drag. Only the types are read, never the contents.
        _ = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.fileDrag = false }
        }
        _ = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
    }

    /// The upper part of the screen around the icon: files dragged into it open the zone.
    var activationArea: CGRect? {
        guard let icon = anchor(), let screen = screen(for: icon) else { return nil }
        return CGRect(x: icon.midX - 220, y: screen.frame.maxY - 220, width: 440, height: 220)
    }

    /// Shows the zone; with `urls` (files right over the icon) directly in its "release" state.
    /// `sticky` keeps it up without a pressed mouse button (self test only).
    func show(targetedBy urls: [URL]? = nil, sticky: Bool = false) {
        if let urls { target(urls) }
        guard !isShown, let icon = anchor(), let screen = screen(for: icon) else { return }
        let visible = screen.visibleFrame
        var x = icon.midX - Self.size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.configured = UploadManager.shared.isConfigured
        panel.setFrame(NSRect(x: x, y: visible.maxY - Self.size.height - 8, width: Self.size.width, height: Self.size.height), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        onVisible(true)
        if !sticky { watchForDragEnd() }
    }

    func hide() {
        endTimer?.invalidate()
        endTimer = nil
        guard isShown else { return }
        panel?.orderOut(nil)
        model.targeted = false
        model.summary = nil
        onVisible(false)
    }

    func target(_ urls: [URL]) {
        model.summary = FileSharing.summary(urls)
        model.multiple = urls.count > 1
        model.targeted = true
    }

    func untarget() { model.targeted = false }

    /// Hands dropped files on (from the zone or the icon) and closes the zone.
    func drop(_ urls: [URL]) -> Bool {
        hide()
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }

    private func mouseDragged() {
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.changeCount != dragCount {
            dragCount = pasteboard.changeCount
            fileDrag = pasteboard.types?.contains(.fileURL) == true
        }
        guard fileDrag else { return }
        let mouse = NSEvent.mouseLocation
        if activationArea?.contains(mouse) == true {
            show()
        } else if let frame = window?.frame, !model.targeted, !frame.insetBy(dx: -40, dy: -40).contains(mouse) {
            hide()
        }
    }

    /// The drag is over once the mouse button has been up for a moment; the drop itself arrives right after the release.
    private func watchForDragEnd() {
        endTimer?.invalidate()
        releasedAt = nil
        endTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    self.releasedAt = nil
                } else if let releasedAt = self.releasedAt {
                    if Date().timeIntervalSince(releasedAt) > 0.4 { self.hide() }
                } else {
                    self.releasedAt = Date()
                }
            }
        }
    }

    private func screen(for icon: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(CGPoint(x: icon.midX, y: icon.midY)) } ?? NSScreen.main
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = DropZoneHost(rootView: DropZoneView(model: model))
        host.registerForDraggedTypes([.fileURL])
        panel.contentView = host
        return panel
    }
}

/// Makes the menu bar icon a drop target as well: files right over it open the zone in its "release" state.
/// The status item's window forwards the dragging messages to its delegate.
@MainActor
final class StatusItemDropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    private weak var window: NSWindow?

    /// Safe to call repeatedly; picks up a new window if macOS replaced the status item's one.
    func attach(to button: NSStatusBarButton) {
        guard let window = button.window, window !== self.window else { return }
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
        self.window = window
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = sender.fileURLs
        guard !urls.isEmpty else { return [] }
        DropZone.shared.show(targetedBy: urls)
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.fileURLs.isEmpty ? [] : .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        DropZone.shared.untarget()
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropZone.shared.drop(sender.fileURLs)
    }
}

/// Shows the zone and takes the drop.
final class DropZoneHost: NSHostingView<DropZoneView> {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = sender.fileURLs
        guard !urls.isEmpty else { return [] }
        DropZone.shared.target(urls)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.fileURLs.isEmpty ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DropZone.shared.untarget()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropZone.shared.drop(sender.fileURLs)
    }
}

final class DropZoneModel: ObservableObject {
    @Published var targeted = false
    @Published var summary: String?
    @Published var multiple = false
    @Published var configured = true
}

struct DropZoneView: View {
    @ObservedObject var model: DropZoneModel

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: model.configured ? "arrow.up.doc.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: tint.opacity(model.targeted ? 0.6 : 0.3), radius: model.targeted ? 10 : 5)
                .scaleEffect(model.targeted ? 1.08 : 1)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary).truncationMode(.middle)
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel.opacity(0.97)))
        .background(RoundedRectangle(cornerRadius: 16).fill(tint.opacity(model.targeted ? 0.14 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(model.targeted ? tint : Color.white.opacity(0.22),
                                                                 style: StrokeStyle(lineWidth: model.targeted ? 2 : 1.5, dash: [6, 5])))
        .animation(.easeOut(duration: 0.15), value: model.targeted)
        .environment(\.colorScheme, .dark)
    }

    private var tint: Color { model.configured ? Theme.accent : .orange }

    private var title: String {
        guard model.configured else { return L("Uploading is not set up yet") }
        guard model.targeted else { return L("Drop here to upload") }
        return model.multiple ? L("Release to upload & copy the links") : L("Release to upload & copy the link")
    }

    private var subtitle: String {
        guard model.configured else { return L("Release to open the settings") }
        return model.summary ?? L("The link lands on the clipboard")
    }
}

extension NSDraggingInfo {
    /// The file URLs on the drag (Finder, desktop, other apps that drag files).
    var fileURLs: [URL] {
        draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
