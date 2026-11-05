import Foundation

/// What kind of conversational moment the latest exchange looks like.
/// Ported from OpenOats' RealtimeGate trigger detection.
enum CopilotTriggerKind: String, Sendable {
    case question
    case claim
    case topic
    case general
}

/// Word-set Jaccard similarity, used for cheap duplicate suppression.
enum CopilotTextSimilarity {
    static func normalizedWords(in text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func jaccard(_ a: String, _ b: String) -> Double {
        let setA = Set(normalizedWords(in: a))
        let setB = Set(normalizedWords(in: b))
        guard !setA.isEmpty || !setB.isEmpty else { return 1.0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(intersection) / Double(union)
    }
}

/// Local (<1ms, no LLM) pre-gate that decides whether the current moment is even worth
/// an LLM gate call. Ported from OpenOats' RealtimeGate; the LLM gate stays the final
/// judge — this only skips clearly weak moments (general chatter, duplicates) and its
/// question-marker list mirrors the "intent over punctuation" cases the LLM prompt names.
struct CopilotRealtimeGate {
    struct Decision: Sendable {
        let shouldProceed: Bool
        let triggerKind: CopilotTriggerKind
        let reason: String
    }

    /// Markers kept aligned with the LLM gate prompt (incomplete/implied questions).
    private static let questionStarts = [
        "what ", "how ", "why ", "should ", "could ", "would ", "which ", "do you think",
        "can you", "tell me", "walk me through",
    ]
    private static let questionPhrases = [
        "should we", "let's go with", "i think we should", "we need to decide", "which one",
        "what about", "i'm curious", "im curious", "curious about", "any thoughts",
    ]
    private static let claimPhrases = [
        "i think", "i assume", "i believe", "probably", "but ", "however", "i disagree",
        "that's not", "thats not", "the problem is",
    ]

    static func detectTriggerKind(_ text: String, topicVocabulary: [String]) -> CopilotTriggerKind {
        let lower = text.lowercased()

        if lower.contains("?") { return .question }
        for start in questionStarts where lower.hasPrefix(start) { return .question }
        for phrase in questionPhrases where lower.contains(phrase) { return .question }
        for phrase in claimPhrases where lower.contains(phrase) { return .claim }
        // Topic words come from the active scenario profile's trigger vocabulary
        // (OpenOats hardcoded a domain list; omi already has this per scenario).
        for word in topicVocabulary where lower.contains(word) { return .topic }
        return .general
    }

    /// Decide whether the recent exchange warrants an LLM gate call.
    /// - `recentText`: tail of the transcript (the words that just landed).
    /// - `kbTopScore`: best notes-retrieval similarity for the current window, if any.
    /// - `recentSuggestionTexts`: this session's suggestions, for duplicate suppression.
    static func evaluate(
        recentText: String,
        kbTopScore: Float?,
        kbSimilarityThreshold: Float,
        recentSuggestionTexts: [String],
        topicVocabulary: [String]
    ) -> Decision {
        let triggerKind = detectTriggerKind(recentText, topicVocabulary: topicVocabulary)
        let kbHit = (kbTopScore ?? 0) >= kbSimilarityThreshold

        // Duplicate suppression: the moment reads just like a suggestion we already made.
        for recent in recentSuggestionTexts.suffix(3) {
            if CopilotTextSimilarity.jaccard(recentText, recent) > 0.7 {
                return Decision(
                    shouldProceed: false, triggerKind: triggerKind,
                    reason: "duplicate of recent suggestion")
            }
        }

        // Strong conversational trigger, scenario topic word, or relevant notes → let the
        // LLM gate judge. Plain general chatter with no notes relevance is skipped locally.
        if triggerKind == .question || triggerKind == .claim || triggerKind == .topic || kbHit {
            return Decision(shouldProceed: true, triggerKind: triggerKind, reason: "passed pre-gate")
        }
        return Decision(
            shouldProceed: false, triggerKind: triggerKind, reason: "general chatter, no notes hit")
    }

    /// Fraction of recent segments (rolling window) that read as questions — a cheap
    /// "how hot is this conversation" signal. From OpenOats' TranscriptStore.
    static func questionDensity(
        segments: [SpeakerSegment], windowSeconds: Double = 60, topicVocabulary: [String] = []
    ) -> Double {
        guard let lastEnd = segments.last?.end else { return 0 }
        let windowStart = lastEnd - windowSeconds
        var total = 0
        var questions = 0
        for segment in segments where segment.end >= windowStart {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            total += 1
            if detectTriggerKind(text, topicVocabulary: topicVocabulary) == .question {
                questions += 1
            }
        }
        guard total > 0 else { return 0 }
        return Double(questions) / Double(total)
    }
}

/// Burst-adaptive pacing (from OpenOats' BurstDecayThrottle tiers): when the conversation
/// is hot (questions flying, notes highly relevant) the suggestion cooldown shrinks so the
/// copilot keeps up; in calm stretches the full cooldown applies.
enum CopilotBurstPacing {
    static func burstScore(questionDensity: Double, kbRelevance: Double) -> Double {
        (questionDensity * 0.4) + (kbRelevance * 0.6)
    }

    /// Multiplier applied to the user's suggestion cooldown.
    static func cooldownScale(questionDensity: Double, kbRelevance: Double) -> Double {
        let burst = burstScore(questionDensity: questionDensity, kbRelevance: kbRelevance)
        if burst > 0.7 { return 0.3 }
        if burst > 0.5 { return 0.6 }
        return 1.0
    }
}
