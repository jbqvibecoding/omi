import Foundation

/// Drops mic segments that are acoustic echoes of system audio — without echo
/// cancellation, the mic re-captures the other party's voice from the speakers and the
/// transcript shows their words twice (once as "them", once as "you").
///
/// Ported from OpenOats' AcousticEchoFilter (Jaccard word-set similarity + substring
/// containment), adapted to omi's local dual-channel STT: mic and system audio are
/// transcribed by separate `LocalTranscriptionService` instances in ~10s windows, so
/// matching uses wall-clock arrival times with a window sized to the flush cycle.
/// Only wired into the local (on-device Parakeet) path — cloud STT diarizes server-side.
@MainActor
final class AcousticEchoFilter {
    static let shared = AcousticEchoFilter()

    /// How long a system-audio text stays eligible as an echo source. Local STT flushes
    /// ~10s windows, so mic and system captures of the same speech land within a cycle.
    private let window: TimeInterval = 15
    private let similarityThreshold = 0.78
    private let minimumWordCount = 4
    private let minimumCharacterCount = 20

    private var recentSystemTexts: [(text: String, at: Date)] = []

    private init() {}

    func reset() {
        recentSystemTexts = []
    }

    /// Filters one delivery batch: records system-audio texts, drops mic texts that
    /// echo recent system audio.
    func filter(_ segments: [TranscriptionService.BackendSegment]) -> [TranscriptionService.BackendSegment] {
        let now = Date()
        recentSystemTexts.removeAll { now.timeIntervalSince($0.at) > window }

        return segments.filter { segment in
            if !segment.is_user {
                recentSystemTexts.append((text: segment.text, at: now))
                return true
            }
            for (systemText, _) in recentSystemTexts.reversed() {
                if let similarity = Self.similarityIfEcho(
                    segment.text, systemText,
                    similarityThreshold: similarityThreshold,
                    minimumWordCount: minimumWordCount,
                    minimumCharacterCount: minimumCharacterCount)
                {
                    log(
                        "AcousticEchoFilter: dropped mic segment as system-audio echo "
                            + "(sim \(String(format: "%.2f", similarity)))")
                    return false
                }
            }
            return true
        }
    }

    /// Similarity when the pair qualifies as an echo (high Jaccard or containment), nil
    /// otherwise. Very short texts are ineligible — too easy to match by chance.
    static func similarityIfEcho(
        _ firstText: String, _ secondText: String,
        similarityThreshold: Double, minimumWordCount: Int, minimumCharacterCount: Int
    ) -> Double? {
        let first = CopilotTextSimilarity.normalizedWords(in: firstText).joined(separator: " ")
        let second = CopilotTextSimilarity.normalizedWords(in: secondText).joined(separator: " ")
        guard isEligible(first, minimumWordCount: minimumWordCount, minimumCharacterCount: minimumCharacterCount),
            isEligible(second, minimumWordCount: minimumWordCount, minimumCharacterCount: minimumCharacterCount)
        else { return nil }

        let similarity = CopilotTextSimilarity.jaccard(first, second)
        let containsOther = first.contains(second) || second.contains(first)
        return similarity >= similarityThreshold || containsOther ? similarity : nil
    }

    private static func isEligible(
        _ normalizedText: String, minimumWordCount: Int, minimumCharacterCount: Int
    ) -> Bool {
        let wordCount = normalizedText.split(separator: " ").count
        return wordCount >= minimumWordCount || normalizedText.count >= minimumCharacterCount
    }
}
