import AppKit
import SwiftUI

private struct SettingsView: View {
    let firstRun: Bool
    let onRequestClose: () -> Void

    @State private var selectedProvider: LLMProvider = Config.shared.provider
    @State private var keyText: String = Config.shared.apiKey ?? ""
    @State private var copyCombo: HotkeyCombo = Config.shared.copyHotkey
    @State private var pasteCombo: HotkeyCombo = Config.shared.pasteHotkey
    @State private var statusMessage: String? = nil
    @State private var statusIsError: Bool = false
    @State private var statusClearWorkItem: DispatchWorkItem? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if firstRun {
                Text("Welcome to Copybara")
                    .font(.title2).bold()
                Text("Choose your LLM provider and paste your API key. Copybara uses it to decide what to paste based on what you copied.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Provider", selection: $selectedProvider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedProvider) { _, new in
                keyText = (new == Config.shared.provider) ? (Config.shared.apiKey ?? "") : ""
            }

            Text("\(selectedProvider.displayName) API key")
                .font(.headline)

            SecureField(selectedProvider.keyPlaceholder, text: $keyText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }

            HStack(spacing: 12) {
                Link("Get a key at \(selectedProvider.keysURL.host ?? "")",
                     destination: selectedProvider.keysURL)
                    .font(.callout)
                Spacer()
                if let msg = statusMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(statusIsError ? .red : .green)
                }
            }

            Divider()

            Text("Hotkeys")
                .font(.headline)
            Text("Click a field, then press the new combo. Esc cancels.")
                .font(.callout)
                .foregroundStyle(.secondary)

            hotkeyRow(label: "AI Copy",
                      combo: $copyCombo,
                      defaultCombo: .defaultCopy,
                      onCommit: { Config.shared.setCopyHotkey($0) })

            hotkeyRow(label: "AI Paste",
                      combo: $pasteCombo,
                      defaultCombo: .defaultPaste,
                      onCommit: { Config.shared.setPasteHotkey($0) })

            HStack {
                Button("Clear key", role: .destructive, action: clear)
                    .disabled(clearDisabled)
                Spacer()
                Button("Cancel", action: onRequestClose)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveDisabled)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func hotkeyRow(
        label: String,
        combo: Binding<HotkeyCombo>,
        defaultCombo: HotkeyCombo,
        onCommit: @escaping (HotkeyCombo) -> Void
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 80, alignment: .leading)
            KeyRecorderField(combo: combo)
                .frame(width: 160, height: 26)
                .onChange(of: combo.wrappedValue) { _, newValue in
                    onCommit(newValue)
                }
            Spacer()
            Button("Reset") {
                combo.wrappedValue = defaultCombo
            }
            .disabled(combo.wrappedValue == defaultCombo)
        }
    }

    private var trimmedKey: String {
        keyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var saveDisabled: Bool {
        if trimmedKey.isEmpty { return true }
        return selectedProvider == Config.shared.provider
            && trimmedKey == (Config.shared.apiKey ?? "")
    }

    private var clearDisabled: Bool {
        if !keyText.isEmpty { return false }
        return selectedProvider != Config.shared.provider || Config.shared.apiKey == nil
    }

    private func save() {
        let result = Config.shared.setAPIKey(trimmedKey, for: selectedProvider)
        switch result {
        case .success:
            if firstRun {
                onRequestClose()
                return
            }
            show(status: "Saved ✓", isError: false)
        case .failure(let err):
            show(status: "Could not save: \(err.localizedDescription)", isError: true)
        }
    }

    private func clear() {
        let result = Config.shared.setAPIKey(nil, for: selectedProvider)
        switch result {
        case .success:
            keyText = ""
            show(status: "Key removed", isError: false)
        case .failure(let err):
            show(status: "Could not clear: \(err.localizedDescription)", isError: true)
        }
    }

    private func show(status: String, isError: Bool) {
        statusMessage = status
        statusIsError = isError
        statusClearWorkItem?.cancel()
        let work = DispatchWorkItem { statusMessage = nil }
        statusClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var firstRun = false

    func show(firstRun: Bool = false) {
        self.firstRun = firstRun
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(firstRun: firstRun, onRequestClose: { [weak self] in
            self?.window?.performClose(nil)
        })
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = "Copybara Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.center()
        win.delegate = self
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
