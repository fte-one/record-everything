import AVFoundation
import AppKit

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

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}
