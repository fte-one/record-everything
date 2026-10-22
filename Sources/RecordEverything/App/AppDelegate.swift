import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = MainMenu.build()
        AppController.shared.launch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppController.shared.togglePopover() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Recorder.shared.isActive else { return .terminateNow }
        Task {
            await Recorder.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Main menu bar (the recording actions are also in the status item menu).
enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()
        let c = AppController.shared

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item(L("About Record Everything"), "", c, #selector(AppController.menuAbout)))
        appMenu.addItem(item(L("Check for Updates…"), "", Updater.shared, #selector(Updater.checkForUpdates(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item(L("Settings…"), ",", c, #selector(AppController.menuSettings)))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide Record Everything"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L("Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit Record Everything"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L("File"))
        fileMenu.addItem(item(L("Record Screen"), "", c, #selector(AppController.menuRecordScreen)))
        fileMenu.addItem(item(L("Record Webcam"), "", c, #selector(AppController.menuRecordCamera)))
        fileMenu.addItem(item(L("Record Audio"), "", c, #selector(AppController.menuRecordAudio)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(L("Upload File…"), "o", c, #selector(AppController.menuUploadFile)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item(L("Open Menu"), "0", c, #selector(AppController.menuOpenMenu)))
        fileMenu.addItem(withTitle: L("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Edit"))
        editMenu.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("Window"))
        windowMenu.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        return main
    }

    @MainActor
    private static func item(_ title: String, _ key: String, _ target: AnyObject, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target
        return i
    }
}
