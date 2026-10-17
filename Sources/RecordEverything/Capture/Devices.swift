import AVFoundation
import CoreMedia

/// Serial queue for all sample buffer callbacks and writer access.
let captureQueue = DispatchQueue(label: "recordeverything.capture", qos: .userInitiated)

struct CaptureDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum Devices {
    static func cameras() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func microphones() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func camera(id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .video)
    }

    static func microphone(id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .audio)
    }

    static func requestAccess(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
}

/// Root mean square level of a PCM sample buffer, mapped to 0…1 on a -50…0 dB scale.
func audioLevel(of sampleBuffer: CMSampleBuffer) -> Float {
    guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return 0 }
    var blockBuffer: CMBlockBuffer?
    var size = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &size,
        bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
        flags: 0, blockBufferOut: nil)
    guard size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
        bufferListOut: abl, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer) == noErr
    else { return 0 }

    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
    var sum: Double = 0
    var count = 0
    for buffer in UnsafeMutableAudioBufferListPointer(abl) {
        guard let data = buffer.mData else { continue }
        if isFloat && asbd.mBitsPerChannel == 32 {
            let n = Int(buffer.mDataByteSize) / 4
            let p = data.bindMemory(to: Float.self, capacity: n)
            for i in stride(from: 0, to: n, by: 4) { sum += Double(p[i] * p[i]); count += 1 }
        } else if asbd.mBitsPerChannel == 16 {
            let n = Int(buffer.mDataByteSize) / 2
            let p = data.bindMemory(to: Int16.self, capacity: n)
            for i in stride(from: 0, to: n, by: 4) { let v = Double(p[i]) / 32768; sum += v * v; count += 1 }
        }
    }
    guard count > 0 else { return 0 }
    let rms = sqrt(sum / Double(count))
    let db = 20 * log10(max(rms, 1e-7))
    return Float(min(max((db + 50) / 50, 0), 1))
}

/// Published input levels for the level meters.
@MainActor
final class AudioLevels: ObservableObject {
    static let shared = AudioLevels()
    @Published var microphone: Float = 0
    @Published var system: Float = 0
}
