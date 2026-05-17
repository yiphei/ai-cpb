import AppKit
import ApplicationServices

final class LassoPasteController: LassoViewDelegate {
    static let shared = LassoPasteController()

    private var window: LassoOverlayWindow?
    private var lassoView: LassoView?
    private var screen: NSScreen?
    private var targetPID: pid_t?
    private var inFlight = false

    /// Synchronous to match CopyModeController.begin(): NSWindow creation in
    /// showLassoOverlay must run on the main thread. The hotkey handler dispatches
    /// to .main, so calling this from there keeps overlay setup on the main thread.
    /// The async pipeline kicks in later from lassoDidCommit.
    func run() {
        if inFlight { return }
        inFlight = true

        guard preflight() else {
            inFlight = false
            return
        }

        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            Notify.error("No active app", "Could not determine the frontmost app to fill.")
            inFlight = false
            return
        }
        targetPID = pid

        guard let target = pickActiveScreen() else {
            inFlight = false
            return
        }
        screen = target

        MenuBar.shared.flash(.pasting)
        showLassoOverlay(on: target)
    }

    // MARK: - LassoViewDelegate

    func lassoDidCommit(viewRect: NSRect) {
        guard let screen = screen, let window = window, let view = lassoView, let pid = targetPID else {
            teardown()
            inFlight = false
            return
        }
        if viewRect.width < 8 || viewRect.height < 8 {
            teardown()
            MenuBar.shared.flash(.idle)
            inFlight = false
            return
        }

        let windowRect = view.convert(viewRect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        teardown()

        // Wait for compositor to drop the dimming overlay before screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.030) { [weak self] in
            guard let self else { return }
            Task {
                await self.handleCommittedRect(screenRect: screenRect, screen: screen, pid: pid)
            }
        }
    }

    func lassoDidCancel() {
        teardown()
        MenuBar.shared.flash(.idle)
        inFlight = false
    }

    // MARK: - Pipeline

    private func handleCommittedRect(screenRect: NSRect, screen: NSScreen, pid: pid_t) async {
        defer { inFlight = false }

        let lassoAX = axRectFromScreenRect(screenRect)

        let app = AXUIElementCreateApplication(pid)
        let fields = AXFieldFinder.find(in: app, intersecting: lassoAX)
        guard !fields.isEmpty else {
            Notify.error(
                "No input fields found in selection",
                "Lasso a region containing one or more text fields and try again. Some apps (Electron, canvas-based apps) don't expose fields to macOS Accessibility."
            )
            MenuBar.shared.flash(.idle)
            return
        }

        guard let raw = ScreenCapturer.captureScreen(screen) else {
            Notify.error("Capture failed", "Could not capture the destination screen.")
            MenuBar.shared.flash(.idle)
            return
        }
        let annotatedPngs = encodeAnnotatedVariants(raw: raw, fields: fields, screen: screen)
        guard annotatedPngs.count == fields.count else {
            Notify.error("Capture failed", "Could not encode annotated destination screenshots.")
            MenuBar.shared.flash(.idle)
            return
        }

        let lassoCenterAX = CGRect(x: lassoAX.midX, y: lassoAX.midY, width: 1, height: 1)
        await PasteIndicator.shared.show(near: lassoCenterAX, on: screen)

        let copyPngs = ContextStore.shared.copies.map(\.imagePng)
        let client = makeClient()
        let results = await runParallelCalls(
            client: client,
            copyPngs: copyPngs,
            annotatedDestPerCall: annotatedPngs,
            totalFields: fields.count
        )

        await PasteIndicator.shared.hide()

        let ops: [MultiFieldWriter.WriteOp] = results.compactMap { r in
            guard let text = r.text, !text.isEmpty else { return nil }
            return MultiFieldWriter.WriteOp(
                field: fields[r.index - 1], text: text, index: r.index
            )
        }

        let saved = PasteboardDriver.snapshot()
        let writeFailures = await MultiFieldWriter.writeAll(ops)
        PasteboardDriver.restore(saved)

        summarizeFailures(results: results, writeFailures: writeFailures, totalFields: fields.count)

        MenuBar.shared.flash(.idle)
    }

    // MARK: - Helpers

    private func preflight() -> Bool {
        let copies = ContextStore.shared.copies
        guard !copies.isEmpty else {
            Notify.error("No AI-copied content yet",
                         "Press \(Config.shared.copyHotkey.displayString) and lasso some content first, then try lasso paste again.")
            return false
        }

        let provider = Config.shared.provider
        guard Config.shared.apiKey != nil else {
            Notify.error("API key missing",
                         "Add your \(provider.displayName) API key in Settings (⌘,) and try again.")
            return false
        }

        let (screenOK, _) = Permissions.checkAll(promptIfMissing: false)
        if !screenOK {
            Notify.error("Screen Recording required",
                         "Grant Screen Recording in System Settings → Privacy & Security, then fully quit and relaunch.")
            return false
        }
        return true
    }

    private func makeClient() -> LLMClient {
        let provider = Config.shared.provider
        let apiKey = Config.shared.apiKey ?? ""
        switch provider {
        case .openRouter: return OpenRouterClient(apiKey: apiKey)
        case .anthropic:  return AnthropicClient(apiKey: apiKey)
        }
    }

    private func pickActiveScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return s
        }
        return NSScreen.main
    }

    private func axRectFromScreenRect(_ screenRect: NSRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screenRect }
        let primaryHeight = primary.frame.height
        return CGRect(
            x: screenRect.origin.x,
            y: primaryHeight - screenRect.origin.y - screenRect.height,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    private func showLassoOverlay(on screen: NSScreen) {
        let win = LassoOverlayWindow(screen: screen)
        let view = LassoView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.tintColor = .systemBlue
        view.delegate = self
        win.contentView = view
        win.makeFirstResponder(view)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSCursor.crosshair.push()

        self.window = win
        self.lassoView = view
    }

    private func teardown() {
        NSCursor.pop()
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        lassoView = nil
        screen = nil
        targetPID = nil
    }

    private func encodeAnnotatedVariants(
        raw: CGImage,
        fields: [DetectedField],
        screen: NSScreen
    ) -> [(index: Int, png: Data)] {
        var out: [(index: Int, png: Data)] = []
        for i in 0..<fields.count {
            let annotatedFields: [ImageAnnotator.AnnotatedField] = fields.enumerated().map { (j, f) in
                ImageAnnotator.AnnotatedField(
                    rectAX: f.rectAX,
                    isCurrent: j == i,
                    index: j + 1
                )
            }
            let annotated = ImageAnnotator.drawNumberedBoxes(on: raw, fields: annotatedFields, on: screen)
            guard let png = ScreenCapturer.png(annotated) else { continue }
            out.append((index: i + 1, png: png))
        }
        return out
    }

    private func siblingSentence(currentIndex: Int, totalFields: Int) -> String {
        "This is field \(currentIndex) of \(totalFields). The destination image has \(totalFields) fields marked: yours is the RED box; the GRAY boxes are sibling fields being filled in parallel by separate calls. Consider the sibling fields' labels and positions when deciding what to output, so you do not output content that belongs in another field. Output ONLY the text for the RED field, or <<NO_PASTE>>."
    }

    private struct FieldResult: Sendable {
        let index: Int
        let text: String?
        let error: String?
    }

    private func runParallelCalls(
        client: LLMClient,
        copyPngs: [Data],
        annotatedDestPerCall: [(index: Int, png: Data)],
        totalFields: Int
    ) async -> [FieldResult] {
        await withTaskGroup(of: FieldResult.self) { group in
            for entry in annotatedDestPerCall {
                let trailing = siblingSentence(currentIndex: entry.index, totalFields: totalFields)
                let idx = entry.index
                let png = entry.png
                let copies = copyPngs
                let clientCopy = client
                group.addTask {
                    do {
                        let text = try await clientCopy.paste(
                            copyPngs: copies,
                            destPng: png,
                            trailingUserText: trailing
                        )
                        if text == "<<NO_PASTE>>" {
                            return FieldResult(index: idx, text: nil, error: "AI declined")
                        }
                        return FieldResult(index: idx, text: text, error: nil)
                    } catch {
                        return FieldResult(index: idx, text: nil, error: error.localizedDescription)
                    }
                }
            }
            var results: [FieldResult] = []
            for await r in group { results.append(r) }
            return results.sorted { $0.index < $1.index }
        }
    }

    private func summarizeFailures(results: [FieldResult], writeFailures: [Int], totalFields: Int) {
        var reasons: [String] = []
        for r in results {
            if let err = r.error {
                reasons.append("Field \(r.index): \(err).")
            }
        }
        for idx in writeFailures {
            reasons.append("Field \(idx): could not focus field.")
        }
        if reasons.isEmpty { return }

        let failedAll = reasons.count >= totalFields
        let title = failedAll ? "Lasso paste failed" : "Lasso paste completed with \(reasons.count) issues"
        Notify.error(title, reasons.joined(separator: " "))
    }
}
