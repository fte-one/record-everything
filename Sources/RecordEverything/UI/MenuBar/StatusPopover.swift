import AppKit
import SwiftUI

/// Content of the menu bar popover: quick actions, recording controls and the recent uploads.
struct StatusPopoverView: View {
    @ObservedObject private var recorder = Recorder.shared
    @ObservedObject private var history = UploadHistory.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var uploads = UploadManager.shared
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 20, height: 20)
                Text("Record Everything").font(.system(size: 13, weight: .semibold))
                Spacer()
                if uploads.activeUploads > 0 { ProgressView().controlSize(.small).help(L("Uploading…")) }
                IconButton(symbol: "gearshape", size: 26, help: L("Settings")) { run { AppController.shared.showSettings() } }
            }

            if recorder.isActive {
                recordingControls
            } else {
                HStack(spacing: 8) {
                    QuickAction(symbol: "camera.viewfinder", badge: "arrow.up", title: L("Screenshot & upload"),
                                shortcut: settings.captureUploadHotKey.display) { run(delay: true) { Screenshots.captureAndUpload() } }
                    QuickAction(symbol: "camera.viewfinder", badge: "pencil", title: L("Screenshot & annotate"),
                                shortcut: settings.captureAnnotateHotKey.display) { run(delay: true) { Screenshots.captureAndAnnotate() } }
                    QuickAction(symbol: "record.circle", badge: nil, title: L("Record screen"),
                                shortcut: settings.startPauseHotKey.display) { run(delay: true) { AppController.shared.startScreenFlow() } }
                }
                HStack(spacing: 6) {
                    SmallAction(symbol: "web.camera", title: L("Webcam")) { run { AppController.shared.showCameraWindow() } }
                    SmallAction(symbol: "mic", title: L("Audio")) { run { AppController.shared.showAudioWindow() } }
                    SmallAction(symbol: "film.stack", title: L("Recordings")) { run { AppController.shared.showHome() } }
                }
            }

            if !uploads.isConfigured {
                Button { run { AppController.shared.showSettings(tab: .upload) } } label: {
                    Label(L("Set up uploading to Cloudflare R2"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("Recent uploads")).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                if history.records.isEmpty {
                    Text(L("No uploads yet")).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(history.records.prefix(settings.upload.historyCount)) { UploadRow(record: $0) }
                        }
                    }
                    .frame(maxHeight: 260)
                }
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
        .padding(14)
        .frame(width: 360)
        .background(Theme.background)
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

private struct QuickAction: View {
    let symbol: String
    let badge: String?
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: symbol).font(.system(size: 24))
                    if let badge {
                        Image(systemName: badge).font(.system(size: 9, weight: .bold))
                            .padding(3).background(Circle().fill(Theme.accent)).offset(x: 6, y: 4)
                    }
                }
                .frame(height: 30)
                Text(title).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
                Text(shortcut).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.tileHover : Theme.tile))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct SmallAction: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11))
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.tile))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            .frame(width: 44, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.3)))

            VStack(alignment: .leading, spacing: 1) {
                Text(record.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(record.date, style: .relative).font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            IconButton(symbol: copied ? "checkmark" : "link", size: 24, help: L("Copy link"), tint: copied ? Theme.accent : .white) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.url.absoluteString, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            }
            IconButton(symbol: "safari", size: 24, help: L("Open in browser")) { NSWorkspace.shared.open(record.url) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.white.opacity(0.06) : .clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button(L("Copy link")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.url.absoluteString, forType: .string)
            }
            Button(L("Open in browser")) { NSWorkspace.shared.open(record.url) }
            Divider()
            Button(L("Remove from list")) { UploadHistory.shared.remove(record) }
        }
    }
}
