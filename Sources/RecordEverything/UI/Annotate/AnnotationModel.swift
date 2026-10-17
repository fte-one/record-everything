import AppKit
import CoreImage
import SwiftUI

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, highlight, pen, text, pixelate, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .pixelate: return "checkerboard.rectangle"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .select: return L("Select and move")
        case .arrow: return L("Arrow")
        case .rectangle: return L("Rectangle")
        case .ellipse: return L("Ellipse")
        case .highlight: return L("Highlighter")
        case .pen: return L("Pen")
        case .text: return L("Text")
        case .pixelate: return L("Pixelate")
        case .crop: return L("Crop")
        }
    }

    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .highlight: return "h"
        case .pen: return "p"
        case .text: return "t"
        case .pixelate: return "x"
        case .crop: return "c"
        }
    }
}

/// One mark on the screenshot. Geometry is in image pixels, origin top left.
struct Annotation: Identifiable, Equatable {
    enum Kind: Equatable {
        case arrow(CGPoint, CGPoint)
        case rectangle(CGRect)
        case ellipse(CGRect)
        case highlight(CGRect)
        case pen([CGPoint])
        case text(CGPoint, String, CGFloat)
        case pixelate(CGRect)
    }

    var id = UUID()
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat

    var bounds: CGRect {
        switch kind {
        case .arrow(let a, let b): return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        case .rectangle(let r), .ellipse(let r), .highlight(let r), .pixelate(let r): return r
        case .pen(let points):
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        case .text(let p, let s, let size): return CGRect(origin: p, size: Annotation.textSize(s, size))
        }
    }

    func offset(_ dx: CGFloat, _ dy: CGFloat) -> Annotation {
        var copy = self
        func o(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        switch kind {
        case .arrow(let a, let b): copy.kind = .arrow(o(a), o(b))
        case .rectangle(let r): copy.kind = .rectangle(r.offsetBy(dx: dx, dy: dy))
        case .ellipse(let r): copy.kind = .ellipse(r.offsetBy(dx: dx, dy: dy))
        case .highlight(let r): copy.kind = .highlight(r.offsetBy(dx: dx, dy: dy))
        case .pixelate(let r): copy.kind = .pixelate(r.offsetBy(dx: dx, dy: dy))
        case .pen(let pts): copy.kind = .pen(pts.map(o))
        case .text(let p, let s, let size): copy.kind = .text(o(p), s, size)
        }
        return copy
    }

    static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .bold) }

    static func textSize(_ s: String, _ size: CGFloat) -> CGSize {
        let r = (s as NSString).boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin],
                                             attributes: [.font: font(size)])
        return CGSize(width: ceil(r.width) + 4, height: ceil(r.height) + 2)
    }
}

/// Editor state with undo history; also renders the final image.
@MainActor
final class AnnotationModel: ObservableObject {
    let image: CGImage
    /// Image pixels per point (2 on Retina).
    let scale: CGFloat

    @Published var annotations: [Annotation] = []
    @Published var cropRect: CGRect?
    @Published var selectedID: UUID?
    @Published var tool: AnnotationTool = .rectangle
    @Published var color: NSColor = AnnotationModel.palette[0]
    @Published var widthStep = 1

