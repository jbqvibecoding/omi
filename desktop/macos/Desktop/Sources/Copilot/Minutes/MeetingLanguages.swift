import Foundation

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — Sources/LiveSubs/Languages.swift
// and TranslationService.englishName in Translator.swift. See ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: gathered into one namespace instead of free functions; languages compare by base code
// ("en-US" is "en", spoken Mandarin is one language whatever script it is written in); an empty
// system list means English rather than Chinese; a script-based guess at a text's language.

/// The languages a meeting can be read in, and how "follow system" resolves to one of them.
///
/// Minutes, subtitles and the interpreter all start from the same answer to "what language
/// does this person read?", so they never disagree: a Chinese user listening to an English
/// livestream gets Chinese minutes and Chinese subtitles without setting either.
enum MeetingLanguages {
    struct Language: Equatable, Identifiable {
        /// Translation code: "zh-CN", "zh-TW", "en", "ja"…
        let code: String
        /// The name in its own language, for pickers.
        let name: String
        var id: String { code }
    }

    /// What minutes and subtitles can be written in.
    static let readable: [Language] = [
        .init(code: "zh-CN", name: "简体中文"),
        .init(code: "zh-TW", name: "繁體中文"),
        .init(code: "en", name: "English"),
        .init(code: "ja", name: "日本語"),
        .init(code: "ko", name: "한국어"),
        .init(code: "es", name: "Español"),
        .init(code: "fr", name: "Français"),
        .init(code: "de", name: "Deutsch"),
        .init(code: "pt", name: "Português"),
    ]

    /// Maps a system language identifier ("zh-Hans-CA", "en-CA", "zh-TW") to a translation code.
    static func translationCode(forSystemLanguage id: String) -> String {
        let locale = Locale(identifier: id)
        let lang = locale.language.languageCode?.identifier ?? "en"
        guard lang == "zh" else { return lang }
        let script = locale.language.script?.identifier
        let region = locale.region?.identifier
        if script == "Hant" { return "zh-TW" }
        if script == nil, let region, ["TW", "HK", "MO"].contains(region) { return "zh-TW" }
        return "zh-CN"
    }

    /// The reader's own language under "follow system": Chinese when the system list has it,
    /// otherwise the first system language.
    ///
    /// Chinese wins over list order on purpose (Cicada's rule, kept): a Chinese speaker with
    /// English as the first system language — common on machines bought abroad — still reads
    /// meetings in Chinese, and someone who never added Chinese is unaffected.
    static func myLanguage(systemLanguages prefs: [String] = Locale.preferredLanguages) -> String {
        translationCode(forSystemLanguage: prefs.first { $0.hasPrefix("zh") } ?? prefs.first ?? "en")
    }

    /// What "follow system" translates into: my language, unless that is what they speak; then
    /// the next system language, or between Chinese and English when the system has only one.
    static func followSystemTarget(
        source: String?, systemLanguages prefs: [String] = Locale.preferredLanguages
    ) -> String {
        let mine = myLanguage(systemLanguages: prefs)
        guard let source, sameLanguage(source, mine) else { return mine }
        return prefs.map(translationCode(forSystemLanguage:)).first { !sameLanguage($0, mine) }
            ?? (mine.hasPrefix("zh") ? "en" : "zh-CN")
    }

    /// "zh-CN" and "zh" are the same language for routing purposes; "zh-CN" and "zh-TW" are not
    /// the same script, but a speaker of one reads the other, so they count as the same too.
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        base(a) == base(b)
    }

    /// "zh-CN" → "zh", "en-US" → "en".
    static func base(_ code: String) -> String {
        String(code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(code)).lowercased()
    }

    /// The name a prompt uses for a language.
    static func englishName(_ code: String) -> String {
        switch code {
        case "zh-CN", "zh-Hans": return "Simplified Chinese"
        case "zh-TW", "zh-Hant": return "Traditional Chinese"
        default:
            return Locale(identifier: "en").localizedString(forLanguageCode: base(code)) ?? code
        }
    }

    /// The name a picker shows for a language.
    static func displayName(_ code: String) -> String {
        readable.first { $0.code == code }?.name
            ?? Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// Whether a language is written in Chinese, Japanese or Korean script.
    static func isCJK(_ code: String) -> Bool {
        ["zh", "ja", "ko"].contains(base(code))
    }

    /// The language a stretch of text is mostly written in, by script: good enough to tell
    /// a Chinese meeting from an English one, which is all "the meeting's own language" needs.
    static func dominantScript(of text: String) -> String? {
        var han = 0, kana = 0, hangul = 0, latin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x3040...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x0041...0x024F: latin += 1
            default: break
            }
        }
        let total = han + kana + hangul + latin
        guard total >= 12 else { return nil }
        // Japanese is mostly kanji with kana between: any real share of kana means Japanese.
        if kana * 10 >= total { return "ja" }
        if hangul * 3 >= total { return "ko" }
        // CJK characters carry far more per character than Latin letters do.
        if han * 4 >= latin { return "zh-CN" }
        return "en"
    }
}
