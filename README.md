# ai-cpb

**AI Copy/Paste Buddy** — a macOS menu-bar utility that adds two AI-powered hotkeys to the OS:

- **`⌘⇧C` — AI Copy.** Lasso a region on screen with the mouse. The pixels inside the rectangle are captured as a PNG and stashed as the current AI-copy context.
- **`⌘⇧V` — AI Paste.** Click into any text field, then hit the hotkey. The app screenshots the destination, marks the focused input with a bright red bounding box, and sends both images to Claude Sonnet 4.6. Claude returns the text to paste — possibly transformed to fit the destination — and the app writes it to the pasteboard and synthesizes a `⌘V`.

## The pitch

Traditional copy/paste moves bytes verbatim. AI Copy/Paste moves *intent*. Copy a rambling text message from a friend ("im allergic to onions and also garlic. Oh dont forget tomatoes as well"), then paste into a restaurant's allergies field — the app sends both the copied content and a screenshot of the destination form to Claude, which figures out the field expects a comma-separated list and pastes `onion, garlic, tomato`.

The destination input is identified by drawing a thick red rectangle on the screenshot before sending it to the model, using macOS Accessibility APIs to find the focused element's bounds. This sidesteps caret-flicker issues and gives the model an unambiguous target.

## How it works

```
⌘⇧C  →  lasso overlay  →  screen capture  →  crop  →  stashed as PNG
⌘⇧V  →  AX-focused element bounds  →  screen capture  →  draw red box
     →  POST {copy_png, dest_png} to OpenRouter (Claude Sonnet 4.6)
     →  receive text  →  save pasteboard  →  write text  →  synth ⌘V  →  restore pasteboard
```

The pasteboard is snapshotted before AI paste and restored ~250 ms after, so a normal `⌘C` followed by `⌘V` still works as expected.

## Requirements

- macOS 14+ (Apple Silicon).
- **Screen Recording** permission — for capturing real screen pixels.
- **Accessibility** permission — for locating the focused input and synthesizing `⌘V`.
- An **OpenRouter API key** ([openrouter.ai/keys](https://openrouter.ai/keys)).

The app prompts for both permissions on first launch via System Settings.

## Setup

1. Build and run the app (single Xcode project, signed for local run only — no notarization, no Sparkle, no App Store).
2. On first launch, a Settings window appears asking for your OpenRouter API key. Paste it and click **Save**. The key is stored in the macOS Keychain (encrypted at rest, device-local, not iCloud-synced).
3. Grant Screen Recording + Accessibility when prompted.
4. Use `⌘⇧C` / `⌘⇧V` anywhere.

The Settings window is reachable any time via the menu-bar dropdown (`Settings…`, `⌘,`).

## Menu bar

The menu bar icon exposes:

- Status (idle / copying / pasting)
- Clear copied context
- Check permissions
- Settings… (`⌘,`) — view / edit / clear the API key
- Quit

The icon flashes briefly on copy and paste as feedback.

## Scope

**In scope** for the MVP:

- Single-user, local-only — no distribution pipeline, no auto-update.
- Rectangle "lasso" (visually presented as a lasso, internally a rectangle).
- Single-monitor copy regions (any monitor works, but a region can't span two).
- Best-effort app coverage — AX-friendly apps work great; AX-hostile apps (some Electron, Citrix canvases, games) may fail silently.

**Out of scope:**

- App Store / notarization / Sparkle.
- Multi-monitor lasso regions.
- Hotkey rebinding UI.
- Model selection UI (hardcoded to `anthropic/claude-sonnet-4.6`).
- Telemetry, animations, sound effects.

## Failure modes

| Condition | Behavior |
| --- | --- |
| `⌘⇧V` with no prior copy | Notification: "No AI-copied content yet." Pasteboard untouched. |
| Screen Recording / Accessibility denied | Menu bar surfaces the missing permission; operation aborts. |
| No AX-focused element | Skip the red-box hint; send the unmodified destination screenshot. |
| Model returns `<<NO_PASTE>>` | Notify + abort. Pasteboard untouched. |
| Network error or timeout (25 s) | Notify + abort. Pasteboard untouched. |
| Lasso rect < 8×8 pt | Treated as accidental click; silently cancel. |
| Escape during lasso | Cancel + close overlay. |

## Implementation notes

- Pure first-party Apple frameworks — AppKit, CoreGraphics, ApplicationServices (AX), Carbon (global hotkeys), Security (Keychain), SwiftUI (Settings window), URLSession. No SPM/CocoaPods.
- `LSUIElement = YES` — menu-bar-only, no Dock icon.
- Unsandboxed — required for broad screen capture and AX. "Sign to Run Locally" is sufficient for personal use.
- The OpenRouter API key lives in the macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). A legacy `~/.config/ai-cpb/config.json` containing `openrouter_api_key` is migrated automatically on first launch and stripped from disk.
- Optional Logfire tracing for the developer is wired in at compile time via the `AICPB_LOGFIRE_TOKEN` env var (or a `.env` file at the repo root). `make dmg` defensively strips this variable so distributed binaries never embed a token.

## Files

See `SPEC.md` and `SPEC-settings-ui.md` for the full technical specs (component-by-component design, prompts, coordinate conventions, build system, acceptance criteria).
