import CoreGraphics
import Foundation

/// Aspect ratio presets of the setting bar.
enum AspectPreset: Int, CaseIterable, Codable, Identifiable {
    case r3x4, r4x3, r9x16, r16x9, fullScreen, custom

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .r3x4: return "3:4"
        case .r4x3: return "4:3"
        case .r9x16: return "9:16"
        case .r16x9: return "16:9"
        case .fullScreen: return L("Full Screen")
        case .custom: return L("Custom")
        }
    }

    /// Width divided by height, nil when the user may pick any shape.
    var ratio: CGFloat? {
        switch self {
        case .r3x4: return 3.0 / 4.0
        case .r4x3: return 4.0 / 3.0
        case .r9x16: return 9.0 / 16.0
        case .r16x9: return 16.0 / 9.0
        case .fullScreen, .custom: return nil
        }
    }
}

/// Output resolution presets. The value is the maximum output height in pixels.
enum ResolutionPreset: Int, CaseIterable, Codable, Identifiable {
    case p720, p1080, k2, k4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .p720: return "720P"
        case .p1080: return "1080P"
        case .k2: return "2K"
        case .k4: return "4K"
        }
    }

    var maxHeight: Int {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        case .k2: return 1440
        case .k4: return 2160
        }
    }

    /// Display order in the menu: largest first.
    static var menuOrder: [ResolutionPreset] { [.k4, .k2, .p1080, .p720] }
}

enum FPSPreset: Int, CaseIterable, Codable, Identifiable {
    case fps15 = 15, fps24 = 24, fps30 = 30, fps60 = 60

    var id: Int { rawValue }
    var title: String { "\(rawValue) FPS" }

    static var menuOrder: [FPSPreset] { [.fps60, .fps30, .fps24, .fps15] }
}

/// Everything the user can switch in the setting bar, camera window and audio window.
struct CaptureOptions: Codable, Equatable {
    var aspect: AspectPreset = .custom
    var resolution: ResolutionPreset = .p1080
    var fps: FPSPreset = .fps30
    var showCursor = true
    var camera = false
    var cameraID: String?
    var systemAudio = true
    var microphone = true
    var microphoneID: String?
}

enum MediaKind: String, Codable {
    case screen, camera, audio

    var fileExtension: String { self == .audio ? "m4a" : "mp4" }

    var fileLabel: String {
        switch self {
        case .screen: return L("Screen")
        case .camera: return L("Camera")
        case .audio: return L("Audio")
        }
    }
}

/// Bitrate formula: width × height × fps × 0.08, clamped to 64 kbit/s … 120 Mbit/s.
func videoBitrate(width: Int, height: Int, fps: Int) -> Int {
    let raw = Double(width) * Double(height) * Double(fps) * 0.08
    return min(max(Int(raw), 64_000), 120_000_000)
}

/// Output pixel size for a capture area: native pixels, scaled down to the resolution preset's height, even dimensions.
func outputSize(points: CGSize, backingScale: CGFloat, preset: ResolutionPreset) -> (width: Int, height: Int) {
    var w = points.width * backingScale
    var h = points.height * backingScale
    let maxH = CGFloat(preset.maxHeight)
    let shortSide = min(w, h)
    if shortSide > maxH {
        let f = maxH / shortSide
        w *= f
        h *= f
    }
    func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) & ~1) }
    return (even(w), even(h))
}
