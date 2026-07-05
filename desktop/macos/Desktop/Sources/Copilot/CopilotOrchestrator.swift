import Foundation

/// Entry point for "Copilot Snap": the user presses the copilot shortcut, we capture
/// a keyframe screenshot, assemble recent context (transcript, OCR, profile), make one
/// structured Gemini vision call, and present a predictive answer in the floating bar.
/// No question is typed — the model infers the need from context.
@MainActor
final class CopilotOrchestrator {
    static let shared = CopilotOrchestrator()

    private var isRunning = false
    private var geminiClient: GeminiClient?

    private init() {}

    /// Registers the omi-ctl debug action. Called once at app startup.
    func setup() {
        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_snap",
            summary: "Trigger a Copilot Snap (screenshot + context → predictive answer in the floating bar); "
                + "returns headline/confidence diagnostics."
        ) { _ in
            await CopilotOrchestrator.shared.triggerSnap(source: "automation")
        }
    }

    /// Runs one snap end-to-end. Returns diagnostics for the automation bridge.
    @discardableResult
    func triggerSnap(source: String) async -> [String: String]? {
        guard !isRunning else {
            log("CopilotOrchestrator: snap already running, ignoring trigger (\(source))")
            return ["error": "snap already running"]
        }
        isRunning = true
        defer { isRunning = false }

        let startedAt = Date()
        log("CopilotOrchestrator: snap triggered (\(source))")

        // Show the thinking state before any capture/network work so the bar
        // responds instantly to the keypress.
        FloatingControlBarManager.shared.beginCopilotSnap()

        // Capture + context assembly in parallel.
        async let snapshotTask = CopilotContextEngine.shared.snapshot()
        let rawScreenshot = ScreenCaptureManager.captureScreenJPEG()
        let context = await snapshotTask

        guard let rawScreenshot else {
            presentFailure("Couldn't capture the screen. Check Screen Recording permission in System Settings.")
            return ["error": "screen capture failed"]
        }
        let imageData = GeminiImageCompression.compress(rawScreenshot) ?? rawScreenshot

        do {
            let client = try cachedGeminiClient()
            let responseText = try await client.sendRequest(
                prompt: CopilotPrompts.userPrompt(context: context),
                imageData: imageData,
                systemPrompt: CopilotPrompts.systemPrompt,
                responseSchema: CopilotPrompts.responseSchema,
                thinkingBudget: 0
            )
            let result = try JSONDecoder().decode(CopilotSnapResult.self, from: Data(responseText.utf8))

            FloatingControlBarManager.shared.presentCopilotResponse(
                headline: result.headline,
                markdown: result.responseMarkdown
            )

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            log("CopilotOrchestrator: snap done in \(elapsedMs)ms (confidence \(result.confidence))")
            PostHogManager.shared.track(
                "copilot_snap_triggered",
                properties: [
                    "source": source,
                    "elapsed_ms": elapsedMs,
                    "confidence": result.confidence,
                    "had_transcript": !context.transcriptWindow.isEmpty,
                ]
            )
            persist(result: result, context: context)

            return [
                "headline": result.headline,
                "confidence": String(format: "%.2f", result.confidence),
                "elapsed_ms": String(elapsedMs),
            ]
        } catch {
            logError("CopilotOrchestrator: snap failed", error: error)
            presentFailure("Copilot couldn't analyze the screen right now. Try again in a moment.")
            return ["error": error.localizedDescription]
        }
    }

    // MARK: - Helpers

    private func cachedGeminiClient() throws -> GeminiClient {
        if let geminiClient { return geminiClient }
        let client = try GeminiClient(model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
        geminiClient = client
        return client
    }

    private func presentFailure(_ message: String) {
        FloatingControlBarManager.shared.presentCopilotResponse(
            headline: "Copilot Snap",
            markdown: message
        )
    }

    /// Persist locally so snaps show up alongside other proactive extractions.
    /// Backend sync joins in Phase 1 together with the live copilot lane.
    private func persist(result: CopilotSnapResult, context: CopilotContextEngine.Snapshot) {
        let record = ProactiveExtractionRecord(
            type: .insight,
            content: result.responseMarkdown,
            category: "copilot_snap",
            confidence: result.confidence,
            sourceApp: context.activeApp ?? "Unknown",
            contextSummary: result.intentGuess
        )
        Task {
            do {
                _ = try await ProactiveStorage.shared.insertExtraction(record)
            } catch {
                logError("CopilotOrchestrator: failed to persist snap", error: error)
            }
        }
    }
}
