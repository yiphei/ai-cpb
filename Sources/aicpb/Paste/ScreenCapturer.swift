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
}

@available(macOS, deprecated: 14.0, message: "Uses CGDisplayCreateImage; intentional for MVP")
private func cgDisplayCreateImageCompat(_ id: CGDirectDisplayID) -> CGImage? {
    CGDisplayCreateImage(id)
}
