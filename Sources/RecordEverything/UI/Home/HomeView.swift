import AppKit
import SwiftUI

/// Start window with the three recording modes and the recordings list.
struct HomeView: View {
    @ObservedObject private var library = MediaLibrary.shared
    @State private var pendingDelete: MediaItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("Record Everything").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .overlay(alignment: .trailing) {
                IconButton(symbol: "gearshape", size: 26, help: L("Settings")) { AppController.shared.showSettings() }
                    .padding(.trailing, 8)
            }
            .frame(height: 38)

            HStack(spacing: 6) {
                ModeTile(symbol: "rectangle.dashed.badge.record", title: L("Screen")) { AppController.shared.startScreenFlow() }
                ModeTile(symbol: "web.camera", title: L("Camera")) { AppController.shared.showCameraWindow() }
                ModeTile(symbol: "mic", title: L("Audio")) { AppController.shared.showAudioWindow() }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            Rectangle().fill(Theme.separator).frame(height: 1)

            if library.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(Theme.secondary)
                    Text(L("No Videos")).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(library.items) { item in
                            MediaRow(item: item, onDelete: { pendingDelete = item })
                            Rectangle().fill(Theme.separator).frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .onAppear { library.load() }
        .sheet(item: $pendingDelete) { item in
            DeleteConfirmView(item: item) { pendingDelete = nil }
        }
    }
}

private struct ModeTile: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 26, weight: .regular))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.tileHover : Theme.tile))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// One recording: thumbnail, title, "size | duration | format" and the action icons.
struct MediaRow: View {
    let item: MediaItem
    let onDelete: () -> Void
    @State private var info = MediaInfo()
    @State private var thumbnail: NSImage?
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { AppController.shared.showInfo(item) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black)
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                    } else if item.kind == .audio {
                        Image(systemName: "waveform").font(.system(size: 30)).foregroundStyle(Theme.level)
                    }
                    if item.kind != .audio || hover {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(hover ? 1 : 0.85))
                            .shadow(radius: 3)
                    }
                }
                .frame(width: 102, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if item.isNew {
                        Text(L("NEW")).font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent)).padding(4)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Play") + " " + item.title)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(formatFileSize(info.fileSize))  |  \(formatDuration(info.duration))  |  \(info.format)")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                HStack(spacing: 6) {
                    IconButton(symbol: "folder", help: L("Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                    }
                    IconButton(symbol: "trash", help: L("Delete"), action: onDelete)
                    IconButton(symbol: "airplayaudio", help: L("Send via AirDrop")) { Sharing.airDrop(item.url) }
                    ShareButton(url: item.url)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(hover ? Color.white.opacity(0.03) : Color.clear)
        .onHover { hover = $0 }
        .task(id: item.modified) {
            info = await MediaInfoCache.shared.info(for: item.url)
            if item.kind != .audio { thumbnail = await MediaInfoCache.shared.thumbnail(for: item.url) }
        }
    }
}

enum Sharing {
    @MainActor
    static func airDrop(_ url: URL) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
    }
}

/// Share icon that opens the system sharing picker anchored at itself.
struct ShareButton: View {
    let url: URL

    var body: some View {
        IconButton(symbol: "square.and.arrow.up", help: L("Share")) {}
            .overlay(SharingAnchor(url: url))
    }
}

private struct SharingAnchor: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        let v = ClickView()
        v.url = url
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ClickView)?.url = url }

    final class ClickView: NSView {
        var url: URL?
        override func mouseDown(with event: NSEvent) {
            guard let url else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: bounds, of: self, preferredEdge: .minY)
        }
    }
}

/// "Do you want to delete this file?" with the option to also delete the source file.
struct DeleteConfirmView: View {
    let item: MediaItem
    let dismiss: () -> Void
    @State private var deleteFile = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Do you want to delete this file?")).font(.headline)
            Text(item.title).foregroundStyle(Theme.secondary).lineLimit(2)
            Toggle(L("Delete Source File"), isOn: $deleteFile)
            HStack {
                Spacer()
                Button(L("Cancel"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(L("Delete")) {
                    WindowManager.shared.close("info-\(item.id)")
                    WindowManager.shared.close("editor-\(item.id)")
                    MediaLibrary.shared.remove(item, deleteFile: deleteFile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .tint(Theme.record)
            }
        }
        .padding(20)
        .frame(width: 326)
    }
}
