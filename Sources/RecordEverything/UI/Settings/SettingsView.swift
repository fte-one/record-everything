import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, upload, shortcuts
    var id: String { rawValue }
}

/// Which settings tab is shown; other parts of the app can jump to a tab.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

/// Settings window with General, Upload and Shortcuts tabs.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $navigation.tab) {
                Text(L("General")).tag(SettingsTab.general)
                Text(L("Upload")).tag(SettingsTab.upload)
                Text(L("Shortcuts")).tag(SettingsTab.shortcuts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .padding(.top, 36)
            .padding(.bottom, 14)

            Group {
                switch navigation.tab {
                case .general: GeneralSettings()
                case .upload: UploadSettingsView()
                case .shortcuts: ShortcutSettings()
                }
            }
            .padding(.horizontal, 28)
            .frame(maxHeight: .infinity, alignment: .top)

            Rectangle().fill(Theme.separator).frame(height: 1)
            HStack {
                HStack(spacing: 8) {
                    Text(Brand.copyright)
                    Link(L("Imprint"), destination: Brand.imprintURL)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                Spacer()
                Button(L("OK")) { WindowManager.shared.close("settings") }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: 560, height: 470)
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
    }
}

private func settingsLabel(_ s: String) -> some View {
    Text(s).foregroundStyle(Theme.secondary).gridColumnAlignment(.trailing)
}

private struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var autoUpdateToggled = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
            GridRow {
                settingsLabel(L("Save Location:"))
                HStack {
                    Text(settings.saveFolder.path)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { chooseFolder() } label: { Image(systemName: "folder") }.buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.tile))
            }
            GridRow {
                settingsLabel(L("Startup:"))
                Toggle(L("Start at login"), isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
            GridRow {
                settingsLabel(L("Dock:"))
                Toggle(L("Show icon in the Dock"), isOn: $settings.showDockIcon)
            }
            GridRow {
                settingsLabel(L("Updates:"))
                HStack {
                    Toggle(L("Check automatically"), isOn: Binding(get: { Updater.shared.automaticallyChecks },
                                                                  set: { Updater.shared.automaticallyChecks = $0; autoUpdateToggled.toggle() }))
                        .id(autoUpdateToggled)
                    Spacer()
                    Button(L("Check Now")) { Updater.shared.checkForUpdates(nil) }
                }
            }
            GridRow {
                settingsLabel(L("Version:"))
                Text(versionString)
            }
        }
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url { settings.saveFolder = url }
    }
}

/// Cloudflare R2 (or any S3-compatible storage): where screenshots and recordings are uploaded.
private struct UploadSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var uploads = UploadManager.shared
    @State private var accessKey = ""
    @State private var secret = ""
    @State private var testState: TestState = .idle
    @State private var showAdvanced = false

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    settingsLabel(L("Account ID:"))
                    TextField(L("Cloudflare account ID"), text: $settings.upload.accountID).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    settingsLabel(L("Bucket:"))
                    TextField("my-bucket", text: $settings.upload.bucket).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    settingsLabel(L("Access Key ID:"))
                    TextField("", text: $accessKey).textFieldStyle(.roundedBorder)
                        .onSubmit { uploads.accessKeyID = accessKey }
                }
                GridRow {
                    settingsLabel(L("Secret Access Key:"))
                    SecureField("", text: $secret).textFieldStyle(.roundedBorder)
                        .onSubmit { uploads.secretAccessKey = secret }
                }
                GridRow {
                    settingsLabel(L("Public URL:"))
                    TextField("https://example.com/files/", text: $settings.upload.publicBaseURL).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    settingsLabel(L("File name:"))
                    HStack {
                        TextField("%month%%random-5%", text: $settings.upload.filenamePattern).textFieldStyle(.roundedBorder)
                        Text(FilenamePattern.make(settings.upload.filenamePattern, fileExtension: "png"))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                    }
                }
                GridRow {
                    settingsLabel(L("After upload:"))
                    Toggle(L("Play a sound"), isOn: $settings.upload.playSound)
                }
            }

            DisclosureGroup(L("Other S3-compatible storage"), isExpanded: $showAdvanced) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        settingsLabel(L("Endpoint:"))
                        TextField(L("empty = Cloudflare R2"), text: $settings.upload.customEndpoint).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        settingsLabel(L("Region:"))
                        TextField("auto", text: $settings.upload.region).textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12))

            HStack(spacing: 10) {
                Button(L("Save & test connection")) { saveAndTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(testState == .running)
                switch testState {
                case .idle: EmptyView()
                case .running: ProgressView().controlSize(.small)
                case .ok(let text):
                    Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 12))
                case .failed(let text):
                    Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.record).font(.system(size: 12)).lineLimit(2)
                }
            }
            Text(L("The keys of an R2 API token (Object Read & Write) are stored in your keychain."))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .onAppear {
            accessKey = uploads.accessKeyID
            secret = uploads.secretAccessKey
        }
        .onDisappear {
            uploads.accessKeyID = accessKey
            uploads.secretAccessKey = secret
        }
    }

    private func saveAndTest() {
        uploads.accessKeyID = accessKey
        uploads.secretAccessKey = secret
        testState = .running
        Task {
            do {
                _ = try await uploads.testConnection()
                testState = .ok(L("Connection works"))
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    settingsLabel(L("Screenshot & annotate:"))
                    HotKeyField(combo: $settings.captureAnnotateHotKey)
                }
                GridRow {
                    settingsLabel(L("Screenshot & copy link:"))
                    HotKeyField(combo: $settings.captureUploadHotKey)
                }
                GridRow {
                    settingsLabel(L("Screenshot & copy image:"))
                    HotKeyField(combo: $settings.captureCopyHotKey)
                }
                GridRow {
                    settingsLabel(L("Start/Pause Recording:"))
                    HotKeyField(combo: $settings.startPauseHotKey)
                }
                GridRow {
                    settingsLabel(L("Stop Recording:"))
                    HotKeyField(combo: $settings.stopHotKey)
                }
            }
            Text(L("A shortcut works in one app at a time. Quit Dropshare if it uses the same keys."))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
    }
}

/// Click, then press the new shortcut. Esc cancels.
private struct HotKeyField: View {
    @Binding var combo: HotKeyCombo
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            listening ? stop() : start()
        } label: {
            Text(listening ? L("Press keys…") : combo.display)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(listening ? Theme.accent.opacity(0.35) : Theme.tile))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDisappear { stop() }
    }

    private func start() {
        listening = true
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            if let c = HotKeyCombo(event: event) {
                combo = c
                stop()
                return nil
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if listening {
            listening = false
            HotKeyCenter.shared.reload()
        }
    }
}

/// Shown when screen recording permission is missing.
struct PermissionView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 54)).foregroundStyle(Theme.accent).padding(.top, 40)
            Text(L("Please allow screen recording for Record Everything and restart it."))
                .font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Text(L("System Settings › Privacy & Security › Screen & System Audio Recording"))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Spacer()
            Button(L("Open System Settings")) {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            .controlSize(.large)
            Button(L("Finished & Restart Record Everything")) { relaunch() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 30)
        .frame(width: 500, height: 420)
        .background(Theme.background)
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
