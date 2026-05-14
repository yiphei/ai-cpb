import AppKit
import ApplicationServices
import CoreGraphics

enum Permissions {
    @discardableResult
    static func checkAll(promptIfMissing: Bool, reportToUser: Bool = false) -> (screen: Bool, ax: Bool) {
        let screen = checkScreenRecording(prompt: promptIfMissing)
        let ax = checkAccessibility(prompt: promptIfMissing)

        if reportToUser {
            if screen && ax {
                Notify.info("Permissions OK", "Screen Recording and Accessibility are both granted.")
            } else {
                let missing = [screen ? nil : "• Screen Recording",
                               ax ? nil : "• Accessibility"]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                Notify.error(
                    "Missing permissions",
                    "ai-cpb needs the following permissions to work:\n\n\(missing)\n\n" +
                    "Grant them in System Settings → Privacy & Security, then fully quit and relaunch the app."
                )
                if !screen {
                    openSystemSettings(pane: "Privacy_ScreenCapture")
                } else if !ax {
                    openSystemSettings(pane: "Privacy_Accessibility")
                }
            }
        }

        return (screen, ax)
    }

    static func checkScreenRecording(prompt: Bool) -> Bool {
        let ok = CGPreflightScreenCaptureAccess()
        if !ok && prompt {
            _ = CGRequestScreenCaptureAccess()
        }
        return ok
    }

    static func checkAccessibility(prompt: Bool) -> Bool {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    private static func openSystemSettings(pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}
