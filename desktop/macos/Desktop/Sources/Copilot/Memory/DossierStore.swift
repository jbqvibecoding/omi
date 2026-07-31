import Foundation

/// The four things worth keeping a file on. Ported from Ami's entity layer — the split
/// matters because the questions you ask about a person ("what do I owe them?") are not
/// the questions you ask about a project ("where did this land?").
enum DossierKind: String, Codable, CaseIterable {
    case person = "People"
    case organization = "Organizations"
    case project = "Projects"
    case topic = "Topics"

    var singular: String {
        switch self {
        case .person: return "Person"
        case .organization: return "Organization"
        case .project: return "Project"
        case .topic: return "Topic"
        }
    }
}

/// One entity file: YAML-ish frontmatter plus a fixed set of markdown sections.
///
/// A flat markdown file rather than a database, for the reason Ami gives: the user can
/// open it, read it, correct it, and delete it. Memory you can't inspect is memory you
/// can't trust.
struct Dossier: Identifiable, Equatable {
    var id: String { "\(kind.rawValue)/\(slug)" }
    let kind: DossierKind
    let slug: String
    /// Frontmatter fields, order-preserved for stable rewrites.
    var fields: [(key: String, value: String)]
    /// Everything below the frontmatter.
    var body: String

    static func == (lhs: Dossier, rhs: Dossier) -> Bool {
        lhs.kind == rhs.kind && lhs.slug == rhs.slug && lhs.body == rhs.body
            && lhs.fields.map(\.key) == rhs.fields.map(\.key)
            && lhs.fields.map(\.value) == rhs.fields.map(\.value)
    }

