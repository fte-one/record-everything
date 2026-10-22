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
            if ["upload", "files", "drop", "drophint", "screenshot", "annotate", "popover", "settings", "menubaricon", "voicemix", "preview"].contains(mode) {
                await runExtra(mode, into: &result)
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: output))
                }
                if !["annotate", "popover", "settings", "preview"].contains(mode) { NSApp.terminate(nil) }
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
        case "menubaricon":
            try? await Task.sleep(for: .seconds(1.5))
            var files: [String] = []
            let base = UserDefaults.standard.string(forKey: "RecordEverythingSelfTestOutput") ?? NSTemporaryDirectory() + "x"
            for (name, image, title) in [("idle", MenuBarIcon.idle, ""), ("upload", MenuBarIcon.upload, ""),
                                         ("recording", MenuBarIcon.recording, " 00:01:23"), ("paused", MenuBarIcon.paused, " 00:01:23")] {
                AppController.shared.previewStatusIcon(image, title: title)
                try? await Task.sleep(for: .milliseconds(600))
                guard let frame = AppController.shared.statusItemFrame,
                      let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }),
                      let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                      let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
                // The menu bar around the icon, including neighbours for comparison.
                let local = screen.localRect(fromGlobal: frame.insetBy(dx: -90, dy: 0))
                let config = SCStreamConfiguration()
                let filter = SCContentFilter(display: display, excludingWindows: [])
                config.sourceRect = local
                config.width = Int(local.width * CGFloat(filter.pointPixelScale))
                config.height = Int(local.height * CGFloat(filter.pointPixelScale))
                config.showsCursor = false
                if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
                   let png = Screenshots.pngData(cg) {
                    let out = base + "-\(name).png"
                    try? png.write(to: URL(fileURLWithPath: out))
                    files.append(out)
                }
            }
            AppController.shared.previewStatusIcon(MenuBarIcon.idle, title: "")
            result["images"] = files
            result["ok"] = !files.isEmpty
        case "settings":
            // -RecordEverythingSelfTestTab general|upload|shortcuts; the window is captured next to the JSON.
            let tab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "RecordEverythingSelfTestTab") ?? "") ?? .upload
            AppController.shared.showSettings(tab: tab)
            try? await Task.sleep(for: .seconds(1.5))
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == L("Settings") }),
               let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let scWindow = content.windows.first(where: { Int($0.windowID) == window.windowNumber }),
               let cg = try? await Screenshots.captureWindow(scWindow), let png = Screenshots.pngData(cg) {
                let out = (UserDefaults.standard.string(forKey: "RecordEverythingSelfTestOutput") ?? NSTemporaryDirectory() + "x") + ".png"
                try? png.write(to: URL(fileURLWithPath: out))
                result["image"] = out
            }
            result["ok"] = true
        case "voicemix":
            // Runs the final audio rendering on a copy of -RecordEverythingSelfTestInput; the audio tracks are
            // described by -RecordEverythingSelfTestTracks, e.g. "system,microphone".
            let input = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "RecordEverythingSelfTestInput") ?? "")
            let copy = URL(fileURLWithPath: (UserDefaults.standard.string(forKey: "RecordEverythingSelfTestOutput") ?? NSTemporaryDirectory() + "x")
                           + "." + input.pathExtension)
            try? FileManager.default.removeItem(at: copy)
            let kinds = (UserDefaults.standard.string(forKey: "RecordEverythingSelfTestTracks") ?? "microphone").split(separator: ",")
            let tracks: [(RecordingWriter.Track, Int)] = kinds.map { ($0 == "system" ? .system : .microphone, 1) }
            do {
                try FileManager.default.copyItem(at: input, to: copy)
                let started = Date()
                let mix = try await AudioMixdown.finish(url: copy, fileType: input.pathExtension == "m4a" ? .m4a : .mp4, tracks: tracks)
                result["seconds"] = Date().timeIntervalSince(started)
                result["speechLevel"] = mix.speechLevel.map { Double($0) } ?? NSNull()
                result["noiseFloor"] = mix.noiseFloor.map { Double($0) } ?? NSNull()
                result["gainDB"] = Double(mix.gainDB)
                result["path"] = copy.path
                result["ok"] = true
            } catch {
                result["error"] = "\(error)"
                result["ok"] = false
            }
        case "preview":
            // Opens the menu, shows the preview of the newest upload and captures menu and preview together.
            try? await Task.sleep(for: .seconds(1.5))
            AppController.shared.togglePopover(sticky: true)
            try? await Task.sleep(for: .seconds(1))
            if let record = UploadHistory.shared.records.first,
               let menu = NSApp.windows.first(where: { $0 is MenuPanel && $0.isVisible }) {
                UploadPreview.shared.show(record, anchorY: menu.frame.minY + menu.frame.height * 0.35)
                try? await Task.sleep(for: .seconds(3))
                if let preview = UploadPreview.shared.frame, let previewNumber = UploadPreview.shared.windowNumber {
                    result["image"] = await composite([(menu.windowNumber, menu.frame), (previewNumber, preview)])
                }
                result["record"] = record.fileName
            }
            result["ok"] = true
        case "files":
            // A text file with umlauts, a folder (goes up as ZIP) and a 3 MB file (progress), then the same file again,
            // cancelled right away. Clipboard and upload history stay as they were.
            let savedClipboard = NSPasteboard.general.string(forType: .string)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecordEverythingFiles-\(UUID().uuidString.prefix(6))")
            let folder = dir.appendingPathComponent("Ordner Test")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let text = dir.appendingPathComponent("Grüße & Test.txt")
            let big = dir.appendingPathComponent("Groß.bin")
            try? Data("Hällo Wörld\n".utf8).write(to: text)
            try? Data("eins".utf8).write(to: folder.appendingPathComponent("eins.txt"))
            try? Data("zwei".utf8).write(to: folder.appendingPathComponent("zwei.txt"))
            try? Data(count: 3_000_000).write(to: big)
            let before = Set(UploadHistory.shared.records.map(\.id))
            let anchor = AppController.shared.statusItemFrame
            let links = await FileSharing.uploadNow([text, folder, big], anchor: anchor)
            result["links"] = links.map(\.absoluteString)
            result["clipboard"] = NSPasteboard.general.string(forType: .string) ?? ""
            let added = UploadHistory.shared.records.filter { !before.contains($0.id) }
            result["history"] = added.map(\.displayName)
            result["thumbnails"] = added.map { $0.thumbnailPath != nil }
            let cancelled = Task { await FileSharing.uploadNow([big], anchor: anchor) }
            cancelled.cancel()
            result["cancelledLinks"] = await cancelled.value.count
            result["ok"] = links.count == 3
            UploadHistory.shared.records.filter { !before.contains($0.id) }.forEach { UploadHistory.shared.remove($0) }
            try? FileManager.default.removeItem(at: dir)
            NSPasteboard.general.clearContents()
            if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
            try? await Task.sleep(for: .seconds(1))
        case "drop":
            // A file and a folder dropped twice: on the menu bar icon (delivered to the status item's window the way
            // AppKit does it) and on the drop zone below it. Clipboard and upload history stay as they were.
            try? await Task.sleep(for: .seconds(1.5))
            let savedClipboard = NSPasteboard.general.string(forType: .string)
            let before = Set(UploadHistory.shared.records.map(\.id))
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RecordEverythingDrop-\(UUID().uuidString.prefix(6))")
            let folder = dir.appendingPathComponent("Ordner Projekt")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("Angebot Müller.pdf")
            try? Data("%PDF-1.4\n".utf8).write(to: file)
            try? Data("Notiz".utf8).write(to: folder.appendingPathComponent("notiz.txt"))
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("RecordEverythingSelfTestDrag"))
            pasteboard.clearContents()
            pasteboard.writeObjects([file as NSURL, folder as NSURL])
            let drag = TestDrag(pasteboard: pasteboard)
            guard let window = NSApp.windows.first(where: { $0.className.contains("StatusBarWindow") }),
                  let icon = AppController.shared.statusItemFrame, let area = DropZone.shared.activationArea else {
                result["ok"] = false
                result["error"] = "no status item window"
                break
            }
            result["areaBelowIcon"] = area.contains(CGPoint(x: icon.midX + 100, y: icon.minY - 120))
            result["areaFarBelow"] = area.contains(CGPoint(x: icon.midX, y: icon.minY - 400))

            // 1. Onto the icon: the zone opens in its release state, the icon lights up.
            typealias Entered = @convention(c) (AnyObject, Selector, NSDraggingInfo) -> UInt
            typealias Exited = @convention(c) (AnyObject, Selector, NSDraggingInfo?) -> Void
            typealias Perform = @convention(c) (AnyObject, Selector, NSDraggingInfo) -> Bool
            let enteredSel = #selector(NSDraggingDestination.draggingEntered(_:))
            let exitedSel = #selector(NSDraggingDestination.draggingExited(_:))
            let performSel = #selector(NSDraggingDestination.performDragOperation(_:))
            let iconOperation = unsafeBitCast(window.method(for: enteredSel), to: Entered.self)(window, enteredSel, drag)
            func button(in view: NSView?) -> NSButton? {
                guard let view else { return nil }
                return view as? NSButton ?? view.subviews.lazy.compactMap { button(in: $0) }.first
            }
            result["iconEntered"] = iconOperation == NSDragOperation.copy.rawValue
            result["iconHover"] = button(in: window.contentView)?.image === MenuBarIcon.upload
            result["zoneOpenedFromIcon"] = DropZone.shared.isShown && DropZone.shared.isTargeted
            // Moving down off the icon keeps the zone open, no longer in its release state.
            unsafeBitCast(window.method(for: exitedSel), to: Exited.self)(window, exitedSel, drag)
            result["zoneStaysAfterIcon"] = DropZone.shared.isShown && !DropZone.shared.isTargeted

            // 2. Onto the zone.
            let host = DropZone.shared.window?.contentView as? DropZoneHost
            result["zoneEntered"] = host?.draggingEntered(drag) == .copy && DropZone.shared.isTargeted
            let zoneAccepted = host?.performDragOperation(drag) == true
            result["zoneAccepted"] = zoneAccepted
            result["zoneClosed"] = !DropZone.shared.isShown

            // 3. Straight onto the icon again.
            _ = unsafeBitCast(window.method(for: enteredSel), to: Entered.self)(window, enteredSel, drag)
            let iconAccepted = unsafeBitCast(window.method(for: performSel), to: Perform.self)(window, performSel, drag)
            result["iconAccepted"] = iconAccepted

            // Both drops upload the file and the folder (as ZIP).
            for _ in 0..<40 where UploadHistory.shared.records.filter({ !before.contains($0.id) }).count < 4 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            let added = UploadHistory.shared.records.filter { !before.contains($0.id) }
            result["history"] = added.map(\.displayName)
            result["clipboard"] = NSPasteboard.general.string(forType: .string) ?? ""
            result["ok"] = iconOperation == NSDragOperation.copy.rawValue && zoneAccepted && iconAccepted && added.count == 4
            added.forEach { UploadHistory.shared.remove($0) }
            try? FileManager.default.removeItem(at: dir)
            pasteboard.releaseGlobally()
            NSPasteboard.general.clearContents()
            if let savedClipboard { NSPasteboard.general.setString(savedClipboard, forType: .string) }
            try? await Task.sleep(for: .seconds(1))
        case "drophint":
            // The drop zone (waiting and in its release state) and the upload notice with progress and cancel button.
            // Drawn by the windows themselves, so no screen recording permission is needed.
            try? await Task.sleep(for: .seconds(1.5))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Vertrag Müller.pdf")
            try? Data(count: 2_400_000).write(to: file)
            var images: [String] = []
            AppController.shared.previewDrop([file])
            DropZone.shared.untarget()
            try? await Task.sleep(for: .seconds(0.4))
            if let window = DropZone.shared.window, let image = render(window, suffix: "-zone") { images.append(image) }
            DropZone.shared.target([file])
            try? await Task.sleep(for: .seconds(0.4))
            if let window = DropZone.shared.window, let image = render(window, suffix: "-zone-release") { images.append(image) }
            AppController.shared.previewDrop(nil)
            Toast.shared.show(L("Uploading…"), detail: file.lastPathComponent, symbol: "arrow.up.circle", style: .progress, duration: nil,
                              anchor: AppController.shared.statusItemFrame, action: Toast.Action(title: L("Cancel")) {})
            Toast.shared.updateProgress(0.4)
            try? await Task.sleep(for: .seconds(0.5))
            if let window = NSApp.windows.first(where: { $0.windowNumber == Toast.shared.windowNumber }),
               let image = render(window, suffix: "-progress") { images.append(image) }
            Toast.shared.hide()
            try? FileManager.default.removeItem(at: file)
            result["images"] = images
            result["ok"] = images.count == 3
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
            } else if let menu = NSApp.windows.first(where: { $0 is MenuPanel && $0.isVisible }) {
                // Without screen capture (e.g. no permission) the menu draws itself.
                result["image"] = render(menu, suffix: "")
            }
            result["ok"] = true
        default:
            AnnotationEditor.open(image: image)
            result["ok"] = true
        }
    }

    /// Lets a window draw its content into a PNG (no screen capture involved); returns the PNG's path.
    private static func render(_ window: NSWindow, suffix: String) -> String? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = (UserDefaults.standard.string(forKey: "RecordEverythingSelfTestOutput") ?? NSTemporaryDirectory() + "x") + suffix + ".png"
        return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))) != nil ? out : nil
    }

    /// Captures windows separately and places them on one picture as they sit on screen; returns the PNG's path.
    private static func composite(_ windows: [(number: Int, frame: CGRect)]) async -> String? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let first = windows.first else { return nil }
        let union = windows.dropFirst().reduce(first.frame) { $0.union($1.frame) }.insetBy(dx: -20, dy: -20)
        let scale = NSScreen.screens.first { $0.frame.intersects(first.frame) }?.backingScaleFactor ?? 2
        guard let ctx = CGContext(data: nil, width: Int(union.width * scale), height: Int(union.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor(white: 0.35, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        for (number, frame) in windows {
            guard let window = content.windows.first(where: { Int($0.windowID) == number }),
                  let cg = try? await Screenshots.captureWindow(window) else { continue }
            ctx.draw(cg, in: CGRect(x: (frame.minX - union.minX) * scale, y: (frame.minY - union.minY) * scale,
                                    width: frame.width * scale, height: frame.height * scale))
        }
        guard let cg = ctx.makeImage(), let png = Screenshots.pngData(cg) else { return nil }
        let out = (UserDefaults.standard.string(forKey: "RecordEverythingSelfTestOutput") ?? NSTemporaryDirectory() + "x") + ".png"
        try? png.write(to: URL(fileURLWithPath: out))
        return out
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

/// Minimal drag for the "drop" mode: only the pasteboard matters to the drop target.
private final class TestDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 2
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
