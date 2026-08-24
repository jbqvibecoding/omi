import Foundation

/// How long an answer should be. A dial the user owns, because "how much detail do I
/// want right now" depends on the moment, not on the model's mood.
enum CopilotResponseLength: String, Codable, CaseIterable {
    /// Two to four sentences. For when you're mid-conversation and reading costs you the room.
    case short
    /// A paragraph or two. The default working length.
    case medium
    /// Let the model match the length to what the question actually needs.
    case adaptive

    var displayName: String {
        switch self {
        case .short: return "Short"
        case .medium: return "Medium"
        case .adaptive: return "Match the question"
        }
    }

    var subtitle: String {
        switch self {
        case .short: return "2-4 sentences. Fastest to read mid-conversation."
        case .medium: return "A paragraph or two, with the reasoning included."
        case .adaptive: return "Brief for simple things, fuller when it earns it."
        }
    }

    /// Appended to the system prompt. Nil for `.adaptive` — the base prompts already
    /// carry their own word budgets, and piling a second instruction on top of them
    /// just makes the model hedge.
    var promptFragment: String? {
        switch self {
        case .short:
            return "LENGTH: Answer in at most 2-4 sentences. Give the conclusion and the one "
                + "fact that supports it. Drop the caveats, the background and the examples."
        case .medium:
            return "LENGTH: Answer in one or two short paragraphs. Include the reasoning that "
                + "makes the answer usable, but no preamble and no recap of the question."
        case .adaptive:
            return nil
        }
    }
}

/// Which language the copilot answers in.
///
/// `.auto` follows the conversation, which is right almost always. The reason this is a
/// setting at all is the case it doesn't cover: you work in your own language but the
/// meeting is in another one.
struct CopilotAnswerLanguage: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// How the model should be told to write. Nil for `.auto`.
    let instruction: String?

    static let auto = CopilotAnswerLanguage(
        id: "auto", displayName: "Follow the conversation", instruction: nil)

    static let all: [CopilotAnswerLanguage] = [
        auto,
        .init(id: "en", displayName: "English", instruction: "English"),
        .init(id: "zh-Hans", displayName: "简体中文", instruction: "Simplified Chinese"),
        .init(id: "zh-Hant", displayName: "繁體中文", instruction: "Traditional Chinese"),
        .init(id: "ja", displayName: "日本語", instruction: "Japanese"),
        .init(id: "ko", displayName: "한국어", instruction: "Korean"),
        .init(id: "es", displayName: "Español", instruction: "Spanish"),
        .init(id: "fr", displayName: "Français", instruction: "French"),
        .init(id: "de", displayName: "Deutsch", instruction: "German"),
        .init(id: "pt", displayName: "Português", instruction: "Portuguese"),
        .init(id: "it", displayName: "Italiano", instruction: "Italian"),
        .init(id: "ru", displayName: "Русский", instruction: "Russian"),
        .init(id: "hi", displayName: "हिन्दी", instruction: "Hindi"),
        .init(id: "ar", displayName: "العربية", instruction: "Arabic"),
    ]

    static func byId(_ id: String) -> CopilotAnswerLanguage {
        all.first { $0.id == id } ?? auto
    }
}

/// Builds the language/length instructions appended to the copilot's system prompts.
@MainActor
enum CopilotAnswerStyle {

    /// For Snap: one block of prose the user reads. Language applies to all of it.
    static func snapFragment() -> String? {
        var parts: [String] = []
        if let language = CopilotSettings.shared.answerLanguage.instruction {
            parts.append("LANGUAGE: Write your answer in \(language), whatever language the "
                + "screen is in. Keep code, identifiers, commands and proper nouns exactly as "
                + "they appear — translating those makes the answer useless.")
        }
        if let length = CopilotSettings.shared.responseLength.promptFragment {
            parts.append(length)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// For live suggestions, where the two output fields have different audiences.
    ///
    /// This is the part a single global language setting gets wrong: `suggestion` is read
    /// silently by the user, but `talk_track` is **said out loud to the other people in the
    /// room**. Handing someone a Chinese sentence to say in an English meeting is worse than
    /// handing them nothing, so the talk track always stays in the language being spoken.
    static func liveFragment() -> String? {
        var parts: [String] = []
        if let language = CopilotSettings.shared.answerLanguage.instruction {
            parts.append("""
                LANGUAGE — the two fields are for different audiences, so they follow \
                different rules:
                - `headline` and `suggestion` are read silently by the user: write them in \
                \(language).
                - `talk_track` is SPOKEN OUT LOUD to the other people in the conversation: \
                write it in the language being spoken in the transcript, NEVER in \(language) \
                unless that is already the language of the conversation.
                Keep names, numbers, product terms and quoted phrases exactly as they were said.
                """)
        }
        if let length = CopilotSettings.shared.responseLength.promptFragment {
            // The live lane's own ≤50-word budget is tighter than "medium", so only the
            // short setting can meaningfully move it.
            if CopilotSettings.shared.responseLength == .short {
                parts.append(length)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
