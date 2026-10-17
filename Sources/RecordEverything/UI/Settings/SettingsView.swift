import AppKit
import SwiftUI

/// Settings window: save location, login item, hot keys, version.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Text(L("Settings")).font(.system(size: 13, weight: .semibold)).frame(height: 38)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 14) {
                GridRow {
                    label(L("Save Location:"))
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
                    label(L("Startup:"))
                    Toggle(L("Start at login"), isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
                }
                GridRow {
                    label(L("Start/Pause Recording:"))
                    HotKeyField(combo: $settings.startPauseHotKey)
                }
                GridRow {
                    label(L("Stop Recording:"))
                    HotKeyField(combo: $settings.stopHotKey)
                }
                GridRow {
                    label(L("Updates:"))
                    HStack {
                        Toggle(L("Check automatically"), isOn: Binding(get: { Updater.shared.automaticallyChecks },
                                                                      set: { Updater.shared.automaticallyChecks = $0; autoUpdateToggled.toggle() }))
                            .id(autoUpdateToggled)
                        Spacer()
                        Button(L("Check Now")) { Updater.shared.checkForUpdates(nil) }
                    }
                }
                GridRow {
                    label(L("Version:"))
                    Text(versionString)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)

            Spacer()
            Rectangle().fill(Theme.separator).frame(height: 1)
            HStack {
                Text("© 2026 Record Everything").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                Button(L("OK")) { WindowManager.shared.close("settings") }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(16)
        }
        .frame(width: 480, height: 372)
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
    }

    @State private var autoUpdateToggled = false

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(Theme.secondary).gridColumnAlignment(.trailing)
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
