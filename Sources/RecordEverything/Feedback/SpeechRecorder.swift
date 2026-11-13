import AVFoundation
import Foundation

/// Records the microphone for a feedback session in pieces cut at speech pauses and transcribes each piece while
/// the session goes on, so a 10-minute session is transcribed by the time it ends.
@MainActor
final class SpeechRecorder {
    private(set) var parts: [FeedbackSpeech] = []
    private(set) var errors: [String] = []
    private(set) var pending = 0
    /// Newest text, for the session bar.
    var onText: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let folder: URL
    private let clock: () -> TimeInterval
    private var recorder: AVAudioRecorder?
    private var chunkURL: URL?
    private var chunkStart: TimeInterval = 0
    private var peak: Float = -160
    private var silenceSince: TimeInterval?
    private var meter: Timer?
    private var index = 0
    private var queue: [(url: URL, start: TimeInterval, end: TimeInterval)] = []
    private var working = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Below this level (dBFS) counts as a pause.
    private let silence: Float = -42
    private let minChunk: TimeInterval = 6
    private let maxChunk: TimeInterval = 40

    init(folder: URL, clock: @escaping () -> TimeInterval) {
        self.folder = folder
        self.clock = clock
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() {
        guard recorder == nil else { return }
        beginChunk()
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Ends the current piece (pause or end of session).
    func stop() {
        meter?.invalidate()
        meter = nil
        finishChunk()
        onLevel?(0)
    }

    /// Waits until every piece is transcribed, at most `limit` seconds; later results are left out.
    func finish(limit: TimeInterval = 120) async {
        stop()
        if pending == 0 { return }
        Task {
            try? await Task.sleep(for: .seconds(limit))
            if !waiters.isEmpty {
                errors.append(String(format: L("%d pieces of speech were still being transcribed."), pending))
                releaseWaiters()
            }
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseWaiters() {
        let done = waiters
        waiters = []
        done.forEach { $0.resume() }
    }

    /// Self-test: treats an audio file as if it had been said at `time`.
    func inject(_ file: URL, at time: TimeInterval, duration: TimeInterval) {
        enqueue(file, start: time, end: time + duration)
    }

    private func beginChunk() {
        index += 1
        let url = folder.appendingPathComponent(String(format: "speech-%03d.wav", index))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else { return }
        recorder.isMeteringEnabled = true
        guard recorder.record() else { return }
        self.recorder = recorder
        chunkURL = url
        chunkStart = clock()
        peak = -160
        silenceSince = nil
    }

    private func finishChunk() {
        guard let recorder, let url = chunkURL else { return }
        recorder.stop()
        self.recorder = nil
        chunkURL = nil
        let end = clock()
        if peak < silence || end - chunkStart < 0.5 {
            try? FileManager.default.removeItem(at: url)   // nothing said
        } else {
            enqueue(url, start: chunkStart, end: end)
        }
    }

    private var lastRetry = Date.distantPast

    private func tick() {
        guard let recorder else {
            // The microphone went away (unplugged, taken by another app): keep trying.
            if Date().timeIntervalSince(lastRetry) > 2 {
                lastRetry = Date()
                beginChunk()
            }
            return
        }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        peak = max(peak, power)
        onLevel?(max(0, min(1, (power + 50) / 50)))
        let now = clock()
        if power < silence {
            if silenceSince == nil { silenceSince = now }
        } else {
            silenceSince = nil
        }
        let length = now - chunkStart
        let pause = silenceSince.map { now - $0 } ?? 0
        // Cut at a pause once the piece is long enough; force a cut before the provider's time limit.
        if (length >= minChunk && pause >= 0.7) || length >= maxChunk {
            finishChunk()
            beginChunk()
        }
    }

    private func enqueue(_ url: URL, start: TimeInterval, end: TimeInterval) {
        queue.append((url, start, end))
        pending += 1
        guard !working else { return }
        working = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let item = queue.removeFirst()
            do {
                let text = try await OpenRouter.transcribe(fileURL: item.url).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    parts.append(FeedbackSpeech(start: item.start, end: item.end, text: text))
                    parts.sort { $0.start < $1.start }
                    onText?(text)
                }
            } catch {
                errors.append("\(feedbackClock(item.start)): \(error.localizedDescription)")
            }
            pending -= 1
        }
        working = false
        releaseWaiters()
    }
}
