import Foundation

/// Which kind of thing the other side is asking about right now.
///
/// The prep sheet exists because the copilot cannot ground an answer it has no material
/// for. But handing it *all* the material on every call is its own failure: when someone
/// asks "what are your salary expectations", a 2000-character résumé is 2000 characters of
/// noise competing with the transcript for the model's attention, and the one line that
/// would actually answer the question is buried in it.
///
/// So the sheet is routed. The category is read off what the other side just said, and
/// only the slots that category can use are injected.
enum PrepCategory: String, CaseIterable {
    case behavioral
    case motivation
    case situational
    case experience
    case compensation
    case technical
    /// Nothing recognizable was asked — inject the scenario's core slots, which is what
    /// the copilot did before routing existed.
    case general

    var displayName: String {
        switch self {
        case .behavioral: return "a story about something you did"
        case .motivation: return "why this role"
        case .situational: return "what you would do"
        case .experience: return "your background"
        case .compensation: return "money and logistics"
        case .technical: return "something technical"
        case .general: return "general"
        }
    }
}

/// Reads the category off the conversation and decides which prep slots to inject.
enum CopilotPrepRouter {
    /// How many of the other side's turns are considered. Five is enough to survive a
    /// "mm hm" or a "sorry, could you repeat that" between the question and the answer,
    /// and short enough that a question from five minutes ago cannot still be steering.
    static let turnWindow = 5

    /// A slot to inject and how much of it to spend.
    struct SlotBudget {
        let key: String
        let characters: Int
    }

    // MARK: - Detection

    /// The category of the most recent recognizable question from the other side.
    ///
    /// Newest turn first: whatever was just asked outranks anything earlier. Falls back to
    /// `.general`, which routes to the scenario's core slots, so a conversation this cannot
    /// read is never *worse* off than it was before routing.
    static func detect(from segments: [SpeakerSegment]) -> PrepCategory {
        let theirs =
            segments
            .filter { !$0.isUser }
            .suffix(turnWindow)
            .map { $0.text }
        for line in theirs.reversed() {
            if let category = category(of: line) { return category }
        }
        return .general
    }

    /// The category for the conversation happening right now.
    ///
    /// Same "live, else just-ended" rule the context engine uses: a question asked in the
    /// last seconds of a session should still route the answer the user asks for after it.
    @MainActor
    static func currentCategory() -> PrepCategory {
        var segments = LiveTranscriptMonitor.shared.segments
        if segments.isEmpty { segments = LiveTranscriptMonitor.shared.savedSegments }
        return detect(from: segments)
    }

