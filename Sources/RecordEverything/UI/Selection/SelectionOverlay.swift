import AppKit
import ScreenCaptureKit
import SwiftUI

/// Full-screen area picker, one window per display.
@MainActor
final class SelectionOverlay {
    static let shared = SelectionOverlay()

    private var windows: [OverlayWindow] = []
    private var onConfirm: ((ScreenTarget, NSScreen) -> Void)?
    private var onCancel: (() -> Void)?
    private(set) var isActive = false
    let bar = SelectionBarModel()

    func begin(onConfirm: @escaping (ScreenTarget, NSScreen) -> Void, onCancel: @escaping () -> Void) {
        guard !isActive else { return }
        isActive = true
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        Task {
            let images = await Self.captureScreens()
            for screen in NSScreen.screens {
                let window = OverlayWindow(screen: screen)
                let view = SelectionView(screen: screen, overlay: self, image: images[screen.displayID])
                window.contentView = view
                windows.append(window)
                window.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            let key = windows.first { $0.targetScreen == mouseScreen } ?? windows.first
            key?.makeKey()
            key?.makeFirstResponder(key?.contentView)
            if AppSettings.shared.capture.camera { CameraBubble.shared.show(on: mouseScreen ?? NSScreen.main!) }
        }
    }

    /// Called by a view when the user starts selecting on its screen; clears the other screens.
    func activate(_ view: SelectionView) {
        for w in windows where w.contentView !== view {
            (w.contentView as? SelectionView)?.clearSelection()
        }
        view.window?.makeKey()
    }

    var activeView: SelectionView? {
        windows.compactMap { $0.contentView as? SelectionView }.first { $0.selection != nil }
    }

    func confirm() {
        guard let view = activeView, let rect = view.selection else { return }
        let screen = view.screen
        let target = ScreenTarget(displayID: screen.displayID, rect: rect.integral, backingScale: screen.backingScaleFactor)
        let cb = onConfirm
        close()
        cb?(target, screen)
    }

    func cancel() {
        let cb = onCancel
        close()
        cb?()
    }

    private func close() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        isActive = false
        onConfirm = nil
        onCancel = nil
        // The setting bar meters the microphone; the recorder starts it again for the recording.
        if !Recorder.shared.isActive { MicrophoneMonitor.shared.stop() }
    }

    /// Still image of each display for the magnifier.
    private static func captureScreens() async -> [CGDirectDisplayID: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [:] }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var result: [CGDirectDisplayID: CGImage] = [:]
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                result[display.displayID] = image
            }
        }
        return result
    }
}

final class OverlayWindow: NSPanel {
    let targetScreen: NSScreen

    init(screen: NSScreen) {
        targetScreen = screen
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: false)
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// State shared between the overlay and the SwiftUI setting bar.
@MainActor
final class SelectionBarModel: ObservableObject {
    @Published var width = 0
    @Published var height = 0
    weak var view: SelectionView?

    func applySize(width: Int, height: Int) { view?.applySize(width: CGFloat(width), height: CGFloat(height)) }
    func applyAspect(_ aspect: AspectPreset) { view?.applyAspect(aspect) }
    func record() { SelectionOverlay.shared.confirm() }
    func close() { SelectionOverlay.shared.cancel() }
}

/// Draws the dimmed screen, the hovered window, the selection with handles, the size label and the magnifier.
final class SelectionView: NSView {
    let screen: NSScreen
    private unowned let overlay: SelectionOverlay
    private let image: CGImage?

    private(set) var selection: CGRect?
    private var hoveredWindow: (rect: CGRect, title: String)?
    private var windowRects: [(rect: CGRect, title: String)] = []
    private var mouse: CGPoint?

    private enum Drag {
        case drawing(start: CGPoint)
        case moving(grab: CGPoint, original: CGRect)
        case resizing(handle: Handle, original: CGRect)
    }
    private var drag: Drag?
    private var didDrag = false

    private enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    private var barHost: NSHostingView<AnyView>?

