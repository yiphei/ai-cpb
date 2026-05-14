import AppKit
import Carbon.HIToolbox

final class HotkeyManager {
    enum HotkeyID: UInt32 { case copy = 1, paste = 2 }

    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?

    private var refs: [EventHotKeyRef?] = []
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

        register(keyCode: UInt32(kVK_ANSI_C), id: .copy)
        register(keyCode: UInt32(kVK_ANSI_V), id: .paste)
    }

    private func register(keyCode: UInt32, id: HotkeyID) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: 0x41494350 /* 'AICP' */, id: id.rawValue)
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey | shiftKey),
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            NSLog("ai-cpb: failed to register hotkey id=\(id.rawValue) status=\(status)")
        }
        refs.append(ref)
    }
}
