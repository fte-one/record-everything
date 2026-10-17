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
    var listHeight: CGFloat = 300
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            header

            if recorder.isActive { recordingControls }

            section("01", L("Screenshots")) {
                QuickAction(symbol: "pencil.and.scribble", tint: Theme.accent, title: L("Screenshot & annotate"),
                            shortcut: settings.captureAnnotateHotKey.display) { run(delay: true) { Screenshots.captureAndAnnotate() } }
                QuickAction(symbol: "link", tint: Theme.cyan, title: L("Screenshot & copy link"),
                            shortcut: settings.captureUploadHotKey.display) { run(delay: true) { Screenshots.captureAndUpload() } }
                QuickAction(symbol: "doc.on.doc.fill", tint: Theme.violet, title: L("Screenshot & copy image"),
                            shortcut: settings.captureCopyHotKey.display) { run(delay: true) { Screenshots.captureAndCopy() } }
            }

            section("02", L("Record")) {
                RecordTile(symbol: "rectangle.dashed.badge.record", tint: Theme.record, title: L("Screen"),
                           shortcut: settings.startPauseHotKey.display) { run(delay: true) { AppController.shared.startScreenFlow() } }
                RecordTile(symbol: "web.camera.fill", tint: Theme.cyan, title: L("Camera"), shortcut: nil) {
                    run { AppController.shared.showCameraWindow() }
                }
                RecordTile(symbol: "mic.fill", tint: .orange, title: L("Audio"), shortcut: nil) { run { AppController.shared.showAudioWindow() } }
            }
            .disabled(recorder.isActive)
            .opacity(recorder.isActive ? 0.45 : 1)

            if !uploads.isConfigured {
                Button { run { AppController.shared.showSettings(tab: .upload) } } label: {
                    Label(L("Set up uploading to Cloudflare R2"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle("03", L("History"))
                    Spacer()
                    PillTabs(selection: $listTab, items: [
                        ("uploads", L("Uploads"), history.records.count),
                        ("recordings", L("Recordings"), library.items.count),
                    ])
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if listTab == "uploads" {
                            if history.records.isEmpty { emptyList("icloud.and.arrow.up", L("No uploads yet")) }
                            ForEach(history.records.prefix(max(settings.upload.historyCount, 20))) { UploadRow(record: $0) }
                        } else {
                            if library.items.isEmpty { emptyList("film.stack", L("No Videos")) }
                            ForEach(library.items) { RecordingRow(item: $0, dismiss: dismiss) }
                        }
                    }
                    .padding(4)
                }
                .frame(height: listHeight)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06)))
            }

            footer
        }
        .padding(18)
        .frame(width: 430)
        .background(background)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onAppear { library.load() }
    }

    /// Dark surface with a soft green glow at the top and a hint of cyan at the bottom.
    private var background: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accent.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Theme.cyan.opacity(0.08), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 320)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                .shadow(color: Theme.accent.opacity(0.45), radius: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text("Record Everything").font(.system(size: 15, weight: .bold))
                Text("by fte.one").font(.system(size: 10, weight: .medium)).tracking(0.6).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if uploads.activeUploads > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L("Uploading…")).font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Theme.accent.opacity(0.18)))
            }
            GearMenu(run: { run($0) })
        }
    }

    private func sectionTitle(_ number: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(number).foregroundStyle(Theme.accent)
            Text("·").foregroundStyle(Theme.secondary)
            Text(title.uppercased()).foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 10, weight: .bold, design: .monospaced))
        .tracking(1.2)
    }

    private func section<Content: View>(_ number: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(number, title)
            HStack(spacing: 10) { content() }
        }
    }

    private func emptyList(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Theme.secondary.opacity(0.6))
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button { run { Brand.showAbout() } } label: {
                FteWordmark()
            }
            .help(L("About Record Everything"))
            Spacer()
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
        .padding(.top, 2)
    }

    private var recordingControls: some View {
        HStack(spacing: 12) {
            PulsingDot(color: recorder.state == .paused ? .orange : Theme.record, pulsing: recorder.state == .recording)
            Text(formatDuration(recorder.elapsed)).font(.system(size: 20, weight: .semibold, design: .monospaced))
            Spacer()
            Button(recorder.state == .paused ? L("Resume") : L("Pause")) { recorder.togglePause() }
                .controlSize(.large)
            Button(L("Stop")) { run { Task { await recorder.stop() } } }
                .controlSize(.large)
                .tint(Theme.record)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.record.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.record.opacity(0.35)))
    }

    /// Closes the menu before an action; capture actions wait until it is gone from the screen.
    private func run(delay: Bool = false, _ action: @escaping () -> Void) {
        dismiss()
        if delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { action() }
        } else {
            action()
        }
    }
}

