import AppKit
import CoreGraphics

enum ImageAnnotator {
    /// Draws a thick red rectangle on `image` at `rectAXTopLeft` (AX top-left origin, points,
    /// in the global AX coord system where the primary screen top-left is (0,0)) relative to
    /// the given screen. Returns a new CGImage in physical pixels.
    static func drawRedBox(on image: CGImage,
                           rectAXTopLeft: CGRect,
                           on screen: NSScreen) -> CGImage {
        let scale = screen.backingScaleFactor
        // The CGImage covers exactly `screen.frame` in points × scale.
        // AX coords give the rect in a global top-left coord space, where the primary screen's
        // top-left is the origin. The destination screen's top-left in AX coords is:
        //   axScreenOriginX = screen.frame.origin.x  (AppKit x matches AX x)
        //   axScreenOriginY = primaryHeight - screen.frame.maxY
        guard let primary = NSScreen.screens.first else { return image }
        let primaryHeight = primary.frame.height
        let axScreenOriginX = screen.frame.origin.x
        let axScreenOriginY = primaryHeight - screen.frame.maxY

        let xPx = (rectAXTopLeft.origin.x - axScreenOriginX) * scale
        let yPx = (rectAXTopLeft.origin.y - axScreenOriginY) * scale
        let wPx = rectAXTopLeft.width * scale
        let hPx = rectAXTopLeft.height * scale
        let pxRectTopLeft = CGRect(x: xPx, y: yPx, width: wPx, height: hPx).integral

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

        // CGContext is bottom-left-origin. Draw the source image flipped so it appears upright.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.restoreGState()

        // Convert pxRectTopLeft (top-left origin) to CGContext bottom-left origin for stroking.
        let pxRectBL = CGRect(
            x: pxRectTopLeft.origin.x,
            y: CGFloat(height) - pxRectTopLeft.origin.y - pxRectTopLeft.height,
            width: pxRectTopLeft.width,
            height: pxRectTopLeft.height
        )

        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.setLineWidth(max(6, 4 * scale))
        ctx.stroke(pxRectBL)

        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.10))
        ctx.fill(pxRectBL)

        return ctx.makeImage() ?? image
    }
}
