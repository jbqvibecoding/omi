import Foundation

/// A scenario profile shapes what the live copilot considers a high-value
/// suggestion: same engine, different judgement criteria, trigger vocabulary,
/// and output tone. Struct (not enum) so custom/third-party profiles can join later.
struct CopilotScenarioProfile: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Role + what qualifies as a suggestion worth interrupting for + output tone.
    let systemPromptBlock: String
    /// Cheap lowercase-contains pre-filter: hitting one of these words in new
    /// transcript text triggers an evaluation without waiting for the word budget.
    /// Empty = word-count trigger only.
    let triggerVocabulary: [String]

    static let meeting = CopilotScenarioProfile(
        id: "meeting",
        displayName: "Meeting",
        systemPromptBlock: """
            Scenario: a work meeting. High-value suggestions are: a decision that was just \
            made (restate it crisply), a concrete action item with an owner, an open question \
            nobody answered, or a commitment the user made earlier that this moment relates to. \
            Do not summarize general discussion — live notes already do that.
            """,
        triggerVocabulary: ["decide", "decision", "action item", "deadline", "follow up", "agreed", "next step"]
    )

    static let sales = CopilotScenarioProfile(
        id: "sales",
        displayName: "Sales call",
        systemPromptBlock: """
            Scenario: the user is selling on this call. High-value suggestions are: a concise \
            response to an objection the prospect just raised (price, competitor, timing, trust), \
            a talking point that advances the deal, or the concrete next step to propose. \
            When you provide talk_track, write it in the first person, ready to say out loud.
            """,
        triggerVocabulary: [
            "price", "pricing", "cost", "expensive", "budget", "competitor", "alternative",
            "concern", "worried", "hesitant", "contract", "discount", "think about it",
        ]
    )

    static let interview = CopilotScenarioProfile(
        id: "interview",
        displayName: "Interview",
        systemPromptBlock: """
            Scenario: an interview. If the user is being asked a question, suggest the key \
            points of a strong answer (STAR framing when behavioral). If the user is the \
            interviewer, suggest a sharp follow-up question probing what was just said. \
            Keep it to skeleton points the user can speak from, never a script to read.
            """,
        triggerVocabulary: ["tell me about", "why did you", "how would you", "experience with", "walk me through"]
    )

    static let support = CopilotScenarioProfile(
        id: "support",
        displayName: "Customer support",
        systemPromptBlock: """
            Scenario: the user is helping a customer. High-value suggestions are: the likely \
            root cause of the problem being described, the next diagnostic question to ask, \
            or a draft reply the user can adapt. Be concrete about steps, never generic empathy.
            """,
        triggerVocabulary: ["not working", "error", "broken", "issue", "problem", "refund", "cancel", "bug"]
    )

    static let all: [CopilotScenarioProfile] = [meeting, sales, interview, support]

    static func byId(_ id: String) -> CopilotScenarioProfile {
        all.first { $0.id == id } ?? .meeting
    }
}