/// Keyboard shortcut as key caps: "⌘ + →" -> [⌘] [→].
private struct KeyCaps: View {
    let display: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(display.components(separatedBy: " + ").enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(minWidth: 16, minHeight: 16)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.18)))
            }
        }
        .foregroundStyle(Color.white.opacity(0.8))
    }
}

/// Gear in the header: settings, updates, about and – deliberately tucked away – quit.
private struct GearMenu: View {
    let run: (@escaping () -> Void) -> Void
    @State private var hover = false

    var body: some View {
        Menu {
            Button(L("Settings…")) { run { AppController.shared.showSettings() } }
            Button(L("Check for Updates…")) { run { Updater.shared.checkForUpdates(nil) } }
            Button(L("About Record Everything")) { run { Brand.showAbout() } }
            Divider()
            Button(L("Quit Record Everything")) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hover ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Settings"))
        .accessibilityLabel(L("Settings"))
        .onHover { hover = $0 }
    }
}

/// Shared look of the tiles: soft gradient, thin border; on hover a colored border, a glow and the
/// hard offset shadow of the fte.one website.
private struct TileBackground: ViewModifier {
    let tint: Color
    let hover: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius).fill(Theme.background)
                    RoundedRectangle(cornerRadius: radius)
                        .fill(LinearGradient(colors: [Color.white.opacity(hover ? 0.13 : 0.09), Color.white.opacity(0.03)],
                                             startPoint: .top, endPoint: .bottom))
                }
            )
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(hover ? tint.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1))
            .background(RoundedRectangle(cornerRadius: radius).fill(tint.opacity(hover ? 0.9 : 0)).offset(x: 4, y: 4))
            .shadow(color: hover ? tint.opacity(0.3) : .clear, radius: 12)
            .offset(x: hover ? -2 : 0, y: hover ? -2 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
            .contentShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// Large tile for the one-click screenshot actions.
private struct QuickAction: View {
    let symbol: String
    let tint: Color
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                        .shadow(color: tint.opacity(0.5), radius: hover ? 10 : 5)
                    Image(systemName: "camera.viewfinder").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(tint)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white))
                        .offset(x: 16, y: 15)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                KeyCaps(display: shortcut)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 128)
            .modifier(TileBackground(tint: tint, hover: hover, radius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Smaller tile for the recording modes.
private struct RecordTile: View {
    let symbol: String
    let tint: Color
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.16)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    if let shortcut { KeyCaps(display: shortcut) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 54)
            .modifier(TileBackground(tint: tint, hover: hover, radius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Capsule switch with a sliding highlight and item counts.
private struct PillTabs: View {
    @Binding var selection: String
    let items: [(id: String, title: String, count: Int)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = item.id }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.title).font(.system(size: 11, weight: .semibold))
                        Text("\(item.count)").font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(selection == item.id ? 0.25 : 0.1)))
                    }
                    .foregroundStyle(selection == item.id ? Color.black : Color.white.opacity(0.75))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background {
                        if selection == item.id {
                            Capsule().fill(Theme.accent).matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

/// The fte.one logo as text: white "fte", red dot, green "one".
private struct FteWordmark: View {
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 1.5) {
            Text("fte").foregroundStyle(.white)
            Circle().fill(Theme.fteRed).frame(width: 3.5, height: 3.5).alignmentGuide(.lastTextBaseline) { $0[.bottom] + 0.5 }
            Text("one").foregroundStyle(Theme.fteGreen)
        }
        .font(.system(size: 13, weight: .bold))
    }
}

/// Red recording dot that breathes while recording.
private struct PulsingDot: View {
    let color: Color
    let pulsing: Bool
    @State private var on = false

    var body: some View {
        Circle().fill(color).frame(width: 12, height: 12)
            .shadow(color: color.opacity(0.8), radius: on ? 8 : 2)
            .scaleEffect(on ? 1.15 : 0.9)
            .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = pulsing }
            .onChange(of: pulsing) { on = pulsing }
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
            .onHover { inside in
                if inside {
                    UploadPreview.shared.show(record, anchorY: NSEvent.mouseLocation.y)
                } else {
                    UploadPreview.shared.hide(record.id)
                }
            }
            .onDisappear { UploadPreview.shared.hide(record.id) }

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
