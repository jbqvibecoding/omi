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
            ]
        )
        currentSessionId = nil
        lastProcessedSegmentEnd = nil
        wordsSinceLastEval = 0
        vocabularyHit = false
        suggestionsThisSession = []
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

        maybeEvaluate(segments: segments)
    }

    private func maybeEvaluate(segments: [SpeakerSegment]) {
        guard !isEvaluating else { return }
        guard wordsSinceLastEval >= wordThreshold || vocabularyHit else { return }
        guard Date().timeIntervalSince(lastEvalAt) >= evalCooldown else { return }
        guard Date().timeIntervalSince(lastSuggestionAt) >= CopilotSettings.shared.suggestionCooldown else { return }
        guard suggestionsThisSession.count < CopilotSettings.shared.maxSuggestionsPerSession else { return }

        let transcript = transcriptWindow(from: segments)
        guard !transcript.isEmpty else { return }

        isEvaluating = true
        lastEvalAt = Date()
        wordsSinceLastEval = 0
        vocabularyHit = false
        let cursorAtEval = lastProcessedSegmentEnd ?? 0

        Task { [weak self] in
            await self?.evaluate(transcript: transcript, cursorAtEval: cursorAtEval, bypassStaleness: false)
        }
    }

    /// Runs the two-stage pipeline. Returns diagnostics (used by the debug automation action).
    /// Callers must have set `isEvaluating = true`; it is cleared here on all paths.
    @discardableResult
    func evaluate(transcript: String, cursorAtEval: Double, bypassStaleness: Bool) async -> [String: String] {
        defer { isEvaluating = false }
        let startedAt = Date()
        let scenario = CopilotSettings.shared.scenario

        do {
            let client = try cachedGeminiClient()

            // Stage 1 — gate (cheap text call with its own timeout, expected to mostly say SKIP)
            let gateText = try await client.sendTextRequest(
                prompt: CopilotPrompts.liveGateUserPrompt(
                    transcript: transcript,
                    recentSuggestions: suggestionsThisSession,
                    scenario: scenario
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
                userProfile: profile
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

            guard result.confidence >= CopilotSettings.shared.minConfidence else {
                log("LiveSuggestionsMonitor: dropped low-confidence suggestion (\(result.confidence))")
                return ["gate": "SPEAK \(gateType)", "dropped": "confidence \(result.confidence)"]
            }

            // Staleness: if the conversation moved well past our snapshot, the moment is gone.
            let cursorNow = lastProcessedSegmentEnd ?? cursorAtEval
            if !bypassStaleness, cursorNow - cursorAtEval > stalenessBudget {
                log("LiveSuggestionsMonitor: dropped stale suggestion (transcript advanced \(cursorNow - cursorAtEval)s)")
                return ["gate": "SPEAK \(gateType)", "dropped": "stale"]
            }

            deliver(result, gateType: gateType, transcript: transcript)

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            PostHogManager.shared.track(
                "copilot_live_suggestion",
                properties: [
                    "type": gateType,
                    "confidence": result.confidence,
                    "elapsed_ms": elapsedMs,
                    "has_talk_track": result.talkTrack?.isEmpty == false,
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

    private func deliver(_ result: CopilotLiveSuggestion, gateType: String, transcript: String) {
        let context = FloatingBarNotificationContext(
            sourceTitle: "Copilot",
            assistantId: "copilot",
            sourceApp: nil,
            windowTitle: nil,
            contextSummary: String(transcript.suffix(300)),
            currentActivity: nil,
            reasoning: gateType,
            detail: result.talkTrack
        )
        NotificationService.shared.sendNotification(
            title: result.headline,
            message: result.suggestion,
            assistantId: "copilot",
            sound: .none,
            context: context,
            respectFrequency: false
        )
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
        isEvaluating = true
        let transcript = transcriptWindow(from: [segment])
        return await evaluate(transcript: transcript, cursorAtEval: segment.end, bypassStaleness: true)
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
