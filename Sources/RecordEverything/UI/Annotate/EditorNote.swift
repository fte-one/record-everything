import AVFoundation
import AppKit

/// The text that goes along with the screenshot: dictated while Control is held (transcribed by OpenRouter),
/// or pasted into the editor with ⌘V – which is how Wispr Flow delivers its dictation.
@MainActor
final class EditorNote: ObservableObject {
    enum State: Equatable { case idle, listening, transcribing, failed(String) }

    @Published var text = ""
    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0
    /// Called when the text ends with a spoken command such as "in Claude einfügen" (already removed).
    var onCommand: ((VoiceCommand.Target) -> Void)?
    /// The app the screenshot came from; "in <its name> einfügen" pastes there.
    var origin: NSRunningApplication?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var startedAt = Date()
    private var meterTimer: Timer?
    /// Loudest moment of the recording in dBFS: silence is not sent off (it makes speech models invent text).
    private var peakPower: Float = -160

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Adds text (dictated or pasted) and runs a trailing voice command.
    func append(_ addition: String) {
        let addition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return }
        text = isEmpty ? addition : text.trimmingCharacters(in: .whitespacesAndNewlines) + " " + addition
        if let command = VoiceCommand.parse(text, origin: origin, targets: AppSettings.shared.pasteTargets) {
            text = command.remainder
            onCommand?(command.target)
        }
    }

    // MARK: Dictation

    var isListening: Bool { state == .listening }

    /// Starts recording right away, so the first word is not lost; `stopListening` discards very short presses.
    func startListening() {
        guard state != .listening, state != .transcribing else { return }
        guard OpenRouter.apiKey != nil else {
            state = .failed(L("Add an OpenRouter key under Settings › Dictation."))
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            state = .failed(L("Microphone access is off (System Settings › Privacy & Security › Microphone)."))
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            state = .failed(L("The microphone could not be started."))
            return
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            state = .failed(L("The microphone could not be started."))
            return
        }
        self.recorder = recorder
        recordingURL = url
        startedAt = Date()
        peakPower = -160
        state = .listening
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                self.peakPower = max(self.peakPower, power)
                self.level = max(0, min(1, (power + 50) / 50))
            }
        }
    }

    /// Stops recording and transcribes; a press shorter than ~0.4 s (a stray Control tap) or one without
    /// anything said is dropped.
    func stopListening(discard: Bool = false) {
        guard state == .listening, let recorder, let url = recordingURL else { return }
        recorder.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        self.recorder = nil
        recordingURL = nil
        level = 0
        if discard || Date().timeIntervalSince(startedAt) < 0.4 || peakPower < -42 {
            try? FileManager.default.removeItem(at: url)
            state = .idle
            return
        }
        state = .transcribing
        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let text = try await OpenRouter.transcribe(fileURL: url)
                state = .idle
                append(text)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Transcribes an existing file as if it had just been dictated (self-test).
    func transcribeForTest(_ url: URL) async {
        state = .transcribing
        do {
            let text = try await OpenRouter.transcribe(fileURL: url)
            state = .idle
            append(text)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func dismissError() {
        if case .failed = state { state = .idle }
    }

    /// The editor closed: stop the microphone and forget the recording.
    func cancel() {
        stopListening(discard: true)
    }
}

/// "… in Claude einfügen" / "… paste into Codex" at the end of the note.
@MainActor
enum VoiceCommand {
    enum Target: Equatable {
        case origin
        case fixed(PasteTarget)
    }

    struct Match {
        let target: Target
        let remainder: String
    }

    /// Spelling that transcription produces for the default apps' names.
    private static let aliases: [String: [String]] = [
        "claude": ["claude", "cloud", "claud", "clod", "klaude", "klod", "clode", "klot"],
        "codex": ["codex", "codecs", "kodex", "kodecs", "codeks"],
        "t3code": ["t3code", "tcode", "teethreecode", "teedreicode", "tdreicode", "t3"],
    ]

    private static let verbs = ["einfugen", "einfuegen", "schicken", "senden", "pasten", "posten"]
    private static let prepositions = ["in", "an", "nach", "zu", "ins"]

    static func parse(_ text: String, origin: NSRunningApplication?, targets: [PasteTarget]) -> Match? {
        // Words with their ranges, so the command can be cut off the original text.
        var words: [(word: String, range: Range<String.Index>)] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            if let word { words.append((normalize(word), range)) }
        }
        guard words.count >= 2 else { return nil }
        let last = words[words.count - 1].word
        let englishPaste = ["paste", "send"]
        var nameWords: ArraySlice<(word: String, range: Range<String.Index>)>
        var commandStart: Int

        if verbs.contains(last) {
            // "<prep> <name …> einfügen": the name is up to three words between preposition and verb.
            guard let prepIndex = (max(0, words.count - 5)..<(words.count - 1)).last(where: { prepositions.contains(words[$0].word) }),
                  prepIndex < words.count - 2 else { return nil }
            nameWords = words[(prepIndex + 1)..<(words.count - 1)]
            commandStart = prepIndex
        } else if let verbIndex = (max(0, words.count - 5)..<words.count).last(where: { englishPaste.contains(words[$0].word) }),
                  verbIndex + 2 < words.count, ["into", "in", "to"].contains(words[verbIndex + 1].word) {
            // "paste into <name …>"
            nameWords = words[(verbIndex + 2)...]
            commandStart = verbIndex
        } else {
            return nil
        }
        guard nameWords.count <= 3 else { return nil }
        let spoken = nameWords.map(\.word).joined()
        guard let target = resolve(spoken, origin: origin, targets: targets) else { return nil }

        var remainder = String(text[..<words[commandStart].range.lowerBound])
        // "… und in Claude einfügen" / "… and paste into Claude": drop the joining word too.
        if commandStart > 0, ["und", "and", "dann", "then"].contains(words[commandStart - 1].word) {
            remainder = String(text[..<words[commandStart - 1].range.lowerBound])
        }
        remainder = remainder.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:–-")))
        return Match(target: target, remainder: remainder)
    }

    private static func resolve(_ spoken: String, origin: NSRunningApplication?, targets: [PasteTarget]) -> Target? {
        func matches(_ name: String) -> Bool {
            let key = normalize(name)
            guard !key.isEmpty else { return false }
            return key == spoken || (aliases[key]?.contains(spoken) ?? false)
        }
        if let origin, matches(PasteIntoApp.displayName(of: origin)) { return .origin }
        if let target = targets.first(where: { matches($0.name) }) { return .fixed(target) }
        return nil
    }

    /// Lowercase letters and digits only, umlauts folded: "Einfügen" → "einfugen", "T3 Code" → "t3code".
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
