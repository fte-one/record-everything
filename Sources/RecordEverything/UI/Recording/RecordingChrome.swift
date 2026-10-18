import AVFoundation
import AppKit
import SwiftUI

/// Borderless panel that can take key status (for Escape) without activating the app.
class ChromePanel: NSPanel {
    var allowsKey = false

    init(rect: CGRect, level: NSWindow.Level) {
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { allowsKey }
}

// MARK: - Countdown

@MainActor
final class Countdown {
    static let shared = Countdown()

    private var panel: ChromePanel?
    private var timer: Timer?
    private var completion: ((Bool) -> Void)?
    private let model = CountdownModel()
    var isRunning: Bool { panel != nil }

    func run(on screen: NSScreen, around rect: CGRect, seconds: Int = 3, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        model.value = seconds
        let size = CGSize(width: 240, height: 230)
        let frame = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        let panel = ChromePanel(rect: frame, level: .screenSaver)
        panel.allowsKey = true
        let host = KeyCatchingHostingView(rootView: CountdownView(model: model).environment(\.colorScheme, .dark))
        host.onEscape = { [weak self] in self?.cancel() }
        panel.contentView = host
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(host)
        self.panel = panel
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        model.value -= 1
        if model.value <= 0 { finish(true) }
    }

    func cancel() { finish(false) }

    private func finish(_ completed: Bool) {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        let cb = completion
        completion = nil
        cb?(completed)
    }
}

final class CountdownModel: ObservableObject {
    @Published var value = 3
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 10) {
            Text("\(model.value)")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .contentTransition(.numericText(countsDown: true))
                .animation(.easeOut(duration: 0.25), value: model.value)
            VStack(alignment: .leading, spacing: 4) {
                if let key = settings.startPauseHotKey { hint(L("Start / Pause:"), key.display) }
                if let key = settings.stopHotKey { hint(L("Stop:"), key.display) }
                hint(L("Cancel:"), "esc")
            }
            .font(.system(size: 11))
        }
        .foregroundStyle(.white)
        .frame(width: 220, height: 210)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.72)))
    }

    private func hint(_ label: String, _ key: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.secondary)
            Spacer()
            Text(key).fontWeight(.semibold)
        }
        .frame(width: 160)
    }
}

final class KeyCatchingHostingView<Content: View>: NSHostingView<Content> {
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

// MARK: - Frame around the recorded area

@MainActor
final class RegionFrame {
    static let shared = RegionFrame()
    private var panel: ChromePanel?

    func show(around rect: CGRect) {
        let panel = ChromePanel(rect: rect.insetBy(dx: -3, dy: -3), level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = FrameView()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private final class FrameView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 2
            path.setLineDash([8, 5], count: 2, phase: 0)
            NSColor(Theme.record).setStroke()
            path.stroke()
        }
    }
}

// MARK: - Record bar

@MainActor
final class RecordBar {
    static let shared = RecordBar()
    private var panel: ChromePanel?

    func show(on screen: NSScreen, avoiding rect: CGRect) {
        let size = CGSize(width: 300, height: 48)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 14)
        if origin.y < screen.visibleFrame.minY + 8 {
            origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 40)
        }
        origin.x = min(max(screen.frame.minX + 8, origin.x), screen.frame.maxX - size.width - 8)
        let panel = ChromePanel(rect: CGRect(origin: origin, size: size), level: .statusBar)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: RecordBarView().environment(\.colorScheme, .dark).tint(Theme.accent))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    func setDimmed(_ dimmed: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            panel?.animator().alphaValue = dimmed ? 0.35 : 1
        }
    }
}

private struct RecordBarView: View {
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var levels = AudioLevels.shared
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 12) {
            ToggleIcon(on: "mic.fill", off: "mic.slash", isOn: Binding(get: { recorder.micEnabled }, set: { _ in recorder.toggleMicrophone() }),
                       help: L("Microphone"), size: 30, level: levels.microphone)
            HStack(spacing: 6) {
                Circle().fill(recorder.state == .paused ? Color.orange : Theme.record).frame(width: 8, height: 8)
                Text(formatDuration(recorder.elapsed))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
            }
            .frame(minWidth: 110)
            IconButton(symbol: recorder.state == .paused ? "play.fill" : "pause.fill", size: 30,
                       help: recorder.state == .paused ? L("Resume") : L("Pause")) { recorder.togglePause() }
            IconButton(symbol: "stop.fill", size: 30, help: L("Stop Recording"), tint: Theme.record) {
                Task { await recorder.stop() }
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 300, height: 48)
        .background(Capsule().fill(Theme.panel.opacity(0.96)))
        .overlay(Capsule().stroke(Color.white.opacity(0.1)))
        .onHover { inside in
            hideTask?.cancel()
            if inside {
                RecordBar.shared.setDimmed(false)
            } else {
                scheduleAutoHide()
            }
        }
        .onAppear { scheduleAutoHide() }
    }

    /// The bar fades after a few seconds without the pointer.
    private func scheduleAutoHide() {
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { RecordBar.shared.setDimmed(true) }
        }
    }
}

// MARK: - Webcam bubble

@MainActor
final class CameraBubble {
    static let shared = CameraBubble()
    private(set) var window: ChromePanel?
    private var started = false
    var isVisible: Bool { window?.isVisible ?? false }

    func show(on screen: NSScreen) {
        if let window { window.orderFrontRegardless(); return }
        let side: CGFloat = 200
        let rect = CGRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: side, height: side)
        let panel = ChromePanel(rect: rect, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        panel.hasShadow = true
        panel.contentView = BubbleView(session: CameraManager.shared.session)
        panel.orderFrontRegardless()
        window = panel
        Task {
            started = await CameraManager.shared.start(deviceID: AppSettings.shared.capture.cameraID)
            if !started {
                hide()
                AppController.shared.presentError(RecorderError.noCamera)
            }
        }
    }

    func switchCamera() {
        guard window != nil else { return }
        Task { _ = await CameraManager.shared.start(deviceID: AppSettings.shared.capture.cameraID); CameraManager.shared.stop() }
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        if started { CameraManager.shared.stop() }
        started = false
    }

    /// Round live preview; drag inside to move, drag the rim to resize.
    private final class BubbleView: NSView {
        private let preview: AVCaptureVideoPreviewLayer
        private var resizing = false
        private var grab = CGPoint.zero

        init(session: AVCaptureSession) {
            preview = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            wantsLayer = true
            preview.videoGravity = .resizeAspectFill
            if let c = preview.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
            layer?.addSublayer(preview)
            layer?.masksToBounds = true
            layer?.borderColor = Theme.accentNS.cgColor
            layer?.borderWidth = 3
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            layer?.cornerRadius = bounds.width / 2
            preview.frame = bounds
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            let d = hypot(p.x - bounds.midX, p.y - bounds.midY)
            resizing = d > bounds.width / 2 - 16
            grab = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            if resizing {
                let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
                let m = NSEvent.mouseLocation
                let side = min(max(2 * hypot(m.x - center.x, m.y - center.y), 120), 520)
                window.setFrame(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), display: true)
            } else {
                let m = NSEvent.mouseLocation
                window.setFrameOrigin(CGPoint(x: m.x - grab.x, y: m.y - grab.y))
            }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
