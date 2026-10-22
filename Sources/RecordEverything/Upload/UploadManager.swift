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
    /// Object name in the bucket.
    var fileName: String
    var date: Date
    var thumbnailPath: String?
    /// Name of the uploaded file, when it had one worth keeping (shared files, recordings).
    var originalName: String?

    var displayName: String { originalName ?? fileName }
}

/// One file to upload. `name` is what a downloader sees: it travels in Content-Disposition and titles the
/// history entry, while the link itself follows the file name pattern.
struct UploadItem {
    var fileURL: URL
    var name: String?
    /// Fills %filename% in the pattern; defaults to `name` without its extension.
    var originalName: String?
    var thumbnail: NSImage?

    init(fileURL: URL, name: String? = nil, originalName: String? = nil, thumbnail: NSImage? = nil) {
        self.fileURL = fileURL
        self.name = name
        self.originalName = originalName ?? name.map { ($0 as NSString).deletingPathExtension }
        self.thumbnail = thumbnail
    }
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
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return L("Uploading is not set up yet. Add your Cloudflare R2 details in the settings.")
            case .tooLarge(let name): return String(format: L("%@ is larger than 5 GB."), name)
            }
        }
    }

    /// Largest object a single S3 PUT accepts.
    static let maxFileSize: Int64 = 5 * 1024 * 1024 * 1024
    /// From this total size on, notices show a progress bar and a cancel button.
    private static let progressThreshold: Int64 = 2_000_000

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

    /// The client; without one it points out the missing setup and opens the upload settings.
    func requireClient(anchor: CGRect? = nil) -> S3Client? {
        do {
            return try client()
        } catch {
            Toast.shared.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", style: .error, duration: 5, anchor: anchor)
            AppController.shared.showSettings(tab: .upload)
            return nil
        }
    }

    /// Uploads a file, puts the public link on the clipboard and records it. Returns the link.
    @discardableResult
    func upload(fileURL: URL, originalName: String? = nil, thumbnail: NSImage? = nil) async -> URL? {
        await upload([UploadItem(fileURL: fileURL, originalName: originalName, thumbnail: thumbnail)]).first
    }

    /// Uploads files one after another, puts the public links on the clipboard (one per line) and records them.
    /// `anchor` shows the notices below it (the menu bar icon) instead of at the top center. Returns the links.
    @discardableResult
    func upload(_ items: [UploadItem], anchor: CGRect? = nil) async -> [URL] {
        guard !items.isEmpty, let client = requireClient(anchor: anchor) else { return [] }
        let settings = currentSettings
        let sizes = items.map { Self.fileSize($0.fileURL) }
        if let index = sizes.firstIndex(where: { $0 > Self.maxFileSize }) {
            let error = UploadError.tooLarge(items[index].name ?? items[index].fileURL.lastPathComponent)
            Toast.shared.show(L("Upload failed") + ": " + error.localizedDescription, symbol: "xmark.octagon.fill",
                              style: .error, duration: 6, anchor: anchor)
            return []
        }
        let total = sizes.reduce(0, +)
        let showsProgress = total > Self.progressThreshold

        activeUploads += 1
        defer { activeUploads -= 1 }
        var links: [URL] = []
        var failures: [Error] = []
        var cancelled = false
        var sent: Int64 = 0
        for (index, item) in items.enumerated() {
            let ext = item.fileURL.pathExtension.isEmpty ? "bin" : item.fileURL.pathExtension
            let key = FilenamePattern.make(settings.filenamePattern, fileExtension: ext, originalName: item.originalName)
            guard let publicURL = settings.publicURL(for: key) else { continue }
            let done = sent, size = sizes[index]
            let work = Task {
                try await client.putObject(key: key, fileURL: item.fileURL, contentType: Self.contentType(forExtension: item.fileURL.pathExtension),
                                           contentDisposition: item.name.map(Self.contentDisposition)) { fraction in
                    guard showsProgress else { return }
                    Task { @MainActor in Toast.shared.updateProgress((Double(done) + fraction * Double(size)) / Double(total)) }
                }
            }
            let title = items.count > 1 ? String(format: L("Uploading %d of %d…"), index + 1, items.count) : L("Uploading…")
            Toast.shared.show(title, detail: item.name, symbol: "arrow.up.circle", style: .progress, duration: nil, anchor: anchor,
                              action: showsProgress ? Toast.Action(title: L("Cancel")) { work.cancel() } : nil)
            if showsProgress && done > 0 { Toast.shared.updateProgress(Double(done) / Double(total)) }
            do {
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            } catch {
                if work.isCancelled {
                    cancelled = true
                    break
                }
                failures.append(error)
                continue
            }
            sent += size
            links.append(publicURL)
            let thumbnail = saveThumbnail(item.thumbnail ?? NSImage(contentsOf: item.fileURL), key: key)
            UploadHistory.shared.add(UploadRecord(url: publicURL, fileName: key, date: Date(), thumbnailPath: thumbnail, originalName: item.name))
        }

        if !links.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.map(\.absoluteString).joined(separator: "\n"), forType: .string)
            if settings.playSound && !cancelled { NSSound(named: "Glass")?.play() }
        }
        let copied = links.count == 1 ? L("Link copied") : String(format: L("%d links copied"), links.count)
        if cancelled {
            Toast.shared.show(L("Upload cancelled"), detail: links.isEmpty ? nil : copied, symbol: "xmark.circle.fill",
                              style: .info, duration: 2.5, anchor: anchor)
        } else if links.isEmpty, let error = failures.first {
            Toast.shared.show(L("Upload failed") + ": " + error.localizedDescription, symbol: "xmark.octagon.fill",
                              style: .error, duration: 6, anchor: anchor)
        } else if failures.isEmpty {
            Toast.shared.show(copied, detail: links.count == 1 ? links[0].absoluteString : L("One link per line"),
                              symbol: "checkmark.circle.fill", style: .success, duration: 2.5, anchor: anchor)
        } else {
            Toast.shared.show(copied + " · " + String(format: L("%d failed"), failures.count), detail: failures[0].localizedDescription,
                              symbol: "exclamationmark.triangle.fill", style: .error, duration: 6, anchor: anchor)
        }
        return links
    }

    /// Uploads a recording from the library.
    func upload(_ item: MediaItem) {
        Task {
            let thumb = item.kind == .audio ? nil : await MediaInfoCache.shared.thumbnail(for: item.url)
            await upload([UploadItem(fileURL: item.url, name: item.url.lastPathComponent, originalName: item.title, thumbnail: thumb)])
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    /// Text goes out as UTF-8 so browsers show umlauts correctly.
    static func contentType(forExtension ext: String) -> String {
        guard !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType else { return "application/octet-stream" }
        return mime.hasPrefix("text/") ? mime + "; charset=utf-8" : mime
    }

    /// `inline` keeps images, PDFs and videos viewable in the browser; a download keeps the original name
    /// (RFC 6266, with an ASCII fallback and the UTF-8 name of RFC 5987).
    static func contentDisposition(for name: String) -> String {
        // File names come decomposed from the file system ("u" + "¨"); send them composed.
        let name = name.precomposedStringWithCanonicalMapping
        let ascii = name.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? name
        let fallback = String(ascii.map { c -> Character in
            c.unicodeScalars.allSatisfy { (0x20..<0x7F).contains($0.value) } && c != "\"" && c != "\\" ? c : "_"
        })
        return "inline; filename=\"\(fallback)\"; filename*=UTF-8''\(S3Client.encodePath(name))"
    }

    private func saveThumbnail(_ image: NSImage?, key: String) -> String? {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Large enough for the hover preview of files that have no full-size image online.
        let maxSide: CGFloat = 320
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
