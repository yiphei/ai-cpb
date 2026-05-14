import AppKit
import CoreGraphics

enum ScreenCapturer {
    static func captureScreen(_ screen: NSScreen) -> CGImage? {
        guard let dispNum = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let dispID = CGDirectDisplayID(dispNum.uint32Value)
        // CGDisplayCreateImage is deprecated in macOS 14+ but still works on 15.
        // Acceptable for MVP; ScreenCaptureKit is overkill here.
        return cgDisplayCreateImageCompat(dispID)
    }

    /// Crop in AppKit screen coords (bottom-left origin, points). Returns a CGImage in physical pixels.
    static func crop(_ image: CGImage, toScreenRect rect: CGRect, on screen: NSScreen) -> CGImage? {
        let scale = screen.backingScaleFactor
        let frame = screen.frame
        let xPx = (rect.origin.x - frame.origin.x) * scale
        let yPxFromTop = (frame.maxY - rect.maxY) * scale
        let wPx = rect.width * scale
        let hPx = rect.height * scale
        let cropRect = CGRect(x: xPx, y: yPxFromTop, width: wPx, height: hPx).integral
        return image.cropping(to: cropRect)
    }

    static func png(_ image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    /// Resize + JPEG-encode for the Anthropic vision API. Anthropic recommends
    /// the longest edge ≤ 1568px and enforces a 5 MB per-image limit.
    static func encodeForAI(_ image: CGImage, maxEdge: CGFloat = 1568, quality: CGFloat = 0.85) -> (data: Data, mediaType: String)? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longest = max(w, h)
        let scale = longest > maxEdge ? maxEdge / longest : 1.0
        let newW = Int((w * scale).rounded())
        let newH = Int((h * scale).rounded())

        let resized: CGImage
        if scale < 1.0,
           let ctx = CGContext(
               data: nil,
               width: newW,
               height: newH,
               bitsPerComponent: 8,
               bytesPerRow: 0,
               space: CGColorSpaceCreateDeviceRGB(),
               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
           ) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
            resized = ctx.makeImage() ?? image
        } else {
            resized = image
        }

        let rep = NSBitmapImageRep(cgImage: resized)
        if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
            return (jpeg, "image/jpeg")
        }
        return nil
    }
}

@available(macOS, deprecated: 14.0, message: "Uses CGDisplayCreateImage; intentional for MVP")
private func cgDisplayCreateImageCompat(_ id: CGDirectDisplayID) -> CGImage? {
    CGDisplayCreateImage(id)
}
