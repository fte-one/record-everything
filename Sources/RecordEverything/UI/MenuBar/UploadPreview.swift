import AppKit
import SwiftUI

/// Large preview of an upload next to the menu while the pointer rests on its thumbnail. It shows the
/// uploaded file itself, loaded from its public link, so you can check what is online without a browser.
@MainActor
final class UploadPreview {
    static let shared = UploadPreview()

    private var panel: NSPanel?
    private var current: UUID?
    private let cache = NSCache<NSURL, NSImage>()
    private static let imageTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    /// Screen frame of the visible preview (self test screenshots).
    var frame: CGRect? { panel?.isVisible == true ? panel?.frame : nil }
    var windowNumber: Int? { panel?.isVisible == true ? panel?.windowNumber : nil }

    /// `anchorY` is the vertical screen position of the hovered row.
    func show(_ record: UploadRecord, anchorY: CGFloat) {
        guard let menu = NSApp.windows.first(where: { $0 is MenuPanel && $0.isVisible }), let screen = menu.screen else { return }
        current = record.id
        let thumbnail = record.thumbnailPath.flatMap { NSImage(contentsOfFile: $0) }
        let aspect = thumbnail.map { $0.size.width / max($0.size.height, 1) } ?? 16 / 10
        // Other files only have their small thumbnail, so their preview stays small and sharp.
        let maxSide: CGFloat = Self.imageTypes.contains(record.url.pathExtension.lowercased()) ? 640 : 320

        // Left of the menu; to the right if the menu sits at the left edge of the screen.
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        let spaceLeft = menu.frame.minX - visible.minX - gap - 8
        let spaceRight = visible.maxX - menu.frame.maxX - gap - 8
        let onLeft = spaceLeft >= 240 || spaceLeft >= spaceRight
        var width = min(maxSide, onLeft ? spaceLeft : spaceRight)
        var height = width / aspect
        let maxHeight = min(maxSide * 0.75, visible.height - 16)
        if height > maxHeight {
            height = maxHeight
            width = height * aspect
        }
        let x = onLeft ? menu.frame.minX - gap - width : menu.frame.maxX + gap
        let y = min(max(anchorY - height / 2, visible.minY + 8), visible.maxY - height - 8)

        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: UploadPreviewView(record: record, placeholder: thumbnail) { [weak self] in
            await self?.image(for: record)
        }
        .environment(\.colorScheme, .dark))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
        self.panel = panel
    }

    /// Hides the preview; with an id only if it still shows that upload (hover events can arrive out of order).
    func hide(_ id: UUID? = nil) {
        guard id == nil || id == current else { return }
        current = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    /// The uploaded image in full resolution; nil for other file types or when it cannot be loaded.
    private func image(for record: UploadRecord) async -> NSImage? {
        guard Self.imageTypes.contains(record.url.pathExtension.lowercased()) else { return nil }
        if let cached = cache.object(forKey: record.url as NSURL) { return cached }
        guard let (data, response) = try? await URLSession.shared.data(from: record.url),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: record.url as NSURL)
        return image
    }
}

private struct UploadPreviewView: View {
    let record: UploadRecord
    let placeholder: NSImage?
    let load: () async -> NSImage?
    @State private var image: NSImage?
    @State private var loading = true

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.background
            if let shown = image ?? placeholder {
                Image(nsImage: shown).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc").font(.system(size: 40)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15)))
        .task {
            image = await load()
            loading = false
        }
    }

    private var caption: String {
        guard let rep = image?.representations.first, rep.pixelsWide > 0 else { return record.displayName }
        return "\(record.displayName) · \(rep.pixelsWide) × \(rep.pixelsHigh)"
    }
}
