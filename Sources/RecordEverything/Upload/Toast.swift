import AppKit
import SwiftUI

/// Small floating notice below the menu bar ("Link copied", upload progress, errors). Needs no notification permission.
@MainActor
final class Toast {
    static let shared = Toast()

    enum Style { case success, error, progress, info }

    private var panel: NSPanel?
    private let model = ToastModel()
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, detail: String? = nil, symbol: String, style: Style, duration: TimeInterval?) {
        model.text = text
        model.detail = detail
        model.symbol = symbol
        model.style = style
        model.progress = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
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
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
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

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let size = panel.contentView?.fittingSize ?? NSSize(width: 340, height: 64)
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }
}

final class ToastModel: ObservableObject {
    @Published var text = ""
    @Published var detail: String?
    @Published var symbol = "checkmark.circle.fill"
    @Published var style: Toast.Style = .info
    @Published var progress: Double?
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
        .onTapGesture { close() }
    }
}
