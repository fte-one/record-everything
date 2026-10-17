import AVKit
import SwiftUI

/// Player plus file details, rename and share actions.
struct MediaInfoView: View {
    let itemID: UUID
    @ObservedObject private var library = MediaLibrary.shared
    @State private var info = MediaInfo()
    @State private var player: AVPlayer?
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var renameError: String?
    @State private var confirmDelete = false

    private var item: MediaItem? { library.item(id: itemID) }

    var body: some View {
        if let item {
            HStack(spacing: 0) {
                PlayerView(player: player)
                    .background(Color.black)
                details(item)
                    .frame(width: 270)
                    .background(Theme.panel)
            }
            .ignoresSafeArea()
            .task(id: item.modified) {
                info = await MediaInfoCache.shared.info(for: item.url)
                player = AVPlayer(url: item.url)
            }
            .onDisappear { player?.pause() }
            .sheet(isPresented: $confirmDelete) {
                DeleteConfirmView(item: item) { confirmDelete = false }
            }
        } else {
            Text(L("The file no longer exists.")).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func details(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                if editingTitle {
                    TextField("", text: $titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(item) }
                        .onExitCommand { editingTitle = false }
                } else {
                    Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                }
                Spacer()
                IconButton(symbol: editingTitle ? "checkmark" : "pencil", help: L("Rename")) {
                    if editingTitle { commitRename(item) } else { titleDraft = item.title; editingTitle = true }
                }
            }
            if let renameError { Text(renameError).font(.system(size: 11)).foregroundStyle(Theme.record) }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                row(L("File Size:"), formatFileSize(info.fileSize))
                row(L("Duration:"), formatDuration(info.duration))
                row(L("Created:"), item.created.formatted(date: .abbreviated, time: .shortened))
                if info.hasVideo {
                    row(L("Dimensions:"), "\(info.width) × \(info.height)")
                    row(L("FPS:"), info.fps > 0 ? String(format: "%.0f", info.fps) : "--")
                }
                row(L("Format:"), info.format.uppercased())
            }
            .font(.system(size: 12))

            HStack(spacing: 8) {
                IconButton(symbol: "folder", size: 30, help: L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                IconButton(symbol: "trash", size: 30, help: L("Delete")) { confirmDelete = true }
                IconButton(symbol: "airplayaudio", size: 30, help: L("Send via AirDrop")) { Sharing.airDrop(item.url) }
                ShareButton(url: item.url)
                IconButton(symbol: "icloud.and.arrow.up", size: 30, help: L("Upload and copy link"), tint: Theme.accent) {
                    UploadManager.shared.upload(item)
                }
            }

            Spacer()

            Button {
                player?.pause()
                AppController.shared.showEditor(item)
            } label: {
                Label(L("Trim"), systemImage: "scissors").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.top, 44)
        .padding(.bottom, 18)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func commitRename(_ item: MediaItem) {
        do {
            try library.rename(item, to: titleDraft)
            renameError = nil
            editingTitle = false
            WindowManager.shared.window("info-\(item.id)")?.title = titleDraft
        } catch {
            renameError = error.localizedDescription
        }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsSharingServiceButton = false
        v.player = player
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
