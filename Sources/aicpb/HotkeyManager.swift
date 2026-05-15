import AppKit
import Carbon.HIToolbox

final class HotkeyManager {
    enum HotkeyID: UInt32 { case copy = 1, paste = 2 }

    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?

    private var copyRef: EventHotKeyRef?
    private var pasteRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

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
        if let r = copyRef { UnregisterEventHotKey(r); copyRef = nil }
        if let r = pasteRef { UnregisterEventHotKey(r); pasteRef = nil }
        copyRef  = register(combo: Config.shared.copyHotkey,  id: .copy)
        pasteRef = register(combo: Config.shared.pasteHotkey, id: .paste)
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
            NSLog("ai-cpb: failed to register hotkey id=\(id.rawValue) combo=\(combo.displayString) status=\(status)")
            return nil
        }
        return ref
    }
}
