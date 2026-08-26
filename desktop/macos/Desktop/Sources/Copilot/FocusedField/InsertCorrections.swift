import AppKit
import Foundation

/// One learned wrong→right pair: something omi typed, and what the user changed it to.
struct InsertCorrection: Codable, Equatable {
    var wrong: String
    var right: String
    /// How many separate insertions this same fix has been seen on.
    var count: Int
    var lastSeenAt: Date
}

/// What the user's own hands corrected after omi typed something in.
///
/// Ported from cetus (`src-tauri/src/corrections.rs`, MIT), and it fills the biggest hole in
/// omi's existing learning: today the only signal is "omi suggested X and the user then said
/// Y", which is a guess about causation. Editing the text omi just typed is not a guess.
/// The user's hands are ground truth; a cleanup model's opinion is not.
///
/// The thresholds are cetus's, and each one is load-bearing:
/// - a pair must be seen on **two separate insertions** before it counts, so a one-off
///   rephrase never becomes a rule;
/// - each side is capped at **10 characters**, which keeps this to the thing it's good at —
///   a name, a product term, a spelling — and out of the business of learning sentences;
/// - **5 pairs per insertion** and **200 stored**, because a user who rewrote the whole
///   draft is not correcting individual words.
@MainActor
final class InsertCorrectionStore {
    static let shared = InsertCorrectionStore()

    /// Seen on this many separate insertions before it's trusted.
    static let minCount = 2
    /// Longest either side of a pair may be. Beyond this it's a rewrite, not a correction.
    static let maxSideChars = 10
    /// Most pairs to take from a single insertion.
    static let maxPairsPerInsertion = 5

    private let storeKey = "copilotInsertCorrections"
    private let maxStored = 200

    private init() {}

    func all() -> [InsertCorrection] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
            let decoded = try? JSONDecoder().decode([InsertCorrection].self, from: data)
        else { return [] }
        return decoded
    }

    /// Record one observed fix. Returns true when this observation is what pushed the pair
    /// over ``minCount`` — the moment it becomes something we act on.
    @discardableResult
    func record(wrong: String, right: String) -> Bool {
        let wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty, !right.isEmpty, wrong != right,
            wrong.count <= Self.maxSideChars, right.count <= Self.maxSideChars
        else { return false }

        var list = all()
        var becameConfirmed = false
        if let index = list.firstIndex(where: { $0.wrong == wrong && $0.right == right }) {
            list[index].count += 1
            list[index].lastSeenAt = Date()
            becameConfirmed = list[index].count == Self.minCount
        } else {
            list.append(
                InsertCorrection(wrong: wrong, right: right, count: 1, lastSeenAt: Date()))
            becameConfirmed = Self.minCount <= 1
        }
        // Drop the least recently seen first — a fix you stopped making is a fix you no
        // longer need.
        if list.count > maxStored {
            list.sort { $0.lastSeenAt > $1.lastSeenAt }
            list = Array(list.prefix(maxStored))
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
        return becameConfirmed
    }

    /// The "right" side of every confirmed pair, for use as speech-recognition hot words.
    /// These are terms the user has demonstrably spelled a specific way, twice.
    func confirmedTerms() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for pair in all().sorted(by: { $0.lastSeenAt > $1.lastSeenAt })
        where pair.count >= Self.minCount {
            let key = pair.right.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(pair.right)
        }
        return out
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    // MARK: - Debug (omi-ctl)

    func debugDump() -> [String: String] {
        let list = all().sorted { $0.count > $1.count }
        let sample = list.prefix(12)
            .map { "\($0.wrong)→\($0.right) ×\($0.count)" }
            .joined(separator: ", ")
        return [
            "pairs": String(list.count),
            "confirmed": String(list.filter { $0.count >= Self.minCount }.count),
            "min_count": String(Self.minCount),
            "sample": sample.isEmpty ? "(none)" : sample,
        ]
    }
}

/// Watches a field after omi typed into it, and turns the user's edits into corrections.
@MainActor
enum InsertCorrectionWatcher {
    /// When the field is read back. The first catches the app's own normalization
    /// (autocorrect, an IME committing, a smart-quote substitution); the second catches the
    /// user actually rereading what was written and fixing it.
    private static let probeDelays: [TimeInterval] = [1.2, 10]
    /// Long enough after the insert for the app to have settled, short enough that the user
    /// hasn't started editing yet — this read is the reference everything is diffed against.
    private static let baselineDelay: TimeInterval = 0.45
    /// Whole-line pairs only count as style evidence when omi wrote most of the field.
    private static let styleCoverageThreshold = 0.6

