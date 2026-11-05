import Foundation

/// A scored dossier hit.
struct DossierHit: Identifiable, Equatable {
    var id: String { dossier.id }
    let dossier: Dossier
    let score: Double
    /// Why it matched, for the breadcrumb we show the user.
    let reason: String
}

/// Finds the right dossiers for a query.
///
/// The scoring is deliberately deterministic — no embedding call, no model in the loop.
/// This is the Ami principle that keeps retrieval honest and cheap: anything you can
/// decide in code, decide in code. An exact email match is not a similarity question.
@MainActor
final class DossierIndex {
    static let shared = DossierIndex()

    /// A frontmatter field hit is worth far more than a body mention.
    private let fieldMatchWeight = 5.0
    private let bodyMatchWeight = 1.0
    private let bodyMatchCap = 8.0
    /// Half-life-ish decay so a dossier nobody has touched in a year sinks.
    private let recencyHalfLifeDays = 90.0
    private let archivedPenalty = 0.3

    private var cache: [Dossier] = []
    private var cachedAtRevision = -1

    private init() {}

    // MARK: - Cache

    func entries() -> [Dossier] {
        let revision = DossierStore.shared.revision
        if cachedAtRevision != revision {
            cache = DossierStore.shared.all()
            cachedAtRevision = revision
        }
        return cache
    }

    func invalidate() { cachedAtRevision = -1 }

    // MARK: - Exact lookups

    /// The dossier for an email address. Exact, case-insensitive — no fuzziness, because
    /// attaching a meeting to the wrong person is worse than attaching it to nobody.
    func person(email: String) -> Dossier? {
        let needle = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        return entries().first { $0.kind == .person && $0.emails.contains(needle) }
    }

    /// The dossier for a display name, only when exactly one candidate matches. Two people
    /// named "Chris" means we don't know which one, so we return neither.
    func uniqueMatch(name: String, kind: DossierKind? = nil) -> Dossier? {
        let needle = DossierStore.normalizeName(name)
        guard needle.count >= 3 else { return nil }
        let candidates = entries().filter { dossier in
            if let kind, dossier.kind != kind { return false }
            if DossierStore.normalizeName(dossier.name) == needle { return true }
            return dossier.aliases.contains { DossierStore.normalizeName($0) == needle }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func organization(emailDomain: String) -> Dossier? {
        let needle = emailDomain.lowercased()
        guard !needle.isEmpty, !Self.publicEmailDomains.contains(needle) else { return nil }
        return entries().first { dossier in
            dossier.kind == .organization
                && (dossier.field("domain") ?? "").lowercased().contains(needle)
        }
    }

    // MARK: - Search

    func search(_ query: String, limit: Int = 5, kind: DossierKind? = nil) -> [DossierHit] {
        let terms = Self.terms(in: query)
        guard !terms.isEmpty else { return [] }
        let now = Date()

        var hits: [DossierHit] = []
        for dossier in entries() {
            if let kind, dossier.kind != kind { continue }
            var score = 0.0
            var reasons: [String] = []

            // Frontmatter is curated, so a match there is a strong signal.
            let fieldBlob = dossier.fields.map { "\($0.key) \($0.value)" }.joined(separator: " ").lowercased()
            let fieldMatches = terms.filter { fieldBlob.contains($0) }
            if !fieldMatches.isEmpty {
                score += Double(fieldMatches.count) * fieldMatchWeight
                reasons.append(fieldMatches.joined(separator: "/"))
            }

            let bodyBlob = dossier.body.lowercased()
            let bodyScore = terms.reduce(0.0) { partial, term in
                partial + (bodyBlob.contains(term) ? bodyMatchWeight : 0)
            }
            if bodyScore > 0 {
                score += min(bodyScore, bodyMatchCap)
                if reasons.isEmpty { reasons.append("mentioned") }
            }
            guard score > 0 else { continue }

            score *= recencyMultiplier(for: dossier, now: now)
            if dossier.isArchived { score *= archivedPenalty }
            hits.append(
                DossierHit(
                    dossier: dossier, score: score,
                    reason: "\(dossier.kind.singular) · \(reasons.joined(separator: ", "))"))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    private func recencyMultiplier(for dossier: Dossier, now: Date) -> Double {
        guard let updated = dossier.updatedAt else { return 0.75 }
        let ageDays = max(0, now.timeIntervalSince(updated) / 86400)
        return 0.5 + exp(-ageDays / recencyHalfLifeDays)
    }

    // MARK: - Helpers

    static let publicEmailDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "yahoo.com",
        "icloud.com", "me.com", "proton.me", "protonmail.com", "qq.com", "163.com", "aol.com",
    ]

    /// Content words from a query, lowercased, stopwords and short tokens dropped.
    static func terms(in query: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "that", "this", "from", "about", "have", "has", "was",
            "were", "what", "when", "where", "who", "our", "their", "them", "they", "you", "your",
        ]
        let raw = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.-")).inverted)
        var seen = Set<String>()
        var out: [String] = []
        for token in raw {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            guard word.count >= 3, !stopwords.contains(word), !seen.contains(word) else { continue }
            seen.insert(word)
            out.append(word)
        }
        return Array(out.prefix(12))
    }

    /// Local part of an email turned into a plausible display name ("sarah.chen" → "Sarah Chen").
    static func displayName(fromEmail email: String) -> String {
        let local = email.components(separatedBy: "@").first ?? email
        return
            local
            .components(separatedBy: CharacterSet(charactersIn: "._-+"))
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func domain(ofEmail email: String) -> String {
        (email.components(separatedBy: "@").last ?? "").lowercased()
    }
}
