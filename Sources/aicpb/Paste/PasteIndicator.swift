import AppKit

@MainActor
final class PasteIndicator {
    static let shared = PasteIndicator()

    private var window: NSWindow?

    func show(near axRect: CGRect?, on screen: NSScreen) {
        hide()

        let size = NSSize(width: 160, height: 36)
        let frame = positionFrame(size: size, near: axRect, on: screen)

        let win = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .screenSaver
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        win.isReleasedWhenClosed = false

        let host = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        host.material = .hudWindow
        host.blendingMode = .behindWindow
        host.state = .active
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true

        let spinner = NSProgressIndicator(frame: NSRect(x: 12, y: 10, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.usesThreadedAnimation = true
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: "AI pasting…")
        label.frame = NSRect(x: 34, y: 9, width: size.width - 44, height: 18)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .left
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.drawsBackground = false

        host.addSubview(spinner)
        host.addSubview(label)
        win.contentView = host
        win.orderFrontRegardless()

        window = win
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    /// Center the HUD on the AX field rect, clamped to the destination screen.
    /// Falls back to top-center of the destination screen when no AX rect is known.
    private func positionFrame(size: NSSize, near axRect: CGRect?, on screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        guard let axRect, let primary = NSScreen.screens.first else {
            return NSRect(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.maxY - size.height - 80,
                width: size.width,
                height: size.height
            ).integral
        }
        let primaryHeight = primary.frame.height
        let fieldAppKit = NSRect(
            x: axRect.origin.x,
            y: primaryHeight - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
        var origin = NSPoint(
            x: fieldAppKit.midX - size.width / 2,
            y: fieldAppKit.midY - size.height / 2
        )
        origin.x = max(screenFrame.minX + 4,
                       min(origin.x, screenFrame.maxX - size.width - 4))
        origin.y = max(screenFrame.minY + 4,
                       min(origin.y, screenFrame.maxY - size.height - 4))
        return NSRect(origin: origin, size: size).integral
    }
}
