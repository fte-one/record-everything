import AppKit
import SwiftUI

/// The app's main surface: screenshot actions, recording, recent uploads and recordings (replaces the home window).
struct StatusPopoverView: View {
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var history = UploadHistory.shared
    @ObservedObject private var library = MediaLibrary.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var uploads = UploadManager.shared
    @AppStorage("popoverListTab") private var listTab = "uploads"
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            header

            if recorder.isActive { recordingControls }

            section(L("Screenshot")) {
                QuickAction(symbol: "camera.viewfinder", badge: "pencil", title: L("Annotate"),
                            subtitle: settings.captureAnnotateHotKey.display) { run(delay: true) { Screenshots.captureAndAnnotate() } }
                QuickAction(symbol: "camera.viewfinder", badge: "arrow.up", title: L("Upload & copy link"),
                            subtitle: settings.captureUploadHotKey.display) { run(delay: true) { Screenshots.captureAndUpload() } }
                QuickAction(symbol: "camera.viewfinder", badge: "doc.on.doc", title: L("Copy image"),
                            subtitle: L("one click")) { run(delay: true) { Screenshots.captureAndCopy() } }
            }

            section(L("Record")) {
                RecordTile(symbol: "rectangle.dashed.badge.record", title: L("Screen"), subtitle: settings.startPauseHotKey.display) {
                    run(delay: true) { AppController.shared.startScreenFlow() }
                }
                RecordTile(symbol: "web.camera", title: L("Camera"), subtitle: nil) { run { AppController.shared.showCameraWindow() } }
                RecordTile(symbol: "mic", title: L("Audio"), subtitle: nil) { run { AppController.shared.showAudioWindow() } }
            }
            .disabled(recorder.isActive)

            if !uploads.isConfigured {
                Button { run { AppController.shared.showSettings(tab: .upload) } } label: {
                    Label(L("Set up uploading to Cloudflare R2"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 8) {
                Picker("", selection: $listTab) {
                    Text(L("Uploads")).tag("uploads")
                    Text(L("Recordings")).tag("recordings")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    LazyVStack(spacing: 2) {
                        if listTab == "uploads" {
                            if history.records.isEmpty { emptyList(L("No uploads yet")) }
                            ForEach(history.records.prefix(max(settings.upload.historyCount, 20))) { UploadRow(record: $0) }
                        } else {
                            if library.items.isEmpty { emptyList(L("No Videos")) }
                            ForEach(library.items) { RecordingRow(item: $0, dismiss: dismiss) }
                        }
                    }
                }
                .frame(height: 300)
            }

            Divider()
            HStack {
                Button(L("Check for Updates…")) { run { Updater.shared.checkForUpdates(nil) } }
                Spacer()
                Button(L("Quit")) { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
        }
        .padding(16)
        .frame(width: 420)
        .background(Theme.background)
        .onAppear { library.load() }
    }

    private var header: some View {
        HStack {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
            Text("Record Everything").font(.system(size: 14, weight: .semibold))
            Spacer()
            if uploads.activeUploads > 0 { ProgressView().controlSize(.small).help(L("Uploading…")) }
            IconButton(symbol: "gearshape", size: 28, help: L("Settings")) { run { AppController.shared.showSettings() } }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            HStack(spacing: 8) { content() }
        }
    }

    private func emptyList(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, minHeight: 80)
    }

    private var recordingControls: some View {
        HStack(spacing: 12) {
            Circle().fill(recorder.state == .paused ? Color.orange : Theme.record).frame(width: 10, height: 10)
            Text(formatDuration(recorder.elapsed)).font(.system(size: 18, weight: .medium, design: .monospaced))
            Spacer()
            Button(recorder.state == .paused ? L("Resume") : L("Pause")) { recorder.togglePause() }
                .controlSize(.large)
            Button(L("Stop")) { run { Task { await recorder.stop() } } }
                .controlSize(.large)
                .tint(Theme.record)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.tile))
    }

    /// Closes the popover before an action; capture actions wait until it is gone from the screen.
    private func run(delay: Bool = false, _ action: @escaping () -> Void) {
        dismiss()
        if delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { action() }
        } else {
            action()
        }
    }
}

