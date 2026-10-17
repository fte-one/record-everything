import AVFoundation
import AppKit
import Foundation

/// One recording in the library.
struct MediaItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var path: String
    var kind: MediaKind
    var created: Date
    var modified: Date
    var isNew = true

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Persists the recordings list as JSON in Application Support.
@MainActor
final class MediaLibrary: ObservableObject {
    static let shared = MediaLibrary()

    @Published private(set) var items: [MediaItem] = []

    private let storeURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Record Everything", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("library.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else { return }
        // Recordings deleted in the Finder disappear from the list.
        items = decoded.filter(\.exists).sorted { $0.created > $1.created }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("Record Everything: saving library failed: \(error)")
        }
    }

    @discardableResult
    func add(url: URL, kind: MediaKind, created: Date = Date()) -> MediaItem {
        let item = MediaItem(title: Self.defaultTitle(for: created), path: url.path, kind: kind,
                             created: created, modified: Date())
        items.insert(item, at: 0)
        save()
        return item
    }

    func item(id: UUID) -> MediaItem? { items.first { $0.id == id } }

    func markSeen(_ item: MediaItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }), items[i].isNew else { return }
        items[i].isNew = false
        save()
    }

    /// Removes the entry; with `deleteFile` the file goes to the Trash.
    func remove(_ item: MediaItem, deleteFile: Bool) {
        if deleteFile {
            NSWorkspace.shared.recycle([item.url])
        }
        items.removeAll { $0.id == item.id }
        save()
    }

    enum RenameError: LocalizedError {
        case exists, empty
        var errorDescription: String? {
            switch self {
            case .exists: return L("This file name already exists, please rename.")
            case .empty: return L("Please enter a name.")
            }
        }
    }

    /// Renames the title and the file on disk.
    func rename(_ item: MediaItem, to newTitle: String) throws {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RenameError.empty }
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let target = item.url.deletingLastPathComponent()
            .appendingPathComponent(safe).appendingPathExtension(item.url.pathExtension)
        if target.path != item.path {
            if FileManager.default.fileExists(atPath: target.path) { throw RenameError.exists }
            try FileManager.default.moveItem(at: item.url, to: target)
            items[i].path = target.path
        }
        items[i].title = title
        items[i].modified = Date()
        save()
    }

    /// Called after the editor overwrote or produced a file.
    func touch(_ item: MediaItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].modified = Date()
        save()
        MediaInfoCache.shared.invalidate(item.url)
    }

    static func defaultTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    /// File name for a new recording: "Record Screen 2026-10-17 11.20.33.mp4".
    static func newRecordingURL(kind: MediaKind, in folder: URL, date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Record \(kind.fileLabel) \(f.string(from: date))"
        var url = folder.appendingPathComponent(base).appendingPathExtension(kind.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(kind.fileExtension)
            n += 1
        }
        return url
    }
}

/// File metadata shown in the list and the info window.
struct MediaInfo: Equatable {
    var fileSize: Int64 = 0
    var duration: Double = 0
    var width: Int = 0
    var height: Int = 0
    var fps: Double = 0
    var format: String = ""
    var hasVideo = false
}

@MainActor
final class MediaInfoCache {
    static let shared = MediaInfoCache()
    private var cache: [URL: MediaInfo] = [:]
    private var thumbs: [URL: NSImage] = [:]

    func invalidate(_ url: URL) {
        cache[url] = nil
        thumbs[url] = nil
    }

    func info(for url: URL) async -> MediaInfo {
        if let c = cache[url] { return c }
        var info = MediaInfo()
        info.format = url.pathExtension.lowercased()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        info.fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let asset = AVURLAsset(url: url)
        if let d = try? await asset.load(.duration) { info.duration = d.seconds.isFinite ? d.seconds : 0 }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            info.hasVideo = true
            if let size = try? await track.load(.naturalSize), let t = try? await track.load(.preferredTransform) {
                let s = size.applying(t)
                info.width = Int(abs(s.width).rounded())
                info.height = Int(abs(s.height).rounded())
            }
            if let fps = try? await track.load(.nominalFrameRate) { info.fps = Double(fps) }
        }
        cache[url] = info
        return info
    }

    func thumbnail(for url: URL) async -> NSImage? {
        if let t = thumbs[url] { return t }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 320, height: 200)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let at = CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)
        guard let cg = try? await gen.image(at: at).image else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs[url] = img
        return img
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}

func formatFileSize(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: bytes)
}
