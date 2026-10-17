import AVFoundation
import SwiftUI

/// Webcam recording window.
struct CameraRecorderView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var levels = AudioLevels.shared
    @State private var cameras = Devices.cameras()
    @State private var microphones = Devices.microphones()
    @State private var cameraReady = false
    @State private var error: String?

    private var options: Binding<CaptureOptions> { $settings.cameraWindowOptions }
    private var isMine: Bool { recorder.kind == .camera }
    private var recording: Bool { isMine && (recorder.state == .recording || recorder.state == .paused) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            CameraPreview(session: CameraManager.shared.session)
            if !cameraReady {
                VStack(spacing: 8) {
                    Image(systemName: "web.camera").font(.system(size: 36))
                    Text(error ?? L("Starting camera…"))
                }
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            controls.padding(.bottom, 14)
        }
        .ignoresSafeArea()
        .task { await startPreview() }
        .onChange(of: settings.cameraWindowOptions.cameraID) { Task { await switchCamera() } }
        .onChange(of: settings.cameraWindowOptions.microphone) { updateMic() }
        .onChange(of: settings.cameraWindowOptions.microphoneID) { updateMic() }
        .onDisappear {
            if recording { Task { await recorder.stop() } }
            CameraManager.shared.stop()
            MicrophoneMonitor.shared.stop()
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            ToggleIcon(on: "speaker.wave.2.fill", off: "speaker.slash", isOn: options.systemAudio, help: L("System sound"))
                .disabled(recording)
            HStack(spacing: 2) {
                ToggleIcon(on: "mic.fill", off: "mic.slash", isOn: options.microphone, help: L("Microphone"), level: levels.microphone)
                DeviceMenu(devices: microphones, selection: options.microphoneID)
            }
            .disabled(recording)
            HStack(spacing: 2) {
                Image(systemName: "web.camera.fill").frame(width: 30, height: 30)
                DeviceMenu(devices: cameras, selection: options.cameraID)
            }
            .disabled(recording)

            Text(formatDuration(isMine ? recorder.elapsed : 0))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .frame(minWidth: 80)

            RecordButton(recording: recording, size: 36) { toggleRecording() }
                .disabled(!cameraReady || recorder.state == .finishing)
            IconButton(symbol: recorder.state == .paused && isMine ? "play.fill" : "pause.fill", size: 30,
                       help: L("Pause"), active: recording) { recorder.togglePause() }
                .disabled(!recording)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.panel.opacity(0.92)))
    }

    private func startPreview() async {
        cameraReady = await CameraManager.shared.start(deviceID: settings.cameraWindowOptions.cameraID)
        if !cameraReady { error = L("No webcam found, please check your device!") }
        updateMic()
    }

    private func switchCamera() async {
        cameraReady = await CameraManager.shared.start(deviceID: settings.cameraWindowOptions.cameraID)
        CameraManager.shared.stop()
    }

    private func updateMic() {
        if settings.cameraWindowOptions.microphone {
            MicrophoneMonitor.shared.start(deviceID: settings.cameraWindowOptions.microphoneID)
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
                if settings.cameraWindowOptions.systemAudio && !CGPreflightScreenCaptureAccess() {
                    CGRequestScreenCaptureAccess()
                    AppController.shared.showPermissionWindow()
                    return
                }
                do { try await recorder.startCamera(options: settings.cameraWindowOptions) } catch { AppController.shared.presentError(error) }
            }
        }
    }
}

/// Mirrored live preview of the shared camera session.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = PreviewView()
        view.preview.session = session
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class PreviewView: NSView {
        let preview = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            preview.videoGravity = .resizeAspect
            layer?.addSublayer(preview)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            preview.frame = bounds
            if let c = preview.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
        }
    }
}
