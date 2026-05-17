import AppKit

enum FlashState {
    case copying, copied, pasting, idle
}

final class MenuBar {
    static let shared = MenuBar()

    private var statusItem: NSStatusItem!
    private var statusLabelItem: NSMenuItem!
    private var clearItem: NSMenuItem!
    private var configStatusItem: NSMenuItem!
    private var flashWorkItem: DispatchWorkItem?
    private var currentStatus: String = "idle"
    private var currentCopyCount: Int = 0

    func install() {
        NSLog("copybara: MenuBar.install() entered")
        // Use a fixed, generous width so macOS cannot shrink us to 0pt.
        statusItem = NSStatusBar.system.statusItem(withLength: 90)
        statusItem.autosaveName = "com.yanyiphei.copybara.status"
        statusItem.isVisible = true
        NSLog("copybara: NSStatusItem length=\(statusItem.length), isVisible=\(statusItem.isVisible)")
        if let button = statusItem.button {
            button.title = "Copybara"
            button.font = NSFont.boldSystemFont(ofSize: 13)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let win = button.window {
                    NSLog("copybara: status item window frame = \(win.frame), screen = \(win.screen?.frame ?? .zero)")
                }
            }
            if let img = brandImage() {
                button.image = img
                button.imagePosition = .imageLeft
                NSLog("copybara: set capybara icon + title on status button")
            } else if let img = symbol("wand.and.stars") {
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageLeft
                NSLog("copybara: brand icon missing; fell back to wand SF Symbol")
            } else {
                NSLog("copybara: SF Symbol missing; using text title only")
            }
        } else {
            NSLog("copybara: NSStatusItem has nil button (!)")
        }

        let menu = NSMenu()
        statusLabelItem = NSMenuItem(title: "Status: idle", action: nil, keyEquivalent: "")
        statusLabelItem.isEnabled = false
        menu.addItem(statusLabelItem)

        configStatusItem = NSMenuItem(
            title: "",
            action: #selector(openSettings),
            keyEquivalent: ""
        )
        configStatusItem.target = self
        configStatusItem.isHidden = true
        menu.addItem(configStatusItem)

        menu.addItem(.separator())

        clearItem = NSMenuItem(title: "Clear copied context",
                               action: #selector(clearCopy),
                               keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = false
        menu.addItem(clearItem)

        let checkPerms = NSMenuItem(title: "Check permissions",
                                    action: #selector(checkPermissions),
                                    keyEquivalent: "")
        checkPerms.target = self
        menu.addItem(checkPerms)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit Copybara",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentStatus = text
            self.renderStatusLabel()
        }
    }

    func setCopyCount(_ count: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentCopyCount = count
            self.clearItem?.isEnabled = count > 0
            self.renderStatusLabel()
        }
    }

    private func renderStatusLabel() {
        let base = "Status: \(currentStatus)"
        let suffix: String
        switch currentCopyCount {
        case 0: suffix = ""
        case 1: suffix = " (1 copy)"
        default: suffix = " (\(currentCopyCount) copies)"
        }
        statusLabelItem?.title = base + suffix
    }

    func refreshConfigState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if Config.shared.apiKey == nil {
                self.configStatusItem.title = "⚠️ API key missing — Open Settings…"
                self.configStatusItem.isHidden = false
            } else {
                self.configStatusItem.isHidden = true
            }
        }
    }

    func flash(_ state: FlashState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.flashWorkItem?.cancel()

            switch state {
            case .copying:
                self.applyBrandImage(to: button)
                self.setStatus("copying…")
            case .copied:
                if let img = self.symbol("checkmark.circle.fill") {
                    img.isTemplate = true
                    button.image = img
                }
                self.setStatus("copied")
                self.scheduleRestore(after: 0.45)
            case .pasting:
                if let img = self.symbol("paperplane.fill") {
                    img.isTemplate = true
                    button.image = img
                }
                self.setStatus("pasting…")
            case .idle:
                self.applyBrandImage(to: button)
                self.setStatus("idle")
            }
        }
    }

    private func scheduleRestore(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.applyBrandImage(to: button)
            self.setStatus("idle")
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func applyBrandImage(to button: NSStatusBarButton) {
        if let img = brandImage() {
            button.image = img
        } else if let img = symbol("wand.and.stars") {
            img.isTemplate = true
            button.image = img
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: name)
    }

    private func brandImage() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            return nil
        }
        // Menu bar icons render best around 18pt tall on macOS.
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = false
        return img
    }

    @objc private func clearCopy() {
        ContextStore.shared.clear()
    }

    @objc private func checkPermissions() {
        Permissions.checkAll(promptIfMissing: true, reportToUser: true)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(firstRun: false)
    }
}
