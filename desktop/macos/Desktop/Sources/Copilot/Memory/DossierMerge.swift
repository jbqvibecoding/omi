import Foundation

/// Finds and resolves duplicate dossiers.
///
/// Duplicates are inevitable: "Sarah", "Sarah Chen" and "s.chen@acme.com" arrive from
/// different meetings. The split here is the Ami one — *candidates* are found in code
/// (same email, same normalized name, alias overlap, same work domain), and the model is
/// asked exactly one question about each pair: same entity or not. Its verdict is then
/// remembered forever, so a pair that is genuinely two different people is never
/// re-adjudicated at cost every night.
@MainActor
enum DossierMerge {
    /// Pairs judged per run. Deliberately tiny — a wrong merge is destructive and slow to
    /// notice, so we'd rather resolve two a day than twenty.
    static let maxPairsPerRun = 2

    private static let verdictsKey = "copilotDossierMergeVerdicts"
    private static let lastRunKey = "copilotDossierMergeLastRun"

    struct Candidate: Equatable {
        let left: Dossier
        let right: Dossier
        let reason: String
        var key: String { [left.id, right.id].sorted().joined(separator: "|") }
    }

    // MARK: - Remembered verdicts

    private static func verdicts() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: verdictsKey) as? [String: String] ?? [:]
    }

    private static func remember(_ key: String, _ verdict: String) {
        var all = verdicts()
        all[key] = verdict
        UserDefaults.standard.set(all, forKey: verdictsKey)
    }

    // MARK: - Deterministic candidates

    /// Pairs worth asking about. No model involved: these are all facts.
    static func candidates() -> [Candidate] {
        let all = DossierStore.shared.all()
        let known = verdicts()
        var out: [Candidate] = []
        for kind in DossierKind.allCases {
            let group = all.filter { $0.kind == kind }
            guard group.count > 1 else { continue }
            for i in group.indices {
                for j in group.index(after: i)..<group.endIndex {
                    guard let reason = duplicateReason(group[i], group[j]) else { continue }
                    let candidate = Candidate(left: group[i], right: group[j], reason: reason)
                    guard known[candidate.key] == nil else { continue }
                    out.append(candidate)
                }
            }
        }
        return out
    }

    static func duplicateReason(_ lhs: Dossier, _ rhs: Dossier) -> String? {
        // An email is an identity. Nothing else needs checking.
        if !Set(lhs.emails).isDisjoint(with: Set(rhs.emails)) { return "same email" }
        let lhsName = DossierStore.normalizeName(lhs.name)
        let rhsName = DossierStore.normalizeName(rhs.name)
        if lhsName == rhsName { return "same name" }
        let lhsAliases = Set(lhs.aliases.map(DossierStore.normalizeName) + [lhsName])
        let rhsAliases = Set(rhs.aliases.map(DossierStore.normalizeName) + [rhsName])
        if !lhsAliases.isDisjoint(with: rhsAliases) { return "shared alias" }
        // A shared work domain plus a shared surname is worth a question; a shared
        // gmail.com is not.
        let lhsDomains = Set(lhs.emails.map { DossierIndex.domain(ofEmail: $0) })
            .subtracting(DossierIndex.publicEmailDomains)
        let rhsDomains = Set(rhs.emails.map { DossierIndex.domain(ofEmail: $0) })
            .subtracting(DossierIndex.publicEmailDomains)
        if !lhsDomains.isDisjoint(with: rhsDomains) {
            let lhsParts = Set(lhsName.split(separator: " ").map(String.init))
            let rhsParts = Set(rhsName.split(separator: " ").map(String.init))
            if !lhsParts.isDisjoint(with: rhsParts) { return "same employer, shared name part" }
        }
        return nil
    }

    // MARK: - Adjudication

    private static let systemPrompt = """
        You decide whether two entity files describe the SAME real entity. Same name is not \
        enough — people share names. Look for identifying evidence: a shared email, the same \
        employer with the same role, one file explicitly referring to the other's facts, \
        overlapping specific events. Ambiguity means DISTINCT: a wrong merge destroys \
        information, a missed merge costs nothing but a duplicate. Answer with exactly one \
        word: MERGED or DISTINCT.
        """

    @discardableResult
    static func runDailyIfNeeded() -> Bool {
        guard CopilotSettings.shared.dossiersEnabled else { return false }
        let last = UserDefaults.standard.double(forKey: lastRunKey)
        if last > 0, Date().timeIntervalSince1970 - last < 20 * 3600 { return false }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRunKey)
        Task { _ = await run() }
        return true
    }

    @discardableResult
    static func run() async -> [String: String] {
        let pairs = Array(candidates().prefix(maxPairsPerRun))
        guard !pairs.isEmpty else { return ["candidates": "0"] }
        var merged = 0
        for pair in pairs {
            let verdict = await adjudicate(pair)
            remember(pair.key, verdict)
            if verdict == "MERGED", apply(pair) { merged += 1 }
        }
        DossierIndex.shared.invalidate()
        log("DossierMerge: reviewed \(pairs.count) pairs, merged \(merged)")
        return ["reviewed": String(pairs.count), "merged": String(merged)]
    }

    static func adjudicate(_ candidate: Candidate) async -> String {
        let prompt = """
            Signal that flagged this pair: \(candidate.reason)

            FILE A:
            \(String(candidate.left.markdown.prefix(4000)))

            FILE B:
            \(String(candidate.right.markdown.prefix(4000)))
            """
        do {
            let client = try GeminiClient(model: ModelQoS.Gemini.utility, fallbackModel: "gemini-2.5-flash")
            let answer = try await client.sendTextRequest(
                prompt: prompt, systemPrompt: systemPrompt, maxRetries: 1, timeout: 60,
                thinkingBudget: 0)
            return answer.uppercased().contains("MERGED") ? "MERGED" : "DISTINCT"
        } catch {
            logError("DossierMerge: adjudication failed", error: error)
            return "DISTINCT"
        }
    }

    /// Fold the newer file into the older (which has the longer history), then leave a
    /// tombstone in place of the duplicate so existing `[[links]]` still resolve.
    @discardableResult
    static func apply(_ candidate: Candidate) -> Bool {
        let (canonical, duplicate) = order(candidate)
        var merged = canonical

        let mergedEmails = Array(Set(canonical.emails + duplicate.emails)).sorted()
        if !mergedEmails.isEmpty { merged.setField("email", mergedEmails.joined(separator: ", ")) }
        let aliases = Set(canonical.aliases + duplicate.aliases + [duplicate.name])
            .subtracting([canonical.name])
        if !aliases.isEmpty { merged.setField("aliases", aliases.sorted().joined(separator: ", ")) }
        for field in duplicate.fields where merged.field(field.key) == nil && !field.value.isEmpty {
            merged.setField(field.key, field.value)
        }

        for section in ["Key facts", "Open items", "Activity", "Assistant notes"] {
            for line in duplicate.section(section).split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { continue }
                let isCheckbox = trimmed.hasPrefix("- [ ] ")
                let content = isCheckbox ? String(trimmed.dropFirst(6)) : String(trimmed.dropFirst(2))
                guard !content.isEmpty else { continue }
                merged.body = DossierWriter.appendBullet(
                    to: merged.body, section: section, line: content, checkbox: isCheckbox)
            }
        }
        guard DossierStore.shared.save(merged) else { return false }

        var tombstone = duplicate
        tombstone.setField("merged_into", merged.id)
        tombstone.body = "Merged into [[\(merged.name)]] on \(DossierStore.iso(Date()))."
        DossierStore.shared.save(tombstone, stampUpdated: false)
        log("DossierMerge: merged \(duplicate.id) into \(merged.id)")
        return true
    }

    /// The file with more history wins — it has more links pointing at it and more to lose.
    private static func order(_ candidate: Candidate) -> (canonical: Dossier, duplicate: Dossier) {
        let leftWeight = candidate.left.markdown.count
        let rightWeight = candidate.right.markdown.count
        return leftWeight >= rightWeight
            ? (candidate.left, candidate.right) : (candidate.right, candidate.left)
    }
}