    private var undoStack: [([Annotation], CGRect?)] = []
    private var redoStack: [([Annotation], CGRect?)] = []
    private var pixelCache: [CGRect: CGImage] = [:]
    private let ciContext = CIContext()

    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.149, blue: 0.0, alpha: 1),     // #FF2600
        NSColor(srgbRed: 0.133, green: 0.753, blue: 0.478, alpha: 1), // brand green
        NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1),     // yellow
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1),     // blue
        .white, .black,
    ]
    static let widths: [CGFloat] = [2, 4, 8]

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    var imageSize: CGSize { CGSize(width: image.width, height: image.height) }
    var lineWidth: CGFloat { Self.widths[widthStep] * scale }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func commit(_ change: () -> Void) {
        undoStack.append((annotations, cropRect))
        redoStack.removeAll()
        change()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((annotations, cropRect))
        (annotations, cropRect) = last
        selectedID = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((annotations, cropRect))
        (annotations, cropRect) = next
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        commit { annotations.removeAll { $0.id == id } }
        selectedID = nil
    }

    /// Applies the current color to the selected annotation (when the user picks a color while one is selected).
    func recolorSelected() {
        guard let id = selectedID, let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        commit { annotations[i].color = color }
    }

    // MARK: Rendering

    /// Draws image and annotations into a y-down context in image pixel coordinates.
    func draw(in ctx: CGContext, selection: Bool) {
        drawImage(image, in: CGRect(origin: .zero, size: imageSize), ctx: ctx)
        for a in annotations { draw(a, in: ctx) }
        if selection, let id = selectedID, let a = annotations.first(where: { $0.id == id }) {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5 * scale)
            ctx.setLineDash(phase: 0, lengths: [4 * scale, 3 * scale])
            ctx.stroke(a.bounds.insetBy(dx: -6 * scale, dy: -6 * scale))
            ctx.restoreGState()
        }
    }

    func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(a.lineWidth)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        // A soft shadow keeps marks readable on any background.
        ctx.setShadow(offset: CGSize(width: 0, height: 1 * scale), blur: 3 * scale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        switch a.kind {
        case .arrow(let from, let to):
            let angle = atan2(to.y - from.y, to.x - from.x)
            let head = max(a.lineWidth * 4, 12 * scale)
            let base = CGPoint(x: to.x - cos(angle) * head * 0.8, y: to.y - sin(angle) * head * 0.8)
            ctx.move(to: from)
            ctx.addLine(to: base)
            ctx.strokePath()
            ctx.move(to: to)
            ctx.addLine(to: CGPoint(x: to.x - cos(angle - .pi / 7) * head, y: to.y - sin(angle - .pi / 7) * head))
            ctx.addLine(to: CGPoint(x: to.x - cos(angle + .pi / 7) * head, y: to.y - sin(angle + .pi / 7) * head))
            ctx.closePath()
            ctx.fillPath()
        case .rectangle(let r):
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2 * scale, cornerHeight: 2 * scale, transform: nil))
            ctx.strokePath()
        case .ellipse(let r):
            ctx.strokeEllipse(in: r)
        case .highlight(let r):
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(a.color.withAlphaComponent(0.45).cgColor)
            ctx.fill(r)
        case .pen(let points):
            guard let first = points.first else { return }
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .text(let p, let s, let size):
            let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 3 * scale
            shadow.shadowOffset = NSSize(width: 0, height: -1 * scale)
            (s as NSString).draw(at: CGPoint(x: p.x + 2, y: p.y), withAttributes: [
                .font: Annotation.font(size), .foregroundColor: a.color, .shadow: shadow,
            ])
            NSGraphicsContext.restoreGraphicsState()
        case .pixelate(let r):
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            if let patch = pixelated(r) { drawImage(patch, in: r, ctx: ctx) }
        }
    }

    private func pixelated(_ rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard r.width >= 2, r.height >= 2 else { return nil }
        if let cached = pixelCache[r] { return cached }
        // Core Image uses a bottom-left origin.
        let ciRect = CGRect(x: r.minX, y: imageSize.height - r.maxY, width: r.width, height: r.height)
        let block = max(10 * scale, min(r.width, r.height) / 12)
        let output = CIImage(cgImage: image).cropped(to: ciRect).clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: ciRect.minX, y: ciRect.minY)])
            .cropped(to: ciRect)
        let result = ciContext.createCGImage(output, from: ciRect)
        pixelCache[r] = result
        return result
    }

    private func drawImage(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// The final image: annotations burned in, cropped if a crop is set.
    func render() -> CGImage? {
        let crop = (cropRect ?? CGRect(origin: .zero, size: imageSize)).integral.intersection(CGRect(origin: .zero, size: imageSize))
        guard crop.width >= 1, crop.height >= 1,
              let ctx = CGContext(data: nil, width: Int(crop.width), height: Int(crop.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: crop.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)
        draw(in: ctx, selection: false)
        return ctx.makeImage()
    }
}
