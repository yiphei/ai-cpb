import AppKit

final class PasteController {
    static let shared = PasteController()

    private var inFlight = false

    func run() async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }

        let copies = ContextStore.shared.copies
        guard !copies.isEmpty else {
            Notify.error("No AI-copied content yet",
                         "Press ⌘⇧C and lasso some content first, then try paste again.")
            return
        }

        let provider = Config.shared.provider
        guard let apiKey = Config.shared.apiKey else {
            Notify.error("API key missing",
                         "Add your \(provider.displayName) API key in Settings (⌘,) and try again.")
            return
        }

        let (screenOK, _) = Permissions.checkAll(promptIfMissing: false)
        if !screenOK {
            Notify.error("Screen Recording required",
                         "Grant Screen Recording in System Settings → Privacy & Security, then fully quit and relaunch.")
            return
        }

        MenuBar.shared.flash(.pasting)

        let focused = AXHelper.focusedFieldRect()
        let destScreen = pickDestinationScreen(for: focused?.rect) ?? NSScreen.main!

        guard let raw = ScreenCapturer.captureScreen(destScreen) else {
            Notify.error("Capture failed",
                         "Could not capture the destination screen. Confirm Screen Recording permission.")
            MenuBar.shared.flash(.idle)
            return
        }

        let annotated: CGImage = {
            guard let rect = focused?.rect else { return raw }
            return ImageAnnotator.drawRedBox(on: raw, rectAXTopLeft: rect, on: destScreen)
        }()

        guard let destPng = ScreenCapturer.png(annotated) else {
            Notify.error("Capture failed", "Could not encode destination screenshot.")
            MenuBar.shared.flash(.idle)
            return
        }

        // Show the floating spinner only AFTER the screenshot is encoded, so the
        // HUD never lands in the destination image we send to the model.
        await PasteIndicator.shared.show(near: focused?.rect, on: destScreen)

        let client: LLMClient = {
            switch provider {
            case .openRouter: return OpenRouterClient(apiKey: apiKey)
            case .anthropic:  return AnthropicClient(apiKey: apiKey)
            }
        }()

        let text: String
        do {
            text = try await client.paste(copyPngs: copies.map(\.imagePng), destPng: destPng)
        } catch {
            await PasteIndicator.shared.hide()
            Notify.error("AI call failed", error.localizedDescription)
            MenuBar.shared.flash(.idle)
            return
        }

        guard text != "<<NO_PASTE>>" else {
            await PasteIndicator.shared.hide()
            Notify.error("AI declined to paste",
                         "Claude couldn't infer what to paste. Try giving it a clearer copy or target field.")
            MenuBar.shared.flash(.idle)
            return
        }

        // Hide before the synthesized ⌘V so the HUD doesn't overlap the actual paste.
        await PasteIndicator.shared.hide()

        let saved = PasteboardDriver.snapshot()
        PasteboardDriver.writeString(text)
        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms — let target see new pasteboard
        PasteboardDriver.sendCommandV()
        try? await Task.sleep(nanoseconds: 400_000_000) // 400ms — let target consume before restore
        PasteboardDriver.restore(saved)

        MenuBar.shared.flash(.idle)
    }

    private func pickDestinationScreen(for axRect: CGRect?) -> NSScreen? {
        guard let axRect, let primary = NSScreen.screens.first else { return nil }
        let appKitRect = axToAppKit(axRect, primaryScreenHeight: primary.frame.height)
        return NSScreen.screens.first { $0.frame.intersects(appKitRect) }
    }

    private func axToAppKit(_ axRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: axRect.origin.x,
            y: primaryScreenHeight - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }
}
