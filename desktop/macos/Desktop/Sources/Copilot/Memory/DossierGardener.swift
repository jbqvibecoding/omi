import Foundation

/// Keeps the knowledge base readable instead of merely large.
///
/// Ami's insight, ported here: an append-only memory decays into an unusable log. Once a
/// day a small number of the most-grown files get rewritten — old activity collapsed by
/// month, and, crucially, patterns that only become visible across several meetings
/// **promoted** from the activity log into standing facts. That promotion step is the
/// difference between a transcript archive and something that actually knows a person.
///
/// The contract is strict in one direction: the gardener may remove redundancy, but it
/// may never invent a fact. We verify that structurally after the rewrite and keep the
/// original when the check fails.
@MainActor
enum DossierGardener {
    /// Target size for a curated file. Past this a dossier stops being readable at a glance.
    static let targetLines = 150
    /// Files curated per day. Small on purpose — this is a background chore, not a batch job.
    static let maxPerRun = 8
    /// A file just curated is left alone for a week.
    static let cooldownDays = 7
    /// Activity older than this is collapsed into one line per month.
    static let collapseAfterDays = 60
    /// No contact for this long marks a dossier stale (retrieval deprioritizes it).
    static let staleAfterDays = 90

    private static let lastRunKey = "copilotDossierGardenLastRun"

    // MARK: - Scheduling

