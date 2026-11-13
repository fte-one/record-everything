import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, upload, shortcuts, paste, dictation
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
                Text(L("Paste into")).tag(SettingsTab.paste)
                Text(L("Dictation")).tag(SettingsTab.dictation)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 500)
            .padding(.top, 36)
            .padding(.bottom, 14)

            Group {
                switch navigation.tab {
                case .general: GeneralSettings()
                case .upload: UploadSettingsView()
                case .shortcuts: ShortcutSettings()
                case .paste: PasteSettings()
                case .dictation: DictationSettings()
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
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                groupTitle(L("Screenshots"))
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
                groupTitle(L("Record")).padding(.top, 8)
                GridRow {
                    settingsLabel(L("Screen – start/pause:"))
                    HotKeyField(combo: $settings.startPauseHotKey)
                }
                GridRow {
                    settingsLabel(L("Stop Recording:"))
                    HotKeyField(combo: $settings.stopHotKey)
                }
                GridRow {
                    settingsLabel(L("Record camera:"))
                    HotKeyField(combo: $settings.recordCameraHotKey)
                }
                GridRow {
                    settingsLabel(L("Record audio:"))
                    HotKeyField(combo: $settings.recordAudioHotKey)
                }
            }
            Text(L("A shortcut works in one app at a time. Quit Dropshare if it uses the same keys."))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func groupTitle(_ title: String) -> some View {
        GridRow {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
                .gridCellColumns(2)
        }
    }
}

/// Screenshot editor: shortcuts that paste the image straight into another app.
private struct PasteSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var trusted = PasteIntoApp.isTrusted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("In the screenshot editor, a shortcut copies the image, switches to the app and pastes it into its input field."))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    settingsLabel(L("App you came from:"))
                    HotKeyField(combo: $settings.pasteBackShortcut)
                }
                ForEach($settings.pasteTargets) { $target in
                    GridRow {
                        HStack(spacing: 6) {
                            if let icon = PasteIntoApp.icon(bundleID: target.bundleID) {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            }
                            Text(target.name + ":").foregroundStyle(Theme.secondary)
                        }
                        .gridColumnAlignment(.trailing)
                        HStack(spacing: 8) {
                            HotKeyField(combo: $target.shortcut)
                            Button { settings.pasteTargets.removeAll { $0.id == target.id } } label: {
                                Image(systemName: "minus.circle").foregroundStyle(Theme.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L("Remove app"))
                        }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Button(L("Add App…")) { addApp() }
                }
            }
            HStack(spacing: 10) {
                if trusted {
                    Label(L("Automatic pasting is allowed"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent).font(.system(size: 12))
                } else {
                    Label(L("Needs Accessibility access to press ⌘V. Without it, the image is copied and the app comes to the front."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("Allow…")) {
                        PasteIntoApp.requestPermission()
                        PasteIntoApp.openAccessibilitySettings()
                    }
                }
            }
            .padding(.top, 4)
        }
        .onReceive(timer) { _ in trusted = PasteIntoApp.isTrusted }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("Add")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
              !settings.pasteTargets.contains(where: { $0.bundleID == bundleID }) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        settings.pasteTargets.append(PasteTarget(bundleID: bundleID, name: name, shortcut: nil))
    }
}

/// Screenshot editor: dictating a note (Control held) through OpenRouter's speech-to-text.
private struct DictationSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var key = ""
    @State private var testState: TestState = .idle

    enum TestState: Equatable { case idle, running, ok, failed(String) }

    private static let suggestedModels = [
        "openai/gpt-transcribe", "elevenlabs/scribe-v2", "google/gemini-3.5-transcribe",
        "mistralai/voxtral-small-transcribe-3-0", "openai/whisper-large-v3-turbo",
    ]
    private static let languages: [(code: String, name: String)] = [
        ("", L("Detect automatically")), ("de", "Deutsch"), ("en", "English"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("In the screenshot editor, hold Control and speak. The text becomes a note that is pasted into the app after the image. Wispr Flow works too: dictate as usual and its text lands in the note."))
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    settingsLabel(L("OpenRouter key:"))
                    SecureField("sk-or-…", text: $key).textFieldStyle(.roundedBorder)
                        .onSubmit { OpenRouter.apiKey = key }
                }
                GridRow {
                    settingsLabel(L("Model:"))
                    HStack(spacing: 6) {
                        TextField(AppSettings.defaultDictationModel, text: $settings.dictationModel).textFieldStyle(.roundedBorder)
                        Menu {
                            ForEach(Self.suggestedModels, id: \.self) { model in
                                Button(model) { settings.dictationModel = model }
                            }
                        } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(L("Suggested models"))
                    }
                }
                GridRow {
                    settingsLabel(L("Language:"))
                    Picker("", selection: $settings.dictationLanguage) {
                        ForEach(Self.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
            HStack(spacing: 10) {
                Button(L("Save & check key")) { saveAndTest() }
                    .buttonStyle(.borderedProminent)
                    .disabled(testState == .running || key.isEmpty)
                switch testState {
                case .idle: EmptyView()
                case .running: ProgressView().controlSize(.small)
                case .ok:
                    Label(L("Key works"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.system(size: 12))
                case .failed(let text):
                    Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.record).font(.system(size: 12)).lineLimit(2)
                }
            }
            Text(L("Say “paste into Claude” at the end (or the name of another app under “Paste into”) to paste right away."))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text(L("The key is stored in your keychain.")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Link(L("Get a key"), destination: URL(string: "https://openrouter.ai/keys")!).font(.system(size: 11))
            }
        }
        .onAppear { key = OpenRouter.apiKey ?? "" }
        .onDisappear { OpenRouter.apiKey = key }
    }

    private func saveAndTest() {
        OpenRouter.apiKey = key
        testState = .running
        Task {
            do {
                try await OpenRouter.checkKey()
                testState = .ok
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

/// Click, then press the new shortcut. Esc cancels, × removes the shortcut.
private struct HotKeyField: View {
    @Binding var combo: HotKeyCombo?
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            listening ? stop() : start()
        } label: {
            HStack {
                Text(listening ? L("Press keys…") : combo?.display ?? L("Not set"))
                    .foregroundStyle(combo == nil && !listening ? Theme.secondary : .primary)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(listening ? Theme.accent.opacity(0.35) : Theme.tile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            if combo != nil && !listening {
                Button { combo = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 7)
                .help(L("Remove shortcut"))
            }
        }
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
