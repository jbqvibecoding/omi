import Combine
import Foundation

/// Maintains a live, structured summary of the current recording session — overview,
/// key points, action items, and suggested follow-up questions — regenerated
/// incrementally as the transcript grows. Ported from glass's summaryService: a
/// running structured record the user can glance at, and a post-session artifact.
///
/// Sibling of LiveNotesMonitor / LiveSuggestionsMonitor: transcript-clocked, one
/// in-flight generation at a time. The final summary is persisted as a single
/// consolidated note via the existing NoteStorage (no schema change).
@MainActor
final class SessionSummaryMonitor: ObservableObject {
    static let shared = SessionSummaryMonitor()

    /// Latest structured summary for UI display.
    @Published private(set) var summary: CopilotSessionSummary?

    /// Regenerate at most this often.
    private let regenerateInterval: TimeInterval = 90
    /// Only regenerate once this many new words have accumulated.
    private let wordThreshold = 60
    private let generateTimeout: Double = 20

    private var currentSessionId: Int64?
    private var sessionStartedAt: Date = Date()
    private var lastGeneratedAt: Date = .distantPast
    private var wordsSinceLastGenerate = 0
    private var lastProcessedSegmentEnd: Double?
    private var isGenerating = false

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
        currentSessionId = sessionId
        sessionStartedAt = Date()
        summary = nil
        lastGeneratedAt = .distantPast
        wordsSinceLastGenerate = 0
        lastProcessedSegmentEnd = nil
    }

    func endSession() {
        guard let sessionId = currentSessionId, let finalSummary = summary else {
            currentSessionId = nil
            return
        }
        // Persist the final record as one consolidated AI note (reuses NoteStorage — no
        // schema change). Preferred content is template-driven meeting minutes shaped by
        // the active scenario (Meetily-style, chunked for long transcripts); the live
        // running summary is the fallback if minutes generation fails.
        let fallbackMarkdown = finalSummary.markdown
        let segments = LiveTranscriptMonitor.shared.segments.isEmpty
            ? LiveTranscriptMonitor.shared.savedSegments
            : LiveTranscriptMonitor.shared.segments
        let transcript = fullTranscript(from: segments)
        let scenario = CopilotSettings.shared.scenario
        let scenarioId = scenario.id
        let scenarioName = scenario.displayName
        let exportMarkdownFile = CopilotSettings.shared.exportMeetingMarkdown
        let startedAt = sessionStartedAt
        let client = try? cachedGeminiClient()
        Task {
            var markdown = fallbackMarkdown
            var usedMinutes = false
            if let client, !transcript.isEmpty {
                do {
                    let minutes = try await MeetingMinutesGenerator.generateMinutes(
                        transcript: transcript, scenarioId: scenarioId, client: client)
                    if !minutes.isEmpty {
                        markdown = minutes
                        usedMinutes = true
                    }
                } catch {
                    logError(
                        "SessionSummaryMonitor: minutes generation failed, keeping live summary",
                        error: error)
                }
            }
            do {
                _ = try await NoteStorage.shared.createNote(
                    sessionId: sessionId, text: markdown, isAiGenerated: true, segmentStartOrder: 0)
            } catch {
                logError("SessionSummaryMonitor: failed to persist final summary", error: error)
            }
            if exportMarkdownFile {
                MeetingMarkdownExporter.export(
                    title: "\(scenarioName) — \(finalSummary.overview.prefix(60))",
                    startedAt: startedAt,
                    scenarioName: scenarioName,
                    sessionId: sessionId,
                    segments: segments,
                    notesMarkdown: markdown
                )
            }
            // Everything above records what was said; this records what it means about the
            // people and projects involved, so the next meeting starts from it. The calendar
            // supplies the attendee list — guessing names off audio is exactly how you end
            // up with a dossier on the wrong person.
            let event = await MeetingPrepService.currentEvent()
            await DossierWriter.ingest(
                transcript: transcript,
                meetingTitle: event?.summary ?? scenarioName,
                attendees: event?.attendees ?? [])
            PostHogManager.shared.track(
                "copilot_session_summary_saved",
                properties: [
                    "key_points": finalSummary.keyPoints.count,
                    "action_items": finalSummary.actionItems.count,
                    "minutes_template": usedMinutes,
                    "transcript_chars": transcript.count,
                ]
            )
        }
        currentSessionId = nil
    }

    // MARK: - Transcript Handling

    private func handleSegmentsUpdate(_ segments: [SpeakerSegment]) {
        guard currentSessionId != nil, CopilotSettings.shared.isEnabled else { return }

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
        if let lastSeg = segments.last { lastProcessedSegmentEnd = lastSeg.end }
        wordsSinceLastGenerate += newText.split(separator: " ").count

        guard !isGenerating else { return }
        guard wordsSinceLastGenerate >= wordThreshold else { return }
        guard Date().timeIntervalSince(lastGeneratedAt) >= regenerateInterval else { return }

        let transcript = fullTranscript(from: segments)
        guard !transcript.isEmpty else { return }
        isGenerating = true
        lastGeneratedAt = Date()
        wordsSinceLastGenerate = 0
        Task { [weak self] in
            await self?.generate(transcript: transcript)
        }
    }

    /// Force template-driven minutes generation from the current/last transcript
    /// (omi-ctl debug action). Returns the minutes markdown head + diagnostics.
    func debugGenerateMinutes() async -> [String: String] {
        let segments = LiveTranscriptMonitor.shared.segments.isEmpty
            ? LiveTranscriptMonitor.shared.savedSegments
            : LiveTranscriptMonitor.shared.segments
        let transcript = fullTranscript(from: segments)
        guard !transcript.isEmpty else { return ["error": "no transcript available"] }
        let scenarioId = CopilotSettings.shared.scenario.id
        do {
            let client = try cachedGeminiClient()
            let minutes = try await MeetingMinutesGenerator.generateMinutes(
                transcript: transcript, scenarioId: scenarioId, client: client)
            return [
                "template": MeetingMinutesGenerator.template(forScenario: scenarioId).id,
                "transcript_chars": String(transcript.count),
                "chunked": transcript.count > 60_000 ? "true" : "false",
                "minutes_head": String(minutes.prefix(600)),
            ]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Force one regeneration (omi-ctl debug action). Returns the summary markdown.
    @discardableResult
    func debugGenerate() async -> [String: String] {
        let segments = LiveTranscriptMonitor.shared.segments.isEmpty
            ? LiveTranscriptMonitor.shared.savedSegments
            : LiveTranscriptMonitor.shared.segments
        let transcript = fullTranscript(from: segments)
        guard !transcript.isEmpty else { return ["error": "no transcript available"] }
        guard !isGenerating else { return ["error": "generation already running"] }
        isGenerating = true
        await generate(transcript: transcript)
        guard let summary else { return ["error": "generation produced no summary"] }
        return [
            "overview": summary.overview,
            "key_points": String(summary.keyPoints.count),
            "action_items": String(summary.actionItems.count),
        ]
    }

    private func generate(transcript: String) async {
        defer { isGenerating = false }
        do {
            let client = try cachedGeminiClient()
            let previous = summary
            // Attach the current screen (shared content/deck) like glass's summary does — it
            // grounds the summary in what's visible, and keeps a valid image part on the request.
            let imageData: Data = {
                guard let raw = ScreenCaptureManager.captureScreenJPEG() else { return Data() }
                return GeminiImageCompression.compress(raw) ?? raw
            }()
            let responseText = try await withThrowingTimeoutSummary(seconds: generateTimeout) {
                try await client.sendRequest(
                    prompt: CopilotPrompts.sessionSummaryUserPrompt(
                        transcript: transcript, previousSummary: previous),
                    imageData: imageData,
                    systemPrompt: CopilotPrompts.sessionSummarySystemPrompt,
                    responseSchema: CopilotPrompts.sessionSummarySchema,
                    thinkingBudget: 0
                )
            }
            let parsed = try JSONDecoder().decode(CopilotSessionSummary.self, from: Data(responseText.utf8))
            summary = parsed
        } catch {
            logError("SessionSummaryMonitor: generation failed", error: error)
        }
    }

    // MARK: - Helpers

    private func fullTranscript(from segments: [SpeakerSegment]) -> String {
        segments
            .compactMap { seg -> String? in
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return "\(seg.isUser ? "You" : "Speaker \(seg.speaker)"): \(text)"
            }
            .joined(separator: "\n")
    }

    private func cachedGeminiClient() throws -> GeminiClient {
        if let geminiClient { return geminiClient }
        let client = try GeminiClient(model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
        geminiClient = client
        return client
    }
}

private func withThrowingTimeoutSummary<T: Sendable>(
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
