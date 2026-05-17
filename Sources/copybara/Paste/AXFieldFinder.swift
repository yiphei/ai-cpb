import AppKit
import ApplicationServices

struct DetectedField {
    let element: AXUIElement
    let rectAX: CGRect    // AX top-left coords, global
    let role: String?
}

enum AXFieldFinder {
    private static let writableTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
    ]

    private static let excludedSubroles: Set<String> = [
        kAXSecureTextFieldSubrole as String,
    ]

    /// Walks the AX tree under `appElement` and returns text-writable fields whose
    /// center point lies inside `lassoAX` (AX top-left coords).
    /// Order: AX tree traversal order (≈ tab order).
    static func find(in appElement: AXUIElement, intersecting lassoAX: CGRect) -> [DetectedField] {
        var raw: [DetectedField] = []
        walk(appElement, lassoAX: lassoAX, into: &raw, depth: 0)
        let deduped = dedupe(raw)
        NSLog("copybara: AXFieldFinder found \(raw.count) raw → \(deduped.count) after dedupe")
        for (i, f) in deduped.enumerated() {
            NSLog("copybara:   field \(i + 1) [\(f.role ?? "?")] rect=\(f.rectAX)")
        }
        return deduped
    }

    /// Browser/React AX trees often expose the same visible input as multiple
    /// nested AXTextField elements (the wrapper + the inner input + sometimes
    /// internal edit elements). They overlap heavily but don't strictly contain
    /// each other, so a pure "child wins" rule misses them. Rule used here:
    /// if two detected fields' rects overlap by more than half of the smaller
    /// field's area, treat them as the same logical input and keep the smaller
    /// one (the inner, actually-focusable element).
    private static func dedupe(_ fields: [DetectedField]) -> [DetectedField] {
        var result: [DetectedField] = []
        outer: for f in fields {
            let fArea = f.rectAX.width * f.rectAX.height
            for i in result.indices {
                let existing = result[i]
                let eArea = existing.rectAX.width * existing.rectAX.height
                let inter = f.rectAX.intersection(existing.rectAX)
                if inter.isNull || inter.isEmpty { continue }
                let interArea = inter.width * inter.height
                let minArea = min(fArea, eArea)
                if minArea > 0 && interArea / minArea > 0.5 {
                    if fArea < eArea {
                        result[i] = f
                    }
                    continue outer
                }
            }
            result.append(f)
        }
        return result
    }

    private static func walk(_ element: AXUIElement,
                             lassoAX: CGRect,
                             into out: inout [DetectedField],
                             depth: Int) {
        if depth > 60 { return }

        let role: String? = stringAttr(element, kAXRoleAttribute as CFString)
        let subrole: String? = stringAttr(element, kAXSubroleAttribute as CFString)

        let roleAccepted: Bool = {
            if let r = role, writableTextRoles.contains(r) { return true }
            if subrole == kAXSearchFieldSubrole as String { return true }
            return false
        }()
        let subroleExcluded: Bool = subrole.map(excludedSubroles.contains) ?? false

        if roleAccepted && !subroleExcluded {
            if let rect = elementRectAX(element), isSettable(element) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                if lassoAX.contains(center) {
                    out.append(DetectedField(element: element, rectAX: rect, role: role))
                }
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                walk(child, lassoAX: lassoAX, into: &out, depth: depth + 1)
            }
        }
    }

    private static func elementRectAX(_ e: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef
        else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt),
              AXValueGetValue(s as! AXValue, .cgSize, &sz),
              sz.width > 4, sz.height > 4
        else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    private static func isSettable(_ e: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let status = AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
        return status == .success && settable.boolValue
    }

    private static func stringAttr(_ e: AXUIElement, _ attr: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr, &ref) == .success else { return nil }
        return ref as? String
    }
}
