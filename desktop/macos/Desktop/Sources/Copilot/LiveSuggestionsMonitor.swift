import Combine
import Foundation

/// Live meeting/call copilot: watches the live transcript during recording sessions
/// and pushes short, immediately usable suggestions (objection responses, action
/// items, next steps) to the floating bar as cards.
///
/// Structure mirrors LiveNotesMonitor (transcript-clocked Combine subscriber with an
/// end-time cursor), with a two-stage LLM pipeline: a cheap text gate that mostly
/// says no, then one structured vision call. Noise control is layered: eval cooldown,
/// suggestion cooldown, per-session cap, confidence floor, dedup against session
/// history, and staleness drop when the conversation has moved on.
@MainActor
final class LiveSuggestionsMonitor: ObservableObject {
    static let shared = LiveSuggestionsMonitor()

    // MARK: - Tunables (session-level rate limits beyond CopilotSettings)

    /// New words that trigger an evaluation when no vocabulary hit occurs.
    private let wordThreshold = 35
    /// Minimum seconds between two gate evaluations.
    private let evalCooldown: TimeInterval = 45
    /// Transcript window fed to the LLM calls (seconds of conversation).
    private let transcriptWindowSeconds: Double = 90
    /// The structured generate call is abandoned past this deadline (the gate call
    /// has its own 15s timeout via sendTextRequest).
    private let generateTimeout: Double = 15
    /// A suggestion is stale (dropped, not shown) if the transcript advanced
    /// more than this many seconds past the evaluation snapshot.
    private let stalenessBudget: Double = 40

    // MARK: - Session State

    private var currentSessionId: Int64?
    /// Whether a copilot session (i.e. a recording) is currently active.
    var isSessionActive: Bool { currentSessionId != nil }
    /// End time of the last segment we consumed (incremental cursor, same technique as LiveNotesMonitor)
    private var lastProcessedSegmentEnd: Double?
    private var wordsSinceLastEval = 0
    private var vocabularyHit = false
    private var lastEvalAt: Date = .distantPast
    private var lastSuggestionAt: Date = .distantPast
    private var suggestionsThisSession: [String] = []
    private var isEvaluating = false
    private var gateSpeakCount = 0
    private var gateSkipCount = 0
    private var preGateSkipCount = 0

    // MARK: - Notes retrieval (pre-fetched on a rolling window, OpenOats-style)

    /// Notes hits are refreshed at most this often during a session.
    private let kbPrefetchInterval: TimeInterval = 15
    /// Hits older than this are considered stale and not used as evidence.
    private let kbFreshnessBudget: TimeInterval = 45
    /// Notes similarity at/above this counts as "the notes are relevant right now".
    private let kbSimilarityThreshold: Float = 0.5
    private var kbHits: [NotesKBHit] = []
    private var kbFetchedAt: Date = .distantPast
    private var isFetchingKB = false
    /// Pre-meeting brief for the session's calendar event, used as opening context so the
    /// copilot starts the meeting already knowing who's in the room.
    private var meetingBrief: MeetingPrepBrief?

    /// The last talk track we handed the user, waiting to see how they actually said it.
    private var pendingTalkTrack: (text: String, at: Date)?
    /// How long after a talk track a spoken line still counts as a rephrasing of it.
    private let styleCorrectionWindow: TimeInterval = 120

