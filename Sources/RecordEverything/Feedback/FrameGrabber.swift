import AppKit
import CoreImage
import ScreenCaptureKit

/// Streams one window at a few frames per second and keeps the newest frame for stills. Each frame also yields a
/// tiny grey thumbnail ("signature") so the session can tell when the content changed and settled again.
final class FrameGrabber: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "recordeverything.feedback.frames")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestSignature: [UInt8] = []
    /// Counts complete frames: the stream only delivers one when the window drew something new.
    private var frameNumber = 0

    /// A frame as an image, with its number and signature.
    struct Still {
        let image: CGImage
        let frame: Int
        let signature: [UInt8]
    }
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var configuration = SCStreamConfiguration()

    /// Called on the capture queue with each new frame's signature.
    var onFrame: (([UInt8]) -> Void)?
    /// Called when the stream stops on its own (window closed, permission withdrawn).
    var onStop: ((Error?) -> Void)?

    static let signatureWidth = 32, signatureHeight = 20

    func start(window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(2, Int(window.frame.width * scale))
        config.height = max(2, Int(window.frame.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 4)
        config.queueDepth = 5
        config.showsCursor = false   // clicks are drawn as markers instead
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false
        configuration = config
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Follows a resized window (size in points).
    func resize(to size: CGSize, scale: CGFloat) {
        guard let stream else { return }
        let config = configuration
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        configuration = config
        stream.updateConfiguration(config) { _ in }
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        lock.withLock { latest = nil }
    }

    /// The newest frame as an image.
    func snapshot() -> Still? {
        guard let (buffer, frame, signature) = lock.withLock({ latest.map { ($0, frameNumber, latestSignature) } }) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return Still(image: cg, frame: frame, signature: signature)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: statusRaw) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        let sig = signature(of: buffer)
        lock.withLock {
            latest = buffer
            latestSignature = sig
            frameNumber += 1
        }
        onFrame?(sig)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    private func signature(of buffer: CVPixelBuffer) -> [UInt8] {
        let image = CIImage(cvPixelBuffer: buffer)
        let w = Self.signatureWidth, h = Self.signatureHeight
        let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / image.extent.width,
                                                            y: CGFloat(h) / image.extent.height))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        context.render(scaled, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8, colorSpace: nil)
        var grey = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            grey[i] = UInt8((Int(rgba[i * 4]) * 3 + Int(rgba[i * 4 + 1]) * 6 + Int(rgba[i * 4 + 2])) / 10)
        }
        return grey
    }

    /// Mean absolute difference of two signatures, 0…255.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }
}
