import Foundation

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — Sources/LiveSubs/Notes.swift
// (the notes model, prompt, lenient parse, carryTimes and the language check) and
// SessionStore.swift (TranscriptExport.clock / notesMarkdown). See
// ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: every point, branch, conclusion and to-do keeps its evidence as quotes tied to
// transcript segment ids instead of only a count and a time, and the current notes go back to
// the model with those evidence ids so it can keep them; carryTimes became carryEvidence;
// evidence ids also parse as ranges ("L12-L14") and times also parse as "mm:ss"; speaker
// labels follow the minutes language; deleted transcript lines keep their numbers but never
// count as evidence; the gate that decides whether a session is a meeting at all is omi's.

// MARK: - Model

/// One transcript line as the minutes number it. The number is the line's position in the
/// session (`index + 1`) and never changes: lines are only appended, and a line the backend
/// deletes stays in place marked `deleted`, so an `L12` written ten minutes ago still names
/// the same line.
struct MinutesLine: Codable, Equatable, Identifiable, Sendable {
    /// The transcript segment's id (`SpeakerSegment.id`).
    let id: String
    /// Seconds into the session.
    var t: Double
    var speakerId: Int
    var isUser: Bool
    var text: String
    var deleted = false
}

/// Where something in the minutes came from: the line that says it, when, who, and the words.
///
/// The quote is a copy taken when the minutes were written, so the minutes still show their
/// sources after the live transcript has scrolled out of memory, and in an export.
struct EvidenceRef: Codable, Equatable, Hashable, Sendable {
    /// The line's number in the session (L-number).
    let line: Int
    /// The transcript segment's id, which is what a jump scrolls to.
    let lineId: String
    let t: Double
    let speaker: String
    let quote: String
}

/// Meeting minutes for one session: written while it runs ("live") and rewritten once over the
/// whole transcript when it ends ("final").
struct MeetingMinutes: Codable, Equatable, Sendable {
    /// A short name for the meeting, in the minutes' language.
    var title: String?
    var summary = ""
    var topics: [MinutesTopic] = []
    var conclusions: [MinutesItem] = []
    var todos: [MinutesItem] = []
    var terms: [MinutesTerm] = []
    /// How many transcript lines (deleted ones included) these minutes have read.
    var covered = 0
    var updatedAt: Date?
    var final = false

    var isEmpty: Bool { summary.isEmpty && topics.isEmpty }
}

struct MinutesTopic: Codable, Equatable, Identifiable, Sendable {
    var start: Double
    var title: String
    var summary: String
    var points: [MinutesPoint]
    var fishbone: MinutesFishbone?
    var id: String { "\(Int(start))-\(title)" }
}

struct MinutesPoint: Codable, Equatable, Sendable {
    var text: String
    var evidence: [EvidenceRef]
    /// When it was first said.
    var t: Double? { evidence.map(\.t).min() }
}

/// A cause-and-effect diagram for a topic that discusses why something happened.
struct MinutesFishbone: Codable, Equatable, Sendable {
    var question: String
    var branches: [MinutesBranch]
}

struct MinutesBranch: Codable, Equatable, Identifiable, Sendable {
    var label: String
    var detail: String
    /// When it was said: the earliest evidence line, or the model's own time without one.
    var t: Double?
    var evidence: [EvidenceRef]
    /// How many lines back this branch; 0 is drawn as weak.
    var support: Int { evidence.count }
    var id: String { label + detail }
}

/// A conclusion or a to-do.
struct MinutesItem: Codable, Equatable, Identifiable, Sendable {
    var text: String
    var owner: String?
    var evidence: [EvidenceRef]
    var support: Int { evidence.count }
    /// When it was first said.
    var t: Double? { evidence.map(\.t).min() }
    var id: String { text }
}

/// A name or term as the minutes settled on it, and how speech recognition heard it.
struct MinutesTerm: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var note: String
    var heard: [String]
    var id: String { name }

    /// Corrected spellings first: what a reader can't work out alone.
    static func ordered(_ terms: [MinutesTerm]) -> [MinutesTerm] {
        terms.filter { !$0.heard.isEmpty } + terms.filter { $0.heard.isEmpty }
    }
}

/// Why a session is being minuted at all.
enum MinutesTrigger: String, Codable, Equatable, Sendable {
    /// A meeting app or a browser call is using the microphone.
    case call
    /// The computer is playing someone talking (a webinar, a livestream, a video).
    case systemAudio
    /// The user asked for minutes of this session.
    case manual
}

