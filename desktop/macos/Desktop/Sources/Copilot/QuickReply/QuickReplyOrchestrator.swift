import AppKit
import Foundation

/// Quick Reply: draft the message the user is about to type, into the box they're typing in.
///
/// Everything the copilot produced before this ended at a card. This is the first path that
/// reads what the user has in front of them — the message being replied to, the half-typed
/// draft, the page it's on — and writes back into the same field.
///
/// The draft is never inserted on its own. It lands in an editable panel first, because a
/// message sent as you is exactly the kind of thing that must not be posted by a shortcut
/// you fat-fingered.
@MainActor
final class QuickReplyOrchestrator {
    static let shared = QuickReplyOrchestrator()

    private var isRunning = false
    private var geminiClient: GeminiClient?

    private init() {}

    /// Registers the omi-ctl debug action. Called once at app startup.
    func setup() {
        DesktopAutomationActionRegistry.shared.register(
            name: "quick_reply",
            summary: "Draft a reply for whatever text field is focused right now (same as the "
                + "quick-reply shortcut). Opens the editable panel; returns draft diagnostics."
        ) { _ in
            await QuickReplyOrchestrator.shared.trigger(source: "automation")
        }
    }

    /// Runs one Quick Reply end-to-end. Returns diagnostics for the automation bridge.
    @discardableResult
    func trigger(source: String) async -> [String: String]? {
        guard !isRunning else {
            log("QuickReplyOrchestrator: already running, ignoring trigger (\(source))")
            return ["error": "quick reply already running"]
        }
        // A second press while the panel is up means "I changed my mind", not "do it twice".
        guard !QuickReplyPanel.shared.isPresented else {
            QuickReplyPanel.shared.dismiss()
            return ["cancelled": "panel dismissed"]
        }
        isRunning = true
        defer { isRunning = false }

        let startedAt = Date()

        // Read the field before anything can steal focus. Both of these are the reason the
        // feature exists, so there's no sensible fallback if there's nowhere to write.
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            log("QuickReplyOrchestrator: omi itself is frontmost")
            return ["error": "no target app"]
        }
        let targetPID = app.processIdentifier
        guard AXFocusedText.hasEditableFocus(pid: targetPID) else {
            notify("Put the cursor in the box you want to reply in, then try again.")
            return ["error": "no editable field focused"]
        }
        let field = AXFocusedText.capture(pid: targetPID)
        let appName = app.localizedName ?? "the app you were in"
        let bundleId = app.bundleIdentifier

        // Take the frame before the panel appears, or our own window sits on top of the
        // thread being replied to. Stealth mode normally keeps it out of captures, but
        // that's a setting the user can switch off, and this shouldn't depend on it.
        let rawScreenshot = ScreenCaptureManager.captureScreenJPEG()

        QuickReplyPanel.shared.present(
            targetAppName: appName,
            onInsert: { text in
                Task { @MainActor in
                    await TextInsertion.insertIntoTarget(text, pid: targetPID)
                    PostHogManager.shared.track(
                        "copilot_quick_reply_inserted",
                        properties: ["source": source, "chars": text.count])
                }
            },
            onCancel: {
                PostHogManager.shared.track(
                    "copilot_quick_reply_discarded", properties: ["source": source])
            }
        )
        let model = QuickReplyPanel.shared.model

        // Context assembly in parallel; the URL only when this is actually a browser.
        async let snapshotTask = CopilotContextEngine.shared.snapshot()
        async let urlTask = BrowserURL.current(bundleId: bundleId)
        let context = await snapshotTask
        let url = await urlTask

        guard let rawScreenshot else {
            finishWithError(model, "Couldn't capture the screen. Check Screen Recording permission.")
            return ["error": "screen capture failed"]
        }
        let imageData = GeminiImageCompression.compress(rawScreenshot) ?? rawScreenshot

        do {
            let client = try cachedGeminiClient()
            let responseText = try await client.sendRequest(
                prompt: QuickReplyPrompts.userPrompt(
                    field: field, appName: appName, windowTitle: context.windowTitle,
                    url: url, context: context),
                imageData: imageData,
                systemPrompt: QuickReplyPrompts.systemPromptWithStyle(),
                responseSchema: QuickReplyPrompts.responseSchema,
                thinkingBudget: 0
            )
            let result = try JSONDecoder().decode(QuickReplyResult.self, from: Data(responseText.utf8))
            let reply = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else {
                finishWithError(model, "Nothing came back. Try again in a moment.")
                return ["error": "empty reply"]
            }

            // "Sound like me" applies here more than anywhere else: this text goes out under
            // the user's name in writing, where a borrowed voice is obvious.
            let styled = await CopilotStyleLearner.shared.enforce(reply)

            // The user may have closed the panel while we were thinking; don't reopen it.
            guard QuickReplyPanel.shared.isPresented else {
                return ["cancelled": "panel closed before the draft arrived"]
            }
            model.draft = styled
            model.addressed = result.usableAddressed
            model.isLoading = false

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            log("QuickReplyOrchestrator: drafted in \(elapsedMs)ms (\(styled.count) chars)")
            PostHogManager.shared.track(
                "copilot_quick_reply_drafted",
                properties: [
                    "source": source,
                    "elapsed_ms": elapsedMs,
                    "chars": styled.count,
                    "addressed_count": result.usableAddressed.count,
                    "had_draft": !(field?.text.isEmpty ?? true),
                    "had_url": url != nil,
                    "app": appName,
                ]
            )
            return [
                "chars": String(styled.count),
                "addressed_count": String(result.usableAddressed.count),
                "elapsed_ms": String(elapsedMs),
                "app": appName,
            ]
        } catch {
            logError("QuickReplyOrchestrator: draft failed", error: error)
            finishWithError(model, "Couldn't draft a reply right now. Try again in a moment.")
            return ["error": error.localizedDescription]
        }
    }

    // MARK: - Helpers

    private func cachedGeminiClient() throws -> GeminiClient {
        if let geminiClient { return geminiClient }
        let client = try GeminiClient(
            model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
        geminiClient = client
        return client
    }

    /// Leave the panel up with the reason rather than closing it — a panel that vanishes
    /// reads as "the shortcut did nothing".
    private func finishWithError(_ model: QuickReplyModel, _ message: String) {
        model.isLoading = false
        model.errorText = message
    }

    private func notify(_ message: String) {
        FloatingControlBarManager.shared.showNotification(
            title: "Quick Reply",
            message: message,
            assistantId: "copilot_quick_reply",
            sound: .none
        )
    }
}
