import AVFoundation
import ScreenCaptureKit

/// ScreenCaptureKit stream for screen video and/or system audio.
final class ScreenStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let wantsVideo: Bool
    private let wantsAudio: Bool
    private var lastLevelUpdate = Date.distantPast

    /// Called on the capture queue.
    var onVideo: ((CMSampleBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Called on the main actor when the system stops the stream.
    var onError: ((Error) -> Void)?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, video: Bool, audio: Bool) {
        wantsVideo = video
        wantsAudio = audio
        super.init()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // A screen output is always attached; without one ScreenCaptureKit logs every dropped frame.
        try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        if audio { try? stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue) }
        self.stream = stream
    }

    func start() async throws {
        try await stream?.startCapture()
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard wantsVideo, Self.isCompleteFrame(sampleBuffer) else { return }
            onVideo?(sampleBuffer)
        case .audio:
            onAudio?(sampleBuffer)
            let now = Date()
            if now.timeIntervalSince(lastLevelUpdate) > 0.05 {
                lastLevelUpdate = now
                let level = audioLevel(of: sampleBuffer)
                Task { @MainActor in AudioLevels.shared.system = level }
            }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.onError?(error) }
    }

    /// Idle frames (no change on screen) carry no new image and must not be written.
    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    static func baseConfiguration() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.sampleRate = 48_000
        c.channelCount = 2
        c.excludesCurrentProcessAudio = true
        c.queueDepth = 6
        return c
    }

    /// Stream that only delivers system audio (camera and audio recordings).
    static func systemAudioOnly() async throws -> ScreenStream {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let c = baseConfiguration()
        c.capturesAudio = true
        c.width = 2
        c.height = 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        c.showsCursor = false
        return ScreenStream(filter: filter, configuration: c, video: false, audio: true)
    }
}
