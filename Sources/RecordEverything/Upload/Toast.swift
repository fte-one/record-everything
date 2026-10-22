import AppKit
import SwiftUI

/// Small floating notice below the menu bar ("Link copied", upload progress, errors). Needs no notification permission.
@MainActor
final class Toast {
    static let shared = Toast()

    enum Style { case success, error, progress, info }

    /// A button on the notice, e.g. to cancel an upload.
    struct Action {
        let title: String
        let handler: () -> Void
    }

    private var panel: NSPanel?
    private let model = ToastModel()
    private var hideWork: DispatchWorkItem?
    /// Counts the notices shown, so a fade-out that ends after a newer notice appeared leaves that one up.
    private var shownCount = 0

    /// Window and screen frame of the visible notice (self test screenshots).
    var windowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }
    var frame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }

    /// `anchor` (a screen rect such as the menu bar icon) puts the notice right below it instead of at the top center.
    func show(_ text: String, detail: String? = nil, symbol: String, style: Style, duration: TimeInterval?,
              anchor: CGRect? = nil, action: Action? = nil) {
        model.text = text
        model.detail = detail
        model.symbol = symbol
        model.style = style
        model.progress = nil
        model.action = action
        shownCount += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel, anchor: anchor)
        // Through the animator, so it also replaces a fade-out still running.
        NSAnimationContext.runAnimationGroup { $0.duration = 0; panel.animator().alphaValue = 1 }
        panel.orderFrontRegardless()
        hideWork?.cancel()
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func updateProgress(_ fraction: Double) {
        guard model.style == .progress else { return }
        model.progress = fraction
    }

    func hide() {
        guard let panel else { return }
        let count = shownCount
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { [weak self] in
                                                 if self?.shownCount == count { panel.orderOut(nil) }
                                             } })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: ToastView(model: model, close: { [weak self] in self?.hide() })
            .environment(\.colorScheme, .dark))
        return panel
    }

    private func position(_ panel: NSPanel, anchor: CGRect?) {
        let point = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main!
        let visible = screen.visibleFrame
        let size = panel.contentView?.fittingSize ?? NSSize(width: 340, height: 64)
        var x = (anchor?.midX ?? visible.midX) - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let frame = NSRect(x: x, y: visible.maxY - size.height - (anchor == nil ? 12 : 6), width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }
}

final class ToastModel: ObservableObject {
    @Published var text = ""
    @Published var detail: String?
    @Published var symbol = "checkmark.circle.fill"
    @Published var style: Toast.Style = .info
    @Published var progress: Double?
    @Published var action: Toast.Action?
}

private struct ToastView: View {
    @ObservedObject var model: ToastModel
    let close: () -> Void

    private var tint: Color {
        switch model.style {
        case .success: return Theme.accent
        case .error: return Theme.record
        case .progress, .info: return .white
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if model.style == .progress && model.progress == nil {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: model.symbol).font(.system(size: 22)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.text).font(.system(size: 13, weight: .semibold)).lineLimit(3)
                if let detail = model.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let progress = model.progress {
                    ProgressView(value: progress).tint(Theme.accent)
                }
            }
            Spacer(minLength: 0)
            if let action = model.action {
                Button(action: action.handler) {
                    Text(action.title)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
        .onTapGesture { close() }
    }
}