/// Large tile for the one-click screenshot actions.
private struct QuickAction: View {
    let symbol: String
    let badge: String?
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: symbol).font(.system(size: 26))
                    if let badge {
                        Image(systemName: badge).font(.system(size: 9, weight: .bold))
                            .padding(3).background(Circle().fill(Theme.accent)).offset(x: 7, y: 4)
                    }
                }
                .frame(height: 32)
                Text(title).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.tileHover : Theme.tile))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Smaller tile for the recording modes.
private struct RecordTile: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 18)).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    if let subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.tileHover : Theme.tile))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct UploadRow: View {
    let record: UploadRecord
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let path = record.thumbnailPath, let img = NSImage(contentsOfFile: path) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc").foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 52, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.3)))

            VStack(alignment: .leading, spacing: 1) {
                Text(record.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(record.date.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            IconButton(symbol: copied ? "checkmark" : "link", size: 26, help: L("Copy link"), tint: copied ? Theme.accent : .white) {
                copyLink()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            IconButton(symbol: "safari", size: 26, help: L("Open in browser")) { NSWorkspace.shared.open(record.url) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.white.opacity(0.06) : .clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button(L("Copy link")) { copyLink() }
            Button(L("Open in browser")) { NSWorkspace.shared.open(record.url) }
            Divider()
            Button(L("Remove from list")) { UploadHistory.shared.remove(record) }
        }
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.url.absoluteString, forType: .string)
    }
}

/// One recording from the library, with the actions of the former home window.
private struct RecordingRow: View {
    let item: MediaItem
    let dismiss: () -> Void
    @State private var info = MediaInfo()
    @State private var thumbnail: NSImage?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button { open { AppController.shared.showInfo(item) } } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.black)
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else if item.kind == .audio {
                        Image(systemName: "waveform").font(.system(size: 16)).foregroundStyle(Theme.level)
                    }
                    if hover { Image(systemName: "play.circle.fill").font(.system(size: 16)).shadow(radius: 2) }
                }
                .frame(width: 52, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .topLeading) {
                    if item.isNew { Circle().fill(Theme.accent).frame(width: 8, height: 8).offset(x: -2, y: -2) }
                }
            }
            .buttonStyle(.plain)
            .help(L("Play"))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(formatFileSize(info.fileSize)) · \(formatDuration(info.duration)) · \(info.format)")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            IconButton(symbol: "icloud.and.arrow.up", size: 26, help: L("Upload and copy link"), tint: Theme.accent) {
                UploadManager.shared.upload(item)
            }
            IconButton(symbol: "folder", size: 26, help: L("Show in Finder")) {
                open { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
            IconButton(symbol: "trash", size: 26, help: L("Delete")) { open { MediaActions.confirmDelete(item) } }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.white.opacity(0.06) : .clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button(L("Open")) { open { AppController.shared.showInfo(item) } }
            Button(L("Trim")) { open { AppController.shared.showEditor(item) } }
            Button(L("Upload and copy link")) { UploadManager.shared.upload(item) }
            Divider()
            Button(L("Show in Finder")) { open { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
            Button(L("Send via AirDrop")) { open { Sharing.airDrop(item.url) } }
            Divider()
            Button(L("Delete…")) { open { MediaActions.confirmDelete(item) } }
        }
        .task(id: item.modified) {
            info = await MediaInfoCache.shared.info(for: item.url)
            if item.kind != .audio { thumbnail = await MediaInfoCache.shared.thumbnail(for: item.url) }
        }
    }

    private func open(_ action: @escaping () -> Void) {
        dismiss()
        action()
    }
}
