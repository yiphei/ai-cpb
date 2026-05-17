import AppKit
import ApplicationServices

enum MultiFieldWriter {
    struct WriteOp {
        let field: DetectedField
        let text: String
        let index: Int    // 1-based, matches detection order
    }

    /// Writes each op in order. Returns 1-based indices of fields that failed
    /// (e.g., focus rejected). LLM-side failures and `<<NO_PASTE>>` skips are
    /// expected to be filtered out by the caller before calling here.
    static func writeAll(_ ops: [WriteOp]) async -> [Int] {
        var failures: [Int] = []
        for op in ops {
            let ok = await writeOne(op)
            if !ok { failures.append(op.index) }
        }
        return failures
    }

    private static func writeOne(_ op: WriteOp) async -> Bool {
        let focused = await focus(op.field.element)
        if !focused { return false }

        // Select-all so ⌘V replaces (not inserts).
        PasteboardDriver.sendCommandA()
        try? await Task.sleep(nanoseconds: 30_000_000)

        PasteboardDriver.writeString(op.text)
        try? await Task.sleep(nanoseconds: 30_000_000)

        PasteboardDriver.sendCommandV()
        try? await Task.sleep(nanoseconds: 400_000_000)

        return true
    }

    private static func focus(_ element: AXUIElement) async -> Bool {
        let status = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        if status == .success {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return true
        }

        // Fallback: raise the element's window first, then retry.
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
           let win = winRef {
            let window = win as! AXUIElement
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            try? await Task.sleep(nanoseconds: 30_000_000)
            let retry = AXUIElementSetAttributeValue(
                element, kAXFocusedAttribute as CFString, kCFBooleanTrue
            )
            if retry == .success {
                try? await Task.sleep(nanoseconds: 50_000_000)
                return true
            }
        }
        return false
    }
}
