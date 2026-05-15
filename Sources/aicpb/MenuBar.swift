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
        NSLog("ai-cpb: MenuBar.install() entered")
        // Use a fixed, generous width so macOS cannot shrink us to 0pt.
        statusItem = NSStatusBar.system.statusItem(withLength: 90)
        statusItem.autosaveName = "com.yanyiphei.aicpb.status"
        statusItem.isVisible = true
        NSLog("ai-cpb: NSStatusItem length=\(statusItem.length), isVisible=\(statusItem.isVisible)")
        if let button = statusItem.button {
            button.title = "AI-CPB"
            button.font = NSFont.boldSystemFont(ofSize: 13)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let win = button.window {
                    NSLog("ai-cpb: status item window frame = \(win.frame), screen = \(win.screen?.frame ?? .zero)")
                }
            }
            if let img = symbol("wand.and.stars") {
                img.isTemplate = true
                button.image = img
                button.imagePosition = .imageLeft
                NSLog("ai-cpb: set wand image + title on status button")
            } else {
                NSLog("ai-cpb: SF Symbol missing; using text title only")
            }
        } else {
            NSLog("ai-cpb: NSStatusItem has nil button (!)")
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

        let quit = NSMenuItem(title: "Quit ai-cpb",
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
                button.image = self.symbol("wand.and.stars")
                self.setStatus("copying…")
            case .copied:
                button.image = self.symbol("checkmark.circle.fill")
                self.setStatus("copied")
                self.scheduleRestore(after: 0.45)
            case .pasting:
                button.image = self.symbol("paperplane.fill")
                self.setStatus("pasting…")
            case .idle:
                button.image = self.symbol("wand.and.stars")
                self.setStatus("idle")
            }
            button.image?.isTemplate = true
        }
    }

    private func scheduleRestore(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            button.image = self.symbol("wand.and.stars")
            button.image?.isTemplate = true
            self.setStatus("idle")
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: name)
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
