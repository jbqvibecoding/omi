import Foundation

/// Learns your preferences in words, not numbers.
///
/// `CopilotFeedbackTuner` already moves a confidence threshold when you dismiss things.
/// That works, but it can only make the copilot quieter or louder — it can never learn
/// *"don't draft replies to recruiters"*. Ported from Ami: log the disagreements, then
/// periodically distill them into a short list of generalized rules in plain English,
/// stored in a file the user can edit directly and injected ahead of the general guidance.
///
/// The distinction that makes it work is that a rule must generalize. "Ignored the
/// pricing card on Tuesday" is not a preference; "don't interrupt with pricing details
/// while I'm presenting" is.
@MainActor
final class CopilotCorrectionLog {
    static let shared = CopilotCorrectionLog()

    /// One time the user's verdict differed from the copilot's.
    struct Correction: Codable, Identifiable {
        var id: String { "\(at.timeIntervalSince1970)-\(situation.prefix(24))" }
        let at: Date
        let scenario: String
        /// The suggestion type ("question", "term", …).
        let type: String
        /// What was on screen / being said, compressed.
        let situation: String
        /// What the copilot did.
        let agentVerdict: String
        /// What the user did about it.
        let userVerdict: String
    }

    private let logKey = "copilotCorrections"
    private let distilledCountKey = "copilotCorrectionsDistilledCount"
    private let maxCorrections = 200
    /// Distill after this many corrections have accumulated since the last pass.
    private let distillThreshold = 6
    private let maxRules = 12

