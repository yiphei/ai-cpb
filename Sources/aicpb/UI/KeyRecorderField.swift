import AppKit
import Carbon.HIToolbox
import SwiftUI

struct KeyRecorderField: NSViewRepresentable {
    @Binding var combo: HotkeyCombo

    func makeNSView(context: Context) -> KeyRecorderNSView {
        let v = KeyRecorderNSView()
        v.combo = combo
        v.onChange = { newCombo in
            DispatchQueue.main.async { self.combo = newCombo }
        }
        return v
    }

    func updateNSView(_ v: KeyRecorderNSView, context: Context) {
        if v.combo != combo { v.combo = combo }
    }
}

final class KeyRecorderNSView: NSView {
    var combo: HotkeyCombo = .defaultCopy { didSet { refresh() } }
    var onChange: ((HotkeyCombo) -> Void)?

    private var recording = false { didSet { refresh() } }
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.5).cgColor

        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 26) }

    override func mouseDown(with event: NSEvent) {
        if recording {
            recording = false
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
            recording = true
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { recording = true }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }

        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }

        let mods = HotkeyCombo.carbonModifiers(from: event.modifierFlags)
        if mods == 0 {
            NSSound.beep()
            return
        }

        let newCombo = HotkeyCombo(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: mods
        )
        combo = newCombo
        onChange?(newCombo)
        window?.makeFirstResponder(nil)
    }

    private func refresh() {
        label.stringValue = recording ? "Press shortcut…" : combo.displayString
        label.textColor = recording ? .secondaryLabelColor : .labelColor
        layer?.borderColor = (recording
            ? NSColor.controlAccentColor
            : NSColor.separatorColor).cgColor
    }
}
