import Foundation

/// OpenRouter: speech to text (dictated notes, feedback sessions) and chat completions (the feedback prompt).
enum OpenRouter {
    private static let keychainAccount = "openrouter"

    static var apiKey: String? {
        get { Keychain.get(keychainAccount).flatMap { $0.isEmpty ? nil : $0 } }
        set { Keychain.set(newValue?.trimmingCharacters(in: .whitespacesAndNewlines), for: keychainAccount) }
    }

    /// The key to use: the stored one, or the self-test's.
    private static var effectiveKey: String? {
        apiKey ?? UserDefaults.standard.string(forKey: "RecordEverythingTestOpenRouterKey")
    }

    static var hasKey: Bool { effectiveKey != nil }

    /// The self-test points this at a local stand-in server.
    private static var baseURL: URL {
        if let test = UserDefaults.standard.string(forKey: "RecordEverythingTestOpenRouterBase"), let url = URL(string: test) { return url }
        return URL(string: "https://openrouter.ai/api/v1")!
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Checks the stored key against OpenRouter.
    static func checkKey() async throws {
        guard let key = apiKey else { throw Failure(message: L("Add an OpenRouter key under Settings › Dictation.")) }
        var request = URLRequest(url: baseURL.appendingPathComponent("key"), timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(status: status, data: data, prefix: nil) }
    }

    /// Transcribes with the model and language from the Dictation settings.
    @MainActor
    static func transcribe(fileURL: URL) async throws -> String {
        let settings = AppSettings.shared
        return try await transcribe(fileURL: fileURL,
                                    model: settings.dictationModel.isEmpty ? AppSettings.defaultDictationModel : settings.dictationModel,
                                    language: settings.dictationLanguage)
    }

    static func transcribe(fileURL: URL, model: String, language: String) async throws -> String {
        let audio = try Data(contentsOf: fileURL)
        var body: [String: Any] = [
            "model": model,
            "input_audio": ["data": audio.base64EncodedString(), "format": fileURL.pathExtension.lowercased()],
        ]
        if !language.isEmpty { body["language"] = language }
        let json = try await post("audio/transcriptions", body: body, timeout: 90, errorPrefix: L("Transcription failed"))
        guard let text = json["text"] as? String else {
            throw Failure(message: L("Transcription failed: no text in the answer."))
        }
        return text
    }

    /// One chat completion; `content` is the user message (text and image parts). Returns the answer text.
    static func chat(model: String, system: String, content: [[String: Any]], maxTokens: Int) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content],
            ],
        ]
        let json = try await post("chat/completions", body: body, timeout: 300, errorPrefix: L("The AI request failed"))
        guard let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else {
            throw Failure(message: L("The AI request failed: no answer."))
        }
        if let text = message["content"] as? String { return text }
        // Some providers answer with content parts.
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        throw Failure(message: L("The AI request failed: no answer."))
    }

    private static func post(_ path: String, body: [String: Any], timeout: TimeInterval, errorPrefix: String) async throws -> [String: Any] {
        guard let key = effectiveKey else {
            throw Failure(message: L("Add an OpenRouter key under Settings › Dictation."))
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://github.com/fte-one/record-everything", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Record Everything", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(status: status, data: data, prefix: errorPrefix) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: errorPrefix + ": " + L("the answer could not be read."))
        }
        if let error = json["error"] as? [String: Any] {
            throw Failure(message: errorPrefix + ": " + ((error["message"] as? String) ?? "?"))
        }
        return json
    }

    private static func failure(status: Int, data: Data, prefix: String?) -> Failure {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return Failure(message: (prefix.map { "\($0) " } ?? "") + "(\(status)): \(message)")
    }
}
