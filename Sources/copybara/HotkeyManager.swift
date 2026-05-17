import AppKit
import Carbon.HIToolbox

final class HotkeyManager {
    static let shared = HotkeyManager()

    enum HotkeyID: UInt32 { case copy = 1, paste = 2 }

    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?

    private var copyRef: EventHotKeyRef?
    private var pasteRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var suspendCount = 0

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                let size = MemoryLayout<EventHotKeyID>.size
                GetEventParameter(event,
                                  EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil, size, nil, &hkID)
                DispatchQueue.main.async {
                    switch HotkeyID(rawValue: hkID.id) {
                    case .copy: mgr.onCopy?()
                    case .paste: mgr.onPaste?()
                    case .none: break
                    }
                }
                return noErr
            },
            1, &spec,
            selfPtr,
            &handlerRef
        )

        applyCurrentHotkeys()

        NotificationCenter.default.addObserver(
            forName: Config.hotkeysDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyCurrentHotkeys()
        }
    }

    func applyCurrentHotkeys() {
        unregisterAll()
        guard suspendCount == 0 else { return }
        copyRef  = register(combo: Config.shared.copyHotkey,  id: .copy)
        pasteRef = register(combo: Config.shared.pasteHotkey, id: .paste)
    }

    /// Temporarily unregister the global hotkeys. Re-entrant: each `suspend()`
    /// must be paired with a `resume()`. Used by the Settings key recorder so
    /// pressing the currently-bound combo doesn't fire AI Copy/Paste.
    func suspend() {
        suspendCount += 1
        if suspendCount == 1 { unregisterAll() }
    }

    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        if suspendCount == 0 { applyCurrentHotkeys() }
    }

    private func unregisterAll() {
        if let r = copyRef  { UnregisterEventHotKey(r); copyRef  = nil }
        if let r = pasteRef { UnregisterEventHotKey(r); pasteRef = nil }
    }

    private func register(combo: HotkeyCombo, id: HotkeyID) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: 0x41494350 /* 'AICP' */, id: id.rawValue)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            NSLog("copybara: failed to register hotkey id=\(id.rawValue) combo=\(combo.displayString) status=\(status)")
            return nil
        }
        return ref
    }
}
