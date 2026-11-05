import Foundation

import Speech

/// A speech recognizer that transcribes one audio channel on this Mac and reports finished lines
/// as backend-shaped segments, so the transcript pipeline can't tell which one ran.
///
/// Driven from the main actor, except `appendAudio`, which the capture thread calls.
@MainActor
protocol LocalSegmentTranscriber: AnyObject {
    func start(
        onSegments: @escaping LocalTranscriptionService.SegmentsHandler,
        onModelLoadFailed: (@MainActor () -> Void)?)
    /// 16 kHz mono Int16 little-endian PCM — the same `Data` the WebSocket path sends.
    nonisolated func appendAudio(_ data: Data)
    /// Fire-and-forget stop; prefer `finish()` when the lifecycle allows it.
    func stop()
    /// Flush and deliver the final lines before returning.
    func finish() async
}

extension LocalTranscriptionService: LocalSegmentTranscriber {}

/// Which recognizer runs a channel.
enum TranscriberKind: String, Equatable {
    /// NVIDIA Parakeet on the Neural Engine (FluidAudio): English, or 25 European languages.
    case parakeet
    /// Apple's SpeechAnalyzer (macOS 26): words as they are said, and it can tell languages apart.
    case appleSpeech
}

enum TranscriberPlan: Equatable {
    /// One cloud stream for the mixed mic and system audio.
    case cloud
    /// Each channel transcribed on this Mac, by its own recognizer.
    case local(mic: TranscriberKind, system: TranscriberKind)
}

/// Picks the recognizer for each channel from the macOS version, the transcription language and
/// whether subtitles are on.
///
/// Before this, "on-device" meant Parakeet for everyone on Apple Silicon, whatever the language
/// — and Parakeet knows English and European languages only. A Chinese, Japanese or Korean
/// meeting came out as confident nonsense, and the minutes and subtitles were built on it. Now:
///
/// | | the other side (system audio) | you (microphone) |
/// |---|---|---|
/// | macOS 26 | Apple's recognizer when subtitles are on or Parakeet can't read the language; otherwise Parakeet | Parakeet when it can read the language; otherwise Apple's recognizer |
/// | older | Parakeet when it can read the language; otherwise the whole session goes to the cloud | same |
///
/// Behaviour only changes where it was broken (CJK) or clearly gets better (live subtitles on
/// macOS 26): an English speaker without subtitles gets exactly what they had.
enum TranscriberRouting {
    /// Parakeet v2 (English) and v3's 25 European languages.
    static let parakeetLanguages: Set<String> = [
        "en", "bg", "hr", "cs", "da", "nl", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt",
        "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
    ]
    /// Languages Apple's on-device SpeechTranscriber covers on macOS 26. A model that turns out
    /// to be unsupported on this Mac fails at start and the session falls back to the cloud.
    static let appleSpeechLanguages: Set<String> = [
        "en", "es", "fr", "de", "it", "ja", "ko", "pt", "zh", "yue",
    ]

    static func parakeetSupports(_ language: String) -> Bool {
        parakeetLanguages.contains(MeetingLanguages.base(language))
    }

    static func appleSpeechSupports(_ language: String) -> Bool {
        appleSpeechLanguages.contains(MeetingLanguages.base(language))
    }

    /// - Parameters:
    ///   - language: the transcription language the user picked (not "multi": auto-detect is a
    ///     mode of the language they picked).
    ///   - localAllowed: Apple Silicon, not a BLE device, cloud not forced.
    ///   - forceLocal: the cloud stream just gave up; record on this Mac whatever it can do.
    static func plan(
        language: String, localAllowed: Bool, appleSpeechAvailable: Bool, subtitlesOn: Bool,
        forceLocal: Bool = false
    ) -> TranscriberPlan {
        guard localAllowed else { return .cloud }
        let parakeet = parakeetSupports(language)
        let apple = appleSpeechAvailable && appleSpeechSupports(language)
        let mic: TranscriberKind? = parakeet ? .parakeet : (apple ? .appleSpeech : nil)
        // The other side: Apple's recognizer gives words as they are said and detects which
        // language they speak — what subtitles need — so it takes that channel whenever it can
        // read the user's language and either subtitles are on or Parakeet can't.
        let system: TranscriberKind? =
            apple && (subtitlesOn || !parakeet) ? .appleSpeech : (parakeet ? .parakeet : nil)
        if let mic, let system { return .local(mic: mic, system: system) }
        // Nothing here reads this language. Normally that means the cloud; after the cloud
        // failed, a poor local transcript beats none.
        if forceLocal {
            let fallback: TranscriberKind = appleSpeechAvailable ? .appleSpeech : .parakeet
            return .local(mic: mic ?? fallback, system: system ?? fallback)
        }
        return .cloud
    }

    /// Whether Apple's on-device recognizer exists on this Mac.
    static var appleSpeechAvailable: Bool {
        // Built with the macOS 26 SDK (Xcode 26, Swift 6.2) or not at all: older toolchains
        // don't know the type, and the app then simply never routes to it.
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) { return SpeechTranscriber.isAvailable }
        #endif
        return false
    }

    /// A recognizer of the given kind for one channel.
    @MainActor
    static func make(_ kind: TranscriberKind, language: String, isUser: Bool) -> LocalSegmentTranscriber {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), kind == .appleSpeech {
                // "multi" is Parakeet's and the cloud's auto-detect mode, not a locale: Apple's
                // recognizer starts from the language it is a mode of.
                let speechLanguage = language == "multi" ? AssistantSettings.shared.transcriptionLanguage : language
                // The other side's language is detected; yours is the one you picked.
                return AppleSpeechTranscriptionService(
                    language: speechLanguage, isUser: isUser, detectLanguage: !isUser)
            }
        #endif
        return LocalTranscriptionService(language: language, isUser: isUser)
    }

    /// The speech locale for a transcription language ("zh" → "zh-CN", "ja" → "ja-JP").
    static func speechLocale(for language: String) -> String {
        let code = language.replacingOccurrences(of: "_", with: "-")
        switch MeetingLanguages.base(code) {
        case "zh":
            let lower = code.lowercased()
            if lower.contains("tw") || lower.contains("hant") { return "zh-TW" }
            if lower.contains("hk") { return "zh-HK" }
            return "zh-CN"
        case "yue": return "yue-CN"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "es": return code.contains("-") ? code : "es-ES"
        case "fr": return code.contains("-") ? code : "fr-FR"
        case "de": return "de-DE"
        case "it": return "it-IT"
        case "pt": return code.contains("-") ? code : "pt-BR"
        case "en": return code.contains("-") ? code : "en-US"
        default: return code
        }
    }
}
