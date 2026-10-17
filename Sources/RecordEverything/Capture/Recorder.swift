import AVFoundation
import AppKit
import IOKit.pwr_mgt
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case noDisplay, writerFailed, busy, noCamera, permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: return L("No display found.")
        case .writerFailed: return L("The recording file cannot be written.")
        case .busy: return L("A recording is already running.")
        case .noCamera: return L("No webcam found, please check your device!")
        case .permissionDenied: return L("Record Everything has no permission to record the screen.")
        }
    }
}

/// The area to record: a display and a rectangle in that display's points (top-left origin).
struct ScreenTarget {
    var displayID: CGDirectDisplayID
    var rect: CGRect
    var backingScale: CGFloat
}

/// Orchestrates one recording session for screen, camera or audio.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    enum State: Equatable { case idle, recording, paused, finishing }

    @Published private(set) var state: State = .idle
    @Published private(set) var kind: MediaKind?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micEnabled = false

    private var writer: RecordingWriter?
    private var stream: ScreenStream?
    private var usesCamera = false
    private var usesMic = false
    private var startedAt = Date()
    private var pausedTotal: TimeInterval = 0
    private var pauseStart: Date?
    private var timer: Timer?
    private var sleepAssertion: IOPMAssertionID = 0
    private var micMuted = false
    /// Sample counts of the last finished recording, e.g. ["video": 120, "microphone": 400].
    private(set) var lastTrackCounts: [String: Int] = [:]

    /// Called after a recording was saved (nil when it was discarded).
    var onFinished: ((MediaItem?) -> Void)?
    /// Called when a recording stops because of an error.
    var onFailure: ((Error) -> Void)?

    var isActive: Bool { state != .idle }

    // MARK: Start

    func startScreen(target: ScreenTarget, options: CaptureOptions, keepWindows: [NSWindow]) async throws {
        guard state == .idle else { throw RecorderError.busy }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) ?? content.displays.first else {
            throw RecorderError.noDisplay
        }
        // All own windows stay out of the video except the webcam bubble.
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let keepIDs = Set(keepWindows.map { CGWindowID($0.windowNumber) })
        let keep = content.windows.filter { keepIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: keep)

        let size = outputSize(points: target.rect.size, backingScale: target.backingScale, preset: options.resolution)
        let config = ScreenStream.baseConfiguration()
        config.sourceRect = target.rect
        config.width = size.width
        config.height = size.height
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = options.showCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps.rawValue))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = options.systemAudio

        let url = MediaLibrary.newRecordingURL(kind: .screen, in: try AppSettings.shared.ensureSaveFolder())
        var tracks: [RecordingWriter.Track] = []
        if options.systemAudio { tracks.append(.system) }
        if options.microphone { tracks.append(.microphone) }
        let writer = try RecordingWriter(url: url, fileType: .mp4,
                                         video: .init(width: size.width, height: size.height, fps: options.fps.rawValue),
                                         audioTracks: tracks)
        let stream = ScreenStream(filter: filter, configuration: config, video: true, audio: options.systemAudio)
        stream.onVideo = { [weak writer] sb in writer?.append(sb, to: .video) }
        stream.onAudio = { [weak writer] sb in writer?.append(sb, to: .system) }
        try await begin(kind: .screen, writer: writer, stream: stream, options: options, camera: false)
    }

    func startCamera(options: CaptureOptions) async throws {
        guard state == .idle else { throw RecorderError.busy }
        guard await CameraManager.shared.start(deviceID: options.cameraID) else { throw RecorderError.noCamera }
        let dims = CameraManager.shared.dimensions ?? CMVideoDimensions(width: 1280, height: 720)
        let url = MediaLibrary.newRecordingURL(kind: .camera, in: try AppSettings.shared.ensureSaveFolder())
        var tracks: [RecordingWriter.Track] = []
        if options.systemAudio { tracks.append(.system) }
        if options.microphone { tracks.append(.microphone) }
        let writer: RecordingWriter
        do {
            writer = try RecordingWriter(url: url, fileType: .mp4,
                                         video: .init(width: Int(dims.width) & ~1, height: Int(dims.height) & ~1, fps: 30),
                                         audioTracks: tracks)
        } catch {
            CameraManager.shared.stop()
            throw error
        }
        var stream: ScreenStream?
        if options.systemAudio {
            stream = try await ScreenStream.systemAudioOnly()
            stream?.onAudio = { [weak writer] sb in writer?.append(sb, to: .system) }
        }
        captureQueue.sync { CameraManager.shared.onFrame = { [weak writer] sb in writer?.append(sb, to: .video) } }
        do {
            try await begin(kind: .camera, writer: writer, stream: stream, options: options, camera: true)
        } catch {
            captureQueue.sync { CameraManager.shared.onFrame = nil }
            CameraManager.shared.stop()
            throw error
        }
    }

    func startAudio(options: CaptureOptions) async throws {
        guard state == .idle else { throw RecorderError.busy }
        let url = MediaLibrary.newRecordingURL(kind: .audio, in: try AppSettings.shared.ensureSaveFolder())
        var tracks: [RecordingWriter.Track] = []
        if options.systemAudio { tracks.append(.system) }
        if options.microphone { tracks.append(.microphone) }
        if tracks.isEmpty { tracks = [.microphone] }
        let writer = try RecordingWriter(url: url, fileType: .m4a, video: nil, audioTracks: tracks)
        var stream: ScreenStream?
        if options.systemAudio {
            stream = try await ScreenStream.systemAudioOnly()
            stream?.onAudio = { [weak writer] sb in writer?.append(sb, to: .system) }
        }
        var opts = options
        if !options.systemAudio { opts.microphone = true }
        try await begin(kind: .audio, writer: writer, stream: stream, options: opts, camera: false)
    }

    private func begin(kind: MediaKind, writer: RecordingWriter, stream: ScreenStream?, options: CaptureOptions, camera: Bool) async throws {
        if options.microphone {
            MicrophoneMonitor.shared.start(deviceID: options.microphoneID)
            captureQueue.sync {
                MicrophoneMonitor.shared.onSample = { [weak self, weak writer] sb in
                    guard let self, !self.micMutedFlag else { return }
                    writer?.append(sb, to: .microphone)
                }
            }
        }
        stream?.onError = { [weak self] error in self?.streamFailed(error) }
        try await stream?.start()

        self.writer = writer
        self.stream = stream
        self.kind = kind
        usesCamera = camera
        usesMic = options.microphone
        micEnabled = options.microphone
        setMicMuted(false)
        startedAt = Date()
        pausedTotal = 0
        pauseStart = nil
        elapsed = 0
        state = .recording
        preventSleep(true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Control

    func togglePause() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        switch state {
        case .recording:
            pauseStart = Date()
            captureQueue.async { [writer] in writer?.pause(at: now) }
            state = .paused
        case .paused:
            if let p = pauseStart { pausedTotal += Date().timeIntervalSince(p) }
            pauseStart = nil
            captureQueue.async { [writer] in writer?.resume(at: now) }
            state = .recording
        default:
            break
        }
    }

    /// Mutes or unmutes the microphone during a recording (record bar mic button).
    func toggleMicrophone() {
        guard usesMic else { return }
        micEnabled.toggle()
        setMicMuted(!micEnabled)
    }

    private nonisolated(unsafe) var micMutedFlag = false
    private func setMicMuted(_ muted: Bool) {
        micMuted = muted
        captureQueue.async { [weak self] in self?.micMutedFlag = muted }
    }

    /// Stops and saves. Recordings shorter than one second are discarded.
    @discardableResult
    func stop() async -> MediaItem? {
        guard state == .recording || state == .paused, let writer, let kind else { return nil }
        state = .finishing
        timer?.invalidate()
        timer = nil
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())

        await stream?.stop()
        stream = nil
        captureQueue.sync {
            MicrophoneMonitor.shared.onSample = nil
            CameraManager.shared.onFrame = nil
        }
        if usesCamera { CameraManager.shared.stop() }

        let ok: Bool = await withCheckedContinuation { cont in
            captureQueue.async { writer.finish(at: stopTime, minimumDuration: 1.0) { cont.resume(returning: $0) } }
        }
        lastTrackCounts = await withCheckedContinuation { cont in
            captureQueue.async { cont.resume(returning: Dictionary(uniqueKeysWithValues: writer.appendedCounts.map { ("\($0.key)", $0.value) })) }
        }
        var item: MediaItem?
        if ok {
            do {
                try await AudioMixdown.mixIfNeeded(url: writer.url, fileType: kind == .audio ? .m4a : .mp4)
            } catch {
                NSLog("Record Everything: audio mixdown failed, keeping separate tracks: \(error)")
            }
            item = MediaLibrary.shared.add(url: writer.url, kind: kind, created: startedAt)
        }
        reset()
        onFinished?(item)
        return item
    }

    /// Stops without saving.
    func cancel() async {
        guard state == .recording || state == .paused, let writer else { return }
        state = .finishing
        await stream?.stop()
        captureQueue.sync {
            MicrophoneMonitor.shared.onSample = nil
            CameraManager.shared.onFrame = nil
        }
        if usesCamera { CameraManager.shared.stop() }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            captureQueue.async { writer.finish(at: .zero, minimumDuration: .infinity) { _ in cont.resume() } }
        }
        reset()
    }

    private func reset() {
        // The camera and audio windows keep metering after a recording; the screen flow does not.
        if kind == .screen { MicrophoneMonitor.shared.stop() }
        timer?.invalidate()
        timer = nil
        writer = nil
        stream = nil
        kind = nil
        usesCamera = false
        usesMic = false
        elapsed = 0
        preventSleep(false)
        state = .idle
    }

    private func tick() {
        let paused = pauseStart.map { Date().timeIntervalSince($0) } ?? 0
        elapsed = Date().timeIntervalSince(startedAt) - pausedTotal - paused
    }

    private func streamFailed(_ error: Error) {
        guard state == .recording || state == .paused else { return }
        NSLog("Record Everything: stream stopped: \(error)")
        Task {
            let item = await stop()
            if item == nil { onFailure?(error) }
        }
    }

    /// F14: the system does not sleep during a recording.
    private func preventSleep(_ on: Bool) {
        if on, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Record Everything recording" as CFString, &sleepAssertion)
        } else if !on, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}
