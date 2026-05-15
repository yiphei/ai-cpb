import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeys = HotkeyManager()
    private let menuBar = MenuBar.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        menuBar.install()
        Config.shared.load()
        menuBar.refreshConfigState()

        NotificationCenter.default.addObserver(
            forName: Config.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MenuBar.shared.refreshConfigState()
        }

        hotkeys.onCopy = { CopyModeController.shared.begin() }
        hotkeys.onPaste = {
            Task { await PasteController.shared.run() }
        }
        hotkeys.install()

        Permissions.checkAll(promptIfMissing: true)

        if Config.shared.apiKey == nil {
            SettingsWindowController.shared.show(firstRun: true)
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit AI-CPB",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo",
                                        action: Selector(("redo:")),
                                        keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
