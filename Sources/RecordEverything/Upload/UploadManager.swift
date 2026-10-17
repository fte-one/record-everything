import AppKit
import UniformTypeIdentifiers

/// Where uploads go: an S3 bucket (Cloudflare R2 by default) and the public URL that serves its objects.
/// Starts empty; every user enters their own storage in the settings.
struct UploadSettings: Codable, Equatable {
    var accountID = ""
    /// Overrides the R2 endpoint for other S3-compatible storage.
    var customEndpoint = ""
    var bucket = ""
    var region = "auto"
    var publicBaseURL = ""
    var filenamePattern = "%month%%random-5%"
    var playSound = true
    var historyCount = 10

    var endpoint: URL? {
        let raw = customEndpoint.trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty { return URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)") }
        let account = accountID.trimmingCharacters(in: .whitespaces)
        return account.isEmpty ? nil : URL(string: "https://\(account).r2.cloudflarestorage.com")
    }

    func publicURL(for key: String) -> URL? {
        var base = publicBaseURL.trimmingCharacters(in: .whitespaces)
        guard let scheme = URL(string: base)?.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        if !base.hasSuffix("/") { base += "/" }
        let path = key.split(separator: "/").map { S3Client.encodePath(String($0)) }.joined(separator: "/")
        return URL(string: base + path)
    }
}

/// Builds object names from a pattern like Dropshare's: %month%%random-5% -> "10aB3xZ".
enum FilenamePattern {
    static let tokens = ["%random-5%", "%month%", "%day%", "%year%", "%date%", "%time%", "%filename%"]

    static func make(_ pattern: String, fileExtension: String, originalName: String? = nil, date: Date = Date()) -> String {
        var result = pattern.isEmpty ? "%month%%random-5%" : pattern
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        func fmt(_ p: String) -> String { f.dateFormat = p; return f.string(from: date) }
        result = result.replacingOccurrences(of: "%month%", with: fmt("MM"))
            .replacingOccurrences(of: "%day%", with: fmt("dd"))
            .replacingOccurrences(of: "%year%", with: fmt("yyyy"))
            .replacingOccurrences(of: "%date%", with: fmt("yyyy-MM-dd"))
            .replacingOccurrences(of: "%time%", with: fmt("HHmmss"))
            .replacingOccurrences(of: "%filename%", with: originalName ?? "file")
        // %random-N% with any length N.
        while let range = result.range(of: #"%random-(\d+)%"#, options: .regularExpression) {
            let digits = result[range].dropFirst("%random-".count).dropLast()
            let count = min(max(Int(digits) ?? 5, 1), 64)
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            result.replaceSubrange(range, with: String((0..<count).map { _ in alphabet.randomElement()! }))
        }
        let safe = result.map { c -> Character in
            c.isASCII && (c.isLetter || c.isNumber || "-_./".contains(c)) ? c : "-"
        }
        return String(safe) + "." + fileExtension.lowercased()
    }
}

/// One finished upload, shown in the menu bar popover.
struct UploadRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var fileName: String
    var date: Date
    var thumbnailPath: String?
}

@MainActor
final class UploadHistory: ObservableObject {
    static let shared = UploadHistory()

    @Published private(set) var records: [UploadRecord] = []
    private let storeURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Record Everything", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("uploads.json")
        if let data = try? Data(contentsOf: storeURL), let list = try? JSONDecoder().decode([UploadRecord].self, from: data) {
            records = list
        }
    }

    func add(_ record: UploadRecord) {
        records.insert(record, at: 0)
        if records.count > 50 { records.removeLast(records.count - 50) }
        save()
    }

    func remove(_ record: UploadRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    private func save() {
        try? JSONEncoder().encode(records).write(to: storeURL, options: .atomic)
    }
}

/// Uploads files, copies the link and keeps the history (Dropshare's core flow).
@MainActor
final class UploadManager: ObservableObject {
    static let shared = UploadManager()

    @Published private(set) var activeUploads = 0
    /// Self test only: credentials and target that bypass keychain and settings.
    var testOverride: (settings: UploadSettings, accessKey: String, secret: String)?

