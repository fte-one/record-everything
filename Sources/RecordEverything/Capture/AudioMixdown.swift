import AVFoundation

/// Renders the final audio of a recording once it has stopped. System audio and microphone are recorded
/// into separate tracks; this mixes them into one AAC track and copies the video untouched.
///
/// The voice gets priority. Mac microphones deliver speech far below a comfortable listening level
/// (around -45 dBFS without processing), so the voice is measured over the whole recording and brought
/// up to a clear speaking level (about -19 LUFS). A low cut removes rumble, background noise between
/// sentences is lowered gently, a limiter catches the peaks, and system audio steps back while someone
/// speaks.
enum AudioMixdown {
    struct Result {
        /// Average level of the speech passages before processing (dBFS), nil without speech or microphone.
        var speechLevel: Float?
        /// Level of the quietest passages (room noise) before processing (dBFS).
        var noiseFloor: Float?
        var gainDB: Float = 0
    }

    static let sampleRate = 48_000
    /// Speech passages are brought to this average RMS level; the recording then plays at about -19 LUFS.
    static let targetSpeechLevel: Float = -20
    static let maxGainDB: Float = 30
    /// Peak ceiling of the limiter (-1 dBFS).
    static let ceiling: Float = 0.89
    /// System audio under a voice (-2 dB), and while someone speaks (about -10 dB).
    static let systemLevel: Float = 0.8
    static let systemDuckedLevel: Float = 0.3

    /// `tracks` lists the writer's audio tracks in creation order with the number of samples each received.
    @discardableResult
    static func finish(url: URL, fileType: AVFileType, tracks: [(RecordingWriter.Track, Int)]) async throws -> Result {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return Result() }

        // An empty track may or may not have been written, so match against both layouts.
        let all = tracks.map(\.0)
        let nonEmpty = tracks.filter { $0.1 > 0 }.map(\.0)
        let kinds = audioTracks.count == all.count ? all : audioTracks.count == nonEmpty.count ? nonEmpty : nil
        var microphone: AVAssetTrack?
        var system: [AVAssetTrack] = []
        for (index, track) in audioTracks.enumerated() {
            if kinds?[index] == .microphone { microphone = track } else { system.append(track) }
        }
        guard microphone != nil || system.count > 1 else { return Result() }

        var result = Result()
        if let microphone {
            (result.speechLevel, result.noiseFloor) = try await measure(microphone, in: asset)
            if let level = result.speechLevel {
                result.gainDB = min(max(targetSpeechLevel - level, 0), maxGainDB)
            }
        }
        // Speaking means clearly above the amplified room noise.
        let threshold = min(max((result.noiseFloor ?? -90) + result.gainDB + 15, -45), -24)
        let renderer = try VoiceMixRenderer(asset: asset, microphone: microphone, system: system,
                                            gain: pow(10, result.gainDB / 20), speakingThreshold: pow(10, threshold / 20))
        try await render(asset: asset, to: url, fileType: fileType, renderer: renderer)
        return result
    }

    /// Speech level and noise floor of the microphone in dBFS, from 50 ms blocks: the noise floor is the
    /// 10th percentile, speech the blocks clearly above it, averaged with a relative gate like a loudness meter.
    private static func measure(_ track: AVAssetTrack, in asset: AVAsset) async throws -> (speech: Float?, noise: Float?) {
        let source = try PCMSource(asset: asset, tracks: [track], channels: 1)
        var lowCut = Biquad.highPass(80)
        let blockSize = sampleRate / 20
        var blocks: [Float] = []
        var sum: Float = 0
        var count = 0
        while let samples = source.nextBuffer() {
            for raw in samples.data {
                let s = lowCut.process(raw)
                sum += s * s
                count += 1
                if count == blockSize {
                    blocks.append(10 * log10(sum / Float(count) + 1e-12))
                    sum = 0
                    count = 0
                }
            }
        }
        try source.check()
        let sorted = blocks.sorted()
        guard sorted.count >= 10 else { return (nil, nil) }
        let noiseFloor = sorted[sorted.count / 10]
        let active = sorted.filter { $0 > max(noiseFloor + 10, -75) }
        guard active.count >= 6 else { return (nil, noiseFloor) }
        let mean = powerMean(active)
        return (powerMean(active.filter { $0 > mean - 10 }), noiseFloor)
    }

    private static func powerMean(_ levels: [Float]) -> Float {
        10 * log10(levels.reduce(0) { $0 + pow(10, $1 / 10) } / Float(max(levels.count, 1)))
    }

    private static func render(asset: AVAsset, to url: URL, fileType: AVFileType, renderer: VoiceMixRenderer) async throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)").appendingPathExtension(url.pathExtension)
        let writer = try AVAssetWriter(outputURL: tmp, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingWriter.aacSettings)
        writer.add(audioInput)
        var jobs: [(AVAssetWriterInput, () -> CMSampleBuffer?)] = [(audioInput, renderer.nextBuffer)]

        var videoReader: AVAssetReader?
        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            reader.add(output)
            let hint = try await videoTrack.load(.formatDescriptions).first
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            writer.add(videoInput)
            guard reader.startReading() else { throw reader.error ?? RecorderError.writerFailed }
            jobs.append((videoInput, { output.copyNextSampleBuffer() }))
            videoReader = reader
        }

        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (index, (input, next)) in jobs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "recordeverything.mixdown.\(index)")
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                if let sb = next() {
                                    input.append(sb)
                                } else {
                                    input.markAsFinished()
                                    cont.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }

        await writer.finishWriting()
        let readerFailed = videoReader.map { $0.status != .completed } ?? false
        guard writer.status == .completed, !readerFailed, renderer.error == nil else {
            try? FileManager.default.removeItem(at: tmp)
            throw renderer.error ?? writer.error ?? videoReader?.error ?? RecorderError.writerFailed
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}

