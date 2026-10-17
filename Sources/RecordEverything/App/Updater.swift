import AppKit
import Sparkle

/// Online updates through Sparkle. The feed is the appcast of the latest GitHub release (SUFeedURL in Info.plist);
/// every update is checked against the EdDSA key SUPublicEDKey and the app's Developer ID signature.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    var updater: SPUUpdater { controller.updater }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    /// A test feed can replace the GitHub feed: --args -RecordEverythingFeedURL http://127.0.0.1:8765/appcast.xml
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "RecordEverythingFeedURL")
    }
}
