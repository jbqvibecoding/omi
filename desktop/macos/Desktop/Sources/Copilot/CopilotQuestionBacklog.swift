import Foundation

/// A question the other side asked that omi never answered out loud.
struct BackloggedQuestion: Identifiable, Equatable {
    let id = UUID()
    /// Mutable because transcription revises itself: the same question arrives again a
    /// second later with a word corrected, and that has to update the entry in place
    /// rather than replace it — a replacement would mint a new `id`, which is what a
    /// list row in the middle of being answered is keyed on.
    var text: String
    let askedAt: Date
    /// Set once an answer has been produced for it, so it stops being offered.
    var answeredAt: Date?

    var isAnswered: Bool { answeredAt != nil }
}

/// The questions aimed at the user that went unanswered.
///
/// The gate already recognizes "they just asked you something" — it is one of the trigger
/// types, and the `.onQuestion` policy is built on it. But that judgement is only ever used
/// to decide whether to pop a card *in that instant*. Every path that suppresses the card
/// — the cooldown, the per-session cap, `.manual`, presentation mode, the pre-gate — throws
/// the question away with it. The user is left knowing something was asked and having
/// nothing to ask omi about it except retyping it.
///
/// So the question is kept whether or not a card follows, and can be answered later, one at
/// a time. Memory only, and it ends with the session: an hour-old question from a meeting
/// that already finished is not a to-do list.
@MainActor
final class CopilotQuestionBacklog: ObservableObject {
    static let shared = CopilotQuestionBacklog()

    /// Beyond this, the oldest unanswered question drops off. A backlog you have to scroll
    /// is a backlog nobody reads.
    private let maxQuestions = 8
    /// How long a question stays worth answering. Past this the conversation has moved on
    /// and an answer would land as a non sequitur.
    private let timeToLive: TimeInterval = 15 * 60
    /// Shortest run of text that can be a real question rather than a transcription artifact.
    private let minCharacters = 12

    @Published private(set) var questions: [BackloggedQuestion] = []

    private init() {}

    /// Questions still worth offering, newest first.
    var pending: [BackloggedQuestion] {
        let cutoff = Date().addingTimeInterval(-timeToLive)
        return Array(questions.filter { !$0.isAnswered && $0.askedAt >= cutoff }.reversed())
    }

    /// Record a question the other side asked.
    func record(_ text: String, askedAt: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minCharacters else { return }
        // Transcription revises itself, so the same question arrives repeatedly with a
        // word changed. Comparing on a normalized form keeps one entry rather than five.
        let key = Self.normalize(trimmed)
        guard !key.isEmpty else { return }
        if let index = questions.firstIndex(where: { Self.normalize($0.text) == key }) {
            // Keep the longer rendering — a later revision usually has the full sentence.
            if trimmed.count > questions[index].text.count {
                questions[index].text = trimmed
            }
            return
        }
        questions.append(BackloggedQuestion(text: trimmed, askedAt: askedAt, answeredAt: nil))
        trim()
    }

    /// Mark one answered, so it stops being offered.
    func markAnswered(id: UUID) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[index].answeredAt = Date()
    }

    /// Mark whichever pending question a delivered suggestion plausibly covers.
    ///
    /// A card the copilot raised on its own almost always *is* the answer to the question
    /// that triggered it, and leaving it in the list would invite the user to ask for the
    /// same thing twice.
    func markAnsweredByCard(gateType: String) {
        guard gateType == "question", let newest = pending.first else { return }
        markAnswered(id: newest.id)
    }

    func clear() {
        questions.removeAll()
    }

    private func trim() {
        let cutoff = Date().addingTimeInterval(-timeToLive)
        questions.removeAll { !$0.isAnswered && $0.askedAt < cutoff }
        let unanswered = questions.filter { !$0.isAnswered }
        guard unanswered.count > maxQuestions else { return }
        let drop = Set(unanswered.prefix(unanswered.count - maxQuestions).map(\.id))
        questions.removeAll { drop.contains($0.id) }
    }

    /// Lowercased, stripped of punctuation and runs of whitespace, for duplicate matching.
    private static func normalize(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Debug (omi-ctl)

    func debugDump() -> [String: String] {
        [
            "total": String(questions.count),
            "pending": String(pending.count),
            "newest": pending.first?.text ?? "-",
        ]
    }
}
