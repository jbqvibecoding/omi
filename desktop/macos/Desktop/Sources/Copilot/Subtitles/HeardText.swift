import Foundation

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — Sources/LiveSubs/HeardText.swift.
// See ThirdPartyLicenses/cicada-LICENSE.txt. Changes: none to the rules; comments reworded for
// where the lines come from in omi (Apple's on-device recognizer on the system channel).

/// The other side's finished lines before they are recorded and translated: tidied, and joined to
/// the line before when a pause cut one sentence in two.
enum HeardText {
    /// Speech recognition leaves stray marks where it hears breaths and hesitations: "in..........",
    /// ", , that", ". , that is". They start lines, and a translator turns them into "，……" or worse.
    static func clean(_ text: String) -> String {
        var s = text
        // Two dots or more, with or without spaces or commas between: one ellipsis.
        s = s.replacingOccurrences(of: #"\s*[.。]{2,}|\s*…+"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"…(?:[\s,，]*…)+"#, with: "…", options: .regularExpression)
        // ", ," and ",," are one comma; a comma against an ellipsis adds nothing.
        s = s.replacingOccurrences(of: #"([,，])(?:\s*[,，])+"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[,，]\s*…|…\s*[,，]"#, with: "…", options: .regularExpression)
        // "UALE ," → "UALE,".
        s = s.replacingOccurrences(of: #"\s+([,，.。…?？!！;；:：])"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        // A line starts with a word, not with what was left of the last one.
        let lead: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "、", "，", "。", "；", "：", "！", "？", "-", "–", "—"]
        s = String(s.drop(while: { lead.contains($0) || $0.isWhitespace }))
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The longest pause, in seconds, that still joins two pieces of one sentence.
    static let joinGap = 1.5
    /// A line this long takes nothing more: past it a translation is slow and the line hard to
    /// read. The piece that finishes a shorter line always joins it, so a sentence is never left half.
    static let joinWords = 40

    /// Whether `next` carries on `previous`, from the same voice, rather than starting a sentence.
    /// `gap`: seconds of audio between them. `cut`: the recognizer was told to end `previous` at a
    /// pause (a long line in progress), so its closing "." is the recognizer's guess, not the
    /// speaker's: it is ignored when `next` starts in lower case (scripts without case keep it).
    static func continues(_ previous: String, _ next: String, gap: Double, cut: Bool) -> Bool {
        guard gap >= -0.5, gap <= joinGap, let last = previous.last, let first = next.first else { return false }
        let cjk = previous.unicodeScalars.contains { $0.properties.isIdeographic }
        let size = cjk ? previous.count / 2 : previous.split(separator: " ").count
        guard size < joinWords else { return false }
        switch last {
        case "?", "!", "？", "！": return false
        case ".", "。": return cut && first.isLowercase
        default: return true
        }
    }

    static func join(_ previous: String, _ next: String) -> String {
        let cjk = previous.unicodeScalars.contains { $0.properties.isIdeographic }
        // A cut's guessed "." goes: "are going to be." + "in the…" reads as one sentence.
        var head = previous
        if head.hasSuffix(".") && !head.hasSuffix("…") { head.removeLast() }
        if head.hasSuffix("。") { head.removeLast() }
        return cjk ? head + next : head + " " + next
    }
}
