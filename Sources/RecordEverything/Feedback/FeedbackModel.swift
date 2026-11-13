import AppKit
import CoreGraphics

/// One still of the recorded window, taken at a click, a selection, the "Mark" button or when the page changed.
struct FeedbackShot: Identifiable, Equatable {
    enum Kind: String { case start, click, selection, mark, change, hover }
    /// Where something happened, in image pixels (origin top left).
    enum Marker: Equatable {
        case click(CGPoint)
        case selection(CGRect)
        /// Where the pointer rested while the user was talking ("this here").
        case pointer(CGPoint)
    }

    let id: Int
    let time: TimeInterval
    let kind: Kind
    /// The image file; several shots can share one when the screen did not change in between.
    let file: URL
    let pixelSize: CGSize
    var marker: Marker?
    var url: String?
    var title: String?
    var selectedText: String?

    /// "K7": how the AI refers to this shot.
    var key: String { "K\(id)" }
}

/// A piece of what was said, with its place on the session clock.
struct FeedbackSpeech: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// The page shown in the window from `time` on.
struct FeedbackPage: Equatable {
    let time: TimeInterval
    let url: String?
    let title: String
}

/// How the screenshots reach the coding agent.
enum FeedbackImageMode: String, Codable, CaseIterable, Identifiable {
    /// Pasted into the input field as images: the model sees them wherever the agent runs (also over SSH).
    case attachments
    /// Only the file paths in the prompt: the agent reads them itself (same Mac only).
    case paths

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attachments: return L("Paste as images (works over SSH too)")
        case .paths: return L("File paths (agent on this Mac only)")
        }
    }

    /// Most images one message takes (Claude: 20 attachments).
    static let attachmentLimit = 20
}

/// Everything a finished session hands to the composer.
struct FeedbackRecording {
    var startDate: Date
    var duration: TimeInterval
    var appName: String
    var windowTitle: String
    var shots: [FeedbackShot]
    var pages: [FeedbackPage]
    var speech: [FeedbackSpeech]
    /// Pieces of speech that could not be transcribed (with the reason).
    var speechErrors: [String]
}

func feedbackClock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}

enum WindowGeometry {
    /// Height of the primary display: the flip between CoreGraphics (top left) and AppKit (bottom left) coordinates.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// CoreGraphics global rect (top-left origin) → AppKit global rect.
    static func appKitRect(_ cg: CGRect) -> CGRect {
        CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    /// AppKit global point (NSEvent.mouseLocation) → CoreGraphics global point.
    static func cgPoint(_ appKit: CGPoint) -> CGPoint {
        CGPoint(x: appKit.x, y: primaryHeight - appKit.y)
    }

    /// The on-screen bounds of a window (CoreGraphics coordinates), nil once it is gone.
    static func bounds(of windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first, let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    /// The frontmost normal window of an app (CoreGraphics lists windows front to back).
    static func frontWindow(of pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid && (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict),
                  rect.width > 120, rect.height > 80 else { continue }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }

    static func owner(of windowID: CGWindowID) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] else { return nil }
        return list.first?[kCGWindowOwnerPID as String] as? pid_t
    }
}

/// PNG and JPEG encoding that can run off the main thread.
enum ImageFiles {
    static func png(_ image: CGImage) -> Data? {
        encode(image, type: "public.png", properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
    }

    static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        encode(image, type: "public.jpeg", properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ image: CGImage, type: String, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
