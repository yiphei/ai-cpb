import AppKit
import ApplicationServices
import CoreGraphics

enum MultiFieldWriter {
    struct WriteOp {
        let field: DetectedField
        let text: String
        let index: Int    // 1-based, matches detection order
    }

    /// Writes each op in order. Returns 1-based indices of fields that failed.
    static func writeAll(_ ops: [WriteOp]) async -> [Int] {
        var failures: [Int] = []
        for op in ops {
            let ok = await writeOne(op)
            if !ok { failures.append(op.index) }
        }
        return failures
    }

    private static func writeOne(_ op: WriteOp) async -> Bool {
        let focused = await focus(op.field)
        if !focused {
            NSLog("copybara: writer focus failed for field \(op.index)")
            return false
        }

        // Select-all so ⌘V replaces (not inserts).
        PasteboardDriver.sendCommandA()
        try? await Task.sleep(nanoseconds: 30_000_000)

        PasteboardDriver.writeString(op.text)
        try? await Task.sleep(nanoseconds: 30_000_000)

        PasteboardDriver.sendCommandV()
        try? await Task.sleep(nanoseconds: 400_000_000)

        return true
    }

    /// Focus by synthesizing a real left-click at the field's center.
    ///
    /// AX-based focus (`AXUIElementSetAttributeValue(_, kAXFocusedAttribute, true)`)
    /// returns .success in Chrome but does not actually move focus, so every
    /// subsequent ⌘V kept landing on whichever field Chrome considered focused
    /// (typically the first one). A real click is universal — native apps,
    /// browser inputs, and Electron all respond to it.
    ///
    /// CGEvent mouse coordinates use the same global top-left origin as AX
    /// coordinates, so the AX rect center is directly usable as a click point.
    private static func focus(_ field: DetectedField) async -> Bool {
        let center = CGPoint(x: field.rectAX.midX, y: field.rectAX.midY)
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(mouseEventSource: src,
                                 mouseType: .leftMouseDown,
                                 mouseCursorPosition: center,
                                 mouseButton: .left),
              let up = CGEvent(mouseEventSource: src,
                               mouseType: .leftMouseUp,
                               mouseCursorPosition: center,
                               mouseButton: .left)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        // 80ms lets the click register, the field activate, and the cursor settle
        // before we start firing keyboard events.
        try? await Task.sleep(nanoseconds: 80_000_000)
        return true
    }
}
