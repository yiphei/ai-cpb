# AI Copy/Paste Buddy (`ai-cpb`) — MVP Tech Spec

## Context

The user wants a macOS menu-bar utility that adds two new globally-bound hotkeys to the OS:

- **`⌘⇧C` — AI Copy.** Lets the user "lasso" a region on screen with the mouse. The pixels inside the rectangle are captured as a PNG and stashed as the current AI-copy context.
- **`⌘⇧V` — AI Paste.** The user has already clicked into a destination text field in some app. We take a screenshot of that screen, programmatically draw a bright red bounding box around the AX-focused element to mark the paste target, and send `{copy_image, destination_image}` to Claude Sonnet 4.6. Claude returns a single string — the text to paste — possibly transformed to fit the destination field. We write that to the pasteboard and synthesize a ⌘V to deliver it.

Target audience: the user themselves, running locally. No distribution, no Sparkle, no notarization, no App Store. Single Xcode project, signed only for local-run.

Out-of-scope (per user): app distribution, fancy progress animations, true-lasso (rectangle is fine), standalone window UI, multi-monitor copy regions, 100% app coverage. AX-hostile apps are allowed to fail.

---

## High-level architecture

```
AppDelegate (menu bar item, lifecycle, permission gating)
 ├── HotkeyManager        — Carbon RegisterEventHotKey for ⌘⇧C and ⌘⇧V
 ├── CopyModeController   — lasso overlay window, screen capture, crop, stash
 │     └── LassoOverlayWindow / LassoView (transparent NSWindow on active screen)
 ├── PasteController      — orchestrates capture → AX-bounds → red box → AI call → paste
 │     ├── AXHelper       — find focused element + global rect
 │     ├── ScreenCapturer — CGDisplayCreateImage of frontmost screen
 │     ├── ImageAnnotator — draw red rect on a CGImage
 │     └── PasteboardDriver — save/write/restore NSPasteboard + CGEvent ⌘V
 ├── OpenRouterClient     — OpenRouter chat-completions HTTP client (URLSession, no SDK)
 ├── ContextStore         — in-memory current AI-copy PNG + metadata
 ├── ConfigLoader         — reads ~/.config/ai-cpb/config.json for API key
 └── PermissionsHelper    — checks/requests Screen Recording + Accessibility
```

State that crosses operations: `ContextStore.currentCopy: CopyPayload?` only. No persistence; cleared on app quit.

---

## Required macOS permissions

The user must grant these once via **System Settings → Privacy & Security**:

1. **Screen Recording** — required for `CGDisplayCreateImage` to return real pixels (otherwise returns the desktop wallpaper only).
2. **Accessibility** — required to (a) query `AXFocusedUIElement` for the paste-destination rect, and (b) reliably post synthetic `⌘V` via `CGEventPost(.cghidEventTap, …)`.

At app launch, call:

- `CGPreflightScreenCaptureAccess()` → if false, `CGRequestScreenCaptureAccess()` and open System Settings.
- `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` → opens the Accessibility prompt automatically.

The menu bar dropdown should expose a "Check Permissions" item that re-runs both and surfaces missing ones.

