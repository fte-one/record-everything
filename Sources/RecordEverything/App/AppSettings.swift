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
    @Published var startPauseHotKey: HotKeyCombo {
        didSet { store(startPauseHotKey, "startPauseHotKey"); HotKeyCenter.shared.reload() }
    }
    @Published var stopHotKey: HotKeyCombo {
        didSet { store(stopHotKey, "stopHotKey"); HotKeyCenter.shared.reload() }
    }
    @Published var captureUploadHotKey: HotKeyCombo {
        didSet { store(captureUploadHotKey, "captureUploadHotKey"); HotKeyCenter.shared.reload() }
    }
    @Published var captureAnnotateHotKey: HotKeyCombo {
        didSet { store(captureAnnotateHotKey, "captureAnnotateHotKey"); HotKeyCenter.shared.reload() }
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
        startPauseHotKey = Self.load("startPauseHotKey") ?? .defaultStartPause
        stopHotKey = Self.load("stopHotKey") ?? .defaultStop
        captureUploadHotKey = Self.load("captureUploadHotKey") ?? .defaultCaptureUpload
        captureAnnotateHotKey = Self.load("captureAnnotateHotKey") ?? .defaultCaptureAnnotate
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

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