/// Mixes voice and system audio chunk by chunk: low cut and gain for the voice, gentle noise reduction
/// between sentences, ducking of system audio while someone speaks, and a peak limiter on the sum.
private final class VoiceMixRenderer {
    private let microphone: PCMSource?
    private let system: PCMSource?
    private let gain: Float
    private let speakingThreshold: Float
    private var lowCut = Biquad.highPass(80)
    private let format: CMAudioFormatDescription
    private(set) var error: Error?

    private let chunk = 4_800
    private var position = 0
    private var micBuffer: [Float]
    private var systemBuffer: [Float]
    private var output: [Float]

    private var voiceEnvelope: Float = 0
    private var voiceOpen: Float = 1
    private var duck: Float
    private var limiterGain: Float = 1
    private let baseSystemLevel: Float
    private let voiceAttack = coefficient(0.005)
    private let voiceRelease = coefficient(0.3)
    private let duckDown = coefficient(0.05)
    private let duckUp = coefficient(0.6)
    private let openUp = coefficient(0.01)
    private let closeDown = coefficient(0.25)
    private let limiterRelease = coefficient(0.1)
    /// Between sentences the voice track (room noise) is lowered by 6 dB.
    private let pauseLevel: Float = 0.5

    init(asset: AVAsset, microphone: AVAssetTrack?, system: [AVAssetTrack], gain: Float, speakingThreshold: Float) throws {
        self.microphone = try microphone.map { try PCMSource(asset: asset, tracks: [$0], channels: 1) }
        self.system = system.isEmpty ? nil : try PCMSource(asset: asset, tracks: system, channels: 2)
        self.gain = gain
        self.speakingThreshold = speakingThreshold
        baseSystemLevel = microphone == nil ? 1 : AudioMixdown.systemLevel
        duck = baseSystemLevel
        micBuffer = [Float](repeating: 0, count: chunk)
        systemBuffer = [Float](repeating: 0, count: chunk * 2)
        output = [Float](repeating: 0, count: chunk * 2)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(AudioMixdown.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        guard let description else { throw RecorderError.writerFailed }
        format = description
    }

    private static func coefficient(_ seconds: Float) -> Float {
        1 - exp(-1 / (seconds * Float(AudioMixdown.sampleRate)))
    }

    /// The next rendered chunk, nil when both sources are exhausted.
    func nextBuffer() -> CMSampleBuffer? {
        guard error == nil else { return nil }
        microphone?.read(start: position, frames: chunk, into: &micBuffer)
        system?.read(start: position, frames: chunk, into: &systemBuffer)
        do {
            try microphone?.check()
            try system?.check()
        } catch {
            self.error = error
            return nil
        }
        let end = max(microphone?.endFrame ?? 0, system?.endFrame ?? 0)
        let frames = min(chunk, end - position)
        guard frames > 0 else { return nil }

        let hasMic = microphone != nil
        for i in 0..<frames {
            var voice: Float = 0
            if hasMic {
                voice = lowCut.process(micBuffer[i]) * gain
                let level = abs(voice)
                voiceEnvelope += (level - voiceEnvelope) * (level > voiceEnvelope ? voiceAttack : voiceRelease)
                let speaking = voiceEnvelope > speakingThreshold
                let open: Float = speaking ? 1 : pauseLevel
                voiceOpen += (open - voiceOpen) * (open > voiceOpen ? openUp : closeDown)
                voice *= voiceOpen
                let target = speaking ? AudioMixdown.systemDuckedLevel : baseSystemLevel
                duck += (target - duck) * (target < duck ? duckDown : duckUp)
            }
            let left = voice + systemBuffer[2 * i] * duck
            let right = voice + systemBuffer[2 * i + 1] * duck
            let peak = max(abs(left), abs(right))
            let needed = peak > AudioMixdown.ceiling ? AudioMixdown.ceiling / peak : 1
            limiterGain = needed < limiterGain ? needed : limiterGain + (1 - limiterGain) * limiterRelease
            output[2 * i] = left * limiterGain
            output[2 * i + 1] = right * limiterGain
        }
        let pts = CMTime(value: CMTimeValue(position), timescale: CMTimeScale(AudioMixdown.sampleRate))
        position += frames
        return makeBuffer(frames: frames, pts: pts)
    }

    private func makeBuffer(frames: Int, pts: CMTime) -> CMSampleBuffer? {
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = output.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == noErr else { return nil }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames, presentationTimeStamp: pts,
                                                             packetDescriptions: nil, sampleBufferOut: &buffer)
        return buffer
    }
}

