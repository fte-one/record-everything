import AppKit
import ImageIO

/// What a session folder holds besides feedback.md and the images, so the history can list and reopen it.
struct FeedbackMeta: Codable {
    struct ImageMeta: Codable {
        var number: Int
        var file: String
        var time: TimeInterval
        var url: String?
        var title: String?
    }

    var title: String
    var date: Date
    var duration: TimeInterval
    var taskCount: Int
    var warning: String?
    var imageMode: FeedbackImageMode?
    var images: [ImageMeta]

    static let fileName = "session.json"
}

/// The feedback sessions saved under Save Location › Feedback, newest first (the "Feedback" tab of the history).
@MainActor
final class FeedbackHistory: ObservableObject {
    static let shared = FeedbackHistory()

    struct Item: Identifiable, Equatable {
        let folder: URL
        let title: String
        let date: Date
        let duration: TimeInterval?
        let imageCount: Int
        let thumbnail: NSImage?
        var id: String { folder.path }

        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.title == b.title && a.date == b.date }
    }

    @Published private(set) var items: [Item] = []

    private var root: URL { AppSettings.shared.saveFolder.appendingPathComponent("Feedback", isDirectory: true) }

    private init() { reload() }

    func reload() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        items = folders.compactMap { folder in
            let markdown = folder.appendingPathComponent("feedback.md")
            guard fm.fileExists(atPath: markdown.path) else { return nil }
            let meta = Self.meta(in: folder)
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let images = meta?.images.count ?? Self.imageFiles(in: folder).count
            let title = meta?.title ?? Self.title(of: markdown) ?? folder.lastPathComponent
            return Item(folder: folder, title: title, date: meta?.date ?? created, duration: meta?.duration,
                        imageCount: images, thumbnail: Self.thumbnail(folder.appendingPathComponent("01.png")))
        }
        .sorted { $0.date > $1.date }
    }

    /// Opens the review window of a saved session again.
    func open(_ item: Item) {
        guard let result = Self.result(for: item.folder) else { return }
        FeedbackReview.show(result)
    }

    func copyPrompt(_ item: Item) {
        guard let markdown = try? String(contentsOf: item.folder.appendingPathComponent("feedback.md"), encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        Toast.shared.show(L("Prompt copied"), symbol: "doc.on.clipboard.fill", style: .success, duration: 1.8)
    }

    func showInFinder(_ item: Item) {
        NSWorkspace.shared.activateFileViewerSelecting([item.folder.appendingPathComponent("feedback.md")])
    }

    /// Moves the session folder to the Trash.
    func trash(_ item: Item) {
        try? FileManager.default.trashItem(at: item.folder, resultingItemURL: nil)
        reload()
    }

    /// Remembers the chosen way of handing over the images for this session.
    static func setImageMode(_ mode: FeedbackImageMode, in folder: URL) {
        guard var meta = meta(in: folder) else { return }
        meta.imageMode = mode
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(meta).write(to: folder.appendingPathComponent(FeedbackMeta.fileName))
    }

    // MARK: Reading a folder

    static func result(for folder: URL) -> FeedbackResult? {
        let markdownFile = folder.appendingPathComponent("feedback.md")
        guard let markdown = try? String(contentsOf: markdownFile, encoding: .utf8) else { return nil }
        let meta = meta(in: folder)
        let images: [FeedbackResult.Image]
        if let meta {
            images = meta.images.map { m in
                let file = folder.appendingPathComponent(m.file)
                return .init(number: m.number, file: file,
                             shot: FeedbackShot(id: m.number, time: m.time, kind: .mark, file: file, pixelSize: .zero, url: m.url, title: m.title))
            }
        } else {
            images = imageFiles(in: folder).enumerated().map { index, file in
                .init(number: index + 1, file: file, shot: FeedbackShot(id: index + 1, time: 0, kind: .mark, file: file, pixelSize: .zero))
            }
        }
        return FeedbackResult(folder: folder, markdownFile: markdownFile, markdown: markdown, images: images,
                              taskCount: meta?.taskCount ?? 0, duration: meta?.duration ?? 0, warning: meta?.warning,
                              imageMode: meta?.imageMode ?? .paths)
    }

    private static func meta(in folder: URL) -> FeedbackMeta? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(FeedbackMeta.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FeedbackMeta.self, from: data)
    }

    private static func imageFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" && Int($0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// "# Feedback: Shop page" → "Shop page".
    private static func title(of markdown: URL) -> String? {
        guard let text = try? String(contentsOf: markdown, encoding: .utf8),
              let first = text.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) else { return nil }
        let title = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return title.hasPrefix("Feedback: ") ? String(title.dropFirst("Feedback: ".count)) : title
    }

    private static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}
