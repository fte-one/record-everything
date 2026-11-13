import AppKit
import ApplicationServices
import AVFoundation
import ScreenCaptureKit

/// "Vibe coding feedback session": records one window while the user clicks through it and talks. Clicks,
/// selections, page changes and the "Mark" button produce stills; speech is transcribed in pieces on the way.
/// At the end the composer turns it into a prompt with numbered screenshots for a coding agent.
@MainActor
final class FeedbackSession: ObservableObject {
    static let shared = FeedbackSession()

    enum State: Equatable { case idle, starting, running, paused, finishing(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastWords = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var shotCount = 0

    var isActive: Bool { state != .idle }
    var isRecording: Bool { state == .running || state == .paused }

    private(set) var windowID: CGWindowID = 0
    private var appPID: pid_t = 0
    private var appName = ""
    private(set) var bounds: CGRect = .zero
    private var startDate = Date()
    private var pausedTotal: TimeInterval = 0
    private var pausedSince: Date?
    private var folder: URL?

    private var grabber: FrameGrabber?
    private var speech: SpeechRecorder?
    private var tick: Timer?
    private var tickCount = 0
    private var pointerTimer: Timer?
    /// Where the pointer rests and since when; `taken` once a still was made for it.
    private var dwell: (point: CGPoint, since: Date, taken: Bool)?
    private var lastHoverShot = Date.distantPast
    /// The self-test has no microphone: resting the pointer counts without speech.
    private var hoverNeedsSpeech = true
    private var mouseMonitor: Any?

    private var shots: [FeedbackShot] = []
    private var pages: [FeedbackPage] = []
    private var nextShotID = 1
    private let writer = DispatchQueue(label: "recordeverything.feedback.writer")

    // Change detection
    private var signature: [UInt8] = []
    private var stableSince = Date()
    private var lastSaved: (signature: [UInt8], frame: Int, file: URL)?
    private var lastAutoShot = Date.distantPast

    // Mouse
    private var down: (point: CGPoint, bounds: CGRect, still: FrameGrabber.Still?, inside: Bool)?

    /// Sessions end on their own after this long.
    private let maxDuration: TimeInterval = 30 * 60

    // MARK: Start and stop

    /// Both ⌘ keys: start on the window in front, or end the running session.
    func toggle() {
        switch state {
        case .idle: startWithFrontWindow()
        case .running, .paused: stop()
        case .starting, .finishing: break
        }
    }

    func startWithFrontWindow() {
        guard state == .idle, !SelectionOverlay.shared.isActive else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == own ? FrontmostAppTracker.shared.lastExternal : front
        guard let app, let window = WindowGeometry.frontWindow(of: app.processIdentifier) else {
            Toast.shared.show(L("No window to record"), detail: L("Bring the window to the front, then start again."),
                              symbol: "exclamationmark.triangle.fill", style: .error, duration: 3)
            return
        }
        Task { await start(windowID: window) }
    }

    /// From the menu: click the window to record.
    func startPickingWindow() {
        guard state == .idle, !SelectionOverlay.shared.isActive else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            AppController.shared.showPermissionWindow()
            return
        }
        SelectionOverlay.shared.begin(mode: .window, onConfirm: { [weak self] target, _ in
            guard let id = target.windowID else { return }
            Task { await self?.start(windowID: id) }
        }, onCancel: {})
    }

    func start(windowID: CGWindowID) async {
        guard state == .idle else { return }
        // Claimed before the first await, so a second ⌘⌘ or menu click cannot start another session meanwhile.
        state = .starting
        let ok = await setUp(windowID: windowID)
        if !ok, state == .starting { state = .idle }
    }

