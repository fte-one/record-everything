import AppKit
import ImageIO
import SwiftUI

/// Shows the finished prompt to check and edit, with the numbered screenshots, and hands it to the coding agent.
@MainActor
enum FeedbackReview {
    /// The result shown last (self-test).
    private(set) static var lastResult: FeedbackResult?

    static func show(_ result: FeedbackResult) {
        lastResult = result
        let model = FeedbackReviewModel(result: result)
        let id = "feedback-\(result.folder.lastPathComponent)"
        WindowManager.shared.show(id: id, title: L("Feedback session"),
                                  style: .init(size: NSSize(width: 1040, height: 700), minSize: NSSize(width: 780, height: 480), resizable: true),
                                  onClose: { model.save() }) {
            FeedbackReviewView(model: model) { WindowManager.shared.close(id) }
        }
    }
}

@MainActor
final class FeedbackReviewModel: ObservableObject {
    let result: FeedbackResult
    @Published var markdown: String
    let thumbnails: [Int: NSImage]

    init(result: FeedbackResult) {
        self.result = result
        markdown = result.markdown
        var thumbs: [Int: NSImage] = [:]
        for image in result.images {
            guard let source = CGImageSourceCreateWithURL(image.file as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 520,
                  ] as CFDictionary) else { continue }
            thumbs[image.number] = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        }
        thumbnails = thumbs
    }

    /// Keeps edits in feedback.md.
    func save() {
        try? markdown.write(to: result.markdownFile, atomically: true, encoding: .utf8)
    }
}

struct FeedbackReviewView: View {
    @ObservedObject var model: FeedbackReviewModel
    let close: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 34)
                .padding(.bottom, 10)
            HStack(spacing: 0) {
                TextEditor(text: $model.markdown)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color.black.opacity(0.25))
                Rectangle().fill(Theme.separator).frame(width: 1)
                gallery.frame(width: 250)
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
            footer.padding(14)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Feedback session")).font(.system(size: 17, weight: .bold))
                Text(meta).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            if let warning = model.result.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var meta: String {
        var parts = [feedbackClock(model.result.duration) + " " + L("min")]
        if model.result.taskCount > 0 { parts.append(String(format: L("%d tasks"), model.result.taskCount)) }
        parts.append(String(format: L("%d screenshots"), model.result.images.count))
        return parts.joined(separator: " · ")
    }

    private var gallery: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.result.images, id: \.number) { image in
                    Button { NSWorkspace.shared.open(image.file) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            if let thumb = model.thumbnails[image.number] {
                                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
                            }
                            Text(String(format: L("Image %d"), image.number) + " · " + feedbackClock(image.shot.time))
                                .font(.system(size: 11, weight: .medium))
                            if let url = image.shot.url {
                                Text(url).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L("Open"))
                }
            }
            .padding(12)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([model.result.markdownFile]) } label: {
                Label(L("Show in Finder"), systemImage: "folder")
            }
            Button {
                model.save()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.markdown, forType: .string)
                Toast.shared.show(L("Prompt copied"), symbol: "doc.on.clipboard.fill", style: .success, duration: 1.8)
            } label: {
                Label(L("Copy"), systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Spacer()
            ForEach(Array(settings.pasteTargets.enumerated()), id: \.element.id) { index, target in
                pasteButton(target, primary: index == 0)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private func pasteButton(_ target: PasteTarget, primary: Bool) -> some View {
        let button = Button { paste(into: target) } label: {
            HStack(spacing: 6) {
                if let icon = PasteIntoApp.icon(bundleID: target.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(String(format: L("Into %@"), target.name))
            }
        }
        .help(String(format: L("Paste the prompt into %@"), target.name) + (target.shortcut.map { " (\($0.display.replacingOccurrences(of: " + ", with: "")))" } ?? ""))
        if let shortcut = target.shortcut, let key = Self.keyEquivalent(shortcut) {
            if primary { button.buttonStyle(.borderedProminent).keyboardShortcut(key.0, modifiers: key.1) }
            else { button.keyboardShortcut(key.0, modifiers: key.1) }
        } else {
            if primary { button.buttonStyle(.borderedProminent) } else { button }
        }
    }

    private func paste(into target: PasteTarget) {
        model.save()
        let text = model.markdown
        let result = model.result
        close()
        Task {
            if result.imageMode == .attachments, !result.images.isEmpty {
                await PasteIntoApp.pasteImages(result.images.map(\.file), text: text, into: nil, bundleID: target.bundleID, name: target.name)
            } else {
                await PasteIntoApp.pasteText(text, into: nil, bundleID: target.bundleID, name: target.name)
            }
        }
    }

    /// A target's shortcut as a SwiftUI key equivalent (letters and digits only).
    static func keyEquivalent(_ combo: HotKeyCombo) -> (KeyEquivalent, EventModifiers)? {
        guard combo.keyLabel.count == 1, let ch = combo.keyLabel.lowercased().first, ch.isLetter || ch.isNumber else { return nil }
        let flags = combo.flags
        var mods: EventModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        return (KeyEquivalent(ch), mods)
    }
}