// MARK: - Gate

/// Decides whether a recording session is a meeting worth minuting.
///
/// omi records all day. Minuting every conversation would spend the shared per-user model
/// budget (30 requests a minute, a daily cap) on someone talking to the dog, and crowd out the
/// copilot. Cicada never had this problem — you start it for a meeting. So minutes start on
/// evidence that this is one: a call, or the computer playing people talking, or being asked.
/// Once a session qualifies it stays qualified until it ends.
enum MinutesGate {
    /// System-audio RMS above which the speakers count as playing something.
    static let soundLevel: Float = 0.005
    /// How many recent five-second samples of the speakers are kept (two minutes).
    static let sampleWindow = 24
    /// Fewest samples before system audio can count, so one loud notification doesn't.
    static let minimumSamples = 6
    /// Lines spoken by someone other than the user before system audio counts.
    static let othersLinesNeeded = 3

    static func trigger(
        enabled: Bool, manual: Bool, callSeen: Bool, soundSamples: [Bool], othersLines: Int
    ) -> MinutesTrigger? {
        guard enabled else { return nil }
        if manual { return .manual }
        if callSeen { return .call }
        let sounding = soundSamples.filter { $0 }.count
        // Someone other than the user is talking *and* the speakers have been busy for a good
        // part of the last two minutes: that is a call app we don't know, or a video of people.
        if othersLines >= othersLinesNeeded, soundSamples.count >= minimumSamples,
            sounding * 10 >= soundSamples.count * 3
        {
            return .systemAudio
        }
        return nil
    }
}

// MARK: - Prompt, parse, carry

enum MinutesLogic {
    /// How often the live minutes are updated while there is new speech.
    static let interval: TimeInterval = 45
    /// Evidence kept per item: enough to show where it came from, not a transcript.
    static let maxEvidence = 6
    /// Longest quote kept per evidence line.
    static let maxQuote = 240

    /// How the minutes name the people in the transcript.
    struct Labels: Equatable {
        /// Chinese minutes call people the way a Chinese reader would ("你", "说话人2"); every
        /// other language gets the English labels the transcript itself shows.
        let chinese: Bool

        static func forLanguage(_ code: String) -> Labels {
            Labels(chinese: MeetingLanguages.base(code) == "zh")
        }

        var me: String { chinese ? "你" : "You" }
        /// "Speaker N", as the prompt explains it.
        var someone: String { chinese ? "说话人N" : "Speaker N" }

        func speaker(_ n: Int) -> String { chinese ? "说话人\(n)" : "Speaker \(n)" }

        func who(_ line: MinutesLine, names: [Int: String]) -> String {
            if line.isUser { return me }
            if let name = names[line.speakerId], !name.isEmpty { return name }
            return speaker(line.speakerId)
        }
    }

