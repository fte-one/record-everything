import SwiftUI

/// Audio-only recording window with a segment level meter.
struct AudioRecorderView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var levels = AudioLevels.shared
    @State private var microphones = Devices.microphones()

    private var options: Binding<CaptureOptions> { $settings.audioWindowOptions }
    private var isMine: Bool { recorder.kind == .audio }
    private var recording: Bool { isMine && (recorder.state == .recording || recorder.state == .paused) }

    private var level: Float {
        let mic = settings.audioWindowOptions.microphone ? levels.microphone : 0
        let sys = recording && settings.audioWindowOptions.systemAudio ? levels.system : 0
        return max(mic, sys)
    }

    var body: some View {
        VStack(spacing: 14) {
            LevelMeter(level: level)
                .frame(height: 64)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))

            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ToggleIcon(on: "mic.fill", off: "mic.slash", isOn: options.microphone, help: L("Microphone"), size: 44)
                    DeviceMenu(devices: microphones, selection: options.microphoneID)
                }
                .disabled(recording)
                Spacer()
                HStack(spacing: 0) {
                    Text(formatDuration(isMine ? recorder.elapsed : 0))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .frame(width: 90)
                    Divider().frame(height: 50)
                    RecordButton(recording: recording, size: 34) { toggleRecording() }
                        .frame(width: 82)
                        .disabled(recorder.state == .finishing || (!settings.audioWindowOptions.microphone && !settings.audioWindowOptions.systemAudio))
                    Divider().frame(height: 50)
                    IconButton(symbol: recorder.state == .paused && isMine ? "play.fill" : "pause.fill", size: 34,
                               help: L("Pause"), active: recording) { recorder.togglePause() }
                        .frame(width: 82)
                        .disabled(!recording)
                }
                .frame(height: 50)
                .background(Capsule().fill(Theme.tile))
                Spacer()
                ToggleIcon(on: "speaker.wave.2.fill", off: "speaker.slash", isOn: options.systemAudio, help: L("System sound"), size: 44)
                    .disabled(recording)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 40)
        .padding(.bottom, 14)
        .frame(width: 430, height: 189)
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .onAppear { updateMic() }
        .onChange(of: settings.audioWindowOptions.microphone) { updateMic() }
        .onChange(of: settings.audioWindowOptions.microphoneID) { updateMic() }
        .onDisappear {
            if recording { Task { await recorder.stop() } }
            MicrophoneMonitor.shared.stop()
        }
    }

    private func updateMic() {
        if settings.audioWindowOptions.microphone {
            MicrophoneMonitor.shared.start(deviceID: settings.audioWindowOptions.microphoneID)
        } else if !recording {
            MicrophoneMonitor.shared.stop()
        }
    }

    private func toggleRecording() {
        Task {
            if recording {
                await recorder.stop()
                updateMic()
            } else {
                if settings.audioWindowOptions.systemAudio && !CGPreflightScreenCaptureAccess() {
                    CGRequestScreenCaptureAccess()
                    AppController.shared.showPermissionWindow()
                    return
                }
                do { try await recorder.startAudio(options: settings.audioWindowOptions) } catch { AppController.shared.presentError(error) }
            }
        }
    }
}

/// Row of vertical segments that light up green with the level.
struct LevelMeter: View {
    var level: Float
    var segments = 40

    var body: some View {
        GeometryReader { geo in
            let lit = Int((Float(segments) * level).rounded())
            HStack(spacing: 4) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < lit ? Theme.level : Color.white.opacity(0.18))
                        .frame(height: geo.size.height * 0.5)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.linear(duration: 0.06), value: lit)
        }
    }
}
