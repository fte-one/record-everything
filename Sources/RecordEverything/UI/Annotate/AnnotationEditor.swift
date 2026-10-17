import AppKit
import Combine
import SwiftUI

/// Opens screenshots for annotation; "Upload" and "Copy" close the window.
@MainActor
enum AnnotationEditor {
    static func open(image: CGImage) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let scale = screen.backingScaleFactor
        let model = AnnotationModel(image: image, scale: scale)
        let id = "annotate-\(UUID().uuidString)"
        let points = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let maxSize = CGSize(width: screen.visibleFrame.width * 0.85, height: screen.visibleFrame.height * 0.85 - 70)
        let fit = min(1, maxSize.width / points.width, maxSize.height / points.height)
        // Wide enough for the whole toolbar including the labelled Copy and Upload buttons.
        let size = NSSize(width: max(960, points.width * fit + 32), height: max(460, points.height * fit + 32 + 64))
        WindowManager.shared.show(id: id, title: L("Edit screenshot"),
                                  style: .init(size: size, minSize: NSSize(width: 960, height: 460), resizable: true)) {
            AnnotationEditorView(model: model) { WindowManager.shared.close(id) }
        }
    }
}

struct AnnotationEditorView: View {
    @ObservedObject var model: AnnotationModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.top, 30)
                .padding(.bottom, 8)
                .background(Theme.panel)
            AnnotationCanvas(model: model)
                .background(Color.black.opacity(0.35))
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button { model.tool = tool; if tool != .select { model.selectedID = nil } } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6).fill(model.tool == tool ? Theme.accent.opacity(0.85) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(tool.key.uppercased()))")
                    .accessibilityLabel(tool.title)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))

            HStack(spacing: 5) {
                ForEach(AnnotationModel.palette.indices, id: \.self) { i in
                    let c = AnnotationModel.palette[i]
                    Button {
                        model.color = c
                        model.recolorSelected()
                    } label: {
                        Circle().fill(Color(nsColor: c)).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.white, lineWidth: model.color == c ? 2.5 : 0.5))
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Color"))
                }
            }

            HStack(spacing: 2) {
                ForEach(AnnotationModel.widths.indices, id: \.self) { i in
                    Button { model.widthStep = i } label: {
                        RoundedRectangle(cornerRadius: 2).fill(Color.white)
                            .frame(width: 16, height: [2, 4, 7][i])
                            .frame(width: 28, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(model.widthStep == i ? Color.white.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Line width"))
                }
            }

            IconButton(symbol: "arrow.uturn.backward", size: 28, help: L("Undo"), active: model.canUndo) { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            IconButton(symbol: "arrow.uturn.forward", size: 28, help: L("Redo"), active: model.canRedo) { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)

            Spacer(minLength: 8)

            IconButton(symbol: "square.and.arrow.down", size: 28, help: L("Save as…")) { saveAs() }
            Button { copyAndClose() } label: { Label(L("Copy"), systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .controlSize(.large)
                .help(L("Copy the image to the clipboard and close"))
            Button { uploadAndClose() } label: { Label(L("Upload"), systemImage: "icloud.and.arrow.up") }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help(L("Upload, copy the link and close"))
        }
    }

    private func copyAndClose() {
        guard let image = model.render() else { return }
        Screenshots.copy(image)
        Toast.shared.show(L("Image copied"), symbol: "doc.on.clipboard.fill", style: .success, duration: 1.8)
        close()
    }

    private func uploadAndClose() {
        guard let image = model.render(), let file = try? Screenshots.writePNG(image) else { return }
        close()
        Task { await UploadManager.shared.upload(fileURL: file, thumbnail: NSImage(cgImage: image, size: .zero)) }
    }

    private func saveAs() {
        guard let image = model.render(), let data = Screenshots.pngData(image) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot \(MediaLibrary.defaultTitle(for: Date()).replacingOccurrences(of: ":", with: ".")).png"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
    }
}

/// Hosts the AppKit drawing surface.
private struct AnnotationCanvas: NSViewRepresentable {
    @ObservedObject var model: AnnotationModel

    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ view: CanvasView, context: Context) { view.needsDisplay = true }
}

/// Drawing surface: maps view points to image pixels and turns drags into annotations.
final class CanvasView: NSView, NSTextFieldDelegate {
    private let model: AnnotationModel
    private var cancellables: Set<AnyCancellable> = []
    private var draft: Annotation?
    private var draftCrop: CGRect?
    private var dragStart: CGPoint?
    private var moving: (id: UUID, last: CGPoint, original: [Annotation])?
    private var textField: NSTextField?
    private var textOrigin: CGPoint?

    init(model: AnnotationModel) {
        self.model = model
        super.init(frame: .zero)
        model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.needsDisplay = true } }.store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

    // MARK: Geometry

    private var imageRect: CGRect {
        let size = model.imageSize
        let area = bounds.insetBy(dx: 16, dy: 16)
        // Fit into the area, never larger than the screenshot's own point size.
        let fit = min(area.width / size.width, area.height / size.height, 1 / model.scale)
        let w = size.width * fit, h = size.height * fit
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    private var viewScale: CGFloat { imageRect.width / model.imageSize.width }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: (p.x - r.minX) / viewScale, y: (p.y - r.minY) / viewScale)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let r = imageRect
        return CGPoint(x: r.minX + p.x * viewScale, y: r.minY + p.y * viewScale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = imageRect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(r)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: viewScale, y: viewScale)
        ctx.interpolationQuality = .high
        model.draw(in: ctx, selection: true)
        if let draft { model.draw(draft, in: ctx) }
        if let crop = draftCrop ?? model.cropRect {
            let dim = CGMutablePath()
            dim.addRect(CGRect(origin: .zero, size: model.imageSize))
            dim.addRect(crop)
            ctx.addPath(dim)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5 / viewScale)
            ctx.setLineDash(phase: 0, lengths: [6 / viewScale, 4 / viewScale])
            ctx.stroke(crop)
        }
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        commitText()
        window?.makeFirstResponder(self)
        let p = toImage(location)
        dragStart = p
        switch model.tool {
        case .select:
            if let hit = model.annotations.last(where: { $0.bounds.insetBy(dx: -8 * model.scale, dy: -8 * model.scale).contains(p) }) {
                model.selectedID = hit.id
                moving = (hit.id, p, model.annotations)
            } else {
                model.selectedID = nil
            }
        case .text:
            if imageRect.contains(location) { beginText(at: p) }
        case .pen:
            draft = Annotation(kind: .pen([p]), color: model.color, lineWidth: model.lineWidth)
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = toImage(convert(event.locationInWindow, from: nil))
        let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        let color = model.color, width = model.lineWidth
        switch model.tool {
        case .select:
            guard let m = moving, let i = model.annotations.firstIndex(where: { $0.id == m.id }) else { return }
            model.annotations[i] = model.annotations[i].offset(p.x - m.last.x, p.y - m.last.y)
            moving?.last = p
        case .arrow: draft = Annotation(kind: .arrow(start, p), color: color, lineWidth: width)
        case .rectangle: draft = Annotation(kind: .rectangle(rect), color: color, lineWidth: width)
        case .ellipse: draft = Annotation(kind: .ellipse(rect), color: color, lineWidth: width)
        case .highlight: draft = Annotation(kind: .highlight(rect), color: color, lineWidth: width)
        case .pixelate: draft = Annotation(kind: .pixelate(rect), color: color, lineWidth: width)
        case .pen:
            if case .pen(var pts) = draft?.kind { pts.append(p); draft?.kind = .pen(pts) }
        case .crop: draftCrop = rect
        case .text: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; draft = nil; draftCrop = nil; needsDisplay = true }
        if let m = moving {
            moving = nil
            let moved = model.annotations
            if moved != m.original {
                model.annotations = m.original
                model.commit { model.annotations = moved }
            }
            return
        }
        if let crop = draftCrop, crop.width > 4, crop.height > 4 {
            model.commit { model.cropRect = crop }
            return
        }
        guard let draft else { return }
        let b = draft.bounds
        if case .pen(let pts) = draft.kind, pts.count < 2 { return }
        if case .pen = draft.kind {} else if max(b.width, b.height) < 4 { return }
        model.commit { model.annotations.append(draft) }
    }

    override func keyDown(with event: NSEvent) {
        if textField != nil { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case 51, 117: model.deleteSelected()           // Delete, forward delete
        case 53: model.selectedID = nil                 // Escape
        default:
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let ch = event.charactersIgnoringModifiers?.lowercased(),
               let tool = AnnotationTool.allCases.first(where: { $0.key == ch }) {
                model.tool = tool
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Text

    private var fontSizePixels: CGFloat { (14 + CGFloat(model.widthStep) * 6) * model.scale }

    private func beginText(at p: CGPoint) {
        textOrigin = p
        let field = NSTextField(frame: .zero)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        field.focusRingType = .none
        field.textColor = model.color
        field.font = Annotation.font(fontSizePixels * viewScale)
        field.placeholderString = L("Text")
        field.delegate = self
        let v = toView(p)
        field.frame = CGRect(x: v.x, y: v.y, width: 240, height: fontSizePixels * viewScale * 1.4)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            textField?.stringValue = ""
            commitText()
            return true
        }
        return false
    }

    private func commitText() {
        guard let field = textField, let origin = textOrigin else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !text.isEmpty else { return }
        let annotation = Annotation(kind: .text(origin, text, fontSizePixels), color: model.color, lineWidth: model.lineWidth)
        model.commit { model.annotations.append(annotation) }
    }
}