    private var geminiClient: GeminiClient?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        LiveTranscriptMonitor.shared.$segments
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segments in
                self?.handleSegmentsUpdate(segments)
            }
            .store(in: &cancellables)
    }

    // MARK: - Session Lifecycle

    func startSession(sessionId: Int64) {
        log("LiveSuggestionsMonitor: starting session \(sessionId)")
        currentSessionId = sessionId
        lastProcessedSegmentEnd = nil
        wordsSinceLastEval = 0
        vocabularyHit = false
        lastEvalAt = .distantPast
        lastSuggestionAt = .distantPast
        suggestionsThisSession = []
        gateSpeakCount = 0
        gateSkipCount = 0
        preGateSkipCount = 0
        kbHits = []
        kbFetchedAt = .distantPast
        meetingBrief = nil

        // Pull the brief for the meeting we're in (if any) so the first suggestions already
        // know the attendees and what's still open with them.
        if CopilotSettings.shared.meetingPrepEnabled {
            let startedSessionId = sessionId
            Task { [weak self] in
                let brief = await MeetingPrepService.briefForCurrentMeeting()
                guard let self, self.currentSessionId == startedSessionId, let brief else { return }
                self.meetingBrief = brief
                log("LiveSuggestionsMonitor: loaded meeting brief for '\(brief.title)'")
            }
        }

        // Auto-select the scenario profile from the calendar (non-blocking, graceful).
        if CopilotSettings.shared.autoSelectScenario {
            let startedSessionId = sessionId
            Task { [weak self] in
                guard let scenarioId = await CalendarScenarioSelector.suggestScenario() else { return }
                // Only apply if this session is still active and the user hasn't already changed it.
                guard let self, self.currentSessionId == startedSessionId else { return }
                guard scenarioId != CopilotSettings.shared.scenarioId else { return }
                CopilotSettings.shared.scenarioId = scenarioId
                log("LiveSuggestionsMonitor: auto-selected scenario '\(scenarioId)' from calendar")
                PostHogManager.shared.track(
                    "copilot_scenario_autoselected", properties: ["scenario": scenarioId])
            }
        }
    }

    func endSession() {
        guard let sessionId = currentSessionId else { return }
        log("LiveSuggestionsMonitor: ending session \(sessionId) with \(suggestionsThisSession.count) suggestions")
        PostHogManager.shared.track(
            "copilot_live_session_ended",
            properties: [
                "suggestions": suggestionsThisSession.count,
                "gate_speak": gateSpeakCount,
                "gate_skip": gateSkipCount,
                "pregate_skip": preGateSkipCount,
            ]
        )
        currentSessionId = nil
        lastProcessedSegmentEnd = nil
        wordsSinceLastEval = 0
        vocabularyHit = false
        suggestionsThisSession = []
        kbHits = []
        meetingBrief = nil
        pendingTalkTrack = nil
        // A session just ended, so there's fresh speech of yours to learn from.
        CopilotStyleLearner.shared.refreshIfNeeded()
    }

    // MARK: - Transcript Handling

    private func handleSegmentsUpdate(_ segments: [SpeakerSegment]) {
        guard currentSessionId != nil, CopilotSettings.shared.isEnabled else { return }

        // Incremental: only consume segments past the cursor.
        let newSegments: ArraySlice<SpeakerSegment>
        if let lastEnd = lastProcessedSegmentEnd {
            if let startIdx = segments.firstIndex(where: { $0.end > lastEnd }) {
                newSegments = segments[startIdx...]
            } else {
                return
            }
        } else {
            newSegments = segments[...]
        }

        let newText = newSegments.map { $0.text }.joined(separator: " ")
        guard !newText.isEmpty else { return }
        if let lastSeg = segments.last {
            lastProcessedSegmentEnd = lastSeg.end
        }

        wordsSinceLastEval += newText.split(separator: " ").count
        let vocabulary = CopilotSettings.shared.scenario.triggerVocabulary
        if !vocabulary.isEmpty {
            let lowered = newText.lowercased()
            if vocabulary.contains(where: { lowered.contains($0) }) {
                vocabularyHit = true
            }
        }

        captureStyleCorrection(in: newSegments)
        prefetchNotesIfNeeded(segments: segments)
        maybeEvaluate(segments: segments)
    }

    /// When omi hands you a line and you then say it your own way, that pair is the single
    /// most useful thing it can learn from — Ami weighs these hardest. We can only catch it
    /// because the transcript already knows which speaker is you.
    private func captureStyleCorrection(in newSegments: ArraySlice<SpeakerSegment>) {
        guard CopilotSettings.shared.styleMatchingEnabled, let pending = pendingTalkTrack else { return }
        guard Date().timeIntervalSince(pending.at) <= styleCorrectionWindow else {
            pendingTalkTrack = nil
            return
        }
        for segment in newSegments where segment.isUser {
            let spoken = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard spoken.count >= 25 else { continue }
            // Only a rephrasing of *that* line counts — an unrelated sentence teaches nothing.
            let overlap = CopilotTextSimilarity.jaccard(pending.text, spoken)
            guard overlap >= 0.25, overlap < 0.95 else { continue }
            CopilotStyleLearner.shared.recordCorrection(suggested: pending.text, actual: spoken)
            pendingTalkTrack = nil
            return
        }
    }

    /// Continuously pre-fetches notes-folder hits for the rolling transcript window so a
    /// finalized moment finds warm retrieval results (OpenOats' pre-fetch layer).
    private func prefetchNotesIfNeeded(segments: [SpeakerSegment]) {
        guard CopilotSettings.shared.notesRagActive else { return }
        guard !isFetchingKB, Date().timeIntervalSince(kbFetchedAt) >= kbPrefetchInterval else { return }

        let window = transcriptWindow(from: segments)
        let queryWords = window.split(separator: " ").suffix(40)
        guard queryWords.count >= 8 else { return }
        let query = queryWords.joined(separator: " ")

        isFetchingKB = true
        Task { [weak self] in
            let hits = await NotesKnowledgeBase.shared.search(queries: [query], topK: 3)
            guard let self else { return }
            self.kbHits = hits
            self.kbFetchedAt = Date()
            self.isFetchingKB = false
            if let top = hits.first {
                log(
                    "LiveSuggestionsMonitor: notes prefetch — \(hits.count) hits, top "
                        + "\(String(format: "%.2f", top.score)) (\(top.breadcrumb))")
            }
        }
    }

    /// Notes hits that are still fresh enough to use as evidence.
    private var freshKBHits: [NotesKBHit] {
        guard Date().timeIntervalSince(kbFetchedAt) <= kbFreshnessBudget else { return [] }
        return kbHits
    }

    private func maybeEvaluate(segments: [SpeakerSegment]) {
        guard !isEvaluating else { return }
        guard wordsSinceLastEval >= wordThreshold || vocabularyHit else { return }
        guard Date().timeIntervalSince(lastEvalAt) >= evalCooldown else { return }
        guard suggestionsThisSession.count < CopilotSettings.shared.maxSuggestionsPerSession else { return }

        let vocabulary = CopilotSettings.shared.scenario.triggerVocabulary
        let questionDensity = CopilotRealtimeGate.questionDensity(
            segments: segments, topicVocabulary: vocabulary)
        let kbTopScore = freshKBHits.first?.score

        // Burst-adaptive pacing (OpenOats): a hot stretch (questions flying / notes highly
        // relevant) shrinks the suggestion cooldown so the copilot keeps up.
        let cooldownScale = CopilotBurstPacing.cooldownScale(
            questionDensity: questionDensity, kbRelevance: Double(kbTopScore ?? 0))
        let effectiveCooldown = CopilotSettings.shared.suggestionCooldown * cooldownScale
        guard Date().timeIntervalSince(lastSuggestionAt) >= effectiveCooldown else { return }

        let transcript = transcriptWindow(from: segments)
        guard !transcript.isEmpty else { return }

        // Local pre-gate (OpenOats RealtimeGate): skip the LLM gate call entirely when the
        // latest exchange is clearly not a moment. Scenario vocabulary hits bypass it —
        // those words are explicit user configuration.
        if !vocabularyHit {
            let recentTail = transcript.split(separator: " ").suffix(25).joined(separator: " ")
            let decision = CopilotRealtimeGate.evaluate(
                recentText: recentTail,
                kbTopScore: kbTopScore,
                kbSimilarityThreshold: kbSimilarityThreshold,
                recentSuggestionTexts: suggestionsThisSession,
                topicVocabulary: vocabulary
            )
            if !decision.shouldProceed {
                preGateSkipCount += 1
                wordsSinceLastEval = 0
                log("LiveSuggestionsMonitor: pre-gate skip (\(decision.reason))")
                return
            }
        }

        isEvaluating = true
        lastEvalAt = Date()
        wordsSinceLastEval = 0
        vocabularyHit = false
        let cursorAtEval = lastProcessedSegmentEnd ?? 0
        let hits = freshKBHits

        Task { [weak self] in
            await self?.evaluate(
                transcript: transcript, cursorAtEval: cursorAtEval, bypassStaleness: false,
                kbHits: hits)
        }
    }

    /// Runs the two-stage pipeline. Returns diagnostics (used by the debug automation action).
    /// Callers must have set `isEvaluating = true`; it is cleared here on all paths.
    @discardableResult
    /// Dossier facts relevant to what's being said right now, as an evidence block.
    private func dossierEvidenceBlock(for transcript: String) -> String? {
        guard CopilotSettings.shared.dossiersEnabled else { return nil }
        let window = String(transcript.suffix(600))
        let hits = DossierIndex.shared.search(window, limit: 2)
        guard !hits.isEmpty else { return nil }
        let blocks = hits.map { hit -> String in
            var parts = ["[\(hit.dossier.kind.singular): \(hit.dossier.name)]"]
            let facts = hit.dossier.section("Key facts")
            if !facts.isEmpty { parts.append(String(facts.prefix(600))) }
            let open = hit.dossier.openItems.prefix(3)
            if !open.isEmpty { parts.append("Open: " + open.joined(separator: "; ")) }
            return parts.joined(separator: "\n")
        }
        return "What you already know about who's involved:\n" + blocks.joined(separator: "\n\n")
    }

    func evaluate(
        transcript: String, cursorAtEval: Double, bypassStaleness: Bool,
        kbHits: [NotesKBHit] = []
    ) async -> [String: String] {
        defer { isEvaluating = false }
        let startedAt = Date()
        let scenario = CopilotSettings.shared.scenario
        var notesEvidence = CopilotPrompts.notesEvidenceBlock(hits: kbHits)
        // Fold the meeting brief in as additional evidence — same untrusted-data framing.
        if let brief = meetingBrief {
            notesEvidence = [notesEvidence, brief.contextBlock]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }
        // What omi already knows about whoever/whatever is being discussed. Deterministic
        // lookup, so it costs nothing and can't drift.
        if let dossierEvidence = dossierEvidenceBlock(for: transcript) {
            notesEvidence = [notesEvidence, dossierEvidence]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }

        // Rules the user taught omi by disagreeing with it. Injected into both stages,
        // ahead of the general guidance, because a preference the gate ignores is a
        // preference the user has to keep re-teaching.
        let preferences = CopilotCorrectionLog.shared.promptBlock()

        do {
            let client = try cachedGeminiClient()

            // Stage 1 — gate (cheap text call with its own timeout, expected to mostly say SKIP).
            // Fold recently-dismissed suggestion texts into the "do not repeat" block so the gate
            // learns which kinds of suggestions this user rejects (semantic suppression).
            let suppressed = CopilotSettings.shared.adaptiveThresholdEnabled
                ? CopilotFeedbackTuner.shared.dismissedTexts(scenario: scenario.id)
                : []
            let gateText = try await client.sendTextRequest(
                prompt: CopilotPrompts.liveGateUserPrompt(
                    transcript: transcript,
                    recentSuggestions: suggestionsThisSession + suppressed,
                    scenario: scenario,
                    notesEvidence: notesEvidence,
                    preferences: preferences
                ),
                systemPrompt: CopilotPrompts.liveGateSystemPrompt,
                maxRetries: 0,
                timeout: 15,
                thinkingBudget: 0
            )
            guard let gateType = Self.parseGate(gateText) else {
                gateSkipCount += 1
                PostHogManager.shared.track("copilot_live_gate", properties: ["decision": "skip"])
                return ["gate": "SKIP"]
            }
            gateSpeakCount += 1
            PostHogManager.shared.track(
                "copilot_live_gate", properties: ["decision": "speak", "type": gateType])

            // Stage 2 — generate (structured vision call; the screen shows shared content/deck)
            guard let rawScreenshot = ScreenCaptureManager.captureScreenJPEG() else {
                return ["gate": "SPEAK \(gateType)", "error": "screen capture failed"]
            }
            let imageData = GeminiImageCompression.compress(rawScreenshot) ?? rawScreenshot
            let profile = await AIUserProfileService.shared.getLatestProfile()?.profileText

            let generatePrompt = CopilotPrompts.liveSuggestionUserPrompt(
                transcript: transcript,
                gateType: gateType,
                recentSuggestions: suggestionsThisSession,
                userProfile: profile,
                notesEvidence: notesEvidence,
                styleCard: CopilotStyleLearner.shared.card,
                preferences: preferences
            )
            let generateSystemPrompt = CopilotPrompts.liveSuggestionSystemPrompt(scenario: scenario)
            let responseText = try await withThrowingTimeoutCopilot(seconds: generateTimeout) {
                try await client.sendRequest(
                    prompt: generatePrompt,
                    imageData: imageData,
                    systemPrompt: generateSystemPrompt,
                    responseSchema: CopilotPrompts.liveSuggestionSchema,
                    thinkingBudget: 0
                )
            }
            let result = try JSONDecoder().decode(CopilotLiveSuggestion.self, from: Data(responseText.utf8))

            // Confidence gate — the threshold adapts per (scenario × type) from user feedback.
            let minConfidence = CopilotSettings.shared.adaptiveThresholdEnabled
                ? CopilotFeedbackTuner.shared.effectiveMinConfidence(
                    baseline: CopilotSettings.shared.minConfidence, scenario: scenario.id, type: gateType)
                : CopilotSettings.shared.minConfidence
            guard result.confidence >= minConfidence else {
                log("LiveSuggestionsMonitor: dropped low-confidence suggestion (\(result.confidence) < \(minConfidence))")
                return ["gate": "SPEAK \(gateType)", "dropped": "confidence \(result.confidence)"]
            }

            // Staleness: if the conversation moved well past our snapshot, the moment is gone.
            let cursorNow = lastProcessedSegmentEnd ?? cursorAtEval
            if !bypassStaleness, cursorNow - cursorAtEval > stalenessBudget {
                log("LiveSuggestionsMonitor: dropped stale suggestion (transcript advanced \(cursorNow - cursorAtEval)s)")
                return ["gate": "SPEAK \(gateType)", "dropped": "stale"]
            }

            // Second pass: rewrite the spoken line in the user's own voice. Cheap, fails open,
            // and it's what makes the style card actually land (Ami's finding).
            var delivered = result
            if let talkTrack = result.talkTrack, !talkTrack.isEmpty {
                let inVoice = await CopilotStyleLearner.shared.enforce(talkTrack)
                if inVoice != talkTrack {
                    delivered = result.withTalkTrack(inVoice)
                }
            }
            deliver(delivered, gateType: gateType, transcript: transcript, kbHits: kbHits)

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            PostHogManager.shared.track(
                "copilot_live_suggestion",
                properties: [
                    "type": gateType,
                    "confidence": result.confidence,
                    "elapsed_ms": elapsedMs,
                    "has_talk_track": result.talkTrack?.isEmpty == false,
                    "has_notes": !kbHits.isEmpty,
                ]
            )
            return [
                "gate": "SPEAK \(gateType)",
                "headline": result.headline,
                "confidence": String(format: "%.2f", result.confidence),
            ]
        } catch {
            logError("LiveSuggestionsMonitor: evaluation failed", error: error)
            return ["error": error.localizedDescription]
        }
    }

    // MARK: - Delivery

    private func deliver(
        _ result: CopilotLiveSuggestion, gateType: String, transcript: String,
        kbHits: [NotesKBHit] = []
    ) {
        // Show where the evidence came from ("From your notes: sales/pricing.md > Tiers").
        var detail = result.talkTrack ?? ""
        if let talkTrack = result.talkTrack, !talkTrack.isEmpty {
            pendingTalkTrack = (talkTrack, Date())
        }
        if let source = kbHits.first {
            let sourceLine = "From your notes: \(source.breadcrumb)"
            detail = detail.isEmpty ? sourceLine : "\(detail)\n\n\(sourceLine)"
        }
        let context = FloatingBarNotificationContext(
            sourceTitle: "Copilot",
            assistantId: "copilot",
            sourceApp: nil,
            windowTitle: nil,
            contextSummary: String(transcript.suffix(300)),
            currentActivity: nil,
            reasoning: gateType,
            detail: detail.isEmpty ? nil : detail,
            feedbackBucket: "\(CopilotSettings.shared.scenario.id):\(gateType)"
        )
        // While presenting, only surface audience-driven cards (questions / term definitions);
        // the presenter's own narration shouldn't trigger interruptions. Suppressed suggestions
        // are still persisted so they're reviewable in history afterward.
        let deliverAsCard = PresentationModeMonitor.shared.shouldDeliver(gateType: gateType)
        if deliverAsCard {
            NotificationService.shared.sendNotification(
                title: result.headline,
                message: result.suggestion,
                assistantId: "copilot",
                sound: .none,
                context: context,
                respectFrequency: false
            )
        } else {
            log("LiveSuggestionsMonitor: presenting — suppressed non-audience card (\(gateType))")
        }
        WatcherEventRouter.copilotSuggested(
            headline: result.headline, suggestion: result.suggestion)
        suggestionsThisSession.append(result.suggestion)
        lastSuggestionAt = Date()

        let record = ProactiveExtractionRecord(
            type: .insight,
            content: result.suggestion,
            category: "copilot_live",
            confidence: result.confidence,
            sourceApp: "Live Copilot",
            contextSummary: result.headline
        )
        Task {
            do {
                _ = try await ProactiveStorage.shared.insertExtraction(record)
            } catch {
                logError("LiveSuggestionsMonitor: failed to persist suggestion", error: error)
            }
        }
    }

    // MARK: - Helpers

    /// Speaker-labelled transcript covering roughly the last `transcriptWindowSeconds`.
    private func transcriptWindow(from segments: [SpeakerSegment]) -> String {
        guard let lastEnd = segments.last?.end else { return "" }
        let windowStart = lastEnd - transcriptWindowSeconds
        var lines: [String] = []
        for segment in segments where segment.end >= windowStart {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = segment.isUser ? "You" : "Speaker \(segment.speaker)"
            lines.append("\(speaker): \(text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Parses the strict gate contract. Returns the suggestion type, or nil for SKIP /
    /// anything unparseable (silence is cheaper than a false positive).
    static func parseGate(_ response: String) -> String? {
        let firstLine = response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard firstLine.uppercased().hasPrefix("SPEAK") else { return nil }
        let parts = firstLine.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let type = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        let allowed = ["objection", "question", "action_item", "factual_gap", "next_step", "term_definition"]
        return allowed.contains(type) ? type : nil
    }

    private func cachedGeminiClient() throws -> GeminiClient {
        if let geminiClient { return geminiClient }
        let client = try GeminiClient(model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
        geminiClient = client
        return client
    }

    // MARK: - Debug (automation bridge)

    /// Feeds fake transcript text and forces one evaluation, bypassing cooldowns.
    /// Lets omi-ctl exercise the full pipeline without a real meeting.
    func debugRunOnce(text: String) async -> [String: String] {
        if currentSessionId == nil {
            startSession(sessionId: -1)
        }
        let words = text.split(separator: " ").map(String.init)
        let segment = SpeakerSegment(
            segmentId: nil,
            speaker: 1,
            text: text,
            start: 0,
            end: Double(max(words.count, 1)) / 2.5,
            isUser: false
        )
        LiveTranscriptMonitor.shared.updateSegments([segment])
        guard !isEvaluating else { return ["error": "evaluation already running"] }
        // Exercise the notes-retrieval path too when it's configured.
        var hits: [NotesKBHit] = []
        if CopilotSettings.shared.notesRagActive {
            hits = await NotesKnowledgeBase.shared.search(queries: [text], topK: 3)
        }
        guard !isEvaluating else { return ["error": "evaluation already running"] }
        isEvaluating = true
        let transcript = transcriptWindow(from: [segment])
        var diagnostics = await evaluate(
            transcript: transcript, cursorAtEval: segment.end, bypassStaleness: true, kbHits: hits)
        if let top = hits.first {
            diagnostics["notes_top_hit"] = "\(top.breadcrumb) (\(String(format: "%.2f", top.score)))"
        }
        return diagnostics
    }
}

/// Local copy of the timeout helper (the InsightAssistant original is file-private).
private func withThrowingTimeoutCopilot<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