    private func setUp(windowID: CGWindowID) async -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            AppController.shared.showPermissionWindow()
            return false
        }
        guard OpenRouter.hasKey else {
            Toast.shared.show(L("Feedback sessions need an OpenRouter key"), detail: L("Add an OpenRouter key under Settings › Dictation."),
                              symbol: "key.fill", style: .error, duration: 5)
            AppController.shared.showSettings(tab: .dictation)
            return false
        }
        let testAudio = UserDefaults.standard.string(forKey: "RecordEverythingTestFeedbackAudio")
        if testAudio == nil, !(await SpeechRecorder.requestAccess()) {
            Toast.shared.show(L("Microphone access is off (System Settings › Privacy & Security › Microphone)."),
                              symbol: "mic.slash.fill", style: .error, duration: 5)
            return false
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }),
              let bounds = WindowGeometry.bounds(of: windowID) else {
            Toast.shared.show(L("No window to record"), symbol: "exclamationmark.triangle.fill", style: .error, duration: 3)
            return false
        }
        guard state == .starting else { return false }

        self.windowID = windowID
        self.bounds = bounds
        appPID = window.owningApplication?.processID ?? WindowGeometry.owner(of: windowID) ?? 0
        appName = window.owningApplication?.applicationName ?? ""
        startDate = Date()
        pausedTotal = 0
        pausedSince = nil
        shots = []
        pages = []
        nextShotID = 1
        shotCount = 0
        elapsed = 0
        lastWords = ""
        signature = []
        lastSaved = nil
        webArea = nil
        noWebAreaUntil = .distantPast
        lastAutoShot = .distantPast
        folder = Self.makeRawFolder()

        // Electron and Chrome build their accessibility tree (URL, selected text) only when asked.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(appPID), "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let grabber = FrameGrabber()
        grabber.onFrame = { [weak self] signature in
            Task { @MainActor in self?.frameArrived(signature) }
        }
        grabber.onStop = { [weak self] _ in
            Task { @MainActor in if self?.isRecording == true { self?.stop() } }
        }
        do {
            try await grabber.start(window: window)
        } catch {
            Toast.shared.show(L("Screenshot failed") + ": " + error.localizedDescription, symbol: "xmark.octagon.fill", style: .error, duration: 5)
            return false
        }
        guard state == .starting else {   // given up while the stream started
            await grabber.stop()
            return false
        }
        self.grabber = grabber
        state = .running
        startDate = Date()

        let speech = SpeechRecorder(folder: folder!, clock: { [weak self] in self?.now() ?? 0 })
        speech.onText = { [weak self] text in self?.lastWords = text }
        speech.onLevel = { [weak self] level in self?.level = level }
        self.speech = speech
        if let testAudio {
            let url = URL(fileURLWithPath: testAudio)
            let duration = (try? AVAudioFileDuration.seconds(of: url)) ?? 2
            speech.inject(url, at: 0.5, duration: duration)
        } else {
            speech.start()
        }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.mouse(event) }
        }
        tickCount = 0
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        dwell = nil
        lastHoverShot = .distantPast
        hoverNeedsSpeech = testAudio == nil
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer() }
        }
        pollPage()
        FeedbackChrome.shared.show(around: bounds)
        return true
    }

    func togglePause() {
        switch state {
        case .running:
            state = .paused
            pausedSince = Date()
            speech?.stop()
        case .paused:
            if let since = pausedSince { pausedTotal += Date().timeIntervalSince(since) }
            pausedSince = nil
            state = .running
            speech?.start()
        default: break
        }
    }

    /// "Mark": keeps what is on screen right now as a still.
    func mark() {
        guard state == .running else { return }
        if let still = grabber?.snapshot() { takeShot(.mark, still: still) }
    }

    /// Ends the session and builds the prompt.
    func stop() {
        guard isRecording else { return }
        if let since = pausedSince { pausedTotal += Date().timeIntervalSince(since) }
        pausedSince = nil
        let duration = now()
        state = .finishing(L("Transcribing …"))
        tearDownInput()
        Task {
            await grabber?.stop()
            grabber = nil
            await speech?.finish()
            await withCheckedContinuation { c in writer.async { c.resume() } }
            state = .finishing(L("Writing the prompt …"))
            let recording = FeedbackRecording(startDate: startDate, duration: duration, appName: appName,
                                              windowTitle: pages.last?.title ?? appName, shots: shots, pages: pages,
                                              speech: speech?.parts ?? [], speechErrors: speech?.errors ?? [])
            let settings = AppSettings.shared
            let options = FeedbackComposer.Options(
                model: settings.feedbackModel.isEmpty ? AppSettings.defaultFeedbackModel : settings.feedbackModel,
                maxImages: settings.feedbackImageMode == .attachments
                    ? min(settings.feedbackMaxImages, FeedbackImageMode.attachmentLimit) : settings.feedbackMaxImages,
                extraInstructions: settings.feedbackInstructions,
                outputRoot: UserDefaults.standard.string(forKey: "RecordEverythingTestFeedbackOutput").map { URL(fileURLWithPath: $0) }
                    ?? settings.saveFolder.appendingPathComponent("Feedback", isDirectory: true),
                imageMode: settings.feedbackImageMode)
            let result = await FeedbackComposer.compose(recording, options: options)
            speech = nil
            FeedbackChrome.shared.hide()
            state = .idle
            FeedbackHistory.shared.reload()
            if let result { FeedbackReview.show(result) }
        }
    }

    /// Ends the session without a prompt.
    func discard() {
        guard isRecording else { return }
        state = .finishing(L("Discarding …"))   // no second stop() or discard() meanwhile
        tearDownInput()
        speech?.stop()
        Task {
            await grabber?.stop()
            grabber = nil
            speech?.stop()
            speech = nil
            if let folder { try? FileManager.default.removeItem(at: folder) }
            FeedbackChrome.shared.hide()
            state = .idle
        }
    }

    private func tearDownInput() {
        tick?.invalidate()
        tick = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        dwell = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        down = nil
    }

    // MARK: Clock and ticks

    /// Session time without pauses.
    func now() -> TimeInterval {
        let paused = pausedTotal + (pausedSince.map { Date().timeIntervalSince($0) } ?? 0)
        return Date().timeIntervalSince(startDate) - paused
    }

    private func onTick() {
        guard isRecording else { return }
        tickCount += 1
        elapsed = now()
        guard let current = WindowGeometry.bounds(of: windowID) else {
            stop()   // the window was closed
            return
        }
        if current != bounds {
            if current.size != bounds.size {
                let scale = NSScreen.screens.first { WindowGeometry.appKitRect(current).intersects($0.frame) }?.backingScaleFactor ?? 2
                grabber?.resize(to: current.size, scale: scale)
            }
            bounds = current
            FeedbackChrome.shared.move(around: current)
        }
        if tickCount % 2 == 0 { pollPage() }
        checkSettled()
        if elapsed >= maxDuration { stop() }
    }

    // MARK: Stills

    private func frameArrived(_ new: [UInt8]) {
        guard state == .running else { return }
        if signature.isEmpty || FrameGrabber.difference(new, signature) > 2 { stableSince = Date() }
        signature = new
        if shots.isEmpty, let still = grabber?.snapshot() {
            takeShot(.start, still: still)
            return
        }
        checkSettled()
    }

    /// The view changed (navigation, scrolling, a dialog) and has settled: keep it. Also run from the tick, as a
    /// window sends no new frames while it stays still.
    private func checkSettled() {
        guard state == .running, !signature.isEmpty, Date().timeIntervalSince(stableSince) >= 0.8,
              Date().timeIntervalSince(lastAutoShot) >= 1.5,
              let saved = lastSaved?.signature, FrameGrabber.difference(signature, saved) > 8,
              let still = grabber?.snapshot() else { return }
        lastAutoShot = Date()
        takeShot(.change, still: still)
    }

    private func takeShot(_ kind: FeedbackShot.Kind, still: FrameGrabber.Still, marker: FeedbackShot.Marker? = nil,
                          selectedText: String? = nil) {
        guard let folder else { return }
        let image = still.image
        let file: URL
        if let saved = lastSaved, saved.frame == still.frame {
            file = saved.file   // the window has not drawn anything new since the last still
        } else {
            file = folder.appendingPathComponent(String(format: "shot-%04d.png", nextShotID))
            writer.async { if let data = ImageFiles.png(image) { try? data.write(to: file) } }
            lastSaved = (still.signature, still.frame, file)
        }
        let page = pages.last
        shots.append(FeedbackShot(id: nextShotID, time: now(), kind: kind, file: file,
                                  pixelSize: CGSize(width: image.width, height: image.height), marker: marker,
                                  url: page?.url, title: page?.title, selectedText: selectedText))
        nextShotID += 1
        shotCount = shots.count
    }

    /// CoreGraphics global point → pixel in the window image.
    private func pixel(_ p: CGPoint, image: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(x: (p.x - bounds.minX) * image.width / max(1, bounds.width),
                y: (p.y - bounds.minY) * image.height / max(1, bounds.height))
    }

    // MARK: Mouse

    private func mouse(_ event: NSEvent) {
        guard state == .running else { return }
        // Where the event happened, not where the pointer is now.
        let p = event.cgEvent?.location ?? WindowGeometry.cgPoint(NSEvent.mouseLocation)
        switch event.type {
        case .leftMouseDown:
            let current = WindowGeometry.bounds(of: windowID) ?? bounds
            let inside = current.contains(p) && NSWorkspace.shared.frontmostApplication?.processIdentifier == appPID
            // The picture before the click: what the user pointed at.
            down = (p, current, inside ? grabber?.snapshot() : nil, inside)
            dwell = (p, Date(), true)
        case .leftMouseUp:
            guard let d = down, d.inside else { down = nil; return }
            down = nil
            let current = WindowGeometry.bounds(of: windowID) ?? bounds
            if current != d.bounds { return }   // the window was moved or resized, not clicked
            if hypot(p.x - d.point.x, p.y - d.point.y) < 8 {
                guard let still = d.still else { return }
                let size = CGSize(width: still.image.width, height: still.image.height)
                takeShot(.click, still: still, marker: .click(pixel(d.point, image: size, in: current)))
            } else {
                let rect = CGRect(x: min(p.x, d.point.x), y: min(p.y, d.point.y), width: abs(p.x - d.point.x), height: abs(p.y - d.point.y))
                // Give the app a moment to draw the selection and the frame grabber to catch it.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard state == .running, let still = grabber?.snapshot() else { return }
                    let size = CGSize(width: still.image.width, height: still.image.height)
                    let origin = pixel(rect.origin, image: size, in: current)
                    let end = pixel(CGPoint(x: rect.maxX, y: rect.maxY), image: size, in: current)
                    takeShot(.selection, still: still,
                             marker: .selection(CGRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)),
                             selectedText: selectedText())
                }
            }
        default: break
        }
    }

    // MARK: Pointer

    /// "Was ist das hier?": when the pointer rests on a spot while the user talks, keep a still with the spot marked.
    private func samplePointer() {
        guard state == .running, down == nil else { return }
        let p = WindowGeometry.cgPoint(NSEvent.mouseLocation)
        guard bounds.contains(p), NSWorkspace.shared.frontmostApplication?.processIdentifier == appPID else {
            dwell = nil
            return
        }
        guard let d = dwell, hypot(p.x - d.point.x, p.y - d.point.y) < 14 else {
            dwell = (p, Date(), false)
            return
        }
        guard !d.taken, Date().timeIntervalSince(d.since) >= 1.0, Date().timeIntervalSince(lastHoverShot) >= 1.5,
              !hoverNeedsSpeech || speech?.isSpeaking == true, let still = grabber?.snapshot() else { return }
        dwell?.taken = true
        lastHoverShot = Date()
        let size = CGSize(width: still.image.width, height: still.image.height)
        takeShot(.hover, still: still, marker: .pointer(pixel(d.point, image: size, in: bounds)))
    }

    // MARK: Accessibility: page and selection

    private var webArea: AXUIElement?
    private var noWebAreaUntil = Date.distantPast

    private func pollPage() {
        let axApp = AXUIElementCreateApplication(appPID)
        // A hanging app must not stall the session (the default timeout is several seconds).
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let window = matchingWindow(axApp) else { return }
        let title = Self.cleanTitle(AX.value(window, kAXTitleAttribute) ?? "", appName: appName)
        var url = webArea.flatMap(Self.url(of:))
        if url == nil, Date() >= noWebAreaUntil {
            webArea = findWebArea(in: window)
            url = webArea.flatMap(Self.url(of:))
            // Apps without a web view: look again only now and then.
            if webArea == nil { noWebAreaUntil = Date().addingTimeInterval(10) }
        }
        if pages.last?.url != url || pages.last?.title != title {
            pages.append(FeedbackPage(time: now(), url: url, title: title))
        }
    }

    private func matchingWindow(_ axApp: AXUIElement) -> AXUIElement? {
        let windows: [AXUIElement] = AX.value(axApp, kAXWindowsAttribute) ?? []
        return windows.first { AX.frame(of: $0).insetBy(dx: -4, dy: -4).contains(bounds.insetBy(dx: 4, dy: 4)) } ?? windows.first
    }

    /// The browser's web area, whose AXURL is the page address.
    private func findWebArea(in window: AXUIElement) -> AXUIElement? {
        var queue = [window], index = 0
        while index < queue.count, index < 400 {
            let element = queue[index]
            index += 1
            if (AX.value(element, kAXRoleAttribute) as String?) == "AXWebArea" { return element }
            queue.append(contentsOf: AX.value(element, kAXChildrenAttribute) as [AXUIElement]? ?? [])
        }
        return nil
    }

    /// "Shop | MyShow - Google Chrome - Ortwin (Work)" → "Shop | MyShow".
    static func cleanTitle(_ title: String, appName: String) -> String {
        guard !appName.isEmpty else { return title }
        for separator in [" - ", " – ", " — "] {
            if let range = title.range(of: separator + appName) { return String(title[..<range.lowerBound]) }
        }
        return title
    }

    private static func url(of webArea: AXUIElement) -> String? {
        if let url: URL = AX.value(webArea, "AXURL") { return url.absoluteString }
        return AX.value(webArea, "AXURL")
    }

    private func selectedText() -> String? {
        let axApp = AXUIElementCreateApplication(appPID)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        guard let focused: AXUIElement = AX.value(axApp, kAXFocusedUIElementAttribute),
              let text: String = AX.value(focused, kAXSelectedTextAttribute) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(600))
    }

    // MARK: Files

    private static func makeRawFolder() -> URL {
        let root = Screenshots.cacheFolder.appendingPathComponent("Feedback", isDirectory: true)
        // Only the newest session's raw stills are kept.
        try? FileManager.default.removeItem(at: root)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Self-test: shots and pages so far.
    var testSnapshot: (shots: [FeedbackShot], pages: [FeedbackPage]) { (shots, pages) }
}