/// Decoded 48 kHz float PCM of one or more audio tracks, addressed by frame position on the recording's
/// timeline. Gaps (e.g. a muted microphone) read as silence.
private final class PCMSource {
    struct Samples {
        var data: [Float]
        var start: Int
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private let channels: Int
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var started = false
    private(set) var finished = false

    init(asset: AVAsset, tracks: [AVAssetTrack], channels: Int) throws {
        self.channels = channels
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioMixdown.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.writerFailed }
    }

    /// Frame position after the last decoded sample.
    var endFrame: Int { bufferStart + buffer.count / channels }

    func check() throws {
        if finished, reader.status == .failed { throw reader.error ?? RecorderError.writerFailed }
    }

    /// Next decoded buffer in reading order (sequential use, e.g. for measuring).
    func nextBuffer() -> Samples? {
        guard let sb = output.copyNextSampleBuffer() else {
            finished = true
            return nil
        }
        return Samples(data: Self.floats(of: sb), start: Self.frame(of: sb) ?? endFrame)
    }

    /// Fills `out` with `frames` frames starting at `start` (interleaved), silence where there is no audio.
    func read(start: Int, frames: Int, into out: inout [Float]) {
        while !finished && endFrame < start + frames { pull() }
        for i in 0..<(frames * channels) { out[i] = 0 }
        let from = max(start, bufferStart)
        let to = min(start + frames, endFrame)
        if to > from {
            for frame in from..<to {
                for c in 0..<channels {
                    out[(frame - start) * channels + c] = buffer[(frame - bufferStart) * channels + c]
                }
            }
        }
        // Drop what has been rendered.
        let consumed = min(start + frames, endFrame) - bufferStart
        if consumed > 0 {
            buffer.removeFirst(consumed * channels)
            bufferStart += consumed
        }
    }

    private func pull() {
        guard let samples = nextBuffer() else { return }
        var data = samples.data
        if !started {
            started = true
            bufferStart = samples.start
            buffer = data
            return
        }
        let end = endFrame
        if samples.start > end {
            buffer.append(contentsOf: [Float](repeating: 0, count: (samples.start - end) * channels))
        } else if samples.start < end {
            let overlap = min((end - samples.start) * channels, data.count)
            data.removeFirst(overlap)
        }
        buffer.append(contentsOf: data)
    }

    private static func frame(of sb: CMSampleBuffer) -> Int? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return nil }
        return Int((pts.seconds * Double(AudioMixdown.sampleRate)).rounded())
    }

    private static func floats(of sb: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: length / 4)
        data.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        return data
    }
}

/// Second-order filter (RBJ cookbook), transposed direct form II.
private struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    /// Butterworth high-pass.
    static func highPass(_ frequency: Float) -> Biquad {
        let w0 = 2 * Float.pi * frequency / Float(AudioMixdown.sampleRate)
        let alpha = sin(w0) / (2 * 0.7071)
        let c = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
