import AppKit
import CoreGraphics
import CoreText

enum ImageAnnotator {
    struct AnnotatedField {
        let rectAX: CGRect
        let isCurrent: Bool
        let index: Int   // 1-based
    }

    /// Draws a thick red rectangle on `image` at `rectAXTopLeft` (AX top-left origin, points,
    /// in the global AX coord system where the primary screen top-left is (0,0)) relative to
    /// the given screen. Returns a new CGImage in physical pixels.
    static func drawRedBox(on image: CGImage,
                           rectAXTopLeft: CGRect,
                           on screen: NSScreen) -> CGImage {
        guard let pxRectTopLeft = axRectToPixels(rectAXTopLeft, on: screen) else { return image }
        return drawing(on: image) { ctx, width, height in
            let pxRectBL = bottomLeftRect(pxRectTopLeft, imageHeight: height)
            let scale = screen.backingScaleFactor
            ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            ctx.setLineWidth(max(6, 4 * scale))
            ctx.stroke(pxRectBL)
            ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.10))
            ctx.fill(pxRectBL)
            _ = width
        }
    }

    /// Draws all detected fields onto the destination screenshot. The field with
    /// `isCurrent == true` is rendered in red (target of THIS call); siblings in gray.
    /// Each box gets a numeric label inside its top-left corner so the model can refer
    /// to fields by index.
    static func drawNumberedBoxes(on image: CGImage,
                                  fields: [AnnotatedField],
                                  on screen: NSScreen) -> CGImage {
        return drawing(on: image) { ctx, _, height in
            let scale = screen.backingScaleFactor
            let red  = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            let gray = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.9)
            let redFill = CGColor(red: 1, green: 0, blue: 0, alpha: 0.10)

            // Draw siblings first so the current (red) box sits on top.
            let sorted = fields.sorted { !$0.isCurrent && $1.isCurrent }
            for f in sorted {
                guard let pxRectTopLeft = axRectToPixels(f.rectAX, on: screen) else { continue }
                let pxRectBL = bottomLeftRect(pxRectTopLeft, imageHeight: height)
                let stroke = f.isCurrent ? red : gray
                ctx.setStrokeColor(stroke)
                ctx.setLineWidth(f.isCurrent ? max(6, 4 * scale) : max(3, 2 * scale))
                ctx.stroke(pxRectBL)
                if f.isCurrent {
                    ctx.setFillColor(redFill)
                    ctx.fill(pxRectBL)
                }
                drawLabel(ctx: ctx,
                          text: "\(f.index)",
                          insideTopLeftOf: pxRectBL,
                          color: stroke,
                          scale: scale)
            }
        }
    }

    // MARK: - helpers

    private static func axRectToPixels(_ axRect: CGRect, on screen: NSScreen) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let scale = screen.backingScaleFactor
        let axScreenOriginX = screen.frame.origin.x
        let axScreenOriginY = primary.frame.height - screen.frame.maxY
        let xPx = (axRect.origin.x - axScreenOriginX) * scale
        let yPx = (axRect.origin.y - axScreenOriginY) * scale
        return CGRect(x: xPx, y: yPx, width: axRect.width * scale, height: axRect.height * scale).integral
    }

    /// Pixel rect in top-left origin → CGContext bottom-left origin.
    private static func bottomLeftRect(_ tl: CGRect, imageHeight: Int) -> CGRect {
        CGRect(
            x: tl.origin.x,
            y: CGFloat(imageHeight) - tl.origin.y - tl.height,
            width: tl.width,
            height: tl.height
        )
    }

    /// Renders the source image into a fresh CGContext, runs the caller's drawing
    /// closure on top, and returns the new CGImage.
    private static func drawing(
        on image: CGImage,
        _ body: (CGContext, Int, Int) -> Void
    ) -> CGImage {
        let width = image.width
        let height = image.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        body(ctx, width, height)
        return ctx.makeImage() ?? image
    }

    /// Draws a bold colored numeric label just inside the top-left corner of a
    /// (bottom-left origin) pixel rect. No leader, no background — simple and legible.
    private static func drawLabel(ctx: CGContext,
                                  text: String,
                                  insideTopLeftOf box: CGRect,
                                  color: CGColor,
                                  scale: CGFloat) {
        let fontSize = 28 * scale
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetImageBounds(line, ctx)
        // box is bottom-left origin: top-left of box is at (box.minX, box.maxY).
        let pad: CGFloat = 4 * scale
        let x = box.minX + pad
        // Text position is the baseline; place baseline so glyph top sits just below box top.
        let y = box.maxY - bounds.height - pad
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