/// Small typed wrapper around the Accessibility attribute API.
enum AX {
    static func value<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == URL.self, CFGetTypeID(value) == CFURLGetTypeID() { return (value as! NSURL) as URL as? T }
        return value as? T
    }

    static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero, size = CGSize.zero
        if let v: AXValue = value(element, kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &origin) }
        if let v: AXValue = value(element, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &size) }
        return CGRect(origin: origin, size: size)
    }
}

enum AVAudioFileDuration {
    static func seconds(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// Which modifier pressed on both sides at once starts and ends a feedback session.
enum DoubleModifier: String, Codable, CaseIterable, Identifiable {
    case command, shift, option, off

    var id: String { rawValue }

    /// Device-dependent bits of the modifier flags for the left and right key (IOKit's NX_DEVICE…KEYMASK).
    var sides: (left: UInt, right: UInt)? {
        switch self {
        case .command: return (0x08, 0x10)
        case .shift: return (0x02, 0x04)
        case .option: return (0x20, 0x40)
        case .off: return nil
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .shift: return .shift
        case .option: return .option
        case .off: return []
        }
    }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .shift: return "⇧"
        case .option: return "⌥"
        case .off: return ""
        }
    }

    /// "⌘ + ⌘", as shown in key caps.
    var display: String? { self == .off ? nil : "\(symbol) + \(symbol)" }

