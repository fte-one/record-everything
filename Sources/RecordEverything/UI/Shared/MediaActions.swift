import AppKit
import SwiftUI

/// Share, AirDrop and delete actions used by the menu bar list and the info window.
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

enum MediaActions {
    /// Asks before removing a recording; the checkbox also moves the file to the Trash.
    @MainActor
    static func confirmDelete(_ item: MediaItem) {
        let alert = NSAlert()
        alert.messageText = L("Do you want to delete this file?")
        alert.informativeText = item.title
        let deleteFile = NSButton(checkboxWithTitle: L("Delete Source File"), target: nil, action: nil)
        deleteFile.state = .on
        alert.accessoryView = deleteFile
        alert.addButton(withTitle: L("Delete"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WindowManager.shared.close("info-\(item.id)")
        WindowManager.shared.close("editor-\(item.id)")
        MediaLibrary.shared.remove(item, deleteFile: deleteFile.state == .on)
    }
}
