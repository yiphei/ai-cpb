import AppKit
import ApplicationServices

struct FocusedField {
    let rect: CGRect
    let role: String?
}

enum AXHelper {
    /// Returns the global rect of the system-wide focused UI element, in AX coords
    /// (top-left origin in points, primary screen's top-left is (0,0)).
    static func focusedFieldRect() -> FocusedField? {
        let system = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        let s1 = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard s1 == .success, let focused = focusedRef else { return nil }
        let element = focused as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let sp = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        let ss = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        guard sp == .success, ss == .success,
              let posVal = posRef, let sizeVal = sizeRef
        else { return nil }

        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        else { return nil }

        if size.width <= 0 || size.height <= 0 { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        let rect = CGRect(origin: pos, size: size)
        let clamped = clampToScreens(rect)
        if clamped.width < 4 || clamped.height < 4 { return nil }

        return FocusedField(rect: clamped, role: role)
    }

    /// Clamp an AX-coords rect to the union of all screens in AX space.
    private static func clampToScreens(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let primaryHeight = primary.frame.height
        var union = CGRect.null
        for screen in NSScreen.screens {
            let f = screen.frame
            // Convert each screen frame into AX coords (top-left origin).
            let axFrame = CGRect(
                x: f.origin.x,
                y: primaryHeight - f.origin.y - f.height,
                width: f.width,
                height: f.height
            )
            union = union.union(axFrame)
        }
        if union.isNull { return rect }
        return rect.intersection(union)
    }
}
