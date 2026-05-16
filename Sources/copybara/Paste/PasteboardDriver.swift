import AppKit
import CoreGraphics
import Carbon.HIToolbox

enum PasteboardDriver {
    static func snapshot() -> [NSPasteboardItem] {
        let pb = NSPasteboard.general
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { src in
            let copy = NSPasteboardItem()
            for type in src.types {
                if let data = src.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    static func writeString(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func restore(_ items: [NSPasteboardItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !items.isEmpty {
            pb.writeObjects(items)
        }
    }

    static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let vDown = CGEvent(keyboardEventSource: src,
                                  virtualKey: CGKeyCode(kVK_ANSI_V),
                                  keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src,
                                virtualKey: CGKeyCode(kVK_ANSI_V),
                                keyDown: false)
        else { return }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
    }
}