    static func clock(_ t: Double) -> String {
        let s = Int(max(0, t))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// The short instruction sent as the user turn; the prompt is the system turn. The language
    /// goes last because that is where the model reads it last.
    static func instruction(language: String) -> String {
        "Update the notes. Write them in \(language)."
    }

    static func prompt(
        minutes: MeetingMinutes, lines: [MinutesLine], from: Int, language: String, final: Bool,
        labels: Labels, names: [Int: String] = [:]
    ) -> String {
        func line(_ i: Int) -> String? {
            let l = lines[i]
            let text = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !l.deleted, !text.isEmpty else { return nil }
            return "[L\(i + 1) \(clock(l.t)) \(labels.who(l, names: names))] \(text)"
        }
        let start = final ? 0 : min(max(0, from), lines.count)
        var current = "{}"
        if !minutes.isEmpty, let data = try? JSONEncoder().encode(Compact(minutes)),
            let s = String(data: data, encoding: .utf8)
        {
            current = s
        }
        // Two lines of what was already covered, so the new lines don't start mid-thought.
        let context = Array((0..<start).reversed().compactMap(line).prefix(2).reversed())
        let fresh = (start..<lines.count).compactMap(line)
        let visible = lines.filter { !$0.deleted && !$0.text.isEmpty }

        var p = """
            You keep notes for a meeting \(final ? "that has just ended. Rewrite them from the whole transcript" : "that is still going on. Update them with the new lines").
            Write the notes in \(language). Return JSON only.


            """
        if !final {
            p += "Current notes (JSON):\n\(current)\n\n"
        }
        if !final, !context.isEmpty {
            p += "Already covered (context only):\n" + context.joined(separator: "\n") + "\n\n"
        }
        p += "\(final ? "Transcript" : "New lines") (id, mm:ss, speaker: \(labels.me) = me, the person these notes are for; a name or \(labels.someone) = another participant, told apart by voice and possibly wrong; text). Speech recognition makes mistakes, often in names: correct them from context, and write a public figure's name as the news spells it.\n"
        p += fresh.joined(separator: "\n")
        // The model splits too eagerly when only told how long a topic should be: say plainly
        // whether this update may start one.
        if final, let first = visible.first?.t, let last = visible.last?.t {
            let most = max(1, min(8, Int((last - first) / 180) + 1))
            p += "\n\nThis meeting ran \(clock(last - first)): use at most \(most) topic\(most == 1 ? "" : "s")."
        } else if !final, let topic = minutes.topics.last, let newest = visible.last?.t,
            newest - topic.start < 120
        {
            p += "\n\nThe current topic \"\(topic.title)\" started at \(clock(topic.start)), under 2 minutes ago: do not start a new topic in this update; add the new lines to it."
        } else if !final, minutes.topics.isEmpty {
            p += "\n\nThese are the first lines: make one topic."
        }
        let owner = "the person's label from the transcript (a name, or \"\(labels.speaker(2))\"), \"\(labels.me)\", or null when unclear"
        p += """


            Return the full notes as one JSON object with exactly these keys:
            {"title": "the meeting's name: what it is about, a few words",
             "summary": "2-3 sentences on the whole meeting so far",
             "topics": [{"start": seconds, "title": "short title", "summary": "one sentence", "points": [{"text": "key point", "evidence": ["L4"]}], "evidence": ["L3"],
                         "fishbone": null or {"question": "the problem or question", "branches": [{"label": "2-6 words", "detail": "one short line", "t": seconds, "evidence": ["L5"]}]}}],
             "conclusions": [{"text": "...", "evidence": ["L7", "L8"]}],
             "todos": [{"text": "...", "owner": \(owner), "evidence": ["L9"]}],
             "terms": [{"name": "correct spelling", "note": "who or what, a few words", "heard": ["how it was misrecognised"]}]}
            Rules (be brief: these notes are read at a glance during the meeting):
            - title: a name for the whole meeting, like a calendar entry (at most 12 Chinese characters or 6 words; no date, no quotes, not "meeting" alone). Keep the current title unless the meeting's subject has clearly changed.
            - summary: at most 3 short sentences.
            - Topics in time order, at most 8 in total. A topic is a stretch of the meeting, usually 3-10 minutes, not a single remark: start a new one only when the subject clearly changes and the current topic started at least 2 minutes before the newest line\(final ? "" : "; add at most one new topic per update"). Otherwise add to the current one, and merge small neighbouring topics. Keep earlier topics as they are unless new lines correct them. The last topic is the one being discussed now.
            - At most 4 points per topic, each one short phrase. Merge rather than repeat.
            - At most 5 conclusions and only real to-dos (often none).
            - Add a fishbone only to a topic that discusses causes, reasons or factors (3-5 branches); otherwise null.
            - Every topic, point, branch, conclusion and to-do needs evidence: the ids of the lines that say it. Never state anything the transcript does not say.\(final ? "" : " Keep the evidence ids of what you carry over from the current notes, and add the ids of new lines that say it again.")
            - terms: at most 10 in total, replacing less useful ones rather than adding: first names the transcript misspells (heard), then the people, places and jargon a reader would not know. Leave out what everyone knows (a famous company, index or politician) unless it was misheard. name is the correct spelling in the transcript's language (no translation in brackets); heard lists only the wrong forms the transcript used; note is a few words.
            - Write the meeting title and every summary, title, point, branch, conclusion and to-do in \(language), even when the transcript is in another language. Only term names keep the transcript's spelling.
            - Write about what was said, never about the transcript or recognition quality.
            - Use empty arrays when there is nothing. No markdown, no text outside the JSON.
            """
        return p
    }

    /// Whether the minutes' own words (summary, titles) are in `language`: Chinese, Japanese and
    /// Korean need a fair share of CJK (names and numbers stay Latin), other languages must not
    /// be mostly CJK.
    static func written(_ minutes: MeetingMinutes, in language: String) -> Bool {
        let text = ([minutes.summary] + minutes.topics.map(\.title)).joined()
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return true }
        let cjk = letters.filter {
            (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        }.count
        let wantsCJK = ["Chinese", "Japanese", "Korean"].contains { language.contains($0) }
        return wantsCJK ? cjk * 5 >= letters.count : cjk * 2 < letters.count
    }

    /// The current minutes as sent back to the model: no bookkeeping, but the evidence ids, so
    /// an update keeps the sources of what it carries over instead of restating it unsourced.
    private struct Compact: Encodable {
        let title: String?
        let summary: String
        let topics: [Topic]
        let conclusions: [Item]
        let todos: [Item]
        let terms: [MinutesTerm]

        struct Point: Encodable {
            let text: String
            let evidence: [String]
        }
        struct Branch: Encodable {
            let label: String
            let detail: String
            let t: Double?
            let evidence: [String]
        }
        struct Fishbone: Encodable {
            let question: String
            let branches: [Branch]
        }
        struct Topic: Encodable {
            let start: Double
            let title: String
            let summary: String
            let points: [Point]
            let fishbone: Fishbone?
        }
        struct Item: Encodable {
            let text: String
            let owner: String?
            let evidence: [String]
        }

        init(_ m: MeetingMinutes) {
            func ids(_ refs: [EvidenceRef]) -> [String] { refs.map { "L\($0.line)" } }
            title = m.title
            summary = m.summary
            topics = m.topics.map { t in
                Topic(
                    start: t.start, title: t.title, summary: t.summary,
                    points: t.points.map { Point(text: $0.text, evidence: ids($0.evidence)) },
                    fishbone: t.fishbone.map { f in
                        Fishbone(
                            question: f.question,
                            branches: f.branches.map {
                                Branch(label: $0.label, detail: $0.detail, t: $0.t, evidence: ids($0.evidence))
                            })
                    })
            }
            conclusions = m.conclusions.map { Item(text: $0.text, owner: $0.owner, evidence: ids($0.evidence)) }
            todos = m.todos.map { Item(text: $0.text, owner: $0.owner, evidence: ids($0.evidence)) }
            terms = m.terms
        }
    }

    // MARK: Parse

    /// The line numbers an evidence value names. Accepts `["L4", "L7"]`, a lone `"L4"`, bare
    /// numbers, and ranges (`"L12-L14"`, `"L12–14"`), which models write despite being asked not to.
    static func lineNumbers(_ value: Any?, lineCount: Int) -> [Int] {
        var raw: [String] = []
        if let list = value as? [Any] {
            for v in list {
                if let s = v as? String { raw.append(s) } else if let n = v as? NSNumber { raw.append(n.stringValue) }
            }
        } else if let s = value as? String {
            raw = s.split(separator: ",").map(String.init)
        } else if let n = value as? NSNumber {
            raw = [n.stringValue]
        }
        var out: [Int] = []
        for id in raw {
            let numbers = id.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            let isRange = numbers.count == 2
                && (id.contains("-") || id.contains("–") || id.contains("~") || id.contains("to"))
            if isRange, numbers[1] >= numbers[0], numbers[1] - numbers[0] <= 12 {
                out.append(contentsOf: numbers[0]...numbers[1])
            } else {
                out.append(contentsOf: numbers)
            }
        }
        var seen = Set<Int>()
        return out.filter { $0 >= 1 && $0 <= lineCount && seen.insert($0).inserted }
    }

    /// "75", 75, "01:15", "1:01:15" → seconds.
    static func seconds(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = Double(s) { return d }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2, parts.count == s.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Lenient: missing keys become empty, evidence ids are checked against the transcript and
    /// turned into quotes. `who` names a line's speaker the way the minutes do.
    static func parse(
        _ raw: String, lines: [MinutesLine], startedAt: Double, who: (MinutesLine) -> String
    ) -> MeetingMinutes? {
        var text = raw
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b {
            text = String(text[a...b])
        }
        guard let data = text.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func str(_ v: Any?) -> String {
            (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func evidence(_ v: Any?) -> [EvidenceRef] {
            let refs = lineNumbers(v, lineCount: lines.count).compactMap { n -> EvidenceRef? in
                let l = lines[n - 1]
                let quote = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !l.deleted, !quote.isEmpty else { return nil }
                return EvidenceRef(
                    line: n, lineId: l.id, t: l.t, speaker: who(l),
                    quote: quote.count > maxQuote ? String(quote.prefix(maxQuote)) + "…" : quote)
            }
            return Array(refs.sorted { $0.t < $1.t }.prefix(maxEvidence))
        }

        var m = MeetingMinutes()
        m.summary = str(root["summary"])
        let title = str(root["title"]).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”「」《》"))
        m.title = title.isEmpty ? nil : title
        m.topics = (root["topics"] as? [[String: Any]] ?? []).compactMap { t in
            let title = str(t["title"])
            guard !title.isEmpty else { return nil }
            var fish: MinutesFishbone?
            if let f = t["fishbone"] as? [String: Any] {
                let branches = (f["branches"] as? [[String: Any]] ?? []).compactMap { b -> MinutesBranch? in
                    let label = str(b["label"])
                    guard !label.isEmpty else { return nil }
                    let refs = evidence(b["evidence"])
                    return MinutesBranch(
                        label: label, detail: str(b["detail"]),
                        t: refs.first?.t ?? seconds(b["t"]), evidence: refs)
                }
                if branches.count >= 2 { fish = MinutesFishbone(question: str(f["question"]), branches: branches) }
            }
            // Points come as {"text", "evidence"} (or plain strings from a careless reply).
            var points: [MinutesPoint] = []
            for p in t["points"] as? [Any] ?? [] {
                let dict = p as? [String: Any]
                let text = dict.map { str($0["text"]) } ?? str(p)
                guard !text.isEmpty else { continue }
                points.append(MinutesPoint(text: text, evidence: evidence(dict?["evidence"])))
            }
            let topicEvidence = evidence(t["evidence"])
            let start = seconds(t["start"])
                ?? topicEvidence.first?.t ?? points.compactMap(\.t).min() ?? startedAt
            return MinutesTopic(
                start: start, title: title, summary: str(t["summary"]), points: points, fishbone: fish)
        }
        func items(_ key: String) -> [MinutesItem] {
            (root[key] as? [[String: Any]] ?? []).compactMap { i in
                let text = str(i["text"])
                let owner = str(i["owner"])
                guard !text.isEmpty else { return nil }
                return MinutesItem(
                    text: text, owner: owner.isEmpty || owner == "null" ? nil : owner,
                    evidence: evidence(i["evidence"]))
            }
        }
        m.conclusions = items("conclusions")
        m.todos = items("todos")
        m.terms = (root["terms"] as? [[String: Any]] ?? []).compactMap { t in
            let name = str(t["name"])
            let heard = (t["heard"] as? [Any] ?? []).map(str).filter { !$0.isEmpty && $0 != name }
            return name.isEmpty ? nil : MinutesTerm(name: name, note: str(t["note"]), heard: heard)
        }
        // The model keeps every term it ever had: bound the glossary, keeping the misheard ones.
        if m.terms.count > 20 { m.terms = Array(MinutesTerm.ordered(m.terms).prefix(20)) }
        return m.isEmpty ? nil : m
    }

    /// The model restates what it already had, sometimes without the evidence: keep the sources
    /// each point, branch and item had, and with them the time it was first said — a later
    /// mention never moves it later.
    static func carryEvidence(from old: MeetingMinutes, into new: inout MeetingMinutes) {
        func key(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        }
        func merged(_ a: [EvidenceRef], _ b: [EvidenceRef]?) -> [EvidenceRef] {
            guard let b, !b.isEmpty else { return a }
            var seen = Set<Int>()
            return Array((a + b).sorted { $0.t < $1.t }.filter { seen.insert($0.line).inserted }.prefix(maxEvidence))
        }
        var points: [String: [EvidenceRef]] = [:]
        var branches: [String: (t: Double?, evidence: [EvidenceRef])] = [:]
        for topic in old.topics {
            for p in topic.points where !p.evidence.isEmpty { points[key(p.text), default: []] += p.evidence }
            for b in topic.fishbone?.branches ?? [] { branches[key(b.label)] = (t: b.t, evidence: b.evidence) }
        }
        var items: [String: [EvidenceRef]] = [:]
        for i in old.conclusions + old.todos where !i.evidence.isEmpty { items[key(i.text), default: []] += i.evidence }

        for ti in new.topics.indices {
            for pi in new.topics[ti].points.indices {
                let k = key(new.topics[ti].points[pi].text)
                new.topics[ti].points[pi].evidence = merged(new.topics[ti].points[pi].evidence, points[k])
            }
            if var fish = new.topics[ti].fishbone {
                for bi in fish.branches.indices {
                    guard let old = branches[key(fish.branches[bi].label)] else { continue }
                    fish.branches[bi].evidence = merged(fish.branches[bi].evidence, old.evidence)
                    let times = [fish.branches[bi].t, old.t, fish.branches[bi].evidence.first?.t].compactMap { $0 }
                    fish.branches[bi].t = times.min()
                }
                new.topics[ti].fishbone = fish
            }
        }
        for i in new.conclusions.indices {
            new.conclusions[i].evidence = merged(new.conclusions[i].evidence, items[key(new.conclusions[i].text)])
        }
        for i in new.todos.indices {
            new.todos[i].evidence = merged(new.todos[i].evidence, items[key(new.todos[i].text)])
        }
    }

    /// What the last live update added, for the "new" marks: topic titles and point texts.
    static func freshKeys(old: MeetingMinutes, new: MeetingMinutes) -> Set<String> {
        guard !old.isEmpty else { return [] }
        let before = Set(old.topics.flatMap { [$0.title] + $0.points.map(\.text) })
        return Set(new.topics.flatMap { [$0.title] + $0.points.map(\.text) }).subtracting(before)
    }

    /// A line with the minutes' misheard spellings replaced by the right ones, before it is
    /// translated: a translator given "江松" can only translate "江松". Latin spellings match
    /// whole words, ignoring case; CJK ones match anywhere (there are no word breaks).
    static func correct(_ text: String, terms: [MinutesTerm]) -> String {
        var out = text
        for term in terms where !term.name.isEmpty {
            for heard in term.heard where heard.count >= 2 && heard != term.name {
                let cjk = heard.unicodeScalars.contains { $0.properties.isIdeographic }
                if cjk {
                    out = out.replacingOccurrences(of: heard, with: term.name)
                } else {
                    let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
                    out = out.replacingOccurrences(
                        of: pattern, with: NSRegularExpression.escapedTemplate(for: term.name),
                        options: [.regularExpression, .caseInsensitive])
                }
            }
        }
        return out
    }

    /// Names for a translation glossary: "江充 (heard as 江松, 江冲)".
    static func glossary(_ terms: [MinutesTerm]) -> [String] {
        terms.prefix(30).map { t in
            t.heard.isEmpty
                ? "\(t.name) (\(t.note))"
                : "\(t.name) (\(t.note); misheard as \(t.heard.joined(separator: ", ")))"
        }
    }

    // MARK: Markdown

    /// The minutes as Markdown, each conclusion and to-do with the words it rests on.
    static func markdown(_ m: MeetingMinutes) -> String {
        guard !m.isEmpty else { return "" }
        func source(_ refs: [EvidenceRef]) -> String {
            guard let first = refs.first else { return " *(little support)*" }
            let more = refs.count > 1 ? " (+\(refs.count - 1))" : ""
            return " — [\(clock(first.t))] \(first.speaker): “\(first.quote)”\(more)"
        }
        var out = "## Minutes\(m.title.map { " · \($0)" } ?? "")\n\n"
        if !m.summary.isEmpty { out += "\(m.summary)\n\n" }
        for t in m.topics {
            out += "### \(clock(t.start)) \(t.title)\n\n"
            if !t.summary.isEmpty { out += "\(t.summary)\n\n" }
            for p in t.points { out += "- \(p.text)\(p.t.map { " [\(clock($0))]" } ?? "")\n" }
            if let f = t.fishbone {
                out += "\n**\(f.question.isEmpty ? "Why" : f.question)**\n\n"
                for b in f.branches { out += "- \(b.label)\(b.detail.isEmpty ? "" : ": \(b.detail)")\n" }
            }
            out += "\n"
        }
        if !m.conclusions.isEmpty {
            out += "### Conclusions\n\n" + m.conclusions.map { "- \($0.text)\(source($0.evidence))\n" }.joined() + "\n"
        }
        if !m.todos.isEmpty {
            out += "### To-dos\n\n"
                + m.todos.map {
                    "- [ ] \($0.text)\($0.owner.map { " (\($0))" } ?? "")\(source($0.evidence))\n"
                }.joined() + "\n"
        }
        if !m.terms.isEmpty {
            out += "### Names & terms\n\n"
                + m.terms.map { t in
                    "- **\(t.name)** \(t.note)\(t.heard.isEmpty ? "" : " (heard as \(t.heard.joined(separator: ", ")))")\n"
                }.joined() + "\n"
        }
        return out
    }
}
