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

        // Boot user-defined watcher agents (each runs its own loop when enabled).
        WatcherRuntime.shared.start()

        // Housekeeping for the knowledge base — curation and dedup, each at most once a day.
        // Delayed so a launch isn't competing with the app coming up.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            DossierGardener.runDailyIfNeeded()
            DossierMerge.runDailyIfNeeded()
        }

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
            name: "copilot_export_meeting",
            summary: "Export the current/last session (summary + timestamped transcript) as a "
                + "markdown file under ~/Documents/Omi/Meetings; returns the file path."
        ) { _ in
            let segments = await MainActor.run {
                LiveTranscriptMonitor.shared.segments.isEmpty
                    ? LiveTranscriptMonitor.shared.savedSegments
                    : LiveTranscriptMonitor.shared.segments
            }
            guard !segments.isEmpty else { return ["error": "no transcript available"] }
            let (scenarioName, notes) = await MainActor.run {
                (
                    CopilotSettings.shared.scenario.displayName,
                    SessionSummaryMonitor.shared.summary?.markdown
                )
            }
            guard
                let url = MeetingMarkdownExporter.export(
                    title: "\(scenarioName) session",
                    startedAt: Date(),
                    scenarioName: scenarioName,
                    sessionId: nil,
                    segments: segments,
                    notesMarkdown: notes
                )
            else { return ["error": "nothing to export"] }
            return ["path": url.path]
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_meeting_prompt_test",
            summary: "Force the 'Meeting detected — start copilot?' floating-bar card "
                + "(bypasses detector state and cooldowns)."
        ) { _ in
            await MeetingAutoDetectMonitor.shared.debugPrompt()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "watcher_list",
            summary: "List user-defined watcher agents (id, name, enabled, interval)."
        ) { _ in
            let watchers = await MainActor.run { WatcherStore.shared.watchers }
            if watchers.isEmpty { return ["count": "0"] }
            var out: [String: String] = ["count": String(watchers.count)]
            for w in watchers {
                out[w.id] = "\(w.name) [\(w.isEnabled ? "on" : "off")] every \(w.effectiveInterval)s"
            }
            return out
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "watcher_run",
            summary: "Force one tick of a watcher (bypasses interval/change-gate/sleep); "
                + "returns response, condition match, and actions run.",
            params: ["id"]
        ) { params in
            guard let id = params["id"], !id.isEmpty else { return ["error": "missing id param"] }
            return await WatcherRuntime.shared.forceRun(id: id)
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_meeting_prep_test",
            summary: "Build the pre-meeting brief for the next calendar meeting within 6h "
                + "(attendees resolved against your notes); returns matched people and bullets."
        ) { _ in
            await MeetingPrepService.debugPrepare()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "watcher_event",
            summary: "Publish a test event to the watcher event router and report which "
                + "watchers it woke.",
            params: ["kind", "title", "summary"]
        ) { params in
            let event = WatcherEvent(
                kind: params["kind"] ?? "test.event",
                title: params["title"] ?? "Test event",
                summary: params["summary"] ?? "")
            let listeners = await MainActor.run {
                WatcherStore.shared.watchers.filter { $0.isEnabled && $0.eventCriteria != nil }
            }
            guard !listeners.isEmpty else {
                return ["error": "no enabled watcher has an event criteria set"]
            }
            let woken = await WatcherEventRouter.route(event, listeners: listeners)
            return [
                "listeners": listeners.map(\.id).joined(separator: ","),
                "woke": woken.isEmpty ? "(none matched)" : woken.joined(separator: ","),
            ]
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "dossier_list",
            summary: "List the entity files omi keeps (people, organizations, projects, topics) "
                + "with their size and last update."
        ) { _ in
            await MainActor.run { () -> [String: String] in
                let all = DossierStore.shared.all()
                guard !all.isEmpty else {
                    return ["count": "0", "root": DossierStore.shared.root.path]
                }
                var out: [String: String] = [
                    "count": String(all.count), "root": DossierStore.shared.root.path,
                ]
                for dossier in all {
                    out[dossier.id] =
                        "\(dossier.lineCount) lines · updated \(dossier.field("updated") ?? "-")"
                        + (dossier.isArchived ? " · stale" : "")
                }
                return out
            }
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "dossier_search",
            summary: "Search the entity files and show what matched and why.",
            params: ["q"]
        ) { params in
            guard let query = params["q"], !query.isEmpty else { return ["error": "missing q param"] }
            return await MainActor.run { () -> [String: String] in
                let hits = DossierIndex.shared.search(query, limit: 5)
                guard !hits.isEmpty else { return ["hits": "0"] }
                var out: [String: String] = ["hits": String(hits.count)]
                for hit in hits {
                    out[hit.dossier.id] =
                        String(format: "%.2f", hit.score) + " · \(hit.reason) · "
                        + String(hit.dossier.section("Summary").prefix(120))
                }
                return out
            }
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "dossier_ingest",
            summary: "Run entity extraction over the current/last transcript now (normally this "
                + "happens when a session ends)."
        ) { _ in
            let transcript = await MainActor.run { () -> String in
                let segments = LiveTranscriptMonitor.shared.segments.isEmpty
                    ? LiveTranscriptMonitor.shared.savedSegments
                    : LiveTranscriptMonitor.shared.segments
                return segments.map { "\($0.isUser ? "Me" : "Them"): \($0.text)" }
                    .joined(separator: "\n")
            }
            guard !transcript.isEmpty else { return ["error": "no transcript available"] }
            let event = await MeetingPrepService.currentEvent()
            return await DossierWriter.ingest(
                transcript: transcript, meetingTitle: event?.summary,
                attendees: event?.attendees ?? [])
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "dossier_garden",
            summary: "Run the daily curation pass now: collapse old activity, promote patterns "
                + "into standing facts, mark long-quiet files stale."
        ) { _ in
            await DossierGardener.run()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "dossier_merge",
            summary: "Review duplicate-looking entity files and merge the ones that are the same "
                + "entity (verdicts are remembered)."
        ) { _ in
            await DossierMerge.run()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "watcher_runs",
            summary: "Show a watcher's recent runs (time, trigger, status, what it did) and "
                + "when it is next due.",
            params: ["id"]
        ) { params in
            guard let id = params["id"], !id.isEmpty else { return ["error": "missing id param"] }
            return await MainActor.run { () -> [String: String] in
                guard let watcher = WatcherStore.shared.watcher(id: id) else {
                    return ["error": "no watcher with id \(id)"]
                }
                let fmt = DateFormatter()
                fmt.dateFormat = "MM-dd HH:mm:ss"
                var out: [String: String] = [
                    "schedule": watcher.effectiveSchedule.humanLabel,
                    "enabled": watcher.isEnabled ? "true" : "false",
                    "fail_count": String(watcher.consecutiveFailures),
                    "last_run": watcher.lastRunAt.map { fmt.string(from: $0) } ?? "-",
                    "next_run": watcher.effectiveSchedule.nextFireDate(after: Date())
                        .map { fmt.string(from: $0) } ?? "-",
                ]
                for run in WatcherRunStore.shared.recent(watcherId: id, limit: 20) {
                    out[fmt.string(from: run.at)] =
                        "\(run.effectiveStatus.rawValue) · \(run.effectiveTrigger.rawValue) · \(run.summaryLine)"
                }
                return out
            }
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_rules_dump",
            summary: "Show the plain-English preferences omi distilled from the times you "
                + "disagreed with it, and where the editable file lives."
        ) { _ in
            await MainActor.run { CopilotCorrectionLog.shared.debugDump() }
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_rules_distill",
            summary: "Re-distill the preference rules from the correction log right now."
        ) { _ in
            await CopilotCorrectionLog.shared.debugDistill()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_style_dump",
            summary: "Show the learned style card omi uses to make talk tracks sound like you, "
                + "plus how much of your own speech it learned from."
        ) { _ in
            await MainActor.run { CopilotStyleLearner.shared.debugDump() }
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "copilot_style_relearn",
            summary: "Relearn the style card now from your recent spoken lines and corrections."
        ) { _ in
            await CopilotStyleLearner.shared.debugRelearn()
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "watcher_inbox",
            summary: "List watcher actions parked waiting for your approval (nothing is sent "
                + "until approved); returns id, watcher, target and the drafted body."
        ) { _ in
            let pending = await MainActor.run { WatcherApprovalStore.shared.pending }
            if pending.isEmpty { return ["pending": "0"] }
            var out: [String: String] = ["pending": String(pending.count)]
            for item in pending {
                out[item.id] =
                    "\(item.watcherName) · \(item.kind) → \(item.target ?? "-") · \(String(item.body.prefix(80)))"
            }
            return out
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "watcher_resolve",
            summary: "Resolve a parked watcher approval: r=allow|always|deny (allow sends it, "
                + "always also grants that exact target).",
            params: ["id", "r"]
        ) { params in
            guard let id = params["id"], !id.isEmpty else { return ["error": "missing id param"] }
            let resolution = params["r"] ?? "deny"
            guard ["allow", "always", "deny"].contains(resolution) else {
                return ["error": "r must be allow|always|deny"]
            }
            let ok = await MainActor.run {
                WatcherApprovalStore.shared.resolve(id: id, resolution: resolution)
            }
            return ["resolved": ok ? "true" : "false", "resolution": resolution]
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "watcher_runs",
            summary: "Print a watcher's recent run history (response head, acted/no-op, errors).",
            params: ["id"]
        ) { params in
            guard let id = params["id"], !id.isEmpty else { return ["error": "missing id param"] }
            let context = await MainActor.run { WatcherRunStore.shared.recentContext(watcherId: id) }
            return ["runs": context]
        }

        DesktopAutomationActionRegistry.shared.register(
            name: "watcher_create_from",
            summary: "Generate a watcher agent from a natural-language description and save it "
                + "(disabled); returns the new watcher id and referenced sensors.",
            params: ["desc"]
        ) { params in
            guard let desc = params["desc"], !desc.isEmpty else { return ["error": "missing desc param"] }
            do {
                let draft = try await WatcherAICreator.generate(description: desc)
                let sensors = await MainActor.run { () -> String in
                    WatcherStore.shared.upsert(draft)
                    return WatcherSensorResolver.referencedSensors(in: draft.systemPrompt)
                        .joined(separator: ",")
                }
                return [
                    "id": draft.id,
                    "name": draft.name,
                    "interval": String(draft.effectiveInterval),
                    "actions": String(draft.actions.count),
                    "sensors": sensors,
                ]
            } catch {
                return ["error": error.localizedDescription]
            }
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
            let artifact = result.usableArtifact
            FloatingControlBarManager.shared.presentCopilotResponse(
                headline: result.headline,
                markdown: result.responseMarkdown,
                artifact: artifact,
                artifactKind: result.contentType
            )

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            log(
                "CopilotOrchestrator: snap done in \(elapsedMs)ms (confidence \(result.confidence), "
                    + "content_type \(result.contentType ?? "general"))")
            PostHogManager.shared.track(
                "copilot_snap_triggered",
                properties: [
                    "source": source,
                    "elapsed_ms": elapsedMs,
                    "confidence": result.confidence,
                    "had_transcript": !context.transcriptWindow.isEmpty,
                    "content_type": result.contentType ?? "general",
                    "has_artifact": artifact != nil,
                ]
            )
            persist(result: result, context: context)

            return [
                "headline": result.headline,
                "confidence": String(format: "%.2f", result.confidence),
                "elapsed_ms": String(elapsedMs),
                "content_type": result.contentType ?? "general",
                "artifact_len": String(artifact?.count ?? 0),
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
