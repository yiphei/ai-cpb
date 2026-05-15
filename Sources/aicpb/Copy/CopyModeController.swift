import AppKit

final class CopyModeController: LassoViewDelegate {
    static let shared = CopyModeController()

    private var window: LassoOverlayWindow?
    private var lassoView: LassoView?
    private var screen: NSScreen?
    private var isActive = false

    func begin() {
        if isActive { return }

        let (screenOK, _) = Permissions.checkAll(promptIfMissing: false)
        if !screenOK {
            Notify.error(
                "Screen Recording required",
                "ai-cpb needs Screen Recording permission to capture pixels. Grant it in System Settings → Privacy & Security → Screen Recording, then fully quit and relaunch."
            )
            _ = Permissions.checkScreenRecording(prompt: true)
            return
        }

        guard let target = pickActiveScreen() else { return }
        screen = target
        isActive = true

        MenuBar.shared.flash(.copying)

        let win = LassoOverlayWindow(screen: target)
        let view = LassoView(frame: NSRect(origin: .zero, size: target.frame.size))
        view.delegate = self
        win.contentView = view
        win.makeFirstResponder(view)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()

        self.window = win
        self.lassoView = view
    }

    private func pickActiveScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return s
        }
        return NSScreen.main
    }

    private func teardown() {
        NSCursor.pop()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        lassoView = nil
        isActive = false
    }

    // MARK: LassoViewDelegate

    func lassoDidCommit(viewRect: NSRect) {
        guard let screen = screen, let window = window else {
            teardown()
            return
        }

        // Reject accidental clicks.
        if viewRect.width < 8 || viewRect.height < 8 {
            teardown()
            MenuBar.shared.flash(.idle)
            return
        }

        // Convert view rect → window rect → screen rect (AppKit, bottom-left origin).
        // LassoView is flipped, so y in view coords grows downward; convert via the window.
        let windowRect = lassoView!.convert(viewRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)

        teardown()

        // Wait for the compositor to drop the dimming overlay before we snap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.030) {
            guard let raw = ScreenCapturer.captureScreen(screen) else {
                Notify.error("Capture failed",
                             "Could not capture the screen. Confirm Screen Recording permission and try again.")
                MenuBar.shared.flash(.idle)
                return
            }
            guard let cropped = ScreenCapturer.crop(raw, toScreenRect: screenRect, on: screen),
                  let png = ScreenCapturer.png(cropped)
            else {
                Notify.error("Capture failed", "Could not crop or encode the captured region.")
                MenuBar.shared.flash(.idle)
                return
            }
            ContextStore.shared.appendCopy(CopyPayload(imagePng: png, capturedAt: Date()))
            MenuBar.shared.flash(.copied)
        }
    }

    func lassoDidCancel() {
        teardown()
        MenuBar.shared.flash(.idle)
    }
}
