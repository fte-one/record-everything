import AppKit
import SwiftUI

/// The frame around the recorded window and the session bar under it.
@MainActor
final class FeedbackChrome {
    static let shared = FeedbackChrome()
    private var frame: ChromePanel?
    private var bar: ChromePanel?
    private var ink: ChromePanel?
    private let inkView = InkView()
    private let barSize = CGSize(width: 560, height: 50)

    /// `bounds`: the window in CoreGraphics coordinates.
    func show(around bounds: CGRect) {
        hide()
        let rect = WindowGeometry.appKitRect(bounds)
        let frame = ChromePanel(rect: rect.insetBy(dx: -8, dy: -8), level: .statusBar)
        frame.ignoresMouseEvents = true
        frame.contentView = NSHostingView(rootView: FeedbackFrameView())
        frame.orderFrontRegardless()
        self.frame = frame

        let bar = ChromePanel(rect: barRect(for: rect), level: .statusBar)
        bar.hasShadow = true
        bar.isMovableByWindowBackground = true
        bar.contentView = NSHostingView(rootView: FeedbackBarView().environment(\.colorScheme, .dark).tint(Theme.accent))
        bar.alphaValue = 0
        bar.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            bar.animator().alphaValue = 1
        }
        self.bar = bar
    }

    func move(around bounds: CGRect) {
        let rect = WindowGeometry.appKitRect(bounds)
        frame?.setFrame(rect.insetBy(dx: -8, dy: -8), display: true)
        bar?.setFrame(barRect(for: rect), display: true)
    }

    func hide() {
        frame?.orderOut(nil)
        bar?.orderOut(nil)
        ink?.orderOut(nil)
        frame = nil
        bar = nil
        ink = nil
    }

    // MARK: Drawing with the shot key

    /// The line drawn so far, over the window (points and window in CoreGraphics coordinates).
    func showInk(_ points: [CGPoint], in window: CGRect) {
        let rect = WindowGeometry.appKitRect(window)
        if ink == nil {
            let panel = ChromePanel(rect: rect, level: .statusBar)
            panel.ignoresMouseEvents = true
            panel.contentView = inkView
            ink = panel
        }
        ink?.setFrame(rect, display: false)
        ink?.alphaValue = 1
        ink?.orderFrontRegardless()
        inkView.points = points.map { CGPoint(x: $0.x - window.minX, y: $0.y - window.minY) }
    }

    func clearInk(fade: Bool) {
        guard let panel = ink else { return }
        guard fade else {
            inkView.points = []
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard panel.alphaValue == 0 else { return }   // a new line started meanwhile
                self.inkView.points = []
                panel.orderOut(nil)
            }
        })
    }

    /// A short white flash over the window: the screenshot was taken.
    func flash(_ window: CGRect) {
        let panel = ChromePanel(rect: WindowGeometry.appKitRect(window), level: .statusBar)
        panel.ignoresMouseEvents = true
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.45).cgColor
        view.layer?.cornerRadius = 10
        panel.contentView = view
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// Under the window, or inside its bottom edge when there is no room below.
    private func barRect(for window: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(window) }) ?? NSScreen.main ?? NSScreen.screens.first else {
            return CGRect(origin: CGPoint(x: window.midX - barSize.width / 2, y: window.minY + 16), size: barSize)
        }
        var origin = CGPoint(x: window.midX - barSize.width / 2, y: window.minY - barSize.height - 12)
        if origin.y < screen.visibleFrame.minY + 4 { origin.y = window.minY + 16 }
        origin.x = min(max(screen.frame.minX + 8, origin.x), screen.frame.maxX - barSize.width - 8)
        return CGRect(origin: origin, size: barSize)
    }
}

/// The red line drawn while the shot key is held (top-left coordinates within the window).
private final class InkView: NSView {
    var points: [CGPoint] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        NSColor(srgbRed: 0.98, green: 0.22, blue: 0.2, alpha: 1).setStroke()
        path.stroke()
    }
}

/// Green frame that flashes in when the session starts, then stays as a thin line.
private struct FeedbackFrameView: View {
    @State private var settled = false
    @ObservedObject private var session = FeedbackSession.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(color, lineWidth: settled ? 3 : 10)
            .shadow(color: color.opacity(settled ? 0.25 : 0.9), radius: settled ? 4 : 22)
            .scaleEffect(settled ? 1 : 1.025)
            .opacity(session.isActive ? 1 : 0)
            .padding(4)
            .onAppear {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.65).delay(0.05)) { settled = true }
            }
    }

    private var color: Color { session.state == .paused ? .orange : Theme.accent }
}

private struct FeedbackBarView: View {
    @ObservedObject private var session = FeedbackSession.shared
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            if case .finishing(let text) = session.state {
                ProgressView().controlSize(.small)
                Text(text).font(.system(size: 12.5, weight: .medium))
                Spacer()
            } else {
                HStack(spacing: 7) {
                    Circle().fill(session.state == .paused ? Color.orange : Theme.record)
                        .frame(width: 9, height: 9)
                        .opacity(session.state == .running && pulse ? 0.35 : 1)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    Text(feedbackClock(session.elapsed))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .frame(width: 44, alignment: .leading)
                }
                Capsule().fill(Color.white.opacity(0.15)).frame(width: 34, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent).frame(width: 34 * CGFloat(session.level), height: 5)
                    }
                Text(session.lastWords.isEmpty ? hint : "„\(session.lastWords)“")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 3) {
                    Image(systemName: "photo.on.rectangle")
                    Text("\(session.shotCount)")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .help(L("Screenshots so far"))
                IconButton(symbol: "camera.viewfinder", size: 30, help: L("Mark: keep what is on screen now")) { session.mark() }
                IconButton(symbol: session.state == .paused ? "play.fill" : "pause.fill", size: 30,
                           help: session.state == .paused ? L("Resume") : L("Pause")) { session.togglePause() }
                IconButton(symbol: "xmark", size: 26, help: L("Discard session")) { confirmDiscard() }
                Button { session.stop() } label: {
                    Label(L("Done"), systemImage: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.record))
                }
                .buttonStyle(.plain)
                .help(L("End the session and write the prompt")
                      + (AppSettings.shared.feedbackTrigger.display.map { " (\($0))" } ?? ""))
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 560, height: 50)
        .background(Capsule().fill(Theme.panel.opacity(0.97)))
        .overlay(Capsule().stroke(Color.white.opacity(0.1)))
        .onAppear { pulse = true }
    }

    private var hint: String {
        let key = AppSettings.shared.feedbackShotKey.symbol
        return String(format: L("Talk · %@ tap: screenshot · hold %@ and move: draw"), key, key)
    }

    private func confirmDiscard() {
        let alert = NSAlert()
        alert.messageText = L("Discard this feedback session?")
        alert.informativeText = L("Screenshots and speech of this session are deleted.")
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { session.discard() }
    }
}