    enum UploadError: LocalizedError {
        case notConfigured
        var errorDescription: String? { L("Uploading is not set up yet. Add your Cloudflare R2 details in the settings.") }
    }

    var accessKeyID: String {
        get { Keychain.get("accessKeyID") ?? "" }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "accessKeyID"); objectWillChange.send() }
    }

    var secretAccessKey: String {
        get { Keychain.get("secretAccessKey") ?? "" }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "secretAccessKey"); objectWillChange.send() }
    }

    var isConfigured: Bool { (try? client()) != nil }

    private var currentSettings: UploadSettings { testOverride?.settings ?? AppSettings.shared.upload }

    func client() throws -> S3Client {
        let settings = currentSettings
        let access = testOverride?.accessKey ?? accessKeyID, secret = testOverride?.secret ?? secretAccessKey
        guard let endpoint = settings.endpoint, !settings.bucket.isEmpty, !access.isEmpty, !secret.isEmpty,
              settings.publicURL(for: "x") != nil else { throw UploadError.notConfigured }
        return S3Client(endpoint: endpoint, bucket: settings.bucket, region: settings.region.isEmpty ? "auto" : settings.region,
                        accessKeyID: access, secretAccessKey: secret)
    }

    /// Writes and deletes a small test object.
    func testConnection() async throws -> URL {
        let client = try client()
        let key = ".record-everything-test-\(UUID().uuidString.prefix(8)).txt"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        try Data("Record Everything".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await client.putObject(key: key, fileURL: file, contentType: "text/plain")
        try? await client.deleteObject(key: key)
        return currentSettings.publicURL(for: key)!
    }

    /// Uploads a file, puts the public link on the clipboard and records it. Returns the link.
    @discardableResult
    func upload(fileURL: URL, originalName: String? = nil, thumbnail: NSImage? = nil) async -> URL? {
        let settings = currentSettings
        let client: S3Client
        do {
            client = try self.client()
        } catch {
            Toast.shared.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .error, duration: 5)
            AppController.shared.showSettings(tab: .upload)
            return nil
        }
        let ext = fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension
        let key = FilenamePattern.make(settings.filenamePattern, fileExtension: ext, originalName: originalName)
        let contentType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        guard let publicURL = settings.publicURL(for: key) else { return nil }

        activeUploads += 1
        defer { activeUploads -= 1 }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        Toast.shared.show(L("Uploading…"), symbol: "arrow.up.circle", style: .progress, duration: nil)
        do {
            try await client.putObject(key: key, fileURL: fileURL, contentType: contentType) { fraction in
                guard size > 2_000_000 else { return }
                Task { @MainActor in Toast.shared.updateProgress(fraction) }
            }
        } catch {
            Toast.shared.show(L("Upload failed") + ": " + error.localizedDescription, symbol: "xmark.octagon.fill", style: .error, duration: 6)
            return nil
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicURL.absoluteString, forType: .string)
        UploadHistory.shared.add(UploadRecord(url: publicURL, fileName: key, date: Date(),
                                              thumbnailPath: saveThumbnail(thumbnail ?? NSImage(contentsOf: fileURL), key: key)))
        if settings.playSound { NSSound(named: "Glass")?.play() }
        Toast.shared.show(L("Link copied"), detail: publicURL.absoluteString, symbol: "checkmark.circle.fill", style: .success, duration: 2.5)
        return publicURL
    }

    /// Uploads a recording from the library.
    func upload(_ item: MediaItem) {
        Task {
            let thumb = item.kind == .audio ? nil : await MediaInfoCache.shared.thumbnail(for: item.url)
            await upload(fileURL: item.url, originalName: item.title, thumbnail: thumb)
        }
    }

    private func saveThumbnail(_ image: NSImage?, key: String) -> String? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let maxSide: CGFloat = 160
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let size = NSSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)
        let small = NSImage(size: size)
        small.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: .zero).draw(in: NSRect(origin: .zero, size: size))
        small.unlockFocus()
        guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = Screenshots.cacheFolder.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
        return (try? png.write(to: url)) != nil ? url.path : nil
    }
}
