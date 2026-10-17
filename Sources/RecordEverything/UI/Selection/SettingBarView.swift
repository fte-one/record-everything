import SwiftUI

/// The bar below the selected area.
struct SettingBarView: View {
    @ObservedObject var model: SelectionBarModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var levels = AudioLevels.shared
    @State private var cameras = Devices.cameras()
    @State private var microphones = Devices.microphones()

    private var options: Binding<CaptureOptions> { $settings.capture }

    var body: some View {
        HStack(spacing: 10) {
            IconButton(symbol: "xmark", size: 24, help: L("Cancel")) { model.close() }

            Divider().frame(height: 24)

            Menu {
                ForEach(AspectPreset.allCases) { preset in
                    Button {
                        model.applyAspect(preset)
                    } label: {
                        if preset == settings.capture.aspect { Label(preset.title, systemImage: "checkmark") } else { Text(preset.title) }
                    }
                }
            } label: {
                Label(settings.capture.aspect.title, systemImage: "aspectratio")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Size"))

            SizeField(value: $model.width) { model.applySize(width: $0, height: model.height) }
            Text("×").foregroundStyle(Theme.secondary)
            SizeField(value: $model.height) { model.applySize(width: model.width, height: $0) }

            Divider().frame(height: 24)

            Menu {
                Section(L("Resolution")) {
                    ForEach(ResolutionPreset.menuOrder) { r in
                        Button {
                            options.wrappedValue.resolution = r
                        } label: {
                            if r == settings.capture.resolution { Label(r.title, systemImage: "checkmark") } else { Text(r.title) }
                        }
                    }
                }
                Section("FPS") {
                    ForEach(FPSPreset.menuOrder) { f in
                        Button {
                            options.wrappedValue.fps = f
                        } label: {
                            if f == settings.capture.fps { Label(f.title, systemImage: "checkmark") } else { Text(f.title) }
                        }
                    }
                }
            } label: {
                VStack(spacing: 0) {
                    Text(settings.capture.resolution.title).font(.system(size: 12, weight: .semibold))
                    Text("\(settings.capture.fps.rawValue) FPS").font(.system(size: 9)).foregroundStyle(Theme.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Resolution and frame rate"))

            Divider().frame(height: 24)

            ToggleIcon(on: "cursorarrow", off: "cursorarrow.slash", isOn: options.showCursor, help: L("Show mouse pointer"))
            HStack(spacing: 2) {
                ToggleIcon(on: "web.camera.fill", off: "web.camera", isOn: cameraBinding, help: L("Webcam"))
                DeviceMenu(devices: cameras, selection: options.cameraID)
            }
            ToggleIcon(on: "speaker.wave.2.fill", off: "speaker.slash", isOn: options.systemAudio, help: L("System sound"))
            HStack(spacing: 2) {
                ToggleIcon(on: "mic.fill", off: "mic.slash", isOn: options.microphone, help: L("Microphone"),
                           level: levels.microphone)
                DeviceMenu(devices: microphones, selection: options.microphoneID)
            }

            RecordButton(recording: false, size: 36) { model.record() }
                .padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .fixedSize()
        .onAppear { updateMicMonitor() }
        .onChange(of: settings.capture.microphone) { updateMicMonitor() }
        .onChange(of: settings.capture.microphoneID) { updateMicMonitor() }
        .onChange(of: settings.capture.cameraID) { if settings.capture.camera { CameraBubble.shared.switchCamera() } }
    }

    private var cameraBinding: Binding<Bool> {
        Binding {
            settings.capture.camera
        } set: { on in
            settings.capture.camera = on
            if on {
                let screen = model.view?.screen ?? NSScreen.main!
                CameraBubble.shared.show(on: screen)
            } else {
                CameraBubble.shared.hide()
            }
        }
    }

    private func updateMicMonitor() {
        if settings.capture.microphone {
            MicrophoneMonitor.shared.start(deviceID: settings.capture.microphoneID)
        } else {
            MicrophoneMonitor.shared.stop()
        }
    }
}

/// Numeric field with up/down arrows.
private struct SizeField: View {
    @Binding var value: Int
    let commit: (Int) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
                .onSubmit { if let v = Int(text) { commit(v) } else { text = "\(value)" } }
            VStack(spacing: 0) {
                Button { commit(value + 10) } label: { Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold)) }
                Button { commit(max(20, value - 10)) } label: { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
        .onAppear { text = "\(value)" }
        .onChange(of: value) { text = "\(value)" }
    }
}
