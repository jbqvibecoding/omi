import Foundation

/// A short brief assembled before a meeting: who's coming, what matters, and what you still
/// owe them. Ported from Ami's meeting-prep — the resolution work is deterministic and only
/// the 3-5 "what matters" bullets come from the model.
struct MeetingPrepBrief {
    let eventId: String
    let title: String
    let startsAt: Date
    /// Attendees we could tie to something the user has written down.
    let matchedAttendees: [String]
    let unmatchedAttendees: [String]
    /// Unchecked `- [ ]` lines found in notes about these people.
    let openItems: [String]
    /// The model's bullets (already prefixed with "· ").
    let bullets: [String]
    let sourceBreadcrumbs: [String]

    var matchedCount: Int { matchedAttendees.count }

    var hudMessage: String {
        var lines = bullets
        if !openItems.isEmpty {
            lines.append(contentsOf: openItems.prefix(3).map { "· Open: \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// Compact form injected as opening context for the live copilot.
    var contextBlock: String {
        var parts = ["Meeting prep for \"\(title)\":"]
        if !matchedAttendees.isEmpty {
            parts.append("Attendees you have notes on: \(matchedAttendees.joined(separator: ", "))")
        }
        if !bullets.isEmpty { parts.append(bullets.joined(separator: "\n")) }
        if !openItems.isEmpty {
            parts.append("Open items with them:\n" + openItems.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }
}

/// Builds a pre-meeting brief from the calendar plus whatever the user has already written
/// about the attendees. Deliberately silent when it knows nothing — an empty brief is worse
/// than no brief, and that gate is why this feature doesn't become noise.
@MainActor
enum MeetingPrepService {
    /// How far ahead a meeting is briefed.
    static let leadTime: TimeInterval = 6 * 3600
    private static let briefedKey = "copilotMeetingPrepBriefed"

    // MARK: - Public

    /// Assemble a brief, or nil when no attendee could be tied to anything the user wrote.
    static func prepare(for event: CalendarEvent) async -> MeetingPrepBrief? {
        guard CopilotSettings.shared.notesRagActive || CopilotSettings.shared.dossiersEnabled else {
            return nil
        }

        let ownEmailFragments = ["me", "self"]
        let attendees = event.attendees
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !ownEmailFragments.contains($0.lowercased()) }
        guard !attendees.isEmpty else { return nil }

        var matched: [String] = []
        var unmatched: [String] = []
        var hits: [NotesKBHit] = []
        var dossiers: [Dossier] = []

        for attendee in attendees {
            // The dossier layer answers "who is this" exactly, so it goes first; the notes
            // folder is the fallback for people omi hasn't built a file on yet.
            let dossier = resolveDossier(attendee: attendee)
            let attendeeHits = await resolve(attendee: attendee)
            if dossier == nil && attendeeHits.isEmpty {
                unmatched.append(attendee)
            } else {
                matched.append(displayName(for: attendee))
                if let dossier { dossiers.append(dossier) }
                hits.append(contentsOf: attendeeHits)
            }
        }

        // The gate: never show an empty brief.
        guard !matched.isEmpty else { return nil }

        var openItems = extractOpenItems(from: hits)
        for item in dossiers.flatMap({ $0.openItems }) where !openItems.contains(item) {
            openItems.append(item)
        }
        openItems = Array(openItems.prefix(8))
        let bullets = await whatMattersBullets(event: event, hits: hits, dossiers: dossiers)
        guard !bullets.isEmpty || !openItems.isEmpty else { return nil }

        return MeetingPrepBrief(
            eventId: event.id,
            title: event.summary,
            startsAt: parseDate(event.startTime) ?? Date(),
            matchedAttendees: matched,
            unmatchedAttendees: unmatched,
            openItems: openItems,
            bullets: bullets,
            sourceBreadcrumbs: Array(Set(hits.map(\.breadcrumb))).sorted()
        )
    }

    /// The next meeting inside the lead-time window that hasn't been briefed yet.
    static func upcomingUnbriefedEvent() async -> CalendarEvent? {
        let status = await CalendarReaderService.shared.verifyConnection()
        guard status == .connected else { return nil }
        guard let events = try? await CalendarReaderService.shared.readEvents(
            daysBack: 0, daysForward: 1, maxResults: 50)
        else { return nil }

        let now = Date()
        let horizon = now.addingTimeInterval(leadTime)
        let briefed = briefedIds()
        return events
            .filter { !$0.isAllDay && !$0.attendees.isEmpty && !briefed.contains($0.id) }
            .compactMap { event -> (CalendarEvent, Date)? in
                guard let start = parseDate(event.startTime), start > now, start <= horizon else {
                    return nil
                }
                return (event, start)
            }
            .sorted { $0.1 < $1.1 }
            .first?.0
    }

    static func markBriefed(eventId: String) {
        var ids = briefedIds()
        ids.insert(eventId)
        // Keep the set small — ids age out naturally as the calendar moves on.
        if ids.count > 100 { ids = Set(ids.suffix(100)) }
        UserDefaults.standard.set(Array(ids), forKey: briefedKey)
    }

    /// Brief for the meeting happening right now, for the live copilot's opening context.
    static func briefForCurrentMeeting() async -> MeetingPrepBrief? {
        guard let current = await currentEvent() else { return nil }
        return await prepare(for: current)
    }

    /// The calendar event covering now, if any. Shared by the brief and by the dossier
    /// writer, which needs the real attendee list rather than names guessed off audio.
    static func currentEvent() async -> CalendarEvent? {
        let status = await CalendarReaderService.shared.verifyConnection()
        guard status == .connected else { return nil }
        guard let events = try? await CalendarReaderService.shared.readEvents(
            daysBack: 0, daysForward: 1, maxResults: 50)
        else { return nil }
        let now = Date()
        return events.first(where: { event in
            guard let start = parseDate(event.startTime) else { return false }
            let end = parseDate(event.endTime) ?? start.addingTimeInterval(3600)
            return start.addingTimeInterval(-15 * 60) <= now && now <= end
        })
    }

    // MARK: - Deterministic attendee resolution

    /// Resolve one attendee to notes. Exact email beats a unique name match; a name that
    /// matches several notes is dropped rather than guessed (a wrong person is worse than none).
    private static func resolve(attendee: String) async -> [NotesKBHit] {
        let isEmail = attendee.contains("@")
        if isEmail {
            let byEmail = await NotesKnowledgeBase.shared.search(queries: [attendee], topK: 3)
            let strong = byEmail.filter { $0.chunkText.localizedCaseInsensitiveContains(attendee) }
            if !strong.isEmpty { return strong }
        }
        let name = displayName(for: attendee)
        guard name.count >= 3 else { return [] }
        let byName = await NotesKnowledgeBase.shared.search(queries: [name], topK: 3)
        // Require the name to actually appear — embedding neighbours aren't identity evidence.
        return byName.filter { $0.chunkText.localizedCaseInsensitiveContains(name) }
    }

    /// "sarah.chen@acme.com" → "sarah chen"; "Sarah Chen (Acme)" → "Sarah Chen".
    static func displayName(for attendee: String) -> String {
        var value = attendee
        if let paren = value.firstIndex(of: "(") {
            value = String(value[value.startIndex..<paren])
        }
        if let at = value.firstIndex(of: "@") {
            value = String(value[value.startIndex..<at])
            value = value.replacingOccurrences(of: ".", with: " ")
            value = value.replacingOccurrences(of: "_", with: " ")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pin an attendee to a dossier. Exact email only, or a name that matches exactly one
    /// file — same rule as the notes path, for the same reason.
    private static func resolveDossier(attendee: String) -> Dossier? {
        guard CopilotSettings.shared.dossiersEnabled else { return nil }
        if attendee.contains("@"), let byEmail = DossierIndex.shared.person(email: attendee) {
            return byEmail
        }
        let name = displayName(for: attendee)
        guard name.count >= 3 else { return nil }
        return DossierIndex.shared.uniqueMatch(name: name, kind: .person)
    }

    /// Unchecked markdown checkboxes in the matched notes — commitments still open with them.
    private static func extractOpenItems(from hits: [NotesKBHit]) -> [String] {
        var items: [String] = []
        for hit in hits {
            for line in hit.chunkText.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- [ ] ") else { continue }
                let text = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && !items.contains(text) { items.append(text) }
                if items.count >= 5 { return items }
            }
        }
        return items
    }

    // MARK: - The one model call

    private static let bulletsSystemPrompt = """
        You write a meeting-prep brief. 3-5 bullets, lead with what to focus on. Use ONLY the \
        provided note content — no invention. Terse, factual, absolute dates (never "next week"). \
        No preamble, no headings: one bullet per line, each starting with "· ".
        """

    private static func whatMattersBullets(
        event: CalendarEvent, hits: [NotesKBHit], dossiers: [Dossier] = []
    ) async -> [String] {
        guard !hits.isEmpty || !dossiers.isEmpty else { return [] }
        var material = "Meeting: \(event.summary) at \(event.startTime)"
        if !event.description.isEmpty {
            material += "\n\nAgenda:\n\(String(event.description.prefix(800)))"
        }
        if !dossiers.isEmpty {
            let files = dossiers.prefix(6).map { "[\($0.name)]\n\(String($0.markdown.prefix(2000)))" }
            material += "\n\nWhat omi knows about the attendees:\n"
                + files.joined(separator: "\n\n---\n\n")
        }
        if !hits.isEmpty {
            let notes = hits.prefix(6).map { "[\($0.breadcrumb)]\n\(String($0.chunkText.prefix(1200)))" }
            material += "\n\nNotes about the attendees:\n" + notes.joined(separator: "\n\n---\n\n")
        }

        do {
            let client = try GeminiClient(
                model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
            let text = try await client.sendTextRequest(
                prompt: material, systemPrompt: bulletsSystemPrompt, maxRetries: 1, timeout: 30,
                thinkingBudget: 0)
            return text.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("·") || $0.hasPrefix("-") }
                .map { $0.hasPrefix("-") ? "· " + $0.dropFirst(1).trimmingCharacters(in: .whitespaces) : $0 }
                .prefix(5)
                .map(String.init)
        } catch {
            logError("MeetingPrepService: brief generation failed", error: error)
            return []
        }
    }

    // MARK: - Helpers

    private static func briefedIds() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: briefedKey) ?? [])
    }

    /// ISO-8601 with or without fractional seconds (calendar events use both).
    static func parseDate(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    // MARK: - Debug (omi-ctl)

    static func debugPrepare() async -> [String: String] {
        guard let event = await upcomingUnbriefedEvent() else {
            return ["result": "no upcoming meeting with attendees in the next 6h"]
        }
        guard let brief = await prepare(for: event) else {
            return [
                "event": event.summary,
                "result": "no brief — no attendee matched anything in your notes",
            ]
        }
        return [
            "event": brief.title,
            "matched": brief.matchedAttendees.joined(separator: ", "),
            "unmatched": String(brief.unmatchedAttendees.count),
            "bullets": String(brief.bullets.count),
            "open_items": String(brief.openItems.count),
            "preview": String(brief.hudMessage.prefix(300)),
        ]
    }
}
