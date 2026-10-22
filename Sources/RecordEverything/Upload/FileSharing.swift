import AppKit
import QuickLookThumbnailing

/// Shares any file: choose it in the menu or drop it at the menu bar icon, it goes up and the link lands on the
/// clipboard. Folders (and packages such as .key documents) go up as a ZIP archive.
@MainActor
enum FileSharing {
    /// Open panel for one or more files or folders; the notices appear below the menu bar icon.
    static func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Upload")
        panel.message = L("The links land on the clipboard. Folders are uploaded as a ZIP archive.")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK else { return }
            upload(panel.urls, anchor: AppController.shared.statusItemFrame)
        }
    }

    static func upload(_ urls: [URL], anchor: CGRect?) {
        Task { await uploadNow(urls, anchor: anchor) }
    }

    /// Prepares the files (ZIP for folders, thumbnails) and uploads them. Returns the links.
    @discardableResult
    static func uploadNow(_ urls: [URL], anchor: CGRect?) async -> [URL] {
        guard !urls.isEmpty, UploadManager.shared.requireClient(anchor: anchor) != nil else { return [] }
        // Right away, so the drop is answered before thumbnails and archives are ready.
        Toast.shared.show(L("Uploading…"), detail: summary(urls), symbol: "arrow.up.circle", style: .progress, duration: nil, anchor: anchor)

        let workFolder = Screenshots.cacheFolder.appendingPathComponent("Shared Files/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }
        var items: [UploadItem] = []
        for url in urls {
            let thumbnail = await thumbnail(for: url)
            guard isFolder(url) else {
                items.append(UploadItem(fileURL: url, name: url.lastPathComponent, thumbnail: thumbnail))
                continue
            }
            Toast.shared.show(L("Compressing folder…"), detail: url.lastPathComponent, symbol: "archivebox", style: .progress,
                              duration: nil, anchor: anchor)
            do {
                let archive = try await Task.detached { try FileSharing.archive(url, into: workFolder) }.value
                items.append(UploadItem(fileURL: archive, name: archive.lastPathComponent, thumbnail: thumbnail))
            } catch {
                Toast.shared.show(L("Could not compress the folder") + ": " + error.localizedDescription, symbol: "xmark.octagon.fill",
                                  style: .error, duration: 6, anchor: anchor)
                return []
            }
        }
        return await UploadManager.shared.upload(items, anchor: anchor)
    }

    /// "Contract.pdf · 2.4 MB", "Project · as ZIP archive" or "3 files · 12 MB".
    static func summary(_ urls: [URL]) -> String {
        if urls.count == 1, let url = urls.first {
            return url.lastPathComponent + " · " + (isFolder(url) ? L("as ZIP archive") : formatFileSize(fileSize(url)))
        }
        let files = urls.filter { !isFolder($0) }
        var parts = [String(format: L("%d files"), urls.count)]
        if !files.isEmpty { parts.append(formatFileSize(files.map(fileSize).reduce(0, +))) }
        if files.count < urls.count { parts.append(L("folders as ZIP")) }
        return parts.joined(separator: " · ")
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    /// Quick Look picture of the file (first page, video frame, …), else its Finder icon.
    private static func thumbnail(for url: URL) async -> NSImage {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 320), scale: 1, representationTypes: .all)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 256, height: 256)
        return icon
    }

    /// Archives a folder the way Finder's "Compress" does; the ZIP keeps the folder's name.
    private nonisolated static func archive(_ folder: URL, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(folder.lastPathComponent + ".zip")
        var coordinationError: NSError?
        var moveError: Error?
        // The coordinator hands out a temporary ZIP that only lives during the block.
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zip in
            do { try FileManager.default.moveItem(at: zip, to: target) } catch { moveError = error }
        }
        if let error = coordinationError ?? moveError { throw error }
        return target
    }
}
