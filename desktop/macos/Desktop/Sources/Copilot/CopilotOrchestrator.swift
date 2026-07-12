import AppKit
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

    // Hot mode: a second shortcut press within this window upgrades the snap
    // into a live voice session over the realtime hub.
    private let hotModeWindow: TimeInterval = 3
    private var lastSnapTriggeredAt: Date?
    private var lastSnapResult: CopilotSnapResult?

    private init() {}

    /// Registers the omi-ctl debug action. Called once at app startup.
    func setup() {
        // Watch for conferencing calls while idle and offer to start the copilot.
        MeetingAutoDetectMonitor.shared.start()

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_snap",
            summary: "Trigger a Copilot Snap (screenshot + context → predictive answer in the floating bar); "
                + "returns headline/confidence diagnostics."
        ) { _ in
            await CopilotOrchestrator.shared.triggerSnap(source: "automation")
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_live_test",
            summary: "Feed fake transcript text into the live copilot and force one gate+generate "
                + "evaluation (bypasses cooldowns); returns gate decision/headline/confidence.",
            params: ["text"]
        ) { params in
            guard let text = params["text"], !text.isEmpty else {
                return ["error": "missing 'text' param (fake transcript to evaluate)"]
            }
            return await LiveSuggestionsMonitor.shared.debugRunOnce(text: text)
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_hot_mode",
            summary: "Toggle Copilot hot mode: starts a live voice session over the realtime hub "
                + "(as if double-pressing the copilot shortcut), or ends it if one is active."
        ) { _ in
            if await PushToTalkManager.shared.state == .lockedListening {
                await PushToTalkManager.shared.finalizeVoiceSession()
                return ["hot_mode": "ended"]
            }
            return await CopilotOrchestrator.shared.upgradeToHotMode(source: "automation")
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_tuner_dump",
            summary: "Dump the feedback tuner's per-(scenario:type) accepted/ignored counts and dismiss rates."
        ) { _ in
            await CopilotFeedbackTuner.shared.debugDump()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_summary_test",
            summary: "Force-generate the structured session summary from the current/last transcript; "
                + "returns overview + key-point/action counts."
        ) { _ in
            await SessionSummaryMonitor.shared.debugGenerate()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_minutes_test",
            summary: "Generate template-driven meeting minutes from the current/last transcript "
                + "using the active scenario's template; returns the markdown head."
        ) { _ in
            await SessionSummaryMonitor.shared.debugGenerateMinutes()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_meeting_prompt_test",
            summary: "Force the 'Meeting detected — start copilot?' floating-bar card "
                + "(bypasses detector state and cooldowns)."
        ) { _ in
            await MeetingAutoDetectMonitor.shared.debugPrompt()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_notes_index",
            summary: "Index (incrementally) the configured copilot notes folder into the notes "
                + "knowledge base; returns scanned/embedded/reused/pruned counts."
        ) { _ in
            await NotesKnowledgeBase.shared.debugIndex()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_notes_search",
            summary: "Search the notes knowledge base; returns top hits with source breadcrumbs.",
            params: ["query"]
        ) { params in
            guard let query = params["query"], !query.isEmpty else {
                return ["error": "missing query param"]
            }
            return await NotesKnowledgeBase.shared.debugSearch(query: query)
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "screen_op_test",
            summary: "Run one Screen-Op analysis on the frontmost app (bypasses the interval); "
                + "returns headline/confidence/sql_count or no_suggestion. Requires monitoring to be on.",
            params: ["app"]
        ) { params in
            guard let assistant = await ProactiveAssistantsPlugin.shared.currentScreenOpAssistant else {
                return ["error": "screen-op assistant not running (is screen monitoring on?)"]
            }
            let appName = await MainActor.run {
                params["app"] ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            }
            do {
                let (result, sqlCount) = try await assistant.testAnalyze(appName: appName, windowTitle: nil)
                guard let result else {
                    return ["result": "no_result", "sql_count": String(sqlCount)]
                }
                guard result.hasSuggestion, let suggestion = result.suggestion else {
                    return [
                        "result": "no_suggestion",
                        "activity": result.currentActivity,
                        "sql_count": String(sqlCount),
                    ]
                }
                return [
                    "headline": suggestion.headline ?? "",
                    "suggestion": suggestion.suggestion,
                    "confidence": String(format: "%.2f", suggestion.confidence),
                    "action_prompt": suggestion.actionPrompt ?? "",
                    "sql_count": String(sqlCount),
                ]
            } catch {
                return ["error": error.localizedDescription]
            }
        }
    }

    /// Runs one snap end-to-end. Returns diagnostics for the automation bridge.
    ///
    /// The copilot shortcut is a three-stage control:
    /// 1st press → snap (screenshot + predictive answer card),
    /// 2nd press within 3s → hot mode (live voice session over the realtime hub),
    /// press during hot mode → end the voice session.
    @discardableResult
    func triggerSnap(source: String) async -> [String: String]? {
        // Hot-mode checks come before the in-flight guard so a double-press
        // upgrades even while the snap request is still running.
        if PushToTalkManager.shared.state == .lockedListening {
            PushToTalkManager.shared.finalizeVoiceSession()
            return ["hot_mode": "ended"]
        }
        if let last = lastSnapTriggeredAt, Date().timeIntervalSince(last) < hotModeWindow {
            lastSnapTriggeredAt = nil
            return upgradeToHotMode(source: source)
        }
        lastSnapTriggeredAt = Date()

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

            lastSnapResult = result
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

    // MARK: - Hot Mode

    /// Upgrade to a live voice session over the realtime hub: continuous mic capture,
    /// spoken replies, and a fresh screen frame injected automatically at the start of
    /// every turn (RealtimeHubController.beginTurn). The last snap's question/answer is
    /// seeded as voice-continuity context so the model knows what was just discussed.
    private func upgradeToHotMode(source: String) -> [String: String] {
        if let snap = lastSnapResult {
            RealtimeHubController.shared.seedVoiceContinuity(
                userText: "[Copilot Snap] \(snap.intentGuess)",
                assistantText: "**\(snap.headline)**\n\(snap.responseMarkdown)"
            )
        }
        let started = PushToTalkManager.shared.startLockedVoiceSession()
        if started {
            log("CopilotOrchestrator: hot mode started (\(source))")
            PostHogManager.shared.track(
                "copilot_hot_mode_started",
                properties: [
                    "source": source,
                    "had_snap_context": lastSnapResult != nil,
                ]
            )
            return ["hot_mode": "started"]
        }
        log("CopilotOrchestrator: hot mode refused — PTT busy (state=\(PushToTalkManager.shared.state))")
        return ["hot_mode": "refused", "ptt_state": String(describing: PushToTalkManager.shared.state)]
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
