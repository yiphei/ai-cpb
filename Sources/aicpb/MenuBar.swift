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

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = symbol("wand.and.stars")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        statusLabelItem = NSMenuItem(title: "Status: idle", action: nil, keyEquivalent: "")
        statusLabelItem.isEnabled = false
        menu.addItem(statusLabelItem)

        configStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        configStatusItem.isEnabled = false
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

        let revealConfig = NSMenuItem(title: "Reveal config file",
                                      action: #selector(revealConfig),
                                      keyEquivalent: "")
        revealConfig.target = self
        menu.addItem(revealConfig)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ai-cpb",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabelItem?.title = "Status: \(text)"
        }
    }

    func setHasCopy(_ has: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.clearItem?.isEnabled = has
        }
    }

    func refreshConfigState() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if Config.shared.apiKey == nil {
                self.configStatusItem.title = "⚠️ API key missing — edit ~/.config/ai-cpb/config.json"
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
        setHasCopy(false)
    }

    @objc private func checkPermissions() {
        Permissions.checkAll(promptIfMissing: true, reportToUser: true)
    }

    @objc private func revealConfig() {
        let dir = Config.configDirURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Config.configFileURL])
    }
}
