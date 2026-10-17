import AVFoundation

/// Runs the microphone for level metering and hands samples to the writer while recording.
final class MicrophoneMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = MicrophoneMonitor()

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "recordeverything.mic.session")
    private var input: AVCaptureDeviceInput?
    private var lastLevelUpdate = Date.distantPast

    /// Set on the capture queue; receives every microphone sample buffer.
    var onSample: ((CMSampleBuffer) -> Void)?

    private override init() {
        super.init()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    func start(deviceID: String?) {
        Task {
            guard await Devices.requestAccess(.audio) else { return }
            sessionQueue.async { [self] in
                let device = Devices.microphone(id: deviceID)
                if input?.device.uniqueID != device?.uniqueID {
                    session.beginConfiguration()
                    if let input { session.removeInput(input) }
                    input = nil
                    if let device, let newInput = try? AVCaptureDeviceInput(device: device), session.canAddInput(newInput) {
                        session.addInput(newInput)
                        input = newInput
                    }
                    session.commitConfiguration()
                }
                if !session.isRunning { session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
        Task { @MainActor in AudioLevels.shared.microphone = 0 }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSample?(sampleBuffer)
        let now = Date()
        guard now.timeIntervalSince(lastLevelUpdate) > 0.05 else { return }
        lastLevelUpdate = now
        let level = audioLevel(of: sampleBuffer)
        Task { @MainActor in AudioLevels.shared.microphone = level }
    }
}