    /// The category of one line, or nil when nothing matches.
    static func category(of line: String) -> PrepCategory? {
        for (category, patterns) in patternsByCategory {
            for pattern in patterns where pattern.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line)) != nil
            {
                return category
            }
        }
        return nil
    }

    // MARK: - Planning

    /// Which slots to inject for `category`, in order, with a character budget each.
    ///
    /// A key the scenario does not define is skipped by the caller, so this can name the
    /// interview slots unconditionally: every other scenario simply falls through to its
    /// own two core slots.
    static func plan(for category: PrepCategory, profile: CopilotScenarioProfile) -> [SlotBudget] {
        let coreKeys = profile.effectivePrepSlots.prefix(2).map(\.key)
        /// The scenario's own slots, always first — they are what makes any answer
        /// specific to this session at all.
        func core(_ characters: Int) -> [SlotBudget] {
            coreKeys.map { SlotBudget(key: $0, characters: characters) }
        }

        switch category {
        case .behavioral:
            // The one case where the résumé earns its full length: the answer has to name
            // a real project, a real number, a real outcome.
            return core(2000) + [SlotBudget(key: "stories", characters: 2000),
                                 SlotBudget(key: "workStyle", characters: 400)]
        case .experience:
            return core(2000) + [SlotBudget(key: "stories", characters: 1000)]
        case .motivation:
            return core(1200) + [SlotBudget(key: "whyCompany", characters: 600),
                                 SlotBudget(key: "whyLeaving", characters: 400),
                                 SlotBudget(key: "workStyle", characters: 400)]
        case .situational:
            return core(1200) + [SlotBudget(key: "workStyle", characters: 500),
                                 SlotBudget(key: "stories", characters: 600)]
        case .compensation:
            // Nothing in a résumé answers "what do you want to be paid". Keep the role
            // description — the band usually depends on it — and drop the rest.
            return [SlotBudget(key: coreKeys.last ?? "", characters: 600),
                    SlotBudget(key: "salaryTarget", characters: 300),
                    SlotBudget(key: "questionsToAsk", characters: 600)]
        case .technical:
            // The skills are in the background slot; the long prose around them is not
            // what makes a system-design answer good.
            return core(900)
        case .general:
            return core(CopilotPrepSheet.maxCharactersPerSlot)
        }
    }

    // MARK: - Patterns

    /// Checked in this order, so the narrow and unambiguous categories are tested before
    /// the broad ones — "walk me through your first 90 days" is situational, while "walk
    /// me through your résumé" is experience, and only the ordering keeps them apart.
    private static let patternSources: [(PrepCategory, [String])] = [
        (.compensation, [
            #"\bsalary\b"#, #"\bcompensation\b"#, #"\bpay (range|expectation)"#,
            #"how much (are|do) you (currently )?(make|making|earn|expect|want)"#,
            #"\b(expected|target) (salary|comp)\b"#,
            #"\bnotice period\b"#, #"when (can|could) you start"#, #"\bstart date\b"#,
            #"\bequity\b"#, #"\bbonus\b"#,
            #"(any|some) questions for (us|me)\b"#, #"anything you.{0,12}(like|want) to ask"#,
        ]),
        (.behavioral, [
            #"tell me about a time"#, #"describe a (time|situation)"#,
            #"walk me through a time"#, #"give me an example"#,
            #"example of (a time|when|how)"#,
            #"have you ever (had|faced|dealt|led|managed)"#,
            #"how did you (handle|deal with|approach|resolve)"#,
            #"(biggest|hardest|toughest) (challenge|failure|mistake|conflict)"#,
            #"\bdisagree(d)? with\b"#, #"\bconflict with\b"#,
            #"a time (when|you|where)"#, #"under pressure\b"#, #"tight deadline"#,
        ]),
        (.motivation, [
            #"why (do you want|are you interested|this (company|role|team)|us\b|here\b)"#,
            #"why (are you|did you) (leaving|leave|looking)"#,
            #"what (attracted|draws|drew|interests|excites|appeals)"#,
            #"where do you see yourself"#, #"\bcareer goals?\b"#, #"\bfive years\b|\b5 years\b"#,
            #"what motivates you"#, #"why should we hire"#,
            #"what are you looking for in (your next|a new|this)"#,
        ]),
        (.situational, [
            #"what would you do if"#,
            #"how would you (handle|approach|deal with|prioriti[sz]e)"#,
            #"imagine (you|that)"#, #"hypothetically"#, #"suppose (you|that|we)"#,
            #"if you (joined|started|were|inherited)"#,
            #"first (30|60|90) days"#, #"\bproduction (outage|incident)\b"#,
        ]),
        (.technical, [
            #"\bsystem design\b"#, #"how would you design"#,
            #"design (a|an|the) (system|service|api|schema|database)"#,
            #"\btrade.?offs?\b"#, #"difference between"#, #"\bwhen would you use\b"#,
            #"how does .{2,40} work"#, #"explain (how|what|why|the)"#,
            #"\b(time|space) complexity\b"#, #"\balgorithm\b"#, #"\bdata structure\b"#,
            #"how (do|would) you scale"#, #"\barchitecture\b"#, #"pros and cons"#,
        ]),
        (.experience, [
            #"tell me about (yourself|your (experience|background|role|work|time))"#,
            #"walk me through your (resume|cv|background|experience|career)"#,
            #"what (were you responsible for|was your role|did you do) at"#,
            #"your (most recent|last|current|previous) (role|job|position)"#,
            #"what have you been working on"#, #"tell me more about"#,
            #"(can you )?(elaborate|expand) on"#, #"\btech stack\b"#,
        ]),
    ]

    /// Compiled once. A pattern that fails to compile is dropped rather than crashing —
    /// a broken regex should cost one category, not the feature.
    private static let patternsByCategory: [(PrepCategory, [NSRegularExpression])] = {
        patternSources.map { category, sources in
            (
                category,
                sources.compactMap {
                    try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
                }
            )
        }
    }()
}
