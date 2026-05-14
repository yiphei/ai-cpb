import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeys = HotkeyManager()
    private let menuBar = MenuBar.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.install()
        Config.shared.load()
        menuBar.refreshConfigState()

        hotkeys.onCopy = { CopyModeController.shared.begin() }
        hotkeys.onPaste = {
            Task { await PasteController.shared.run() }
        }
        hotkeys.install()

        Permissions.checkAll(promptIfMissing: true)
    }
}