    private var corrections: [Correction]
    private var isDistilling = false
    /// Cards already logged this launch (first outcome wins).
    private var recordedCards: Set<UUID> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: logKey),
            let decoded = try? JSONDecoder().decode([Correction].self, from: data)
        {
            corrections = decoded
        } else {
            corrections = []
        }
    }

    // MARK: - Recording

    /// Log a disagreement. Recording the user agreeing would teach nothing, so agreement
    /// instead *retracts* an earlier correction about the same situation — the user changed
    /// their mind, and a rule distilled from the old verdict should stop being supported.
    func record(scenario: String, type: String, situation: String, agentVerdict: String, userVerdict: String) {
        let situation = String(
            situation.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))
        guard !situation.isEmpty else { return }

        if agentVerdict == userVerdict {
            let before = corrections.count
            corrections.removeAll { $0.type == type && $0.situation == situation }
            if corrections.count != before { persist() }
            return
        }

        corrections.append(
            Correction(
                at: Date(), scenario: scenario, type: type, situation: situation,
                agentVerdict: agentVerdict, userVerdict: userVerdict))
        if corrections.count > maxCorrections {
            corrections.removeFirst(corrections.count - maxCorrections)
        }
        persist()
        distillIfNeeded()
    }

    /// Convenience for the card outcome hooks: the copilot said "worth interrupting for",
    /// and the user either used it or waved it away.
    ///
    /// First outcome per card wins, same as the tuner — Copy dismisses the card, and the
    /// dismissal must not then be logged as a rejection of what the user just took.
    func recordCardOutcome(notificationId: UUID, bucket: String?, situation: String, accepted: Bool) {
        guard let bucket, !bucket.isEmpty else { return }
        guard !recordedCards.contains(notificationId) else { return }
        recordedCards.insert(notificationId)
        let parts = bucket.split(separator: ":").map(String.init)
        record(
            scenario: parts.first ?? "", type: parts.count > 1 ? parts[1] : "",
            situation: situation, agentVerdict: "worth showing",
            userVerdict: accepted ? "worth showing" : "not worth showing")
    }

    var all: [Correction] { corrections }
    var recent: [Correction] { Array(corrections.suffix(20)) }

    private func persist() {
        if let data = try? JSONEncoder().encode(corrections) {
            UserDefaults.standard.set(data, forKey: logKey)
        }
    }

    // MARK: - Rules file

    /// The distilled preferences, as plain markdown the user can open and edit.
    var preferencesURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("omi", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("preferences.md")
    }

    var rulesText: String {
        (try? String(contentsOf: preferencesURL, encoding: .utf8)) ?? ""
    }

    var rules: [String] {
        rulesText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)) }
            .filter { !$0.isEmpty }
    }

    func setRulesText(_ text: String) {
        try? text.write(to: preferencesURL, atomically: true, encoding: .utf8)
    }

    func reset() {
        corrections = []
        persist()
        UserDefaults.standard.set(0, forKey: distilledCountKey)
        try? FileManager.default.removeItem(at: preferencesURL)
    }

    /// The block injected into gate and generate prompts. Preferences beat the general
    /// standard — that's the whole point of having learned them.
    func promptBlock() -> String? {
        let rules = rules
        guard !rules.isEmpty else { return nil }
        var block = "The user's learned preferences. THESE OVERRIDE the general guidance above:\n"
        block += rules.map { "- \($0)" }.joined(separator: "\n")
        let examples = recent.prefix(8).filter { $0.agentVerdict != $0.userVerdict }
        if !examples.isEmpty {
            block += "\n\nRecent corrections (omi's call → theirs):\n"
            block += examples.map {
                "- \($0.type.isEmpty ? "card" : $0.type): omi said \($0.agentVerdict), they said "
                    + "\($0.userVerdict) — \(String($0.situation.prefix(140)))"
            }.joined(separator: "\n")
        }
        return block
    }

    // MARK: - Distillation

    private static let systemPrompt = """
        You turn a log of corrections into a short list of standing preferences for an \
        assistant that decides when to interrupt someone and what to say.

        Each rule MUST generalize beyond the example it came from — generalize across the \
        kind of moment, the kind of content, the topic, and who is in the room. A rule that \
        only describes one incident is useless. Write rules the assistant can apply to a \
        situation it has never seen.

        Rules:
        - At most \(maxRules) rules, fewer is better. Merge overlapping ones.
        - Plain imperative English, one line each, starting with "- ".
        - When two corrections conflict, the more recent one wins.
        - Drop any rule the corrections no longer support.
        - Do not restate the assistant's general job. Only what is specific to this user.

        Output ONLY the bullet list. No preamble, no headings.
        """

    func distillIfNeeded() {
        let lastCount = UserDefaults.standard.integer(forKey: distilledCountKey)
        guard corrections.count - lastCount >= distillThreshold, !isDistilling else { return }
        Task { _ = await distill() }
    }

    @discardableResult
    func distill() async -> String? {
        guard !isDistilling else { return nil }
        isDistilling = true
        defer { isDistilling = false }
        guard !corrections.isEmpty else { return nil }

        var prompt = "Existing rules:\n\(rulesText.isEmpty ? "(none yet)" : rulesText)\n\n"
        prompt += "Corrections, oldest first:\n"
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        prompt += corrections.suffix(60).map { correction in
            "[\(fmt.string(from: correction.at))] scenario=\(correction.scenario) "
                + "type=\(correction.type) omi=\(correction.agentVerdict) "
                + "user=\(correction.userVerdict)\n  situation: \(correction.situation)"
        }.joined(separator: "\n")

        do {
            let client = try GeminiClient(
                model: ModelQoS.Gemini.utility, fallbackModel: "gemini-2.5-flash")
            let text = try await client.sendTextRequest(
                prompt: prompt, systemPrompt: Self.systemPrompt, maxRetries: 1, timeout: 60,
                thinkingBudget: 0)
            let lines = text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .prefix(maxRules)
            guard !lines.isEmpty else { return nil }
            let markdown = """
                # Your preferences

                Omi learned these from the times you disagreed with it. Edit or delete any \
                line — this file is read as-is.

                \(lines.joined(separator: "\n"))
                """
            setRulesText(markdown)
            UserDefaults.standard.set(corrections.count, forKey: distilledCountKey)
            log("CopilotCorrectionLog: distilled \(lines.count) rules from \(corrections.count) corrections")
            PostHogManager.shared.track(
                "copilot_rules_distilled",
                properties: ["rules": lines.count, "corrections": corrections.count])
            return markdown
        } catch {
            logError("CopilotCorrectionLog: distillation failed", error: error)
            return nil
        }
    }

    // MARK: - Debug (omi-ctl)

    func debugDump() -> [String: String] {
        var out: [String: String] = [
            "corrections": String(corrections.count),
            "rules": String(rules.count),
            "file": preferencesURL.path,
        ]
        for (index, rule) in rules.enumerated() {
            out[String(format: "rule_%02d", index + 1)] = rule
        }
        return out
    }

    func debugDistill() async -> [String: String] {
        guard let markdown = await distill() else {
            return ["error": "nothing to distill yet — dismiss or act on a few suggestions first"]
        }
        return ["rules": String(markdown.prefix(900))]
    }
}
