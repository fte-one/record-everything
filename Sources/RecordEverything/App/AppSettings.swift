import AppKit
import Foundation
import ServiceManagement

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// User preferences plus the last used capture options.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var saveFolder: URL {
        didSet { defaults.set(saveFolder.path, forKey: "saveFolder") }
    }
    /// Global shortcuts; nil means none. Recording shortcuts are unset by default because ⌘1/⌘2 and the
    /// like belong to other apps (tab switching in browsers).
    @Published var startPauseHotKey: HotKeyCombo? {
        didSet { store(startPauseHotKey, "startPauseHotKey"); HotKeyCenter.shared.reload() }
    }
    @Published var stopHotKey: HotKeyCombo? {
        didSet { store(stopHotKey, "stopHotKey"); HotKeyCenter.shared.reload() }
    }
    @Published var recordCameraHotKey: HotKeyCombo? {
        didSet { store(recordCameraHotKey, "recordCameraHotKey"); HotKeyCenter.shared.reload() }
    }
    @Published var recordAudioHotKey: HotKeyCombo? {
        didSet { store(recordAudioHotKey, "recordAudioHotKey"); HotKeyCenter.shared.reload() }
    }
    @Published var captureUploadHotKey: HotKeyCombo? {
        didSet { store(captureUploadHotKey, "captureUploadHotKey"); HotKeyCenter.shared.reload() }
    }
    @Published var captureAnnotateHotKey: HotKeyCombo? {
        didSet { store(captureAnnotateHotKey, "captureAnnotateHotKey"); HotKeyCenter.shared.reload() }
    }
    @Published var captureCopyHotKey: HotKeyCombo? {
        didSet { store(captureCopyHotKey, "captureCopyHotKey"); HotKeyCenter.shared.reload() }
    }
    /// Annotation editor: shortcut that pastes into the app in front before the screenshot (default ⌘X).
    @Published var pasteBackShortcut: HotKeyCombo? {
        didSet { store(pasteBackShortcut, "pasteBackShortcut") }
    }
    /// Annotation editor: fixed apps to paste into, each with its own shortcut.
    @Published var pasteTargets: [PasteTarget] {
        didSet { store(pasteTargets, "pasteTargets") }
    }
    /// The drawing tool the editor starts with: the last one used, the arrow at first.
    @Published var annotationTool: String {
        didSet { defaults.set(annotationTool, forKey: "annotationTool") }
    }
    /// OpenRouter transcription model for dictating a note in the screenshot editor.
    @Published var dictationModel: String {
        didSet { defaults.set(dictationModel, forKey: "dictationModel") }
    }
    static let defaultDictationModel = "openai/gpt-transcribe"
    /// ISO 639-1 code of the spoken language; empty means detect automatically.
    @Published var dictationLanguage: String {
        didSet { defaults.set(dictationLanguage, forKey: "dictationLanguage") }
    }
    /// Feedback sessions: OpenRouter model that writes the prompt, most screenshots, text added to every prompt.
    @Published var feedbackModel: String {
        didSet { defaults.set(feedbackModel, forKey: "feedbackModel") }
    }
    static let defaultFeedbackModel = "anthropic/claude-sonnet-5.5"
    @Published var feedbackMaxImages: Int {
        didSet { defaults.set(feedbackMaxImages, forKey: "feedbackMaxImages") }
    }
    @Published var feedbackInstructions: String {
        didSet { defaults.set(feedbackInstructions, forKey: "feedbackInstructions") }
    }
    /// How the screenshots reach the agent: pasted as images (default) or as file paths.
    @Published var feedbackImageMode: FeedbackImageMode {
        didSet { defaults.set(feedbackImageMode.rawValue, forKey: "feedbackImageMode") }
    }
    /// Pressing both keys of this modifier starts and ends a feedback session (default: both ⌘).
    @Published var feedbackTrigger: DoubleModifier {
        didSet {
            defaults.set(feedbackTrigger.rawValue, forKey: "feedbackTrigger")
            DoubleModifierMonitor.shared.apply(feedbackTrigger)
        }
    }
    @Published var upload: UploadSettings {
        didSet { store(upload, "upload") }
    }
    /// Off: the app lives in the menu bar only, like Dropshare.
    @Published var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: "showDockIcon"); applyActivationPolicy() }
    }
    @Published var capture: CaptureOptions {
        didSet { store(capture, "capture") }
    }
    @Published var cameraWindowOptions: CaptureOptions {
        didSet { store(cameraWindowOptions, "cameraWindowOptions") }
    }
    @Published var audioWindowOptions: CaptureOptions {
        didSet { store(audioWindowOptions, "audioWindowOptions") }
    }

    private init() {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Record Everything", isDirectory: true)
        saveFolder = defaults.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? movies
        startPauseHotKey = Self.loadHotKey("startPauseHotKey", default: nil)
        stopHotKey = Self.loadHotKey("stopHotKey", default: nil)
        recordCameraHotKey = Self.loadHotKey("recordCameraHotKey", default: nil)
        recordAudioHotKey = Self.loadHotKey("recordAudioHotKey", default: nil)
        captureUploadHotKey = Self.loadHotKey("captureUploadHotKey", default: .defaultCaptureUpload)
        captureAnnotateHotKey = Self.loadHotKey("captureAnnotateHotKey", default: .defaultCaptureAnnotate)
        captureCopyHotKey = Self.loadHotKey("captureCopyHotKey", default: .defaultCaptureCopy)
        pasteBackShortcut = Self.loadHotKey("pasteBackShortcut", default: .defaultPasteBack)
        pasteTargets = Self.load("pasteTargets") ?? PasteTarget.installedDefaults()
        annotationTool = defaults.string(forKey: "annotationTool") ?? AnnotationTool.arrow.rawValue
        dictationModel = defaults.string(forKey: "dictationModel") ?? Self.defaultDictationModel
        dictationLanguage = defaults.string(forKey: "dictationLanguage")
            ?? (Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "" } ?? "")
        feedbackModel = defaults.string(forKey: "feedbackModel") ?? Self.defaultFeedbackModel
        feedbackMaxImages = defaults.object(forKey: "feedbackMaxImages") as? Int ?? 20
        feedbackInstructions = defaults.string(forKey: "feedbackInstructions") ?? ""
        feedbackImageMode = defaults.string(forKey: "feedbackImageMode").flatMap(FeedbackImageMode.init(rawValue:)) ?? .attachments
        feedbackTrigger = defaults.string(forKey: "feedbackTrigger").flatMap(DoubleModifier.init(rawValue:)) ?? .command
        upload = Self.load("upload") ?? UploadSettings()
        showDockIcon = defaults.object(forKey: "showDockIcon") as? Bool ?? false
        capture = Self.load("capture") ?? CaptureOptions()
        var cam = CaptureOptions()
        cam.camera = true
        cam.systemAudio = false
        cameraWindowOptions = Self.load("cameraWindowOptions") ?? cam
        var audio = CaptureOptions()
        audio.systemAudio = false
        audioWindowOptions = Self.load("audioWindowOptions") ?? audio
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
    }

    /// Creates the save folder on demand and returns it.
    func ensureSaveFolder() throws -> URL {
        try FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        return saveFolder
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Record Everything: login item change failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    /// A stored shortcut, a stored "none" (JSON null) or, if nothing was ever stored, the default.
    private static func loadHotKey(_ key: String, default value: HotKeyCombo?) -> HotKeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return value }
        do { return try JSONDecoder().decode(HotKeyCombo?.self, from: data) } catch { return value }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
