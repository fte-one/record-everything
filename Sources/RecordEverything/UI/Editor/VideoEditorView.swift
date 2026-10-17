import AVKit
import SwiftUI

/// Trim editor: player, transport, thumbnail timeline with selection, cut / delete / undo / mute, save.
struct VideoEditorView: View {
    let itemID: UUID
    @StateObject private var model: EditorModel
    @State private var showSaveAs = false

    init(itemID: UUID) {
        self.itemID = itemID
        let item = MediaLibrary.shared.item(id: itemID) ?? MediaItem(title: "", path: "", kind: .screen, created: Date(), modified: Date())
        _model = StateObject(wrappedValue: EditorModel(item: item))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if model.hasVideo {
                    EditorPlayerView(player: model.player)
                } else {
                    Image(systemName: "waveform").font(.system(size: 60)).foregroundStyle(Theme.level)
                }
                if model.busy {
                    ProgressView(L("Processing")).padding(20).background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                }
            }
            .padding(.top, 28)

            VStack(spacing: 12) {
                transport
                Timeline(model: model).frame(height: 64)
                toolbar
            }
            .padding(16)
            .background(Theme.panel)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .task { await model.load() }
        .onDisappear { model.cleanup() }
        .sheet(isPresented: $showSaveAs) {
            SaveAsView(model: model) { showSaveAs = false }
        }
        .alert(L("Attention!"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("OK")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Text(model.item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer()
            IconButton(symbol: "gobackward.5", size: 30, help: L("Back 5 seconds")) { model.skip(-5) }
            IconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", size: 36, help: L("Play")) { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            IconButton(symbol: "goforward.5", size: 30, help: L("Forward 5 seconds")) { model.skip(5) }
            Spacer()
            Text("\(formatDuration(model.currentTime)) / \(formatDuration(model.duration))")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            IconButton(symbol: "arrow.uturn.backward", size: 32, help: L("Undo"), active: model.hasChanges) { model.undo() }
                .disabled(!model.hasChanges)
            IconButton(symbol: "scissors", size: 32, help: L("Keep only the selection")) { model.trimToSelection() }
            IconButton(symbol: "trash", size: 32, help: L("Delete the selection")) { model.deleteSelection() }
            IconButton(symbol: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 32,
                       help: model.muted ? L("Sound: Off") : L("Sound: On")) { model.muted.toggle() }
            Text(L("Selection") + ": " + formatDuration(model.selection.upperBound - model.selection.lowerBound))
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Spacer()
            Button(L("Save as…")) { showSaveAs = true }
                .controlSize(.large)
                .disabled(model.busy)
            Button(L("SAVE")) { save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy || (!model.hasChanges && !model.muted))
        }
    }

    private func save() {
        Task {
            let item = model.item
            if await model.export(to: item.url, replace: true) {
                MediaLibrary.shared.touch(item)
                WindowManager.shared.close("editor-\(item.id)")
            }
        }
    }
}

private struct EditorPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .none
        v.player = player
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

/// Thumbnail strip with a draggable selection (left and right handles) and a draggable playhead.
private struct Timeline: View {
    @ObservedObject var model: EditorModel
    @State private var dragStartSelection: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(model.duration, 0.001)
            let x = { (t: Double) in CGFloat(t / total) * w }
            let t = { (x: CGFloat) in min(max(0, Double(x / w) * total), total) }
            let selLo = x(model.selection.lowerBound), selHi = x(model.selection.upperBound)

            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if model.thumbnails.isEmpty {
                        Rectangle().fill(Theme.tile)
                    } else {
                        ForEach(model.thumbnails.indices, id: \.self) { i in
                            Image(nsImage: model.thumbnails[i]).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: w / CGFloat(model.thumbnails.count), height: geo.size.height).clipped()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(to: t($0.location.x)) })

                // Dim the parts outside the selection.
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, selLo)).allowsHitTesting(false)
                Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, w - selHi)).offset(x: selHi).allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.accent, lineWidth: 3)
                    .frame(width: max(2, selHi - selLo))
                    .offset(x: selLo)
                    .allowsHitTesting(false)

                // Playhead; it moves with the seek gesture on the strip and must not cover the handles.
                Rectangle().fill(Color.white).frame(width: 2, height: geo.size.height + 10)
                    .overlay(alignment: .top) { Circle().fill(Color.white).frame(width: 10, height: 10).offset(y: -5) }
                    .offset(x: x(model.currentTime) - 1)
                    .allowsHitTesting(false)

                handle(edge: .leading).offset(x: selLo - 7)
                    .highPriorityGesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { v in
                        let lo = min(t(v.location.x), model.selection.upperBound - 0.2)
                        model.selection = max(0, lo)...model.selection.upperBound
                        model.seek(to: model.selection.lowerBound)
                    })
                handle(edge: .trailing).offset(x: selHi - 7)
                    .highPriorityGesture(DragGesture(coordinateSpace: .named("timeline")).onChanged { v in
                        let hi = max(t(v.location.x), model.selection.lowerBound + 0.2)
                        model.selection = model.selection.lowerBound...min(total, hi)
                        model.seek(to: model.selection.upperBound)
                    })
            }
            .coordinateSpace(name: "timeline")
        }
    }

    private func handle(edge: HorizontalEdge) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.accent)
            .frame(width: 14)
            .overlay(Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            .contentShape(Rectangle())
    }
}

/// "Save as" dialog: file name, format, save location.
private struct SaveAsView: View {
    @ObservedObject var model: EditorModel
    let dismiss: () -> Void
    @State private var name = ""
    @State private var folder = AppSettings.shared.saveFolder
    @State private var error: String?

    private var ext: String { model.hasVideo ? "mp4" : "m4a" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Save as")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(L("File Name:")).foregroundStyle(Theme.secondary)
                    TextField("", text: $name).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(L("Format:")).foregroundStyle(Theme.secondary)
                    Text(ext.uppercased())
                }
                GridRow {
                    Text(L("Save Location:")).foregroundStyle(Theme.secondary)
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { choose() } label: { Image(systemName: "folder") }
                    }
                }
            }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Theme.record) }
            HStack {
                Spacer()
                Button(L("Cancel"), action: dismiss).keyboardShortcut(.cancelAction)
                Button(L("OK")) { save() }.keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { name = model.item.title + " " + L("edited") }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    private func save() {
        let clean = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        guard !clean.isEmpty else { error = L("Please enter a name."); return }
        let url = folder.appendingPathComponent(clean).appendingPathExtension(ext)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            error = L("This file name already exists, please rename.")
            return
        }
        Task {
            if await model.export(to: url, replace: false) {
                let new = MediaLibrary.shared.add(url: url, kind: model.item.kind)
                try? MediaLibrary.shared.rename(new, to: clean)
                dismiss()
            }
        }
    }
}
