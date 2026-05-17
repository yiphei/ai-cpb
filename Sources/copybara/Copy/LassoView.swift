import AppKit

protocol LassoViewDelegate: AnyObject {
    func lassoDidCommit(viewRect: NSRect)
    func lassoDidCancel()
}

final class LassoView: NSView {
    weak var delegate: LassoViewDelegate?
    var tintColor: NSColor = .systemRed

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startPoint = p
        currentPoint = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        let rect = currentRect()
        startPoint = nil
        currentPoint = nil
        needsDisplay = true
        delegate?.lassoDidCommit(viewRect: rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            delegate?.lassoDidCancel()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = startPoint, let c = currentPoint else { return }
        let r = NSRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(c.x - s.x),
            height: abs(c.y - s.y)
        )
        tintColor.withAlphaComponent(0.10).setFill()
        r.fill()

        let path = NSBezierPath(rect: r)
        path.lineWidth = 2
        tintColor.setStroke()
        path.stroke()
    }

    private func currentRect() -> NSRect {
        guard let s = startPoint, let c = currentPoint else { return .zero }
        return NSRect(
            x: min(s.x, c.x),
            y: min(s.y, c.y),
            width: abs(c.x - s.x),
            height: abs(c.y - s.y)
        )
    }
}