    /// Start observing `pid`'s focused field after `inserted` was typed into it.
    ///
    /// Fire-and-forget: a failed read at any point simply ends the observation. There is
    /// nothing to report to the user and nothing to retry — the next insertion gets its own
    /// chance.
    static func observe(inserted: String, pid: pid_t) {
        let inserted = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inserted.count >= 8 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(baselineDelay * 1_000_000_000))
            guard let baseline = AXFocusedText.capture(pid: pid) else { return }

            var elapsed = baselineDelay
            var recorded = 0
            for delay in probeDelays {
                let wait = delay - elapsed
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                elapsed = max(elapsed, delay)
                guard let current = AXFocusedText.capture(pid: pid),
                    current.isSameTarget(as: baseline),
                    current.text != baseline.text
                else { continue }
                recorded += apply(
                    baseline: baseline.text, current: current.text, inserted: inserted,
                    budget: InsertCorrectionStore.maxPairsPerInsertion - recorded)
            }
        }
    }

    /// Diff the two readings and record what changed. Returns how many pairs were taken.
    private static func apply(
        baseline: String, current: String, inserted: String, budget: Int
    ) -> Int {
        guard budget > 0 else { return 0 }

        // The whole-line pair, which is what the style learner wants: it needs enough text
        // to say something about voice, and it only means anything if omi wrote the bulk of
        // what's there.
        let coverage = baseline.isEmpty ? 0 : Double(inserted.count) / Double(baseline.count)
        if coverage >= styleCoverageThreshold {
            CopilotStyleLearner.shared.recordCorrection(suggested: inserted, actual: current)
        }

        // The word-level pairs, which are what the recognizer wants. Only edits to text omi
        // actually typed count — the user rewriting their own surrounding sentence is not a
        // correction of ours.
        let insertedLower = inserted.lowercased()
        var taken = 0
        for pair in TokenDiff.pairs(from: baseline, to: current) {
            guard taken < budget else { break }
            guard pair.wrong.count <= InsertCorrectionStore.maxSideChars,
                pair.right.count <= InsertCorrectionStore.maxSideChars,
                insertedLower.contains(pair.wrong.lowercased())
            else { continue }
            let confirmed = InsertCorrectionStore.shared.record(
                wrong: pair.wrong, right: pair.right)
            taken += 1
            if confirmed {
                log("InsertCorrectionWatcher: learned \(pair.wrong) → \(pair.right)")
            }
        }
        return taken
    }
}

/// Word-level diff producing (wrong, right) pairs.
///
/// Word-level rather than character-level on purpose: a character diff of "recieve" and
/// "receive" yields a pair of single letters, which is true and useless. The unit people
/// actually correct is the word.
enum TokenDiff {
    struct Pair {
        let wrong: String
        let right: String
    }

    /// Tokens compared for the diff. Capped because this is an O(n·m) table and the input
    /// is a text field someone might have pasted a novel into.
    private static let maxTokens = 400

    static func pairs(from old: String, to new: String) -> [Pair] {
        let a = tokens(old)
        let b = tokens(new)
        guard !a.isEmpty, !b.isEmpty else { return [] }

        let lengths = lcsTable(a, b)
        var pairs: [Pair] = []
        var oldRun: [String] = []
        var newRun: [String] = []

        func flush() {
            defer {
                oldRun.removeAll()
                newRun.removeAll()
            }
            guard !oldRun.isEmpty, !newRun.isEmpty else { return }
            // Tokens carry their punctuation, so "Sarah," → "Sara," would otherwise be
            // stored with the comma and be useless as a hot word.
            let wrong = trimEdgePunctuation(oldRun.joined(separator: " "))
            let right = trimEdgePunctuation(newRun.joined(separator: " "))
            guard !wrong.isEmpty, !right.isEmpty, wrong != right else { return }
            pairs.append(Pair(wrong: wrong, right: right))
        }

        // Forward walk of the LCS table, emitting runs of tokens that didn't survive.
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                flush()
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                oldRun.append(a[i])
                i += 1
            } else {
                newRun.append(b[j])
                j += 1
            }
        }
        while i < a.count {
            oldRun.append(a[i])
            i += 1
        }
        while j < b.count {
            newRun.append(b[j])
            j += 1
        }
        flush()
        return pairs
    }

    /// A deliberately small set: stripping everything `CharacterSet.punctuation` covers
    /// would mangle things people genuinely write, like `C++` or `--force`.
    private static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?\"'“”‘’()[]{}…—–")

    private static func trimEdgePunctuation(_ text: String) -> String {
        text.trimmingCharacters(in: edgePunctuation.union(.whitespacesAndNewlines))
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .prefix(maxTokens)
            .map(String.init)
    }

    /// `lengths[i][j]` is the LCS length of `a[i...]` and `b[j...]` — suffix-indexed so the
    /// walk above can run forward without reconstructing a backtrack path.
    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var lengths = Array(
            repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        guard !a.isEmpty, !b.isEmpty else { return lengths }
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] =
                    a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        return lengths
    }
}
