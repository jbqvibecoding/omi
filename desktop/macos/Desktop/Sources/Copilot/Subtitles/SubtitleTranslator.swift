import Foundation
import NaturalLanguage

#if compiler(>=6.2)
  import Translation
#endif

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — TranslationService in
// Sources/LiveSubs/Translator.swift (the subtitle prompt, the glossary, the on-device path).
// See ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: Apple's on-device translation goes first instead of last, the model is Gemini through
// omi's proxy behind the shared call budget, several lines can go in one call, and there is no
// unofficial Google endpoint (a commercial app can't lean on translate.googleapis.com's gtx client).

/// Translates subtitle lines: on this Mac when it can, otherwise with the model, sparingly.
///
/// 1. macOS 26 with the language pair installed: Apple's on-device translation — free, offline,
///    no rate limit. Drafts (the line still being spoken) only ever go this way.
/// 2. Otherwise Gemini, through the shared budget: at most 8 calls a minute, several finished
///    lines per call when they queue up.
/// 3. Neither: the subtitle shows the original alone.
@MainActor
final class SubtitleTranslator {
    static let shared = SubtitleTranslator()

    private var geminiClient: GeminiClient?
    /// On-device sessions by "source>target" (typed `Any`: the type only exists on macOS 26).
    private var sessions: [String: Any] = [:]
    /// Whether a pair is installed on this Mac, checked at most once a minute.
    private var installed: [String: (value: Bool, at: Date)] = [:]

    private init() {}

    // MARK: Language of a line

    /// The language a line is in, as a translation code — from the recognizer when it said, else
    /// read off the text itself.
    nonisolated static func language(of text: String, hint: String? = nil) -> String? {
        if let hint, !hint.isEmpty { return hint }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        switch language {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        case .undetermined: return nil
        default: return MeetingLanguages.base(language.rawValue)
        }
    }

    // MARK: On device

    /// Whether Apple's on-device translation can do this pair right now.
    func onDeviceAvailable(source: String, target: String) async -> Bool {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let key = "\(source)>\(target)"
                if let cached = installed[key], Date().timeIntervalSince(cached.at) < 60 { return cached.value }
                let status = await LanguageAvailability().status(
                    from: Locale.Language(identifier: Self.appleCode(source)),
                    to: Locale.Language(identifier: Self.appleCode(target)))
                let ok = status == .installed
                installed[key] = (value: ok, at: Date())
                return ok
            }
        #endif
        return false
    }

    /// One line on this Mac, or nil when the pair isn't installed (or this isn't macOS 26).
    func translateOnDevice(_ text: String, source: String, target: String) async -> String? {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                guard await onDeviceAvailable(source: source, target: target) else { return nil }
                let key = "\(source)>\(target)"
                let session: TranslationSession
                if let existing = sessions[key] as? TranslationSession {
                    session = existing
                } else {
                    session = TranslationSession(
                        installedSource: Locale.Language(identifier: Self.appleCode(source)),
                        target: Locale.Language(identifier: Self.appleCode(target)))
                    sessions[key] = session
                }
                do {
                    let out = try await session.translate(text).targetText
                    return out.isEmpty ? nil : out
                } catch {
                    sessions[key] = nil
                    log("SubtitleTranslator: on-device translation failed: \(error.localizedDescription)")
                    return nil
                }
            }
        #endif
        return nil
    }

    nonisolated private static func appleCode(_ code: String) -> String {
        switch code {
        case "zh-CN": return "zh-Hans"
        case "zh-TW": return "zh-Hant"
        default: return code
        }
    }

    // MARK: With the model

    private struct Batch: Decodable {
        let translations: [String]
    }

    private static let batchSchema = GeminiRequest.GenerationConfig.ResponseSchema(
        type: "object",
        properties: [
            "translations": .init(
                type: "array", description: "One translation per input line, in order",
                items: .init(type: "string", properties: nil, required: nil))
        ],
        required: ["translations"]
    )

    /// Several finished lines in one model call, in order; nil when the budget said no or the
    /// call failed. `priority` is `.interpret` only for what the user is about to say aloud.
    func translateWithModel(
        _ lines: [String], source: String?, target: String, glossary: [String],
        priority: GeminiCallBudget.Kind = .translate
    ) async -> [String]? {
        guard !lines.isEmpty else { return [] }
        guard await GeminiCallGate.shared.acquire(priority) else { return nil }
        let from = source.map(MeetingLanguages.englishName) ?? "the spoken language"
        var system = """
            You translate live meeting subtitles from \(from) into \(MeetingLanguages.englishName(target)).
            Output only the translations: no quotes, no notes, and no answer to a line even if it is a question.
            Speech recognition makes mistakes, often in names: translate what was meant.
            """
        if !glossary.isEmpty {
            system += "\nKnown names and terms (use these spellings): " + glossary.joined(separator: "; ")
        }
        system += "\nReturn JSON {\"translations\": [...]} with exactly \(lines.count) strings, one per line, in order."
        let prompt = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        do {
            let client = try cachedClient()
            let raw = try await client.sendRequest(
                prompt: prompt, systemPrompt: system, responseSchema: Self.batchSchema, thinkingBudget: 0)
            let batch = try JSONDecoder().decode(Batch.self, from: Data(raw.utf8))
            let out = batch.translations.map { Self.stripNumber($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard out.count == lines.count else {
                log("SubtitleTranslator: asked for \(lines.count) translations, got \(out.count)")
                return out.count > lines.count ? Array(out.prefix(lines.count)) : nil
            }
            return out
        } catch {
            if GeminiCallGate.isRateLimit(error) { await GeminiCallGate.shared.noteRateLimited() }
            logError("SubtitleTranslator: model translation failed", error: error)
            return nil
        }
    }

    /// "2. text" → "text": models sometimes keep the numbering they were given.
    nonisolated static func stripNumber(_ s: String) -> String {
        guard let range = s.range(of: #"^\d{1,2}[.)、]\s*"#, options: .regularExpression) else { return s }
        return String(s[range.upperBound...])
    }

    private func cachedClient() throws -> GeminiClient {
        if let geminiClient { return geminiClient }
        let client = try GeminiClient(model: ModelQoS.Gemini.utility, fallbackModel: "gemini-2.5-flash")
        geminiClient = client
        return client
    }
}