    func field(_ key: String) -> String? {
        fields.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    mutating func setField(_ key: String, _ value: String) {
        if let idx = fields.firstIndex(where: { $0.key.lowercased() == key.lowercased() }) {
            fields[idx].value = value
        } else {
            fields.append((key: key, value: value))
        }
    }

    var name: String { field("name") ?? slug }
    var aliases: [String] {
        (field("aliases") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    var emails: [String] {
        (field("email") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
    var isArchived: Bool { (field("archived") ?? "").lowercased() == "true" }
    /// A merged-away duplicate. Kept as a tombstone so old `[[wiki-links]]` still resolve.
    var mergedInto: String? {
        let value = field("merged_into") ?? ""
        return value.isEmpty ? nil : value
    }
    var updatedAt: Date? { DossierStore.parseISO(field("updated") ?? "") }
    var lineCount: Int { body.split(separator: "\n", omittingEmptySubsequences: false).count }

    /// Lines under `## Open items` that are still unchecked.
    var openItems: [String] {
        section("Open items")
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- [ ] ") else { return nil }
                return String(trimmed.dropFirst(6))
            }
    }

    /// The text under a `## Heading`, up to the next `## `.
    func section(_ heading: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var collecting = false
        var out: [String] = []
        for line in lines {
            if line.hasPrefix("## ") {
                if collecting { break }
                collecting = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                    == heading.lowercased()
                continue
            }
            if collecting { out.append(line) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var markdown: String {
        var out = "---\n"
        for field in fields {
            out += "\(field.key): \(field.value)\n"
        }
        out += "---\n\n"
        out += body.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n"
        return out
    }
}

/// Reads and writes dossier files under Application Support.
///
/// Every write snapshots the previous version into `.history/` first. That is deliberately
/// not git: an LLM rewriting a file is exactly the case where you want an undo, and a
/// dated copy gives you one without dragging libgit2 into the app.
@MainActor
final class DossierStore: ObservableObject {
    static let shared = DossierStore()

    /// Bumped when files change so views reload.
    @Published private(set) var revision = 0

    private let fileManager = FileManager.default
    private let maxSnapshotsPerFile = 10

    private init() {}

    // MARK: - Locations

    var root: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("omi/knowledge", isDirectory: true)
    }

    func directory(for kind: DossierKind) -> URL {
        root.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    func url(kind: DossierKind, slug: String) -> URL {
        directory(for: kind).appendingPathComponent("\(slug).md")
    }

    /// Where unpromoted observations go — things that didn't clear the bar for a file of
    /// their own, so the user can promote them by hand instead of the assistant guessing.
    var suggestionsURL: URL { root.appendingPathComponent("suggested-topics.md") }

    private func historyDirectory(for kind: DossierKind) -> URL {
        directory(for: kind).appendingPathComponent(".history", isDirectory: true)
    }

    func ensureDirectories() {
        for kind in DossierKind.allCases {
            try? fileManager.createDirectory(
                at: historyDirectory(for: kind), withIntermediateDirectories: true)
        }
    }

    // MARK: - Reading

    func slugs(for kind: DossierKind) -> [String] {
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: directory(for: kind), includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
        return contents.filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func load(kind: DossierKind, slug: String) -> Dossier? {
        guard let text = try? String(contentsOf: url(kind: kind, slug: slug), encoding: .utf8) else {
            return nil
        }
        return Self.parse(text, kind: kind, slug: slug)
    }

    /// Every dossier, tombstones excluded (they exist only to keep old links resolving).
    func all(includeArchived: Bool = true) -> [Dossier] {
        DossierKind.allCases.flatMap { kind in
            slugs(for: kind).compactMap { load(kind: kind, slug: $0) }
        }
        .filter { $0.mergedInto == nil }
        .filter { includeArchived || !$0.isArchived }
    }

    func exists(kind: DossierKind, slug: String) -> Bool {
        fileManager.fileExists(atPath: url(kind: kind, slug: slug).path)
    }

    // MARK: - Writing

    /// Write a dossier, snapshotting whatever was there first.
    @discardableResult
    func save(_ dossier: Dossier, stampUpdated: Bool = true) -> Bool {
        ensureDirectories()
        var copy = dossier
        if stampUpdated { copy.setField("updated", Self.iso(Date())) }
        let target = url(kind: copy.kind, slug: copy.slug)
        snapshot(kind: copy.kind, slug: copy.slug)
        do {
            try copy.markdown.write(to: target, atomically: true, encoding: .utf8)
            revision += 1
            return true
        } catch {
            logError("DossierStore: failed to write \(copy.id)", error: error)
            return false
        }
    }

    func delete(kind: DossierKind, slug: String) {
        snapshot(kind: kind, slug: slug)
        try? fileManager.removeItem(at: url(kind: kind, slug: slug))
        revision += 1
    }

    /// Append a line to the suggestions file (an observation that didn't earn a dossier).
    func appendSuggestion(_ line: String) {
        ensureDirectories()
        let existing = (try? String(contentsOf: suggestionsURL, encoding: .utf8)) ?? "# Suggested\n\n"
        guard !existing.contains(line) else { return }
        let updated = existing + "- [ ] \(line)\n"
        try? updated.write(to: suggestionsURL, atomically: true, encoding: .utf8)
        revision += 1
    }

    // MARK: - History

    private func snapshot(kind: DossierKind, slug: String) {
        let source = url(kind: kind, slug: slug)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let dir = historyDirectory(for: kind)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.fileStamp(Date())
        try? fileManager.copyItem(at: source, to: dir.appendingPathComponent("\(slug)@\(stamp).md"))
        pruneSnapshots(kind: kind, slug: slug)
    }

    func snapshots(kind: DossierKind, slug: String) -> [(stamp: String, url: URL)] {
        let dir = historyDirectory(for: kind)
        let contents =
            (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("\(slug)@") }
            .map { (stamp: $0.deletingPathExtension().lastPathComponent.components(separatedBy: "@").last ?? "", url: $0) }
            .sorted { $0.stamp > $1.stamp }
    }

    private func pruneSnapshots(kind: DossierKind, slug: String) {
        let items = snapshots(kind: kind, slug: slug)
        guard items.count > maxSnapshotsPerFile else { return }
        for item in items.dropFirst(maxSnapshotsPerFile) {
            try? fileManager.removeItem(at: item.url)
        }
    }

    /// Restore a snapshot over the live file (itself snapshotted first, so it's reversible).
    @discardableResult
    func restore(kind: DossierKind, slug: String, snapshot url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let restored = Self.parse(text, kind: kind, slug: slug)
        else { return false }
        return save(restored, stampUpdated: false)
    }

    // MARK: - Parsing

    static func parse(_ text: String, kind: DossierKind, slug: String) -> Dossier? {
        var fields: [(key: String, value: String)] = []
        var body = text
        if text.hasPrefix("---") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var index = 1
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "---" {
                let line = lines[index]
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { fields.append((key: key, value: value)) }
                }
                index += 1
            }
            body = lines.dropFirst(min(index + 1, lines.count)).joined(separator: "\n")
        }
        return Dossier(
            kind: kind, slug: slug, fields: fields,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A stable, filename-safe id derived from a display name.
    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let allowed = lowered.map { char -> Character in
            char.isLetter || char.isNumber ? char : "-"
        }
        let collapsed = String(allowed).split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(60))
    }

    /// Normalized form used for "is this the same person" comparisons.
    static func normalizeName(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func iso(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    static func parseISO(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.date(from: value)
    }

    static func fileStamp(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: date)
    }

    /// The empty shape a new dossier starts from — the same sections every time, so the
    /// writer prompt and the reader both know where things live.
    static func template(kind: DossierKind, name: String, extraFields: [(String, String)] = []) -> Dossier {
        var fields: [(key: String, value: String)] = [
            ("type", kind.singular.lowercased()),
            ("name", name),
            ("created", iso(Date())),
            ("updated", iso(Date())),
        ]
        for extra in extraFields where !extra.1.isEmpty {
            fields.append((key: extra.0, value: extra.1))
        }
        let body = """
            # \(name)

            ## Summary

            ## Key facts

            ## Open items

            ## Activity

            ## Assistant notes
            """
        return Dossier(kind: kind, slug: slugify(name), fields: fields, body: body)
    }
}
