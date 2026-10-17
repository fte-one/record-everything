import AVFoundation
import AppKit
import ScreenCaptureKit
import SwiftUI

/// Headless check of the recording engine:
///   open "Record Everything.app" --args -RecordEverythingSelfTest screen|audio|pause -RecordEverythingSelfTestOutput /path/result.json
/// Records a few seconds, writes the file's metadata as JSON and quits.
@MainActor
enum SelfTest {
    static var mode: String? { UserDefaults.standard.string(forKey: "RecordEverythingSelfTest") }

    static func run() {
        guard let mode else { return }
        let output = UserDefaults.standard.string(forKey: "RecordEverythingSelfTestOutput") ?? NSTemporaryDirectory() + "recordeverything-selftest.json"
        Task {
            var result: [String: Any] = ["mode": mode]
            if ["upload", "screenshot", "annotate", "popover", "settings"].contains(mode) {
                await runExtra(mode, into: &result)
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: output))
                }
                if !["annotate", "popover", "settings"].contains(mode) { NSApp.terminate(nil) }
                return
            }
            do {
                let recorder = Recorder.shared
                var options = CaptureOptions()
                options.resolution = .p1080
                options.fps = .fps30
                options.systemAudio = true
                options.microphone = UserDefaults.standard.bool(forKey: "RecordEverythingSelfTestMic")
                switch mode {
                case "audio":
                    try await recorder.startAudio(options: options)
                default:
                    let screen = NSScreen.main!
                    let rect = mode == "region"
                        ? CGRect(x: 100, y: 100, width: 800, height: 450)
                        : CGRect(origin: .zero, size: screen.frame.size)
                    try await recorder.startScreen(target: ScreenTarget(displayID: screen.displayID, rect: rect, backingScale: screen.backingScaleFactor),
                                                   options: options, keepWindows: [])
                }
                // Make some system sound so the audio track has content.
                NSSound(named: "Glass")?.play()
                try await Task.sleep(for: .seconds(2))
                if mode == "pause" {
                    recorder.togglePause()
                    try await Task.sleep(for: .seconds(2))
                    recorder.togglePause()
                }
                NSSound(named: "Ping")?.play()
                try await Task.sleep(for: .seconds(2))
                guard let item = await recorder.stop() else { throw RecorderError.writerFailed }
                result["path"] = item.path
                result["samples"] = recorder.lastTrackCounts
                let asset = AVURLAsset(url: item.url)
                result["duration"] = try await asset.load(.duration).seconds
                var tracks: [[String: Any]] = []
                for t in try await asset.load(.tracks) {
                    var d: [String: Any] = ["type": t.mediaType.rawValue]
                    if t.mediaType == .video {
                        let size = try await t.load(.naturalSize)
                        d["width"] = size.width
                        d["height"] = size.height
                        d["fps"] = try await t.load(.nominalFrameRate)
                        d["bitrate"] = try await t.load(.estimatedDataRate)
                    } else {
                        d["bitrate"] = try await t.load(.estimatedDataRate)
                    }
                    if let fd = try await t.load(.formatDescriptions).first {
                        d["codec"] = fourCC(CMFormatDescriptionGetMediaSubType(fd))
                    }
                    d["timeRange"] = try await t.load(.timeRange).duration.seconds
                    tracks.append(d)
                }
                result["tracks"] = tracks
                result["ok"] = true
            } catch {
                result["ok"] = false
                result["error"] = "\(error)"
            }
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: output))
            }
            NSApp.terminate(nil)
        }
    }

    /// upload: test image -> S3 endpoint from the arguments; screenshot: capture an area; annotate: open the editor.
    private static func runExtra(_ mode: String, into result: inout [String: Any]) async {
        let d = UserDefaults.standard
        let image = testImage()
        if let endpoint = d.string(forKey: "RecordEverythingTestEndpoint") {
            var s = UploadSettings()
            s.customEndpoint = endpoint
            s.bucket = d.string(forKey: "RecordEverythingTestBucket") ?? "test-bucket"
            s.publicBaseURL = d.string(forKey: "RecordEverythingTestPublic") ?? "http://127.0.0.1/share/"
            s.playSound = false
            UploadManager.shared.testOverride = (s, d.string(forKey: "RecordEverythingTestAccessKey") ?? "",
                                                 d.string(forKey: "RecordEverythingTestSecret") ?? "")
        }
        switch mode {
        case "upload":
            do {
                result["testConnection"] = try await UploadManager.shared.testConnection().absoluteString
            } catch {
                result["testConnectionError"] = "\(error)"
            }
            // The test must not leave anything behind in the user's clipboard or upload history.
            let savedClipboard = NSPasteboard.general.string(forType: .string)
            let file = try? Screenshots.writePNG(image)
            if let file, let url = await UploadManager.shared.upload(fileURL: file, thumbnail: NSImage(cgImage: image, size: .zero)) {
                result["url"] = url.absoluteString
                result["clipboard"] = NSPasteboard.general.string(forType: .string) ?? ""
                result["historyFirst"] = UploadHistory.shared.records.first?.url.absoluteString ?? ""
                result["ok"] = true
                if let record = UploadHistory.shared.records.first, record.url == url { UploadHistory.shared.remove(record) }
            } else {
                result["ok"] = false
            }
            if let file { try? FileManager.default.removeItem(at: file) }
            NSPasteboard.general.clearContents()
            if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
            try? await Task.sleep(for: .seconds(1))
        case "screenshot":
            let screen = NSScreen.main!
            do {
                let shot = try await Screenshots.capture(ScreenTarget(displayID: screen.displayID, rect: CGRect(x: 40, y: 60, width: 400, height: 300),
                                                                      backingScale: screen.backingScaleFactor))
                result["width"] = shot.width
                result["height"] = shot.height
                result["ok"] = true
            } catch {
                result["ok"] = false
                result["error"] = "\(error)"
            }
        case "settings":
            AppController.shared.showSettings(tab: .upload)
            result["ok"] = true
        case "popover":
            try? await Task.sleep(for: .seconds(1.5))
            AppController.shared.togglePopover(sticky: true)
            try? await Task.sleep(for: .seconds(2))
            if let number = AppController.shared.popoverWindowNumber,
               let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let window = content.windows.first(where: { Int($0.windowID) == number }),
               let cg = try? await Screenshots.captureWindow(window),
               let png = Screenshots.pngData(cg) {
                let out = (UserDefaults.standard.string(forKey: "RecordEverythingSelfTestOutput") ?? NSTemporaryDirectory() + "x") + ".png"
                try? png.write(to: URL(fileURLWithPath: out))
                result["image"] = out
            }
            result["ok"] = true
        default:
            AnnotationEditor.open(image: image)
            result["ok"] = true
        }
    }

    /// A 1200 × 800 test picture with some shapes and text.
    private static func testImage() -> CGImage {
        let w = 1200, h = 800
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor(srgbRed: 0.13, green: 0.75, blue: 0.48, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 80, y: 480, width: 420, height: 220))
        ctx.setFillColor(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: 640, y: 160, width: 380, height: 380))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        ("Record Everything – Test" as NSString).draw(at: CGPoint(x: 80, y: 120), withAttributes: [
            .font: NSFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: NSColor.darkGray])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}
