import AVFoundation

/// Wraps AVAssetWriter. All methods except `init` must run on `captureQueue`.
/// Pausing shifts later timestamps back by the paused time.
final class RecordingWriter {
    enum Track: Hashable { case video, system, microphone }

    struct VideoFormat {
        var width: Int
        var height: Int
        var fps: Int
    }

    let url: URL
    private let writer: AVAssetWriter
    private var inputs: [Track: AVAssetWriterInput] = [:]
    private let hasVideo: Bool

    private var sessionStarted = false
    private var sessionStart = CMTime.invalid
    private var lastEnd = CMTime.invalid
    private var lastPTS: [Track: CMTime] = [:]
    private var paused = false
    private var pauseBegan = CMTime.invalid
    private var offset = CMTime.zero
    private var lastVideoFrame: CMSampleBuffer?
    private(set) var failed = false
    /// Appended sample buffers per track (diagnostics for the self test).
    private(set) var appendedCounts: [Track: Int] = [:]

    init(url: URL, fileType: AVFileType, video: VideoFormat?, audioTracks: [Track]) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true
        hasVideo = video != nil

        if let video {
            // H.264 High, CABAC, no frame reordering, keyframe every 2 s.
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: video.width,
                AVVideoHeightKey: video.height,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAverageBitRateKey: videoBitrate(width: video.width, height: video.height, fps: video.fps),
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: video.fps,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            inputs[.video] = input
        }
        for track in audioTracks {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            inputs[track] = input
        }
        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed }
    }

    static let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]

    func pause(at hostTime: CMTime) {
        guard !paused else { return }
        paused = true
        pauseBegan = hostTime
    }

    func resume(at hostTime: CMTime) {
        guard paused else { return }
        paused = false
        if pauseBegan.isValid { offset = offset + (hostTime - pauseBegan) }
    }

    func append(_ sampleBuffer: CMSampleBuffer, to track: Track) {
        guard !failed, !paused, let input = inputs[track] else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        if !sessionStarted {
            // With video the file starts at the first frame; earlier audio is dropped.
            if hasVideo && track != .video { return }
            writer.startSession(atSourceTime: pts - offset)
            sessionStart = pts - offset
            sessionStarted = true
        }

        let adjusted = pts - offset
        if adjusted < sessionStart { return }
        if let last = lastPTS[track], adjusted <= last { return }
        guard input.isReadyForMoreMediaData else { return }
        guard let retimed = retime(sampleBuffer, by: offset) else { return }
        if input.append(retimed) {
            if track == .video { lastVideoFrame = sampleBuffer }
            appendedCounts[track, default: 0] += 1
            lastPTS[track] = adjusted
            let end = adjusted + CMSampleBufferGetDuration(sampleBuffer)
            if !lastEnd.isValid || end > lastEnd { lastEnd = end.isValid ? end : adjusted }
        } else if writer.status == .failed {
            failed = true
            NSLog("Record Everything: writer failed: \(String(describing: writer.error))")
        }
    }

    /// Recorded length in seconds.
    var duration: Double {
        guard sessionStarted, lastEnd.isValid else { return 0 }
        return (lastEnd - sessionStart).seconds
    }

    /// Repeats the last frame at the stop time. ScreenCaptureKit sends no frames for a static screen,
    /// so without this the video track would end at the last change instead of at the stop.
    private func holdLastFrame(until hostTime: CMTime) {
        guard let frame = lastVideoFrame, let input = inputs[.video], let last = lastPTS[.video] else { return }
        let end = (paused && pauseBegan.isValid ? pauseBegan : hostTime) - offset
        guard end > last + CMTime(value: 1, timescale: 30), input.isReadyForMoreMediaData else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: end, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: frame, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        if let copy, input.append(copy) {
            lastPTS[.video] = end
            if !lastEnd.isValid || end > lastEnd { lastEnd = end }
        }
    }

    /// Finishes the file. Returns false (and deletes the file) when nothing usable was written.
    func finish(at hostTime: CMTime, minimumDuration: Double, completion: @escaping (Bool) -> Void) {
        if sessionStarted, !failed, hasVideo { holdLastFrame(until: hostTime) }
        guard sessionStarted, !failed, duration >= minimumDuration else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(false)
            return
        }
        for input in inputs.values { input.markAsFinished() }
        writer.endSession(atSourceTime: lastEnd)
        writer.finishWriting { [writer, url] in
            let ok = writer.status == .completed
            if !ok {
                NSLog("Record Everything: finishing failed: \(String(describing: writer.error))")
                try? FileManager.default.removeItem(at: url)
            }
            completion(ok)
        }
    }

    private func retime(_ sb: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        if offset == .zero { return sb }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid { timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset }
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
