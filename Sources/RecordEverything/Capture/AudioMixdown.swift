import AVFoundation

/// Mixes all audio tracks of a recording into one AAC track and copies the video untouched.
enum AudioMixdown {
    static func mixIfNeeded(url: URL, fileType: AVFileType) async throws {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1 else { return }
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)").appendingPathExtension(url.pathExtension)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: tmp, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = true

        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(mixOutput)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: RecordingWriter.aacSettings)
        writer.add(audioInput)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(mixOutput, audioInput)]
        if let videoTrack {
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            reader.add(videoOutput)
            let hint = try await videoTrack.load(.formatDescriptions).first
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
            writer.add(videoInput)
            pairs.append((videoOutput, videoInput))
        }

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? RecorderError.writerFailed
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (index, (output, input)) in pairs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "recordeverything.mixdown.\(index)")
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                if let sb = output.copyNextSampleBuffer() {
                                    input.append(sb)
                                } else {
                                    input.markAsFinished()
                                    cont.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw writer.error ?? reader.error ?? RecorderError.writerFailed
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
