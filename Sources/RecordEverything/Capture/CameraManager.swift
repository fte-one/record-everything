import AVFoundation

/// Owns the webcam session. Preview layers attach to `session`; frames go to `onFrame` while recording.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = CameraManager()

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "recordeverything.camera.session")
    private var input: AVCaptureDeviceInput?
    private var users = 0

    /// Set on the capture queue; receives camera frames.
    var onFrame: ((CMSampleBuffer) -> Void)?

    private override init() {
        super.init()
        session.sessionPreset = .high
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    /// Starts (or switches) the camera. Every `start` needs a matching `stop`.
    func start(deviceID: String?) async -> Bool {
        guard await Devices.requestAccess(.video) else { return false }
        return await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                users += 1
                let device = Devices.camera(id: deviceID)
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
                cont.resume(returning: input != nil)
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            users = max(0, users - 1)
            if users == 0, session.isRunning { session.stopRunning() }
        }
    }

    /// Pixel size of the active camera format.
    var dimensions: CMVideoDimensions? {
        input.map { CMVideoFormatDescriptionGetDimensions($0.device.activeFormat.formatDescription) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