    static var lastRunAt: Date? {
        let ts = UserDefaults.standard.double(forKey: lastRunKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    /// Run at most once a day, in the background.
    static func runDailyIfNeeded() {
        guard CopilotSettings.shared.dossiersEnabled else { return }
        if let last = lastRunAt, Date().timeIntervalSince(last) < 20 * 3600 { return }
        Task { _ = await run() }
    }

    @discardableResult
    static func run() async -> [String: String] {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastRunKey)
        let archived = archiveStale()
        let candidates = selectCandidates()
        var curated = 0
        var rejected = 0
        for dossier in candidates {
            switch await curate(dossier) {
            case .curated: curated += 1
            case .rejected: rejected += 1
            case .skipped: break
            }
        }
        DossierIndex.shared.invalidate()
        log("DossierGardener: curated \(curated), rejected \(rejected), archived \(archived)")
        PostHogManager.shared.track(
            "copilot_dossier_garden",
            properties: ["curated": curated, "rejected": rejected, "archived": archived])
        return [
            "curated": String(curated), "rejected": String(rejected), "archived": String(archived),
            "candidates": String(candidates.count),
        ]
    }

    // MARK: - Deterministic passes

    /// Mark long-quiet dossiers stale. This only sets a flag — the file stays exactly where
    /// it is so `[[wiki-links]]` keep resolving; retrieval simply weighs it lower.
    @discardableResult
    static func archiveStale() -> Int {
        var count = 0
        for dossier in DossierStore.shared.all() where !dossier.isArchived {
            guard let updated = dossier.updatedAt,
                Date().timeIntervalSince(updated) > Double(staleAfterDays) * 86400
            else { continue }
            var stale = dossier
            stale.setField("archived", "true")
            if DossierStore.shared.save(stale, stampUpdated: false) { count += 1 }
        }
        return count
    }

    /// The files most in need of attention: biggest and busiest first, off cooldown.
    static func selectCandidates() -> [Dossier] {
        let now = Date()
        return
            DossierStore.shared.all()
            .filter { dossier in
                let activityLines = dossier.section("Activity").split(separator: "\n").count
                guard activityLines >= 8 || dossier.markdown.count >= 7000 else { return false }
                guard let curatedAt = DossierStore.parseISO(dossier.field("curated_at") ?? "") else {
                    return true
                }
                return now.timeIntervalSince(curatedAt) > Double(cooldownDays) * 86400
            }
            .sorted { lhs, rhs in
                weight(lhs) > weight(rhs)
            }
            .prefix(maxPerRun)
            .map { $0 }
    }

    private static func weight(_ dossier: Dossier) -> Int {
        dossier.section("Activity").split(separator: "\n").count * 400 + dossier.markdown.count
    }

    // MARK: - The rewrite

    enum Outcome { case curated, rejected, skipped }

    private static let systemPrompt = """
        You curate one entity file in a personal knowledge base. You are rewriting it to be \
        readable, not summarizing it away.

        HARD CONTRACT:
        - Never add a fact that is not already in the file. You have no other source.
        - Never lose a substantive fact, name, number, date, link or open item.
        - Output the complete file, once: frontmatter, then the same section headings.
        - Keep every existing frontmatter field. You may add `curated_at`.

        WHAT TO DO:
        - Aim for at most \(targetLines) lines. Cut repetition, not content.
        - Collapse activity older than \(collapseAfterDays) days into one line per month \
        ("2026-03 — three calls about pricing; agreed on the enterprise tier").
        - PROMOTE: patterns visible only across several entries become standing entries under \
        `## Key facts`, each with the date it became true. A recurring way of working \
        (prefers async, always reschedules Mondays, wants numbers before opinions) goes under \
        `## Assistant notes`.
        - Open items that the file itself shows were completed become completed (`- [x]`); \
        never delete an open item that is still open.
        - Downgrade any Role/title that the file does not actually evidence: move it out of \
        frontmatter and write it as an observation.
        - Use absolute dates everywhere. Never "recently", "last month", "soon".

        Output ONLY the file content. No commentary, no code fences.
        """

    static func curate(_ dossier: Dossier) async -> Outcome {
        let original = dossier.markdown
        do {
            let client = try GeminiClient(model: ModelQoS.Gemini.utility, fallbackModel: "gemini-2.5-flash")
            let rewritten = try await client.sendTextRequest(
                prompt: "Today is \(DossierStore.iso(Date())).\n\nFile:\n\n\(original)",
                systemPrompt: systemPrompt, maxRetries: 1, timeout: 120, thinkingBudget: 0)
            let cleaned = stripFences(rewritten)
            guard var parsed = DossierStore.parse(cleaned, kind: dossier.kind, slug: dossier.slug),
                passesIntegrityCheck(original: dossier, rewritten: parsed)
            else {
                log("DossierGardener: rejected rewrite of \(dossier.id) — keeping original")
                return .rejected
            }
            parsed.setField("curated_at", DossierStore.iso(Date()))
            // Preserve identity fields the rewrite may have dropped.
            for field in dossier.fields where parsed.field(field.key) == nil {
                parsed.setField(field.key, field.value)
            }
            return DossierStore.shared.save(parsed, stampUpdated: false) ? .curated : .rejected
        } catch {
            logError("DossierGardener: curation failed for \(dossier.id)", error: error)
            return .skipped
        }
    }

    /// The structural half of the "don't invent, don't lose" contract. The prompt asks;
    /// this checks. A rewrite that shrinks below a third of the original, grows, drops an
    /// open item, or loses a link is thrown away and the original kept.
    static func passesIntegrityCheck(original: Dossier, rewritten: Dossier) -> Bool {
        let originalBody = original.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let newBody = rewritten.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newBody.isEmpty else { return false }
        // Curation only ever shrinks. Growth means the model added something.
        guard newBody.count <= originalBody.count else { return false }
        guard newBody.count >= originalBody.count / 3 else { return false }
        // Links are the cheapest thing to lose and the most annoying.
        guard links(in: newBody).isSuperset(of: links(in: originalBody)) else { return false }
        // Every still-open item must survive, either open or explicitly completed.
        for item in original.openItems {
            guard newBody.contains(item) else { return false }
        }
        return true
    }

    private static func links(in text: String) -> Set<String> {
        var out = Set<String>()
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s\)\]]+"#) else { return out }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            if let r = Range(match.range, in: text) { out.insert(String(text[r])) }
        }
        return out
    }

    private static func stripFences(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("```") {
            out = out.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n")
            if let fence = out.range(of: "```", options: .backwards) {
                out = String(out[out.startIndex..<fence.lowerBound])
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
