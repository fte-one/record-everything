import AVFoundation
import AppKit
import Combine

/// Non-destructive edit list for the trim editor.
/// `segments` are the kept ranges of the original file, in order.
@MainActor
final class EditorModel: ObservableObject {
    let item: MediaItem
    private let asset: AVURLAsset

    @Published private(set) var segments: [CMTimeRange] = []
    @Published private(set) var history: [[CMTimeRange]] = []
    @Published private(set) var duration: Double = 0
    @Published var selection: ClosedRange<Double> = 0...0
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var muted = false { didSet { player.isMuted = muted } }
    @Published private(set) var thumbnails: [NSImage] = []
    @Published private(set) var hasVideo = false
    @Published var busy = false
    @Published var errorMessage: String?

    let player = AVPlayer()
    private var timeObserver: Any?
    private var composition = AVMutableComposition()
    private var originalDuration = CMTime.zero

    init(item: MediaItem) {
        self.item = item
        asset = AVURLAsset(url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = t.seconds.isFinite ? t.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    func cleanup() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    func load() async {
        originalDuration = (try? await asset.load(.duration)) ?? .zero
        hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        segments = [CMTimeRange(start: .zero, duration: originalDuration)]
        await rebuild()
    }

    var hasChanges: Bool { !history.isEmpty }

    // MARK: Edits

    /// Keeps only the selected part (scissors).
    func trimToSelection() {
        let keep = originalRanges(for: selection)
        guard !keep.isEmpty else { return }
        apply(keep)
    }

    /// Removes the selected part (trash).
    func deleteSelection() {
        let remove = originalRanges(for: selection)
        var result: [CMTimeRange] = []
        for seg in segments {
            var pieces = [seg]
            for r in remove {
                pieces = pieces.flatMap { piece -> [CMTimeRange] in
                    let cut = piece.intersection(r)
                    guard !cut.isEmpty else { return [piece] }
                    var out: [CMTimeRange] = []
                    if cut.start > piece.start { out.append(CMTimeRange(start: piece.start, end: cut.start)) }
                    if cut.end < piece.end { out.append(CMTimeRange(start: cut.end, end: piece.end)) }
                    return out
                }
            }
            result.append(contentsOf: pieces.filter { $0.duration.seconds > 0.04 })
        }
        guard !result.isEmpty else { errorMessage = L("At least a part of the video has to remain."); return }
        apply(result)
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        segments = previous
        Task { await rebuild() }
    }

    private func apply(_ newSegments: [CMTimeRange]) {
        history.append(segments)
        segments = newSegments
        Task { await rebuild() }
    }

    /// Maps a range on the edited timeline back to ranges of the original file.
    private func originalRanges(for range: ClosedRange<Double>) -> [CMTimeRange] {
        var result: [CMTimeRange] = []
        var offset = 0.0
        for seg in segments {
            let len = seg.duration.seconds
            let lo = max(range.lowerBound, offset), hi = min(range.upperBound, offset + len)
            if hi > lo {
                let start = seg.start + CMTime(seconds: lo - offset, preferredTimescale: 600)
                result.append(CMTimeRange(start: start, duration: CMTime(seconds: hi - lo, preferredTimescale: 600)))
            }
            offset += len
        }
        return result
    }

    // MARK: Composition

    private func makeComposition(includeAudio: Bool) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = includeAudio ? try await asset.loadTracks(withMediaType: .audio) : []
        var pairs: [(AVAssetTrack, AVMutableCompositionTrack)] = []
        for t in videoTracks + audioTracks {
            if let ct = comp.addMutableTrack(withMediaType: t.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) {
                ct.preferredTransform = (try? await t.load(.preferredTransform)) ?? .identity
                pairs.append((t, ct))
            }
        }
        var cursor = CMTime.zero
        for seg in segments {
            for (src, dst) in pairs {
                let range = (try? await src.load(.timeRange)).map { seg.intersection($0) } ?? seg
                guard !range.isEmpty else { continue }
                try dst.insertTimeRange(range, of: src, at: cursor + (range.start - seg.start))
            }
            cursor = cursor + seg.duration
        }
        return comp
    }

    private func rebuild() async {
        do {
            composition = try await makeComposition(includeAudio: true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        duration = composition.duration.seconds
        selection = 0...duration
        if currentTime > duration { seek(to: 0) }
        let wasPlaying = player.rate != 0
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        player.isMuted = muted
        if wasPlaying { player.play() }
        await makeThumbnails()
    }

    private func makeThumbnails() async {
        guard hasVideo, duration > 0 else { thumbnails = []; return }
        let gen = AVAssetImageGenerator(asset: composition)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 100)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let count = 14
        var images: [NSImage] = []
        for i in 0..<count {
            let t = CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let cg = try? await gen.image(at: t).image {
                images.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        thumbnails = images
    }

    // MARK: Playback

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), duration)
        currentTime = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }

    // MARK: Export

    /// Writes the edited result. With `replace` the original file is overwritten.
    func export(to url: URL, replace: Bool) async -> Bool {
        busy = true
        defer { busy = false }
        player.pause()
        do {
            let comp = try await makeComposition(includeAudio: !muted)
            let isAudio = !hasVideo
            let fileType: AVFileType = isAudio ? .m4a : .mp4
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString)").appendingPathExtension(url.pathExtension)
            try await exportComposition(comp, to: tmp, fileType: fileType, isAudio: isAudio)
            if replace {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            errorMessage = L("Failed to save, please try again") + "\n" + error.localizedDescription
            return false
        }
    }

    private func exportComposition(_ comp: AVComposition, to url: URL, fileType: AVFileType, isAudio: Bool) async throws {
        // Passthrough keeps the original quality; re-encoding is the fallback.
        let presets = isAudio ? [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A]
                              : [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        var lastError: Error?
        for preset in presets {
            guard let session = AVAssetExportSession(asset: comp, presetName: preset) else { continue }
            session.shouldOptimizeForNetworkUse = true
            do {
                try? FileManager.default.removeItem(at: url)
                try await session.export(to: url, as: fileType)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RecorderError.writerFailed
    }
}
