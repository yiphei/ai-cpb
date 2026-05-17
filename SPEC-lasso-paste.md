# SPEC: Lasso Paste

> Multi-field AI paste activated by lassoing a region containing multiple input fields. The AI fills each field in the region based on copied context, in one paste operation.

This document is self-contained for a single implementer. It assumes familiarity with the existing single-field paste flow in `Sources/copybara/Paste/PasteController.swift` and the lasso UI in `Sources/copybara/Copy/`. Read those first.

---

## 1. Feature summary

**Current behavior.** `⌘⇧V` runs a focused-field paste: query AX system-wide for the focused element, screenshot the screen, annotate the focused element's rect with a red box, send one LLM call, paste the returned text via `⌘V`.

**New behavior.** `⌘⇧X` runs a lasso paste:

1. User presses `⌘⇧X`. A full-screen lasso overlay appears (visually distinct from copy-mode by color: **blue** border + fill).
2. User drags to select a rectangular region. On mouseup, the overlay tears down.
3. The app walks the AX tree of the frontmost app (captured before the overlay appeared) and collects all writable text fields whose **center** is inside the lasso rect.
4. The destination screen is screenshotted. The screenshot is annotated with **all** detected field rects — **one in red (the call's target), the rest in gray** — and indices are drawn outside each box with a leader line.
5. N LLM calls fire **in parallel**, one per detected field. Each call sees the same copy context, the same destination screenshot annotated with all sibling field rects, but with only its own field highlighted in red. Each call returns a single text value or `<<NO_PASTE>>`.
6. Per field, the writer focuses the field, synthesizes `⌘A` to clear, writes the returned text to the pasteboard, synthesizes `⌘V`, waits, then advances to the next field. Pasteboard is snapshotted once at start, restored once at end.
7. Failures (focus rejection, LLM error, per-field `<<NO_PASTE>>`) are collected and surfaced in a single notification at the end. Other fields still fill.

**Out of scope (explicitly):**

- Combobox / popup / select / date-picker fields. (Roles excluded: `AXComboBox`, `AXPopUpButton`.)
- Secure / password fields. (Role excluded: `AXSecureTextField`.)
- Rich-text editors and `contentEditable` (no special handling — they may or may not work via the ⌘V path; not actively supported).
- Electron and other apps with partial/no AX cooperation. Best-effort only.
- Multi-screen lassos. Lasso is constrained to the screen under the cursor at hotkey press (same constraint as copy mode).
- Cancellation mid-LLM-call.
- A preview-before-commit step.
- Per-field progress UI.

---

## 2. User-facing behavior

### 2.1 Trigger

- Default hotkey: **`⌘⇧X`** (Cmd + Shift + X).
- Configurable in Settings (new row alongside existing AI Copy and AI Paste hotkeys).
- Hotkey is global, registered via Carbon `RegisterEventHotKey` (same path as the other two — extend `HotkeyManager.HotkeyID`).

### 2.2 Lasso overlay (paste mode)

- Reuses `LassoOverlayWindow` and `LassoView`. `LassoView` is parameterized with a tint color so paste mode renders **blue** (`NSColor.systemBlue`) while copy mode continues to render **red** (`NSColor.systemRed`).
- Same gestures: mousedown-drag-mouseup commits, `Esc` cancels, drag <8pt in either dimension cancels (matches `CopyModeController.swift:69`).
- Crosshair cursor while overlay is up.
- MenuBar shows status `pasting…` from the moment hotkey fires (use `FlashState.pasting` — no new state needed).

### 2.3 Field detection rule

- A field "is inside the lasso" if its **center point** is inside the lasso rect (in screen coords, AX top-left space).
- Decision: center-point rule chosen for predictability — users can intentionally include/exclude edge-grazing fields by dragging tightly or generously. Alternatives (any-overlap, full-contain) were rejected as too permissive / too strict respectively.

### 2.4 No fields detected

- Show error notification: title `"No input fields found in selection"`, body `"Lasso a region containing one or more text fields and try again. Some apps (Electron, canvas-based apps) don't expose fields to macOS Accessibility."`
- Abort. Do not fall back to focused-field paste — that would conflate two intents.

### 2.5 Field write order

- Sort detected fields by **AX tree traversal order** (the order they were discovered during recursive walk). This typically matches tab order, which matches user expectation.
- Note: index labels in the annotated screenshot match this same order, so the LLM and the writer agree.

### 2.6 Multi-field paste result

- Each field is filled with the LLM's returned text (after clearing the field via ⌘A).
- If a per-field LLM call returns `<<NO_PASTE>>`, that field is left **untouched** (no clear, no write).
- If a per-field LLM call throws (HTTP error, timeout), that field is left untouched and a per-field failure is recorded.
- If focusing a field fails (AX rejects `kAXFocusedAttribute` and the window-raise retry also fails), that field is left untouched and a per-field failure is recorded.
- At the end, if any failures occurred, surface a **single summary notification**: title `"Lasso paste completed with N issues"`, body listing per-field reasons (e.g., `"Field 2: AI declined. Field 4: HTTP 529."`).
- Hotkey re-entrancy: while a lasso paste is in flight, the hotkey is suppressed via an `inFlight` guard (same pattern as `PasteController.run()`).

### 2.7 Pasteboard discipline

- Snapshot user's pasteboard once before the first field write.
- Restore user's pasteboard once after the last field write completes (or after all writes are abandoned).
- Pasteboard is briefly populated with each field's value as the writer cycles through. The user's clipboard is restored within ~2–3 seconds of the hotkey for a 5-field paste.

### 2.8 Indicator

- The existing `PasteIndicator` is shown while LLM calls are in flight, centered on the lasso rect (not on a field). Hide before any ⌘V is synthesized.

---

## 3. Architecture

### 3.1 New files

| File | Purpose |
|---|---|
| `Sources/copybara/Paste/LassoPasteController.swift` | Orchestrates the whole flow: lasso → field discovery → screenshot → parallel LLM → fill loop. Mirrors `CopyModeController`'s lifecycle pattern. |
| `Sources/copybara/Paste/AXFieldFinder.swift` | Recursively walks the AX tree of the captured frontmost app, collects writable text fields whose center is in the lasso rect. |
| `Sources/copybara/Paste/MultiFieldWriter.swift` | Per-field focus + ⌘A + pasteboard write + ⌘V + delay loop. Pure utility. |

### 3.2 Modified files

| File | Change |
|---|---|
| `Sources/copybara/Hotkeys/HotkeyCombo.swift` | Add `static let defaultLassoPaste = HotkeyCombo(keyCode: kVK_ANSI_X, carbonModifiers: cmdKey \| shiftKey)`. |
| `Sources/copybara/Config.swift` | Add `lassoPasteHotkey: HotkeyCombo`, default `.defaultLassoPaste`. Load/persist alongside existing `copy_hotkey` and `paste_hotkey` keys (JSON key: `"lasso_paste_hotkey"`). Add `setLassoPasteHotkey(_:)`. |
| `Sources/copybara/HotkeyManager.swift` | Add `HotkeyID.lassoPaste = 3`, `onLassoPaste` callback, `lassoPasteRef`, register/unregister in `applyCurrentHotkeys()`. |
| `Sources/copybara/AppDelegate.swift` | Wire `hotkeys.onLassoPaste = { Task { await LassoPasteController.shared.run() } }`. |
| `Sources/copybara/Copy/LassoView.swift` | Parameterize tint color. Add `var tintColor: NSColor = .systemRed` property. Replace `NSColor.systemRed` literals in `draw(_:)` with `tintColor`. Existing call sites (copy mode) keep the default; the new `LassoPasteController` sets `view.tintColor = .systemBlue` before installing the view. |
| `Sources/copybara/Paste/ImageAnnotator.swift` | Add new entry point `drawNumberedBoxes(on:, fields:, on screen:) -> CGImage`. Keep existing `drawRedBox(...)` for the single-field paste path. See §4.4 for the input type. |
| `Sources/copybara/Paste/PasteboardDriver.swift` | Add `sendCommandA()` mirroring `sendCommandV()` (uses `kVK_ANSI_A` instead of V). |
| `Sources/copybara/UI/SettingsWindow.swift` | Add a third hotkey row for "AI Lasso Paste" using the existing `hotkeyRow` helper. |
| `Sources/copybara/AI/LLMClient.swift` | Add `trailingUserText: String?` parameter (default `nil`) to the `LLMClient.sendRequest` protocol method and the `paste(...)` extension helper. Default `nil` preserves the existing single-field caller. See §4.6. |
| `Sources/copybara/AI/AnthropicClient.swift` | (a) Append the optional `trailingUserText` as the final text block in `userContent`, after the dest-image caption. (b) Add `cache_control: {"type": "ephemeral"}` to the last block of the cacheable prefix and to the system block. See §6. |
| `Sources/copybara/AI/OpenRouterClient.swift` | Append the optional `trailingUserText` as the final text block in `userContent`, after the dest-image caption. (Prompt caching not added — see §6.4.) |

---

## 4. Detailed algorithms

### 4.1 Frontmost-app capture timing

The lasso overlay window will itself become frontmost once shown — so we must capture the user's frontmost app **before** showing the overlay. Store it on `LassoPasteController`:

```swift
private var targetPID: pid_t?

func run() async {
    // ... permission / API-key / in-flight guards (mirror PasteController.run()) ...

    targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard targetPID != nil else { /* error notify + abort */ }

    // ... show lasso overlay ...
}
```

After the lasso commits, use `AXUIElementCreateApplication(targetPID!)` as the root for `AXFieldFinder.find(...)`.

### 4.2 Lasso → screen rect

Same conversion as `CopyModeController.swift:75-78`:

```swift
let windowRect = lassoView.convert(viewRect, to: nil)
let screenRect = window.convertToScreen(windowRect)   // AppKit, bottom-left origin
```

Convert to AX top-left space (matching what AX position attribute returns):

```swift
let primaryHeight = NSScreen.screens.first!.frame.height
let lassoAX = CGRect(
    x: screenRect.origin.x,
    y: primaryHeight - screenRect.origin.y - screenRect.height,
    width: screenRect.width,
    height: screenRect.height
)
```

`AXFieldFinder` operates entirely in AX top-left coords. `ImageAnnotator.drawNumberedBoxes` accepts AX coords and reuses the conversion logic already in `ImageAnnotator.drawRedBox` (`ImageAnnotator.swift:17-25`).

### 4.3 AX tree walk (`AXFieldFinder.swift`)

```swift
struct DetectedField {
    let element: AXUIElement
    let rectAX: CGRect      // AX top-left coords, global
    let role: String?
}

enum AXFieldFinder {
    private static let writableTextRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        // kAXSearchField is a subrole, not a primary role — handle via subrole check below.
    ]

    private static let excludedSubroles: Set<String> = [
        kAXSecureTextFieldSubrole as String,
    ]

    /// Walks the AX tree under `appElement` and returns text-writable fields whose
    /// **center point** lies inside `lassoAX` (AX top-left coords).
    /// Order: AX tree traversal order (≈ tab order).
    static func find(in appElement: AXUIElement, intersecting lassoAX: CGRect) -> [DetectedField] {
        var out: [DetectedField] = []
        walk(appElement, lassoAX: lassoAX, into: &out, depth: 0)
        return out
    }

    private static func walk(_ element: AXUIElement,
                             lassoAX: CGRect,
                             into out: inout [DetectedField],
                             depth: Int) {
        if depth > 60 { return }   // safety against pathological trees

        // 1. Inspect role / subrole. If this element is a candidate field, test it.
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

        // 2. Recurse into children — even if this element matched. AX trees occasionally
        // nest writable subfields inside containers that themselves report a text role.
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
```

Edge cases the walker handles implicitly:
- Pathologically deep trees → depth limit (60).
- Elements with no position/size → skipped.
- Elements not settable → skipped (catches read-only text fields, disabled inputs).
- Hidden / occluded fields → still discoverable via AX (we don't try to detect occlusion). User's lasso intent overrides; if the user lassos a covered area, they get whatever AX exposes.

### 4.4 Annotated destination screenshot (per-call)

We render **N annotated screenshots** — one per call — each emphasizing a different field. All siblings appear faded so the model can reason about partition without coordination:

- **Current field**: red stroke (`CGColor(red: 1, green: 0, blue: 0, alpha: 1)`), thick (`max(6, 4 * scale)`), 10% red fill.
- **Sibling fields**: gray stroke (`CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.9)`), thinner (`max(3, 2 * scale)`), no fill.
- **Index labels**: numeric `"1"`, `"2"`, ... drawn **outside** each box (above the top-left corner) with a 2-pixel leader line, using a bold system font sized `24 * scale` points. If positioning the label above would render it off the screen's pixel rect (field is near the top of the screen), position the label below the box instead. Label color matches box color. Background: small white rounded-rect with 80% alpha behind the digit so it remains readable on any backdrop.

`ImageAnnotator.drawNumberedBoxes(on:, fields:, on screen:)` accepts:

```swift
struct AnnotatedField {
    let rectAX: CGRect
    let isCurrent: Bool
    let index: Int   // 1-based, matches the field's position in the detection order
}

static func drawNumberedBoxes(
    on image: CGImage,
    fields: [AnnotatedField],
    on screen: NSScreen
) -> CGImage
```

Internally reuses the AX-to-pixel conversion from `drawRedBox` (`ImageAnnotator.swift:17-25`).

### 4.5 Parallel LLM calls

`LassoPasteController` runs N calls concurrently via `withTaskGroup`. Each task calls the **extended** `LLMClient.paste(copyPngs:destPng:trailingUserText:)` (see §3.2 and §4.6), passing a per-call sibling-awareness sentence built from `currentIndex` and `totalFields`:

```swift
struct FieldResult {
    let index: Int        // 1-based
    let text: String?     // nil = field skipped or failed
    let error: String?    // human-readable reason (nil on success)
}

private func runParallelCalls(
    client: LLMClient,
    copyPngs: [Data],
    annotatedDestPerCall: [(index: Int, png: Data)],
    totalFields: Int
) async -> [FieldResult] {
    await withTaskGroup(of: FieldResult.self) { group in
        for entry in annotatedDestPerCall {
            let trailing = siblingSentence(currentIndex: entry.index, totalFields: totalFields)
            group.addTask {
                do {
                    let text = try await client.paste(
                        copyPngs: copyPngs,
                        destPng: entry.png,
                        trailingUserText: trailing
                    )
                    if text == "<<NO_PASTE>>" {
                        return FieldResult(index: entry.index, text: nil,
                                           error: "AI declined")
                    }
                    return FieldResult(index: entry.index, text: text, error: nil)
                } catch {
                    return FieldResult(index: entry.index, text: nil,
                                       error: error.localizedDescription)
                }
            }
        }
        var results: [FieldResult] = []
        for await r in group { results.append(r) }
        return results.sorted { $0.index < $1.index }
    }
}
```

Notes:
- Each call goes through the existing `LLMClient.paste(...)` extension method, which logs to Logfire automatically. N calls = N Logfire records.
- The `LLMClient` value (`AnthropicClient` or `OpenRouterClient`) is shared across tasks — both are `Sendable` value types with no shared mutable state.
- `URLSession.shared` handles N concurrent requests fine.
- The existing `<<NO_PASTE>>` sentinel is preserved end-to-end: the existing system prompt already documents it.

### 4.6 Sibling-awareness sentence (per-call trailing user text)

To keep the cache-prefix stable across the N parallel calls (§6), **do not** vary the system prompt per call. Instead, each call appends a small per-call text block to its `userContent` array **after** the dest-image caption. The `LLMClient` protocol is extended (§3.2) with a `trailingUserText: String?` parameter that both `AnthropicClient` and `OpenRouterClient` honor by appending it as the final text block in `userContent`.

`LassoPasteController.siblingSentence(currentIndex:totalFields:)` produces:

```
"This is field {currentIndex} of {totalFields}. The destination image has {totalFields} fields marked: yours is the RED box; the GRAY boxes are sibling fields being filled in parallel by separate calls. Consider the sibling fields' labels and positions when deciding what to output, so you do not output content that belongs in another field. Output ONLY the text for the RED field, or <<NO_PASTE>>."
```

Because this text comes **after** the cache breakpoint (which sits on the last copy-image caption — see §6.2), it never invalidates the cached prefix. The system prompt is unchanged from the single-field path.

### 4.7 Multi-field writer (`MultiFieldWriter.swift`)

```swift
enum MultiFieldWriter {
    struct WriteOp {
        let field: AXFieldFinder.DetectedField
        let text: String
        let index: Int
    }

    /// Returns the indices of fields that failed to write (e.g., focus rejected).
    static func writeAll(_ ops: [WriteOp]) async -> [Int] {
        var failures: [Int] = []
        for op in ops {
            let ok = await writeOne(op)
            if !ok { failures.append(op.index) }
        }
        return failures
    }

    private static func writeOne(_ op: WriteOp) async -> Bool {
        // 1. Focus the field.
        let focused = await focus(op.field.element)
        if !focused { return false }

        // 2. Select-all the field's existing content. ⌘V on a selection replaces it
        //    (instead of inserting at the cursor), so any pre-existing text is overwritten.
        PasteboardDriver.sendCommandA()
        try? await Task.sleep(nanoseconds: 30_000_000)   // 30ms

        // 3. Write the value to the pasteboard.
        PasteboardDriver.writeString(op.text)
        try? await Task.sleep(nanoseconds: 30_000_000)   // 30ms

        // 4. Synthesize ⌘V.
        PasteboardDriver.sendCommandV()
        try? await Task.sleep(nanoseconds: 400_000_000)  // 400ms

        return true
    }

    private static func focus(_ element: AXUIElement) async -> Bool {
        // Try direct focus first.
        let status = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        if status == .success {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms — let focus settle
            return true
        }

        // Fallback: raise the element's window first, then retry focus.
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
```

Per-field timing per write: ~510ms (50 focus + 30 ⌘A + 30 pasteboard + 400 ⌘V). For 5 fields ≈ 2.5s.

The writer is **serial**, not parallel — synthesized key events must land in a known focus context. Parallelizing here would race the focus state.

### 4.8 Pasteboard discipline (`LassoPasteController`)

```swift
let saved = PasteboardDriver.snapshot()
let failures = await MultiFieldWriter.writeAll(ops)
PasteboardDriver.restore(saved)
```

Restore happens **after** the last write's tail-sleep, so the target has consumed the final paste.

---

## 5. `LassoPasteController` end-to-end skeleton

```swift
@MainActor
final class LassoPasteController: LassoViewDelegate {
    static let shared = LassoPasteController()

    private var window: LassoOverlayWindow?
    private var lassoView: LassoView?
    private var screen: NSScreen?
    private var targetPID: pid_t?
    private var inFlight = false

    func run() async {
        if inFlight { return }
        inFlight = true
        // inFlight is cleared in teardown() / completion paths

        // 1. Permission + API key preflight (copy/paste from PasteController.run()).
        guard preflight() else { inFlight = false; return }

        // 2. Capture frontmost app BEFORE showing overlay.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            Notify.error("No active app", "Could not determine the frontmost app to fill.")
            inFlight = false
            return
        }
        targetPID = pid

        // 3. Show lasso overlay (blue tint).
        guard let target = pickActiveScreen() else { inFlight = false; return }
        screen = target
        MenuBar.shared.flash(.pasting)
        showLassoOverlay(on: target)
    }

    // MARK: LassoViewDelegate

    func lassoDidCommit(viewRect: NSRect) {
        guard let screen, let window, let pid = targetPID else { teardown(); return }
        if viewRect.width < 8 || viewRect.height < 8 {
            teardown(); MenuBar.shared.flash(.idle); inFlight = false; return
        }
        let windowRect = lassoView!.convert(viewRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        teardown()

        // Wait for compositor to drop the dimming overlay before screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.030) { [self] in
            Task { await self.handleCommittedRect(screenRect: screenRect, screen: screen, pid: pid) }
        }
    }

    func lassoDidCancel() {
        teardown()
        MenuBar.shared.flash(.idle)
        inFlight = false
    }

    // MARK: Pipeline

    private func handleCommittedRect(screenRect: NSRect, screen: NSScreen, pid: pid_t) async {
        defer { inFlight = false }

        // a. Convert lasso rect to AX coords.
        let lassoAX = axRectFromScreenRect(screenRect)

        // b. Walk AX tree of captured frontmost app.
        let app = AXUIElementCreateApplication(pid)
        let fields = AXFieldFinder.find(in: app, intersecting: lassoAX)
        guard !fields.isEmpty else {
            Notify.error(
                "No input fields found in selection",
                "Lasso a region containing one or more text fields and try again. Some apps (Electron, canvas-based apps) don't expose fields to macOS Accessibility."
            )
            MenuBar.shared.flash(.idle); return
        }

        // c. Capture destination screen + encode N annotated variants.
        guard let raw = ScreenCapturer.captureScreen(screen) else {
            Notify.error("Capture failed", "Could not capture the destination screen.")
            MenuBar.shared.flash(.idle); return
        }
        let annotatedPngs: [(index: Int, png: Data)] = encodeAnnotatedVariants(
            raw: raw, fields: fields, screen: screen
        )
        guard annotatedPngs.count == fields.count else {
            Notify.error("Capture failed", "Could not encode annotated destination screenshots.")
            MenuBar.shared.flash(.idle); return
        }

        // d. Show paste indicator at lasso center.
        let lassoCenterAX = CGRect(
            x: lassoAX.midX, y: lassoAX.midY, width: 1, height: 1
        )
        await PasteIndicator.shared.show(near: lassoCenterAX, on: screen)

        // e. Fire N parallel LLM calls.
        let copyPngs = ContextStore.shared.copies.map(\.imagePng)
        let client = makeClient()
        let results = await runParallelCalls(
            client: client,
            copyPngs: copyPngs,
            annotatedDestPerCall: annotatedPngs,
            totalFields: fields.count
        )

        await PasteIndicator.shared.hide()

        // f. Build write ops, skip nil results.
        let ops: [MultiFieldWriter.WriteOp] = results.compactMap { r in
            guard let text = r.text, !text.isEmpty else { return nil }
            return MultiFieldWriter.WriteOp(
                field: fields[r.index - 1], text: text, index: r.index
            )
        }

        let saved = PasteboardDriver.snapshot()
        let writeFailures = await MultiFieldWriter.writeAll(ops)
        PasteboardDriver.restore(saved)

        // g. Surface a single combined notification if anything failed.
        summarizeFailures(results: results, writeFailures: writeFailures, totalFields: fields.count)

        MenuBar.shared.flash(.idle)
    }

    // ... helpers (preflight, makeClient, encodeAnnotatedVariants, summarizeFailures,
    //     siblingSentence, showLassoOverlay, pickActiveScreen, teardown,
    //     axRectFromScreenRect) ...
}
```

---

## 6. Anthropic prompt caching

### 6.1 Why

Each of the N parallel calls shares the same prefix: system prompt + copy images + their captions. Only the dest image and the trailing sibling-awareness sentence vary. Caching that prefix means call 1 writes the cache (full input cost) and calls 2..N read it (~10% of input cost) — *if* the first call returns before the others start. With true parallel firing, the first one in usually wins the cache write and the rest hit it.

### 6.2 Where to add `cache_control`

In `AnthropicClient.swift` `sendRequest(...)`, place a single `cache_control: {"type": "ephemeral"}` breakpoint on the **last block of the cacheable prefix** — i.e., the trailing text caption after the final copy image:

```swift
for (idx, png) in copyPngs.enumerated() {
    userContent.append([ "type": "image", "source": [...] ])
    let isLastCopy = (idx == copyPngs.count - 1)
    var caption: [String: Any] = [
        "type": "text",
        "text": "Image \(idx + 1) = copied content #\(idx + 1)."
    ]
    if isLastCopy {
        caption["cache_control"] = ["type": "ephemeral"]
    }
    userContent.append(caption)
}
// dest image, dest caption, sibling sentence — all AFTER the cache breakpoint, NOT cached.
```

Add the breakpoint to the **system** field too, by switching from a string to a list-of-blocks form:

```swift
"system": [
    [
        "type": "text",
        "text": systemPrompt,
        "cache_control": ["type": "ephemeral"]
    ]
]
```

(Anthropic accepts both string and array forms for `system`. The array form supports per-block `cache_control`.)

### 6.3 Constraints

- Minimum cacheable prefix ≈ 1024 tokens. Copy images easily clear this. If a multi-paste fires with no copy context, we abort before the call anyway.
- TTL: 5 minutes (default `ephemeral` cache). Sufficient for back-to-back multi-pastes within a session.
- Cache hits cost 10% of equivalent uncached input. Cache writes cost 1.25× of uncached input (paid once across the N calls in a batch).
- Net cost for a 5-field batch ≈ 1.25× (first call write) + 4 × 0.1× (subsequent hits) ≈ 1.65× single-call cost. Without caching: ~5× single-call cost.

### 6.4 OpenRouter

OpenRouter passes prompt caching through for Anthropic models when `cache_control` is included. For now, add the breakpoint only to `AnthropicClient.swift`. `OpenRouterClient.swift` works without caching — fine for an MVP, and the user can configure either provider.

---

## 7. Settings UI changes

In `SettingsWindow.swift` `SettingsView.body`, add a third row after the existing "AI Paste" row, immediately before the `HStack { Button("Clear key" ...) ... }` block:

```swift
hotkeyRow(label: "AI Lasso Paste",
          combo: $lassoPasteCombo,
          defaultCombo: .defaultLassoPaste,
          onCommit: { Config.shared.setLassoPasteHotkey($0) })
```

Add `@State private var lassoPasteCombo: HotkeyCombo = Config.shared.lassoPasteHotkey`.

The existing `hotkeyRow` helper requires no change. `KeyRecorderField` is unchanged.

---

## 8. Error handling matrix

| Failure | Behavior |
|---|---|
| `inFlight == true` when hotkey pressed | Silently ignore. |
| No Screen Recording permission | Same notification as `CopyModeController.swift:16-21`. Abort. |
| No API key | Same notification as `PasteController.swift:21-25`. Abort. |
| No copy context | `Notify.error("No AI-copied content yet", "Press <copy hotkey> and lasso some content first, then try lasso paste again.")`. Abort. |
| `NSWorkspace.shared.frontmostApplication` nil | `Notify.error("No active app", "Could not determine the frontmost app to fill.")`. Abort. |
| Lasso drag <8pt | Treat as cancel. No notification. |
| `Esc` during lasso | Cancel. No notification. |
| Lasso committed but `AXFieldFinder.find` returns empty | `Notify.error("No input fields found in selection", "Lasso a region containing one or more text fields and try again. Some apps (Electron, canvas-based apps) don't expose fields to macOS Accessibility.")`. Abort. |
| `ScreenCapturer.captureScreen` returns nil | `Notify.error("Capture failed", ...)`. Abort. |
| Annotated PNG encoding fails | `Notify.error("Capture failed", "Could not encode annotated destination screenshots.")`. Abort. |
| Per-field LLM call throws | Record failure. Continue other calls. Surface in summary at end. |
| Per-field LLM returns `<<NO_PASTE>>` | Record per-field decline. Skip that field's write. Surface in summary at end. |
| Per-field `MultiFieldWriter.focus` fails | Record write failure. Continue to next field. Surface in summary at end. |
| Some succeed, some fail | At end, one summary notification: `"Lasso paste completed with N issues"` body lists per-field reasons. |
| **All** N calls fail / decline | Notification: `"Lasso paste failed"` body: per-field reasons. |
| All calls and writes succeed | No notification. MenuBar returns to `.idle`. |

---

## 9. Acceptance criteria

A lasso-paste build is considered conformant when all of the following hold:

- `⌘⇧X` activates the blue lasso overlay (visually distinguishable from copy-mode red).
- `Esc` cancels the overlay; drag <8pt cancels.
- Lasso around a 3-field native form (e.g., a System Settings pane with first/last/email): all 3 fields detected, 3 LLM calls fire, 3 fields filled, user's pasteboard restored at end.
- Lasso around a 3-field Safari form: all 3 fields detected, filled. React-controlled inputs persist (don't snap back).
- Lasso around a 5-field Chrome form: same.
- Lasso around an empty region: error notification "No input fields found", no crash.
- Lasso around a region whose fields contain pre-existing text: pre-existing text is replaced, not appended.
- Lasso with no copy context yet: error notification "No AI-copied content yet".
- Lasso while LLM is mid-call: subsequent `⌘⇧X` is suppressed.
- Settings UI shows three hotkey rows, all editable, defaults restorable.
- Rebind to a different combo (e.g., `⌃⌥P`) takes effect immediately without restart.
- Logfire (if configured) records N separate entries per lasso paste, with `cache_creation_input_tokens` on the first and `cache_read_input_tokens` on the rest (within 5min of each other).
- A field whose LLM call returns `<<NO_PASTE>>` is left untouched; other fields still fill; summary notification lists the declined field.

---

## 10. References to existing code

| Existing pattern | File:line | What to reuse |
|---|---|---|
| Lasso overlay window | `Sources/copybara/Copy/LassoOverlayWindow.swift` | Reuse as-is. |
| Lasso view with gestures | `Sources/copybara/Copy/LassoView.swift` | Reuse; parameterize tint color. |
| Lasso-controller lifecycle | `Sources/copybara/Copy/CopyModeController.swift` | Template for `LassoPasteController` (overlay show, teardown, screen pick, mouseup→committed→post-compositor screenshot). |
| Screen capture | `Sources/copybara/Paste/ScreenCapturer.swift` | Reuse `captureScreen`, `png`. |
| Single-box annotation | `Sources/copybara/Paste/ImageAnnotator.swift:8-59` | Reuse coord-conversion logic; add `drawNumberedBoxes` alongside `drawRedBox`. |
| Pasteboard ⌘V | `Sources/copybara/Paste/PasteboardDriver.swift:34-47` | Mirror as `sendCommandA` (`kVK_ANSI_A` instead of `kVK_ANSI_V`). |
| LLM client call + Logfire | `Sources/copybara/AI/LLMClient.swift:44-97` | Reuse `paste(...)` unchanged. Per-call Logfire happens automatically. |
| Hotkey registration | `Sources/copybara/HotkeyManager.swift` | Add third `HotkeyID` and `EventHotKeyRef`. |
| Hotkey settings row | `Sources/copybara/UI/SettingsWindow.swift:88-109` | Reuse `hotkeyRow` helper. |
| Paste indicator | `Sources/copybara/Paste/PasteIndicator.swift` | Reuse; `show(near:)` accepts an AX rect — pass the lasso center as a 1×1 rect. |
| AX→AppKit conversion | `Sources/copybara/Paste/PasteController.swift:99-112` | Identical conversion used in `LassoPasteController`. Either factor into a shared helper or duplicate (it's 7 lines). |
