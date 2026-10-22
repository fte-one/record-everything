import AppKit

/// Menu bar icon in the style of the app icon: four selection corners around a record dot.
enum MenuBarIcon {
    private static let size = NSSize(width: 20, height: 16)

    /// Template image; macOS tints it for light and dark menu bars.
    static let idle: NSImage = {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, frameColor: .black, dotColor: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Record Everything"
        return image
    }()

    /// While a file is dragged onto the icon and while uploads run: an arrow instead of the record dot.
    static let upload: NSImage = {
        let image = NSImage(size: size, flipped: false) { rect in
            drawCorners(in: rect, color: .black)
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let arrow = NSBezierPath()
            arrow.lineWidth = 1.6
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: CGPoint(x: c.x, y: c.y - 3.8))
            arrow.line(to: CGPoint(x: c.x, y: c.y + 3.6))
            arrow.move(to: CGPoint(x: c.x - 3, y: c.y + 0.6))
            arrow.line(to: CGPoint(x: c.x, y: c.y + 3.6))
            arrow.line(to: CGPoint(x: c.x + 3, y: c.y + 0.6))
            NSColor.black.setStroke()
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L("Upload File…")
        return image
    }()

    static let recording = makeRecording(paused: false)
    static let paused = makeRecording(paused: true)

    /// While recording the dot turns red (orange when paused); the corners follow the menu bar's text color.
    private static func makeRecording(paused: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, frameColor: .labelColor, dotColor: paused ? .systemOrange : .systemRed)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = L("Stop Recording")
        return image
    }

    private static func draw(in rect: NSRect, frameColor: NSColor, dotColor: NSColor) {
        drawCorners(in: rect, color: frameColor)

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 3.6, y: center.y - 3.6, width: 7.2, height: 7.2))
        ring.lineWidth = 1.3
        dotColor.setStroke()
        ring.stroke()
        dotColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: center.x - 1.8, y: center.y - 1.8, width: 3.6, height: 3.6)).fill()
    }

    private static func drawCorners(in rect: NSRect, color: NSColor) {
        let frame = rect.insetBy(dx: 1.2, dy: 1.2)
        let arm: CGFloat = 4.2
        let corners = NSBezierPath()
        corners.lineWidth = 1.7
        corners.lineCapStyle = .round
        corners.lineJoinStyle = .round
        for (p, dx, dy) in [(CGPoint(x: frame.minX, y: frame.maxY), 1.0, -1.0), (CGPoint(x: frame.maxX, y: frame.maxY), -1.0, -1.0),
                            (CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1.0, 1.0)] {
            corners.move(to: CGPoint(x: p.x + dx * arm, y: p.y))
            corners.line(to: p)
            corners.line(to: CGPoint(x: p.x, y: p.y + dy * arm))
        }
        color.setStroke()
        corners.stroke()
    }
}
