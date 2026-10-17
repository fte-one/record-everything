import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The two screenshot actions of the menu bar: capture and upload, capture and annotate.
@MainActor
enum Screenshots {
    static var cacheFolder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Record Everything", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Area or window -> upload -> link on the clipboard.
    static func captureAndUpload() {
        select { image in
            guard let file = try? writePNG(image) else { return }
            Task { await UploadManager.shared.upload(fileURL: file, thumbnail: NSImage(cgImage: image, size: .zero)) }
        }
    }

    /// Area or window -> annotation editor (upload or copy from there).
    static func captureAndAnnotate() {
        select { image in AnnotationEditor.open(image: image) }
    }

    private static func select(then handle: @escaping (CGImage) -> Void) {
        guard !SelectionOverlay.shared.isActive, !Countdown.shared.isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            AppController.shared.showPermissionWindow()
            return
        }
        SelectionOverlay.shared.begin(mode: .screenshot, onConfirm: { target, _ in
            Task {
                do {
                    handle(try await capture(target))
                } catch {
                    Toast.shared.show(L("Screenshot failed") + ": " + error.localizedDescription,
                                      symbol: "xmark.octagon.fill", style: .error, duration: 5)
                }
            }
        }, onCancel: {})
    }

    /// Captures a window on its own, or an area of a display, at full pixel resolution without the pointer.
    static func capture(_ target: ScreenTarget) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        let filter: SCContentFilter
        if let id = target.windowID, let window = content.windows.first(where: { $0.windowID == id }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
        } else {
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else { throw RecorderError.noDisplay }
            let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            config.sourceRect = target.rect
            config.width = Int(target.rect.width * scale)
            config.height = Int(target.rect.height * scale)
        }
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Writes a PNG into the cache folder and returns its URL.
    static func writePNG(_ image: CGImage) throws -> URL {
        guard let data = pngData(image) else { throw RecorderError.writerFailed }
        let folder = cacheFolder.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Screenshot \(MediaLibrary.defaultTitle(for: Date()).replacingOccurrences(of: ":", with: ".")).png")
        try data.write(to: url)
        return url
    }

    /// Puts the image on the clipboard as PNG and TIFF.
    static func copy(_ image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let ns = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        pb.writeObjects([ns])
        if let png = pngData(image) { pb.setData(png, forType: .png) }
    }
}
