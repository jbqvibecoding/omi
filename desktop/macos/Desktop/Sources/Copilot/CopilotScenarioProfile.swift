import Foundation

/// A scenario profile shapes what the live copilot considers a high-value
/// suggestion: same engine, different judgement criteria, trigger vocabulary,
/// and output tone. Struct (not enum) so custom/third-party profiles can join later.
struct CopilotScenarioProfile: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    /// Role + what qualifies as a suggestion worth interrupting for + output tone.
    let systemPromptBlock: String
    /// Cheap lowercase-contains pre-filter: hitting one of these words in new
    /// transcript text triggers an evaluation without waiting for the word budget.
    /// Empty = word-count trigger only.
    let triggerVocabulary: [String]
    /// True for user-created profiles (persisted in CustomProfileStore).
    var isCustom: Bool = false
    /// What this scenario needs the user to hand it before a session. Optional so
    /// profiles stored before prep sheets existed still decode.
    var prepSlots: [PrepSlotSpec]? = nil

    /// Prep slots for this profile, falling back to one generic slot so every scenario —
    /// including user-created ones — has somewhere to put session context.
    var effectivePrepSlots: [PrepSlotSpec] {
        prepSlots ?? [
            PrepSlotSpec(
                key: "context", label: "Context for this session",
                placeholder: "Anything the copilot should know going in.")
        ]
    }

    static let meeting = CopilotScenarioProfile(
        id: "meeting",
        displayName: "Meeting",
        systemPromptBlock: """
            Scenario: a work meeting. High-value suggestions are: a decision that was just \
            made (restate it crisply), a concrete action item with an owner, an open question \
            nobody answered, or a commitment the user made earlier that this moment relates to. \
            Do not summarize general discussion — live notes already do that.
            """,
        triggerVocabulary: ["decide", "decision", "action item", "deadline", "follow up", "agreed", "next step"],
        prepSlots: [
            PrepSlotSpec(key: "agenda", label: "What this meeting is for", placeholder: "The decision you need out of it, or the thread you are picking back up."),
            PrepSlotSpec(key: "stakes", label: "What matters to you here", placeholder: "What you need to land, and anything you would rather not relitigate."),
        ]
    )

    static let sales = CopilotScenarioProfile(
        id: "sales",
        displayName: "Sales call",
        systemPromptBlock: """
            Scenario: the user is selling on this call. High-value suggestions are: a concise \
            response to an objection the prospect just raised (price, competitor, timing, trust), \
            a talking point that advances the deal, or the concrete next step to propose. \
            When you provide talk_track, write it in the first person, ready to say out loud — \
            persuasive but not pushy, anchored on value.

            Examples of the talk_track quality bar:
            - Prospect: "I need to think about it" → "I completely understand — what specific \
            concern can I address right now, timeline, cost, or integration?"
            - Prospect: "What makes you different?" → name 2-3 concrete differentiators with \
            numbers, then ask which matters most to them.
            """,
        triggerVocabulary: [
            "price", "pricing", "cost", "expensive", "budget", "competitor", "alternative",
            "concern", "worried", "hesitant", "contract", "discount", "think about it",
        ],
        prepSlots: [
            PrepSlotSpec(key: "offering", label: "What you are selling", placeholder: "The product, the pricing you can actually offer, and your two strongest differentiators."),
            PrepSlotSpec(key: "account", label: "This account", placeholder: "Who they are, what they have already told you, and where the deal currently stands."),
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

            When the user has provided their background, build the answer out of THEIR \
            actual projects, numbers and job history — name the specific thing. A generic \
            STAR skeleton is what they could have written themselves; pointing them at the \
            right story from their own history is the whole value. Never invent experience \
            they did not list.
            """,
        triggerVocabulary: ["tell me about", "why did you", "how would you", "experience with", "walk me through"],
        prepSlots: [
            PrepSlotSpec(key: "background", label: "Your background", placeholder: "Paste your résumé, or the projects and numbers you want it to draw answers from."),
            PrepSlotSpec(key: "role", label: "The role and company", placeholder: "Paste the job description, plus anything you know about the team or the interviewer."),
        ]
    )

    static let support = CopilotScenarioProfile(
        id: "support",
        displayName: "Customer support",
        systemPromptBlock: """
            Scenario: the user is helping a customer. High-value suggestions are: the likely \
            root cause of the problem being described, the next diagnostic question to ask, \
            or a draft reply the user can adapt. Be concrete about steps, never generic empathy.
            """,
        triggerVocabulary: ["not working", "error", "broken", "issue", "problem", "refund", "cancel", "bug"],
        prepSlots: [
            PrepSlotSpec(key: "product", label: "The product or system", placeholder: "What you support, and how the parts fit together."),
            PrepSlotSpec(key: "known", label: "Known issues right now", placeholder: "Current incidents, recent regressions, and the workarounds you are allowed to give."),
        ]
    )

    static let negotiation = CopilotScenarioProfile(
        id: "negotiation",
        displayName: "Negotiation",
        systemPromptBlock: """
            Scenario: a business negotiation or deal discussion. High-value suggestions are: a \
            strategic response to a demand or pushback, a way to reframe toward a win-win, or a \
            concession structured to protect the user's position. When you provide talk_track, \
            write the exact words to say — calm, strategic, addressing the underlying concern \
            rather than just the stated position.

            Examples of the talk_track quality bar:
            - Other party: "That price is too high" → reframe on value/ROI, then offer a \
            structural alternative (payment terms, phased scope) rather than just discounting.
            - Other party: "We're considering other options" → acknowledge it, then surface the \
            2-3 differentiators that matter for their decision and ask how they weigh them.
            """,
        triggerVocabulary: [
            "too high", "too expensive", "better deal", "other options", "walk away", "final offer",
            "terms", "counteroffer", "concession", "budget", "margin",
        ],
        prepSlots: [
            PrepSlotSpec(key: "position", label: "Your position", placeholder: "What you want, what you can concede, and the point where you walk away."),
            PrepSlotSpec(key: "counterparty", label: "What you know about them", placeholder: "Their constraints, their alternatives, and what they have already asked for."),
        ]
    )

    /// Exam/certification assistance. Ethically sensitive (see CopilotSettings.examProfileUnlocked)
    /// — positioned for study and review, not covert test-taking. Locked by default and excluded
    /// from `all` unless the user explicitly unlocks it in Settings.
    static let exam = CopilotScenarioProfile(
        id: "exam",
        displayName: "Study / review",
        systemPromptBlock: """
            Scenario: the user is studying or reviewing practice material. When a question appears, \
            give the direct answer first, then a brief justification so the user understands why — \
            the goal is learning, not just the answer. Keep it short and accurate. Include the \
            question, the correct answer, and one-line reasoning.
            """,
        triggerVocabulary: [
            "which of the following", "true or false", "select the", "what is the", "define",
            "explain why", "answer",
        ],
        prepSlots: [
            PrepSlotSpec(key: "subject", label: "What you are studying", placeholder: "The subject and the level, so explanations land where you actually are."),
            PrepSlotSpec(key: "focus", label: "What you keep getting wrong", placeholder: "The topics worth extra care when it explains an answer."),
        ]
    )

    static let presentation = CopilotScenarioProfile(
        id: "presentation",
        displayName: "Presentation",
        systemPromptBlock: """
            Scenario: the user is presenting or demoing. While they are speaking, stay silent — \
            you are only valuable when the audience asks a question or needs context. When a \
            question comes, give a tight, confident answer the presenter can say out loud, backed \
            by a specific number or fact where possible. If a proper noun the audience may not know \
            just came up, define it in one line.
            """,
        triggerVocabulary: ["question", "how does", "what about", "can you explain", "why", "does it"],
        prepSlots: [
            PrepSlotSpec(key: "material", label: "What you are presenting", placeholder: "Your outline, the numbers you will show, and the claims you will make."),
            PrepSlotSpec(key: "room", label: "Who is in the room", placeholder: "Who they are, what they already know, and the questions you expect."),
        ]
    )

    /// Profiles always available in the picker.
    static let all: [CopilotScenarioProfile] = [meeting, sales, interview, support, negotiation, presentation]

    /// All profiles including the gated exam profile (used when it is unlocked).
    static let allIncludingGated: [CopilotScenarioProfile] = all + [exam]

    /// Built-in + user custom profiles, honoring the exam-unlock gate.
    @MainActor
    static var allAvailable: [CopilotScenarioProfile] {
        let builtIns = CopilotSettings.shared.examProfileUnlocked ? allIncludingGated : all
        return builtIns + CustomProfileStore.shared.profiles
    }

    @MainActor
    static func byId(_ id: String) -> CopilotScenarioProfile {
        if let custom = CustomProfileStore.shared.profiles.first(where: { $0.id == id }) {
            return custom
        }
        return allIncludingGated.first { $0.id == id } ?? .meeting
    }
}
