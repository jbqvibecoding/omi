import Foundation

/// Learns how the user actually talks and rewrites the copilot's talk tracks to match.
///
/// Ported from Ami's style cards, with one omi-specific advantage: a talk track is meant to
/// be *spoken*, and our transcripts already label who is who (`SpeakerSegment.isUser`), so we
/// can mine the user's real spoken voice for free — no mailbox or chat history needed.
///
/// Two application points, both of which Ami found necessary: the card is injected into the
/// generator, **and** a cheap second pass rewrites the finished line. The second pass is what
/// makes it stick.
@MainActor
final class CopilotStyleLearner {
    static let shared = CopilotStyleLearner()

    private let cardKey = "copilotStyleCard"
    private let cardUpdatedKey = "copilotStyleCardUpdatedAt"
    private let correctionsKey = "copilotStyleCorrections"
    /// Refresh the card when it's older than this.
    private let refreshInterval: TimeInterval = 20 * 3600
    /// Spoken samples worth learning from.
    private let minSampleChars = 25
    private let maxSampleChars = 1500
    private let maxSamples = 200
    private let maxCorrections = 40

    /// A (what omi suggested → what the user actually said/sent) pair. Ami weighs these
    /// heaviest because they show exactly what to change.
    private struct StyleCorrection: Codable {
        let suggested: String
        let actual: String
        let at: Date
    }

    private init() {}

    // MARK: - The card

    /// The learned style card, or nil when nothing has been learned yet.
    var card: String? {
        let value = UserDefaults.standard.string(forKey: cardKey)
        return (value?.isEmpty ?? true) ? nil : value
    }

    func setCard(_ value: String) {
        UserDefaults.standard.set(value, forKey: cardKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cardUpdatedKey)
    }

    var cardUpdatedAt: Date? {
        let ts = UserDefaults.standard.double(forKey: cardUpdatedKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    private var isStale: Bool {
        guard let updated = cardUpdatedAt else { return true }
        return Date().timeIntervalSince(updated) > refreshInterval
    }

    /// Learn (or refresh) the card in the background when it's stale and there's material.
    func refreshIfNeeded() {
        guard CopilotSettings.shared.styleMatchingEnabled, isStale else { return }
        Task { _ = await learnCard() }
    }

    // MARK: - Corpus

    /// The user's own spoken lines from recent sessions.
    private func spokenSamples() -> [String] {
        let segments = LiveTranscriptMonitor.shared.savedSegments.isEmpty
            ? LiveTranscriptMonitor.shared.segments
            : LiveTranscriptMonitor.shared.savedSegments
        return segments
            .filter { $0.isUser }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minSampleChars && $0.count <= maxSampleChars }
            .suffix(maxSamples)
            .map { $0 }
    }

    private func corrections() -> [StyleCorrection] {
        guard let data = UserDefaults.standard.data(forKey: correctionsKey),
            let decoded = try? JSONDecoder().decode([StyleCorrection].self, from: data)
        else { return [] }
        return decoded
    }

    /// Record that omi suggested one thing and the user said/sent another.
    func recordCorrection(suggested: String, actual: String) {
        let s = suggested.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = actual.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !a.isEmpty, s != a, a.count >= minSampleChars else { return }
        var list = corrections()
        list.append(StyleCorrection(suggested: s, actual: a, at: Date()))
        if list.count > maxCorrections { list.removeFirst(list.count - maxCorrections) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: correctionsKey)
        }
    }

    // MARK: - Learning

    private static let learnerSystemPrompt = """
        You analyze how someone speaks and produce a concise style card another writer can \
        follow to imitate them. Cover: how they open and close, formality, sentence length, \
        filler and characteristic phrases, directness, and tone. These are SPOKEN lines from \
        meetings — capture how the person actually talks, not how they would write. \
        Output markdown, max 25 lines, no preamble.
        """

    @discardableResult
    func learnCard() async -> String? {
        let samples = spokenSamples()
        let corrections = corrections()
        guard samples.count >= 8 || !corrections.isEmpty else {
            log("CopilotStyleLearner: not enough material to learn a style card")
            return nil
        }

        var prompt = "Here are \(samples.count) things the user said in meetings:\n\n"
        prompt += samples.map { "- \($0)" }.joined(separator: "\n")
        if !corrections.isEmpty {
            // Ami's finding: these show exactly what to change, so weight them hardest.
            prompt += "\n\nThe user also rephrased lines omi drafted for them — weigh these "
                + "heavily, they show exactly what to change:\n"
            prompt += corrections.suffix(15).enumerated()
                .map { "\($0.offset + 1). omi: \($0.element.suggested)\n   them: \($0.element.actual)" }
                .joined(separator: "\n")
        }

        do {
            let client = try GeminiClient(
                model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
            let text = try await client.sendTextRequest(
                prompt: prompt, systemPrompt: Self.learnerSystemPrompt, maxRetries: 1, timeout: 45,
                thinkingBudget: 0)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            setCard(trimmed)
            log("CopilotStyleLearner: learned style card from \(samples.count) spoken samples")
            PostHogManager.shared.track(
                "copilot_style_card_learned",
                properties: ["samples": samples.count, "corrections": corrections.count])
            return trimmed
        } catch {
            logError("CopilotStyleLearner: learning failed", error: error)
            return nil
        }
    }

    // MARK: - The enforcement pass

    private static let enforceSystemPrompt = """
        You rewrite a line so it sounds exactly like the user would say it, following their \
        style card rigorously: word choice, directness, sentence length, characteristic \
        phrases. Preserve ALL content and meaning — every fact, number, name and question must \
        survive unchanged. Do not add anything new. If the line already matches the card, \
        return it unchanged. Output ONLY the line, no commentary, no quotes.
        """

    /// Rewrite a talk track in the user's voice. Fails open — any problem returns the original.
    func enforce(_ talkTrack: String) async -> String {
        let trimmed = talkTrack.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CopilotSettings.shared.styleMatchingEnabled, !trimmed.isEmpty, let card else {
            return talkTrack
        }
        do {
            let client = try GeminiClient(
                model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
            let rewritten = try await client.sendTextRequest(
                prompt: "Style card:\n\(card)\n\nLine to rewrite:\n\(trimmed)",
                systemPrompt: Self.enforceSystemPrompt, maxRetries: 0, timeout: 12,
                thinkingBudget: 0)
            let result = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
            // Guard against a degenerate rewrite (empty, or wildly longer than the original).
            guard !result.isEmpty, result.count < trimmed.count * 3 else { return talkTrack }
            return result
        } catch {
            return talkTrack
        }
    }

    // MARK: - Debug (omi-ctl)

    func debugDump() -> [String: String] {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return [
            "has_card": card == nil ? "false" : "true",
            "updated_at": cardUpdatedAt.map { formatter.string(from: $0) } ?? "-",
            "spoken_samples": String(spokenSamples().count),
            "corrections": String(corrections().count),
            "card": card ?? "(none)",
        ]
    }

    func debugRelearn() async -> [String: String] {
        guard let card = await learnCard() else {
            return ["error": "not enough spoken material yet — record a meeting first"]
        }
        return ["card": String(card.prefix(800))]
    }
}
