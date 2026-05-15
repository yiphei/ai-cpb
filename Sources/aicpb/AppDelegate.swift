import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeys = HotkeyManager()
    private let menuBar = MenuBar.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