    var title: String {
        switch self {
        case .command: return L("Both ⌘ keys")
        case .shift: return L("Both ⇧ keys")
        case .option: return L("Both ⌥ keys")
        case .off: return L("Off")
        }
    }
}

/// Both keys of the chosen modifier pressed together (within a moment, nothing else held) toggle a feedback session.
@MainActor
final class DoubleModifierMonitor {
    static let shared = DoubleModifierMonitor()
    var handler: (() -> Void)?
    var key: DoubleModifier = .command {
        didSet { reset() }
    }
    private var global: Any?
    private var local: Any?
    private var firstDown: Date?
    private var fired = false

    func start() {
        guard global == nil else { return }
        global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { DoubleModifierMonitor.shared.handle(event.modifierFlags) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            MainActor.assumeIsolated { DoubleModifierMonitor.shared.handle(event.modifierFlags) }
            return event
        }
    }

    func stop() {
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil
        local = nil
        reset()
    }

    /// Starts or stops listening for the chosen modifier.
    func apply(_ key: DoubleModifier) {
        self.key = key
        if key == .off { stop() } else { start() }
    }

    private func reset() {
        firstDown = nil
        fired = false
    }

    func handle(_ flags: NSEvent.ModifierFlags) {
        guard let sides = key.sides else { return }
        let left = flags.rawValue & sides.left != 0
        let right = flags.rawValue & sides.right != 0
        let others = flags.intersection([.command, .shift, .option, .control, .function]).subtracting(key.flag)
        if !left && !right {
            reset()
            return
        }
        if left && right {
            if !fired, others.isEmpty, let first = firstDown, Date().timeIntervalSince(first) < 0.6 {
                fired = true
                handler?()
            }
        } else if firstDown == nil {
            firstDown = Date()
        }
    }
}