    init(screen: NSScreen, overlay: SelectionOverlay, image: CGImage?) {
        self.screen = screen
        self.overlay = overlay
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        loadWindowRects()
        let options: NSTrackingArea.Options = [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var aspect: AspectPreset { AppSettings.shared.capture.aspect }

    // MARK: Windows under the cursor

    private func loadWindowRects() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displayBounds = CGDisplayBounds(screen.displayID)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let local = bounds.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY).intersection(self.bounds)
            guard local.width > 40, local.height > 40 else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let name = info[kCGWindowName as String] as? String ?? ""
            windowRects.append((local, name.isEmpty ? owner : "\(owner) – \(name)"))
        }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if selection == nil, let mouse {
            hoveredWindow = windowRects.first { $0.rect.contains(mouse) }
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        overlay.activate(self)
        didDrag = false
        if let sel = selection {
            if let h = handle(at: p, in: sel) {
                drag = .resizing(handle: h, original: sel)
                return
            }
            if sel.contains(p) {
                drag = .moving(grab: p, original: sel)
                return
            }
        }
        drag = .drawing(start: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        mouse = p
        didDrag = true
        switch drag {
        case .drawing(let start):
            hoveredWindow = nil
            var r = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            if let ratio = aspect.ratio {
                r.size.height = r.width / ratio
                if p.y < start.y { r.origin.y = start.y - r.height }
            }
            setSelection(r, keepAspect: false)
        case .moving(let grab, let original):
            var r = original.offsetBy(dx: p.x - grab.x, dy: p.y - grab.y)
            r.origin.x = min(max(0, r.minX), bounds.width - r.width)
            r.origin.y = min(max(0, r.minY), bounds.height - r.height)
            setSelection(r, keepAspect: false)
        case .resizing(let handle, let original):
            setSelection(resize(original, handle: handle, to: p), keepAspect: false)
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        if case .drawing = drag, !didDrag || (selection?.width ?? 0) < 8 || (selection?.height ?? 0) < 8 {
            // A click picks the window under the cursor, or the whole screen.
            let p = convert(event.locationInWindow, from: nil)
            let target = windowRects.first { $0.rect.contains(p) }?.rect ?? bounds
            if target == bounds {
                var options = AppSettings.shared.capture
                options.aspect = .fullScreen
                AppSettings.shared.capture = options
            } else if aspect == .fullScreen {
                var options = AppSettings.shared.capture
                options.aspect = .custom
                AppSettings.shared.capture = options
            }
            setSelection(target, keepAspect: aspect.ratio != nil)
        }
        if event.clickCount == 2, selection != nil { overlay.confirm() }
        window?.invalidateCursorRects(for: self)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: overlay.cancel()                  // Escape
        case 36, 76: overlay.confirm()            // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: convert(event.locationInWindow, from: nil)) }

    private func updateCursor(at p: CGPoint) {
        guard let sel = selection else { NSCursor.crosshair.set(); return }
        if let h = handle(at: p, in: sel) {
            switch h {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if sel.contains(p) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: Geometry

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    private func handlePoints(_ r: CGRect) -> [Handle: CGPoint] {
        [.topLeft: CGPoint(x: r.minX, y: r.minY), .top: CGPoint(x: r.midX, y: r.minY), .topRight: CGPoint(x: r.maxX, y: r.minY),
         .right: CGPoint(x: r.maxX, y: r.midY), .bottomRight: CGPoint(x: r.maxX, y: r.maxY), .bottom: CGPoint(x: r.midX, y: r.maxY),
         .bottomLeft: CGPoint(x: r.minX, y: r.maxY), .left: CGPoint(x: r.minX, y: r.midY)]
    }

    private func handle(at p: CGPoint, in r: CGRect) -> Handle? {
        handlePoints(r).first { hypot($0.value.x - p.x, $0.value.y - p.y) < 9 }?.key
    }

    private func resize(_ o: CGRect, handle: Handle, to p: CGPoint) -> CGRect {
        var minX = o.minX, minY = o.minY, maxX = o.maxX, maxY = o.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        var r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: max(abs(maxX - minX), 20), height: max(abs(maxY - minY), 20))
        if let ratio = aspect.ratio {
            switch handle {
            case .top, .bottom:
                let w = r.height * ratio
                r.origin.x = o.midX - w / 2
                r.size.width = w
            default:
                let h = r.width / ratio
                if handle == .topLeft || handle == .topRight { r.origin.y = r.maxY - h }
                r.size.height = h
            }
        }
        return r
    }

    private func fitted(_ r: CGRect) -> CGRect {
        var r = r
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(0, r.minX), bounds.width - r.width)
        r.origin.y = min(max(0, r.minY), bounds.height - r.height)
        return r
    }

    func setSelection(_ r: CGRect, keepAspect: Bool) {
        var r = r
        if keepAspect, let ratio = aspect.ratio { r = shape(r, ratio: ratio) }
        selection = fitted(r).integral
        overlay.bar.width = Int(selection!.width)
        overlay.bar.height = Int(selection!.height)
        overlay.bar.view = self
        layoutBar()
        needsDisplay = true
    }

    /// Gives a rect the ratio while keeping its center and staying on screen.
    private func shape(_ r: CGRect, ratio: CGFloat) -> CGRect {
        var w = r.width, h = r.width / ratio
        if h > bounds.height * 0.95 { h = bounds.height * 0.95; w = h * ratio }
        if w > bounds.width * 0.95 { w = bounds.width * 0.95; h = w / ratio }
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    func clearSelection() {
        selection = nil
        barHost?.isHidden = true
        needsDisplay = true
    }

    func applyAspect(_ preset: AspectPreset) {
        var options = AppSettings.shared.capture
        options.aspect = preset
        AppSettings.shared.capture = options
        switch preset {
        case .fullScreen:
            setSelection(bounds, keepAspect: false)
        case .custom:
            break
        default:
            let base = selection ?? bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2)
            setSelection(base, keepAspect: true)
        }
    }

    func applySize(width: CGFloat, height: CGFloat) {
        guard let sel = selection else { return }
        var w = max(20, width), h = max(20, height)
        if let ratio = aspect.ratio {
            if Int(w) != Int(sel.width) { h = w / ratio } else { w = h * ratio }
        }
        setSelection(CGRect(x: sel.midX - w / 2, y: sel.midY - h / 2, width: w, height: h), keepAspect: false)
    }

    // MARK: Setting bar

    private func layoutBar() {
        guard let sel = selection else { return }
        if barHost == nil {
            let host = NSHostingView(rootView: AnyView(SettingBarView(model: overlay.bar).environment(\.colorScheme, .dark).tint(Theme.accent)))
            addSubview(host)
            barHost = host
        }
        guard let host = barHost else { return }
        host.isHidden = false
        let size = host.fittingSize
        var origin = CGPoint(x: sel.midX - size.width / 2, y: sel.maxY + 12)
        if origin.y + size.height > bounds.height - 8 { origin.y = sel.minY - size.height - 12 }
        if origin.y < 8 { origin.y = sel.maxY - size.height - 24 }
        origin.x = min(max(8, origin.x), bounds.width - size.width - 8)
        host.frame = CGRect(origin: origin, size: size)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        let hole = selection ?? hoveredWindow?.rect

        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let hole { dim.addRect(hole) }
        ctx.addPath(dim)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillPath(using: .evenOdd)

        if let sel = selection {
            drawSelection(sel, in: ctx)
        } else if let hovered = hoveredWindow {
            ctx.setFillColor(Theme.accentNS.withAlphaComponent(0.14).cgColor)
            ctx.fill(hovered.rect)
            ctx.setStrokeColor(Theme.accentNS.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(hovered.rect.insetBy(dx: 1.5, dy: 1.5))
            drawLabel(hovered.title, at: CGPoint(x: hovered.rect.midX, y: hovered.rect.midY), centered: true)
        }

        if selection == nil {
            drawLabel(L("Click a window or drag to select an area · Esc to cancel"),
                      at: CGPoint(x: bounds.midX, y: 60), centered: true)
        }

        var showMagnifier = selection == nil
        if case .drawing = drag { showMagnifier = true }
        if case .resizing = drag { showMagnifier = true }
        if showMagnifier, let mouse { drawMagnifier(at: mouse, in: ctx) }
    }

    private func drawSelection(_ sel: CGRect, in ctx: CGContext) {
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))
        ctx.setStrokeColor(Theme.accentNS.cgColor)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))
        ctx.setLineDash(phase: 0, lengths: [])

        for (_, p) in handlePoints(sel) {
            let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        let label = "\(Int(sel.width)) × \(Int(sel.height))"
        let y = sel.minY > 30 ? sel.minY - 16 : sel.minY + 16
        drawLabel(label, at: CGPoint(x: sel.minX + 4, y: y), centered: false)
    }

    private func drawLabel(_ text: String, at p: CGPoint, centered: Bool) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        var r = CGRect(x: p.x, y: p.y - size.height / 2 - 3, width: size.width + 14, height: size.height + 6)
        if centered { r.origin.x -= r.width / 2 }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(at: CGPoint(x: r.minX + 7, y: r.minY + 3))
    }

    private func drawMagnifier(at p: CGPoint, in ctx: CGContext) {
        let diameter: CGFloat = 120
        let zoom: CGFloat = 4
        var origin = CGPoint(x: p.x + 20, y: p.y + 20)
        if origin.x + diameter > bounds.width { origin.x = p.x - 20 - diameter }
        if origin.y + diameter + 22 > bounds.height { origin.y = p.y - 20 - diameter - 22 }
        let circle = CGRect(origin: origin, size: CGSize(width: diameter, height: diameter))

        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        NSColor.black.setFill()
        ctx.fill(circle)
        if let image {
            let scale = CGFloat(image.width) / bounds.width
            let side = diameter / zoom
            let src = CGRect(x: (p.x - side / 2) * scale, y: (p.y - side / 2) * scale, width: side * scale, height: side * scale)
            if let crop = image.cropping(to: src) {
                ctx.interpolationQuality = .none
                // The view is flipped; draw the image upside down so it appears upright.
                ctx.translateBy(x: circle.minX, y: circle.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
            }
        }
        ctx.restoreGState()

        ctx.setStrokeColor(Theme.accentNS.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: circle.midX, y: circle.minY + 6)); ctx.addLine(to: CGPoint(x: circle.midX, y: circle.maxY - 6))
        ctx.move(to: CGPoint(x: circle.minX + 6, y: circle.midY)); ctx.addLine(to: CGPoint(x: circle.maxX - 6, y: circle.midY))
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: circle)

        drawLabel("\(Int(p.x)), \(Int(p.y))", at: CGPoint(x: circle.midX, y: circle.maxY + 14), centered: true)
    }
}