No microphone, camera, contacts, files, or network entitlements beyond outbound HTTPS (which doesn't need an entitlement for non-sandboxed apps).

---

## Project setup

1. **Xcode → New Project → macOS → App.** Product name `ai-cpb`. Interface: AppKit (not SwiftUI). Language: Swift. Use Storyboards = NO (delete `MainMenu.storyboard`, `Main.storyboard`, and the storyboard reference in Info.plist). Bundle ID: `com.local.aicpb`.

2. **Info.plist** keys:
   - `LSUIElement` = `YES` (no Dock icon, menu-bar-only app).
   - `NSAppTransportSecurity` → leave default; openrouter.ai is HTTPS.
   - Do NOT add a sandbox entitlement (we need broad screen capture + AX, which the sandbox forbids).

3. **Signing & Capabilities:** "Sign to Run Locally" is sufficient. Disable App Sandbox if Xcode added it by default. Disable Hardened Runtime is optional — leave it on; it doesn't block AX or screen capture for unsandboxed apps.

4. **No third-party dependencies.** Everything below uses only Foundation, AppKit, CoreGraphics, ApplicationServices (AX), Carbon (hotkeys), and URLSession.

5. **AppDelegate wiring:** in `AppDelegate.applicationDidFinishLaunching` set `NSApp.setActivationPolicy(.accessory)`, build the `NSStatusItem`, instantiate the managers, and run `PermissionsHelper.checkAll()`.

6. **Config file** at `~/.config/ai-cpb/config.json`:
   ```json
   { "openrouter_api_key": "sk-or-..." }
   ```
   `ConfigLoader` reads at startup, surfaces missing-key state in the menu bar dropdown ("⚠️ API key missing"). No UI for entering the key — the user edits the file by hand (single-user MVP).

---

## File layout

```
ai-cpb/
├── ai-cpb.xcodeproj
├── ai-cpb/
│   ├── AppDelegate.swift
│   ├── MenuBar.swift
│   ├── HotkeyManager.swift
│   ├── Permissions.swift
│   ├── Config.swift
│   ├── ContextStore.swift
│   ├── Copy/
│   │   ├── CopyModeController.swift
│   │   ├── LassoOverlayWindow.swift
│   │   └── LassoView.swift
│   ├── Paste/
│   │   ├── PasteController.swift
│   │   ├── AXHelper.swift
│   │   ├── ScreenCapturer.swift
│   │   ├── ImageAnnotator.swift
│   │   └── PasteboardDriver.swift
│   └── AI/
│       └── OpenRouterClient.swift
└── Info.plist
```

Single-target app. No tests for MVP.

---

## Component specs

### 1. `HotkeyManager.swift` — Carbon global hotkeys

Two hotkeys: `⌘⇧C` (kVK_ANSI_C = 0x08) and `⌘⇧V` (kVK_ANSI_V = 0x09), modifiers `cmdKey | shiftKey`.

Implementation outline:

```swift
import Carbon.HIToolbox

final class HotkeyManager {
    enum HotkeyID: UInt32 { case copy = 1, paste = 2 }
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    private var refs: [EventHotKeyRef?] = []

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData!).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout.size(ofValue: hkID), nil, &hkID)
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
            Unmanaged.passUnretained(self).toOpaque(),
            nil)

        register(keyCode: UInt32(kVK_ANSI_C), id: .copy)
        register(keyCode: UInt32(kVK_ANSI_V), id: .paste)
    }

    private func register(keyCode: UInt32, id: HotkeyID) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: 0x41494350 /* 'AICP' */, id: id.rawValue)
        RegisterEventHotKey(keyCode,
                            UInt32(cmdKey | shiftKey),
                            hkID,
                            GetApplicationEventTarget(),
                            0, &ref)
        refs.append(ref)
    }
}
```

`AppDelegate` wires `onCopy = { CopyModeController.shared.begin() }`, `onPaste = { PasteController.shared.run() }`.

### 2. `CopyModeController.swift` + lasso UI

On `⌘⇧C`:

1. Determine the active screen: `let screen = NSScreen.screens.first { NSMouseInWindow.contains($0.frame) } ?? NSScreen.main!`. Use `NSEvent.mouseLocation` to find the cursor's screen — pick the `NSScreen` whose `frame` contains it.
2. Present a borderless transparent `NSWindow` over exactly that screen (`LassoOverlayWindow`):
   - `styleMask = .borderless`
   - `level = .screenSaver` (above almost everything; can become key)
   - `isOpaque = false`, `backgroundColor = NSColor.black.withAlphaComponent(0.08)` (subtle dim to signal "copy mode")
   - `ignoresMouseEvents = false`
   - `acceptsMouseMovedEvents = true`
   - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
3. Set cursor: `NSCursor.crosshair.push()` in `mouseEntered:`; pop on close.
4. `LassoView` is a flipped `NSView` filling the window. Override:
   - `mouseDown(with:)` → `startPoint = event.locationInWindow`, `currentPoint = startPoint`, `needsDisplay = true`
   - `mouseDragged(with:)` → update `currentPoint`, redraw
   - `mouseUp(with:)` → compute final `NSRect` between start and current, call back into `CopyModeController.commit(rect:)`
   - `draw(_:)` → if dragging, fill rect with `NSColor.systemRed.withAlphaComponent(0.10)` and stroke a 2pt red `NSBezierPath` border. Optionally a 1pt white outer stroke for contrast on dark backgrounds.
   - `keyDown(with:)` → if `event.keyCode == 53` (Escape), cancel and close the window.
   - `acceptsFirstResponder = true`; window's `makeFirstResponder(lassoView)` after `makeKeyAndOrderFront`.
5. **Important**: the overlay must close BEFORE the screen capture, otherwise we capture our own dimming + border. Sequence in `commit(rect:)`:
   a. Compute the rectangle in screen coordinates: convert lasso view-local rect → window rect → screen rect (using `window.convertToScreen(_:)`).
   b. Close the overlay window and `NSCursor.pop()`.
   c. After a 30 ms `DispatchQueue.main.asyncAfter` (let the compositor commit the close), call `ScreenCapturer.captureScreen(_:)` for that screen, crop to the screen-relative rect, encode as PNG.
   d. Store in `ContextStore.shared.currentCopy = CopyPayload(image: pngData, capturedAt: Date())`.
   e. Briefly flash the menu bar icon (e.g., swap title for 400ms then restore) as feedback. No sound.

Normalize the lasso rect: `NSRect(x: min(startX, endX), y: min(startY, endY), width: abs(dx), height: abs(dy))`. Reject rects smaller than 8×8 pt as accidental clicks (silently no-op + close).

### 3. `ScreenCapturer.swift`

```swift
enum ScreenCapturer {
    /// Capture the full display containing `screen`. Returns a CGImage in physical pixels.
    static func captureScreen(_ screen: NSScreen) -> CGImage? {
        guard let dispID = (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { return nil }
        return CGDisplayCreateImage(CGDirectDisplayID(dispID))
    }

    static func crop(_ image: CGImage, toScreenRect rect: CGRect, on screen: NSScreen) -> CGImage? {
        // rect is in AppKit screen coords (origin bottom-left of the screen's frame).
        // CGImage is in physical pixels with top-left origin.
        let scale = screen.backingScaleFactor
        let screenFrame = screen.frame
        let xPx = (rect.origin.x - screenFrame.origin.x) * scale
        let yPxFromTop = (screenFrame.maxY - rect.maxY) * scale
        let wPx = rect.width * scale
        let hPx = rect.height * scale
        let cropRect = CGRect(x: xPx, y: yPxFromTop, width: wPx, height: hPx).integral
        return image.cropping(to: cropRect)
    }

    static func png(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
```

Note: `CGDisplayCreateImage` is deprecated in macOS 14+ but still works and is far simpler than ScreenCaptureKit for an MVP. If the OS deprecation warning bothers the implementer, suppress with `@available` annotations — do not rewrite using SCStream for MVP.

### 4. `AXHelper.swift` — focused element bounds

```swift
struct FocusedField { let rect: CGRect; let role: String? }

enum AXHelper {
    static func focusedFieldRect() -> FocusedField? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused as! AXUIElement?
        else { return nil }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        guard let posRef, let sizeRef else { return nil }

        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        // AX coords are top-left-origin, in points, screen-global.
        return FocusedField(rect: CGRect(origin: pos, size: size), role: role)
    }
}
```

Edge cases: if no focused element, `PasteController` skips the red-box annotation and sends just the unmodified destination screenshot.

### 5. `ImageAnnotator.swift` — red bounding box

```swift
enum ImageAnnotator {
    /// Draws a thick red rectangle on `image` at `rectAXTopLeft` (AX top-left origin in points)
    /// relative to `screen`. Returns a new CGImage.
    static func drawRedBox(on image: CGImage,
                           rectAXTopLeft: CGRect,
                           on screen: NSScreen) -> CGImage {
        let scale = screen.backingScaleFactor
        let screenFrame = screen.frame
        let xPx = (rectAXTopLeft.origin.x - screenFrame.origin.x) * scale
        let yPx = (rectAXTopLeft.origin.y - screenFrame.origin.y) * scale
        let wPx = rectAXTopLeft.width * scale
        let hPx = rectAXTopLeft.height * scale
        let pxRect = CGRect(x: xPx, y: yPx, width: wPx, height: hPx).integral

        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Image is top-left origin in physical pixels; CGContext is bottom-left. Flip.
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: 0, y: -CGFloat(image.height))

        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(max(6, 4 * scale))
        ctx.stroke(pxRect)
        // Subtle red fill inside to make it loud
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.10))
        ctx.fill(pxRect)
        return ctx.makeImage()!
    }
}
```

This resolves the user's caret-flicker concern: we never rely on the system caret; we draw our own unmissable marker on the snapshot itself. Caret state at capture time is irrelevant.

### 6. `OpenRouterClient.swift`

Single endpoint: `POST https://openrouter.ai/api/v1/chat/completions` (OpenAI-compatible).

Headers:
- `Authorization: Bearer <key>`
- `Content-Type: application/json`
- `HTTP-Referer: https://github.com/yiphei/ai-cpb` (OpenRouter attribution; optional)
- `X-Title: ai-cpb` (OpenRouter attribution; optional)

Body:

```json
{
  "model": "anthropic/claude-sonnet-4.6",
  "max_tokens": 1024,
  "messages": [
    { "role": "system", "content": "<system prompt — see below>" },
    { "role": "user", "content": [
        { "type": "image_url",
          "image_url": { "url": "data:image/png;base64,<COPY_PNG_B64>" } },
        { "type": "text", "text": "Image 1 = copied content." },
        { "type": "image_url",
          "image_url": { "url": "data:image/png;base64,<DEST_PNG_B64>" } },
        { "type": "text", "text": "Image 2 = paste destination (red rectangle marks the target input field)." }
    ]}
  ]
}
```

System prompt (verbatim):

```
You are an AI paste assistant. The user has copied content (Image 1) and wants to paste relevant data into a destination text input on their screen (Image 2). The destination input field is marked with a bright red rectangle.

Your job: decide what text to put into the marked field. You may:
- Extract a strict substring from Image 1.
- Transform Image 1's content: strip filler words, restructure as a list, normalize formatting, summarize, etc., to fit what the destination field is asking for.

Look at labels, placeholder text, surrounding UI in Image 2 to infer the field's expected format (e.g., comma-separated list, single name, full address, date in MM/DD/YYYY).

Output ONLY the exact text to paste. No preamble. No explanation. No surrounding quotes. No markdown fences. No trailing newline. If the answer is a list, format it the way the field expects.

If you genuinely cannot determine what to paste, output exactly: <<NO_PASTE>>
```

Response parsing: take `response.choices[0].message.content` (string), trim whitespace. If it equals `<<NO_PASTE>>`, abort the paste with a user-visible error (NSUserNotification or menu-bar flash) and leave the clipboard untouched.

Timeout: 25 s. On non-2xx or timeout, abort + notify, do not paste, do not touch pasteboard.

Implementation: `URLSession.shared.data(for:)` with an `async` API. No streaming.

### 7. `PasteboardDriver.swift` — save / write / fake ⌘V / restore

```swift
enum PasteboardDriver {
    /// Returns a snapshot of all current pasteboard items for later restore.
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
        pb.writeObjects(items)
    }

    static func sendCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)!
        let vUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)!
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
    }
}
```

### 8. `PasteController.swift` — orchestration

Pseudocode:

```swift
func run() async {
    guard let payload = ContextStore.shared.currentCopy else {
        notify("No AI-copied content yet. Press ⌘⇧C first."); return
    }
    // 1. Identify destination screen = screen containing the focused element (or main).
    let focused = AXHelper.focusedFieldRect()
    let destScreen: NSScreen = {
        if let r = focused?.rect,
           let s = NSScreen.screens.first(where: { $0.frame.intersects(axToAppKit(r, $0)) }) { return s }
        return NSScreen.main!
    }()

    // 2. Capture that screen.
    guard let raw = ScreenCapturer.captureScreen(destScreen) else {
        notify("Screen capture failed (check Screen Recording permission)."); return
    }

    // 3. Annotate with red box if we have AX bounds.
    let annotated: CGImage = focused.map { ImageAnnotator.drawRedBox(on: raw, rectAXTopLeft: $0.rect, on: destScreen) } ?? raw
    guard let destPng = ScreenCapturer.png(annotated) else { return }

    // 4. Call Claude.
    let text: String
    do {
        text = try await OpenRouterClient.shared.paste(copyPng: payload.image, destPng: destPng)
    } catch {
        notify("AI call failed: \(error.localizedDescription)"); return
    }
    guard text != "<<NO_PASTE>>" else { notify("AI declined to paste."); return }

    // 5. Pasteboard dance.
    let saved = PasteboardDriver.snapshot()
    PasteboardDriver.writeString(text)
    // Tiny gap to ensure the destination process can read the new pasteboard.
    try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms
    PasteboardDriver.sendCommandV()
    // Wait for the target to consume the clipboard before restoring.
    try? await Task.sleep(nanoseconds: 250_000_000) // 250 ms
    PasteboardDriver.restore(saved)
}
```

Coordinate note: AX returns top-left-origin points in a single global space where the primary screen's top-left is origin. AppKit's `NSScreen.frame` uses bottom-left origin with the primary screen at origin. The `axToAppKit` helper:

```swift
func axToAppKit(_ axRect: CGRect, _ screen: NSScreen) -> CGRect {
    let primaryHeight = NSScreen.screens.first!.frame.height
    return CGRect(x: axRect.origin.x,
                  y: primaryHeight - axRect.origin.y - axRect.height,
                  width: axRect.width, height: axRect.height)
}
```

(Used only for screen-membership testing; `ImageAnnotator` works directly in AX coords on the pixel buffer because both AX and the CGImage use top-left origin.)

### 9. `MenuBar.swift`

`NSStatusItem` with a small symbol icon (`NSImage(systemSymbolName: "wand.and.stars", …)`). Dropdown items:

- `Status: idle / copying / pasting…` (disabled item, just a label)
- separator
- `Clear copied context` (only enabled if `ContextStore.currentCopy != nil`)
- `Check permissions`
- `Reveal config file` (opens `~/.config/ai-cpb/` in Finder)
- separator
- `Quit`

Flash mechanism for feedback: when copy completes, briefly set the status item's `button.image` to a filled variant (`wand.and.stars.inverse`) for 350 ms then restore. When paste is in flight, set it to a yellow-tinted variant; restore on completion.

### 10. `ContextStore.swift`

```swift
struct CopyPayload {
    let imagePng: Data
    let capturedAt: Date
}

final class ContextStore {
    static let shared = ContextStore()
    private(set) var currentCopy: CopyPayload?
    func setCopy(_ p: CopyPayload) { currentCopy = p }
    func clear() { currentCopy = nil }
}
```

No disk persistence. Lost on quit — by design.

---

## Error / failure handling

| Condition | Behavior |
| --- | --- |
| ⌘⇧V pressed with no prior copy | Menu-bar flash + `NSUserNotification` "No AI-copied content yet." Pasteboard untouched. |
| Screen Recording denied | Menu-bar item highlights red; clicking "Check Permissions" reopens System Settings. Operations abort early. |
| Accessibility denied | Same as above. Paste still attempted via pasteboard + ⌘V (works without AX, just without the red-box hint to the model). |
| AX returns no focused element | Skip red-box annotation. Send unmodified destination screenshot. Continue. |
| AI returns `<<NO_PASTE>>` | Notify + abort. Pasteboard untouched. |
| AI network error / non-2xx / timeout (25s) | Notify + abort. Pasteboard untouched. |
| Lasso rect < 8×8 pt | Silently cancel copy. |
| Escape during lasso | Cancel copy, close overlay. |

All notifications: short, plain text, via `NSUserNotificationCenter` (or `UNUserNotificationCenter` — either works; `NSUserNotificationCenter` is deprecated but needs no entitlement and works for a local-run unsandboxed app).

---

## AI prompt details (recap)

- One `messages` turn with `[image, text, image, text]` content array, in that order.
- Both images are PNG, base64-encoded.
- `max_tokens = 1024` (paste payloads are short; ceiling guards against runaway output).
- `temperature` omitted (default). The system prompt requires raw output with no formatting, which Sonnet 4.6 reliably honors.
- Model: `"claude-sonnet-4-6"`.

---

## Manual verification plan

Run these end-to-end after first build, in order. Each is a hard pass/fail.

1. **Permissions.** Launch app, grant Screen Recording + Accessibility when prompted, relaunch.
2. **Hotkey registration.** With another app focused, press ⌘⇧C → menu-bar status item flashes "copying" and the screen dims slightly with a crosshair cursor. ESC closes cleanly.
3. **Lasso copy.** Drag a rectangle around any text on screen → overlay closes, status item flashes "copied". The "Clear copied context" menu item is now enabled.
4. **Plain-substring paste.** Open TextEdit. Type "My name is ___". Place caret on the blank. Press ⌘⇧V. Expected: name appears at caret. Inspect log: 2 images + 1 system + 1 user-text payload sent to openrouter.ai.
5. **Transform paste (the canonical case).** In Messages or Notes, write `im allergic to onions and also garlic. Oh dont forget tomatoes as well`. ⌘⇧C around it. Open a webpage with an allergies form field (any OpenTable reservation page works; or just a plain `<input placeholder="allergies (comma-separated)">` test page). Click the field. ⌘⇧V. Expected: `onion, garlic, tomato` (order may vary) pasted into the field.
6. **Caret-flicker resilience.** Repeat #5 five times in rapid succession in the same field. Red-box annotation must succeed each time — the AX bounds are stable regardless of caret blink.
7. **Multi-monitor copy on secondary.** With cursor on a secondary display, ⌘⇧C → overlay appears only on that display, lasso captures only that display's pixels.
8. **Pasteboard restore.** Copy something normal with ⌘C ("hello"). Then ⌘⇧V into a TextEdit doc (using a prior AI-copy). After paste settles, press ⌘V — `hello` must still paste. (Confirms `PasteboardDriver.restore` works.)
9. **No-copy guard.** Fresh launch (or after "Clear copied context"). Press ⌘⇧V. Expected: notification "No AI-copied content yet."
10. **AX-hostile target acceptable failure.** Try ⌘⇧V into a Chrome web `<textarea>` — expected to work (pasteboard route). Try into something genuinely hostile (e.g., a Citrix/VMWare canvas, or a game). Expected: ⌘V is delivered but the target may ignore it; not a regression.

If steps 4 and 5 pass, the MVP is functional.

---

## Critical files to be created (summary)

- `ai-cpb/AppDelegate.swift`
- `ai-cpb/MenuBar.swift`
- `ai-cpb/HotkeyManager.swift`
- `ai-cpb/Permissions.swift`
- `ai-cpb/Config.swift`
- `ai-cpb/ContextStore.swift`
- `ai-cpb/Copy/CopyModeController.swift`
- `ai-cpb/Copy/LassoOverlayWindow.swift`
- `ai-cpb/Copy/LassoView.swift`
- `ai-cpb/Paste/PasteController.swift`
- `ai-cpb/Paste/AXHelper.swift`
- `ai-cpb/Paste/ScreenCapturer.swift`
- `ai-cpb/Paste/ImageAnnotator.swift`
- `ai-cpb/Paste/PasteboardDriver.swift`
- `ai-cpb/AI/OpenRouterClient.swift`
- `Info.plist` (set `LSUIElement = YES`, remove storyboard refs)
- `~/.config/ai-cpb/config.json` (created by user, holds `openrouter_api_key`)

No reused project code (greenfield). All listed APIs are first-party Apple frameworks; no SPM/CocoaPods deps.
