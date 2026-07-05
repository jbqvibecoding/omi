import Foundation

/// All Copilot Snap prompt templates in one place.
/// Cross-reference: the backend proactive pipeline keeps its own gate/generate/critic
/// prompts in backend/utils/llm/proactive_notification.py — keep intent aligned when
/// either side changes materially.
enum CopilotPrompts {

    /// System prompt for the predictive snap call. The user pressed the copilot key
    /// and typed nothing — the model must infer the need and answer it directly.
    static let systemPrompt = """
        You are an invisible realtime copilot on the user's Mac. The user pressed the \
        copilot shortcut — they did NOT type a question. Infer what they need right now \
        from the screenshot, the recent conversation transcript, and their recent screen \
        activity, then answer that need directly.

        Rules:
        - Never ask what they want. Never ask clarifying questions.
        - If they are in a call or meeting: give what they should say or know next \
        (an answer, a talking point, a fact, an objection response).
        - If they are reading: give the key answer, summary, or missing background.
        - If they are operating software or writing code: give the concrete next step \
        or the fix for the visible error.
        - If genuinely ambiguous, give the single most likely answer, then one short \
        alternate under a "If instead you meant..." line.
        - Keep response_markdown under 120 words. Use markdown (bold, short bullets) \
        for scannability. No greetings, no preamble.
        - headline is a max-8-word summary of your answer.
        - confidence is 0.0-1.0: how sure you are this is what the user needed.
        """

    /// Structured output schema for the snap call.
    static let responseSchema = GeminiRequest.GenerationConfig.ResponseSchema(
        type: "object",
        properties: [
            "intent_guess": .init(type: "string", enum: nil, description: "One sentence: what the user most likely needs right now"),
            "headline": .init(type: "string", enum: nil, description: "Max 8 words summarizing the answer"),
            "response_markdown": .init(type: "string", enum: nil, description: "The direct answer, markdown, under 120 words"),
            "confidence": .init(type: "number", enum: nil, description: "0.0-1.0 confidence that this is what the user needed"),
        ],
        required: ["intent_guess", "headline", "response_markdown", "confidence"]
    )

    /// Builds the user prompt from the assembled context snapshot. Empty sections are omitted.
    static func userPrompt(context: CopilotContextEngine.Snapshot) -> String {
        var sections: [String] = []

        if let app = context.activeApp, !app.isEmpty {
            var line = "Active app: \(app)"
            if let title = context.windowTitle, !title.isEmpty {
                line += " — \(title)"
            }
            sections.append(line)
        }

        if !context.transcriptWindow.isEmpty {
            sections.append("Recent conversation transcript (most recent last):\n\(context.transcriptWindow)")
        }

        if !context.recentOCR.isEmpty {
            sections.append("Recent on-screen text from the user's activity (OCR, may be noisy):\n\(context.recentOCR)")
        }

        if let profile = context.userProfile, !profile.isEmpty {
            sections.append("What we know about the user:\n\(profile)")
        }

        sections.append("The screenshot shows what the user is looking at right now. Infer their need and answer it.")

        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Live Copilot (meeting/call suggestion lane)

extension CopilotPrompts {

    /// Gate call: cheap yes/no on whether this transcript moment deserves a suggestion.
    /// sendTextRequest has no structured output, so the contract is a strict first line:
    /// `SKIP` or `SPEAK <type>`. Anything unparseable is treated as SKIP.
    static let liveGateSystemPrompt = """
        You are the gate of a realtime meeting copilot. Given the recent transcript, decide \
        if RIGHT NOW is a moment where a short suggestion would genuinely help the user — \
        most moments are not.

        Reply with EXACTLY one line:
        SKIP
        or
        SPEAK <type>
        where <type> is one of: objection, question, action_item, factual_gap, next_step

        Say SPEAK only when: someone raised an objection or hard question directed at the \
        user, a concrete commitment/action item was just made, a factual claim needs \
        checking, or the conversation clearly stalls on what to do next. If a similar \
        suggestion was already given (see list), say SKIP. When in doubt, SKIP.
        """

    static func liveGateUserPrompt(
        transcript: String,
        recentSuggestions: [String],
        scenario: CopilotScenarioProfile
    ) -> String {
        var sections = [scenario.systemPromptBlock]
        if !recentSuggestions.isEmpty {
            sections.append(
                "Suggestions already given (do not repeat):\n"
                    + recentSuggestions.suffix(5).map { "- \($0)" }.joined(separator: "\n"))
        }
        sections.append("Recent transcript (most recent last):\n\(transcript)")
        return sections.joined(separator: "\n\n")
    }

    static func liveSuggestionSystemPrompt(scenario: CopilotScenarioProfile) -> String {
        """
        You are an invisible realtime copilot in an ongoing conversation. Produce ONE short, \
        immediately usable suggestion for the user based on the transcript and the screenshot \
        (which shows shared content or the user's screen).

        \(scenario.systemPromptBlock)

        Rules:
        - suggestion is under 50 words, concrete, no preamble.
        - headline is a max-8-word label for the suggestion.
        - talk_track (optional): the exact sentence the user could say out loud, first person.
        - confidence 0.0-1.0: how sure you are this helps right now. Be honest — low-value \
        suggestions with inflated confidence destroy trust.
        - Never repeat a suggestion from the already-given list.
        """
    }

    static func liveSuggestionUserPrompt(
        transcript: String,
        gateType: String,
        recentSuggestions: [String],
        userProfile: String?
    ) -> String {
        var sections: [String] = ["Trigger type: \(gateType)"]
        if !recentSuggestions.isEmpty {
            sections.append(
                "Suggestions already given (do not repeat):\n"
                    + recentSuggestions.suffix(5).map { "- \($0)" }.joined(separator: "\n"))
        }
        if let userProfile, !userProfile.isEmpty {
            sections.append("What we know about the user:\n\(userProfile)")
        }
        sections.append("Recent transcript (most recent last):\n\(transcript)")
        return sections.joined(separator: "\n\n")
    }

    static let liveSuggestionSchema = GeminiRequest.GenerationConfig.ResponseSchema(
        type: "object",
        properties: [
            "headline": .init(type: "string", enum: nil, description: "Max 8 words labeling the suggestion"),
            "suggestion": .init(type: "string", enum: nil, description: "The suggestion, under 50 words, concrete"),
            "talk_track": .init(type: "string", enum: nil, description: "Optional exact sentence the user could say, first person"),
            "confidence": .init(type: "number", enum: nil, description: "0.0-1.0 confidence this helps right now"),
        ],
        required: ["headline", "suggestion", "confidence"]
    )
}

/// Parsed structured response from the live suggestion call.
struct CopilotLiveSuggestion: Decodable {
    let headline: String
    let suggestion: String
    let talkTrack: String?
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case headline
        case suggestion
        case talkTrack = "talk_track"
        case confidence
    }
}

/// Parsed structured response from the snap call.
struct CopilotSnapResult: Decodable {
    let intentGuess: String
    let headline: String
    let responseMarkdown: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case intentGuess = "intent_guess"
        case headline
        case responseMarkdown = "response_markdown"
        case confidence
    }
}
