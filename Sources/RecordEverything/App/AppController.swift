import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Central coordinator: status item, hot keys and the screen recording flow.
@MainActor
final class AppController: NSObject {
    static let shared = AppController()

    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []
    private let recorder = Recorder.shared
    private var homeWasVisible = false

    func launch() {
        setupStatusItem()
        HotKeyCenter.shared.handler = { [weak self] action in self?.handleHotKey(action) }
        HotKeyCenter.shared.reload()

        recorder.onFinished = { [weak self] item in self?.recordingFinished(item) }
        recorder.onFailure = { error in
            let alert = NSAlert()
            alert.messageText = L("Recording has stopped due to errors.")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        recorder.$state.combineLatest(recorder.$elapsed)
            .sink { [weak self] _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        if SelfTest.mode != nil {
            recorder.onFinished = nil
            SelfTest.run()
            return
        }
        _ = Updater.shared
        showHome()
    }

    // MARK: Windows

    func showHome() {
        WindowManager.shared.show(id: "home", title: "Record Everything",
                                  style: .init(size: NSSize(width: 404, height: 584), minSize: NSSize(width: 404, height: 480), resizable: true)) {
            HomeView()
        }
    }

    func showSettings() {
        WindowManager.shared.show(id: "settings", title: L("Settings"), style: .init(size: NSSize(width: 480, height: 372))) {
            SettingsView()
        }
    }

    func showCameraWindow() {
        guard !recorder.isActive else { return }
        WindowManager.shared.show(id: "camera", title: L("Record Webcam"),
                                  style: .init(size: NSSize(width: 560, height: 360), minSize: NSSize(width: 420, height: 270), resizable: true)) {
            CameraRecorderView()
        }
    }

    func showAudioWindow() {
        guard !recorder.isActive else { return }
        WindowManager.shared.show(id: "audio", title: L("Record Audio"), style: .init(size: NSSize(width: 430, height: 189))) {
            AudioRecorderView()
        }
    }

    func showInfo(_ item: MediaItem) {
        MediaLibrary.shared.markSeen(item)
        WindowManager.shared.show(id: "info-\(item.id)", title: item.title,
                                  style: .init(size: NSSize(width: 860, height: 520), minSize: NSSize(width: 640, height: 420), resizable: true)) {
            MediaInfoView(itemID: item.id)
        }
    }

    func showEditor(_ item: MediaItem) {
        WindowManager.shared.close("info-\(item.id)")
        WindowManager.shared.show(id: "editor-\(item.id)", title: L("Trim video"),
                                  style: .init(size: NSSize(width: 900, height: 620), minSize: NSSize(width: 700, height: 520), resizable: true)) {
            VideoEditorView(itemID: item.id)
        }
    }

    func showPermissionWindow() {
        WindowManager.shared.show(id: "permission", title: L("Permissions"), style: .init(size: NSSize(width: 500, height: 420))) {
            PermissionView()
        }
    }

    // MARK: Screen recording flow

    func startScreenFlow() {
        guard !recorder.isActive, !SelectionOverlay.shared.isActive else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showPermissionWindow()
            return
        }
        let home = WindowManager.shared.window("home")
        homeWasVisible = home?.isVisible ?? false
        home?.orderOut(nil)
        SelectionOverlay.shared.begin(
            onConfirm: { [weak self] target, screen in self?.runCountdown(target: target, screen: screen) },
            onCancel: { [weak self] in
                CameraBubble.shared.hide()
                self?.restoreHome()
            })
    }

    private func runCountdown(target: ScreenTarget, screen: NSScreen) {
        let globalRect = screen.globalRect(fromLocal: target.rect)
        Countdown.shared.run(on: screen, around: globalRect) { [weak self] completed in
            guard let self else { return }
            if completed {
                self.beginScreenRecording(target: target, screen: screen, globalRect: globalRect)
            } else {
                CameraBubble.shared.hide()
                self.restoreHome()
            }
        }
    }

    private func beginScreenRecording(target: ScreenTarget, screen: NSScreen, globalRect: CGRect) {
        let options = AppSettings.shared.capture
        let keep = CameraBubble.shared.isVisible ? [CameraBubble.shared.window].compactMap { $0 } : []
        Task {
            do {
                try await recorder.startScreen(target: target, options: options, keepWindows: keep)
                let isFullScreen = target.rect.size == screen.frame.size
                if !isFullScreen { RegionFrame.shared.show(around: globalRect) }
                RecordBar.shared.show(on: screen, avoiding: globalRect)
            } catch {
                CameraBubble.shared.hide()
                restoreHome()
                presentError(error)
            }
        }
    }

    private func recordingFinished(_ item: MediaItem?) {
        RecordBar.shared.hide()
        RegionFrame.shared.hide()
        CameraBubble.shared.hide()
        showHome()
        if let item { NotificationCenter.default.post(name: .recordingAdded, object: item.id) }
    }

    private func restoreHome() {
        if homeWasVisible { WindowManager.shared.window("home")?.makeKeyAndOrderFront(nil) }
    }

    func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Recording failed")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Hot keys

    private func handleHotKey(_ action: HotKeyCenter.Action) {
        switch action {
        case .startPause:
            if recorder.isActive {
                recorder.togglePause()
            } else if SelectionOverlay.shared.isActive {
                SelectionOverlay.shared.confirm()
            } else if !Countdown.shared.isRunning {
                startScreenFlow()
            }
        case .stop:
            if Countdown.shared.isRunning { Countdown.shared.cancel() }
            if SelectionOverlay.shared.isActive { SelectionOverlay.shared.cancel() }
            if recorder.isActive { Task { await recorder.stop() } }
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record Everything")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        let menu = NSMenu()
        if recorder.isActive {
            let pause = recorder.state == .paused ? L("Resume") : L("Pause")
            menu.addItem(menuItem(pause, #selector(menuPause)))
            menu.addItem(menuItem(L("Stop Recording"), #selector(menuStop)))
        } else {
            menu.addItem(menuItem(L("Record Screen"), #selector(menuRecordScreen)))
            menu.addItem(menuItem(L("Record Webcam"), #selector(menuRecordCamera)))
            menu.addItem(menuItem(L("Record Audio"), #selector(menuRecordAudio)))
            menu.addItem(.separator())
            menu.addItem(menuItem(L("Open Home Page"), #selector(menuHome)))
            menu.addItem(menuItem(L("Settings…"), #selector(menuSettings)))
            let update = NSMenuItem(title: L("Check for Updates…"), action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
            update.target = Updater.shared
            menu.addItem(update)
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: L("Quit Record Everything"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        }
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        switch recorder.state {
        case .recording, .paused:
            button.image = NSImage(systemSymbolName: recorder.state == .paused ? "pause.circle.fill" : "stop.circle.fill",
                                   accessibilityDescription: L("Stop Recording"))
            button.title = " " + formatDuration(recorder.elapsed)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        default:
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Record Everything")
            button.title = ""
        }
    }

    @objc func menuRecordScreen() { startScreenFlow() }
    @objc func menuRecordCamera() { showCameraWindow() }
    @objc func menuRecordAudio() { showAudioWindow() }
    @objc func menuHome() { showHome() }
    @objc func menuSettings() { showSettings() }
    @objc private func menuPause() { recorder.togglePause() }
    @objc private func menuStop() { Task { await recorder.stop() } }
}

extension Notification.Name {
    static let recordingAdded = Notification.Name("recordingAdded")
}
