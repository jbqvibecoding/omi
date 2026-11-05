import Foundation

/// Picks a copilot scenario profile from the user's calendar at session start, so the
/// user rarely has to switch profiles by hand. Degrades gracefully: if the calendar
/// integration isn't connected, it returns nil and the current/default profile stands.
///
/// Classification is rule-first (title + attendee heuristics) with a single cheap LLM
/// fallback, so a title like "Interview: Backend Eng" picks the interview profile and a
/// "Acme <> Us intro call" with an external attendee picks sales.
@MainActor
enum CalendarScenarioSelector {

    /// Returns a scenario id to switch to, or nil to leave the profile unchanged.
    static func suggestScenario() async -> String? {
        // Graceful degradation: only proceed if the calendar actually works right now.
        let status = await CalendarReaderService.shared.verifyConnection()
        guard status.isConnected else { return nil }

        let events: [CalendarEvent]
        do {
            events = try await CalendarReaderService.shared.readEvents(
                daysBack: 0, daysForward: 1, maxResults: 50)
        } catch {
            return nil
        }

        guard let event = currentEvent(in: events) else { return nil }

        if let ruleHit = classifyByRules(event) {
            return ruleHit
        }
        return await classifyByLLM(event)
    }

    // MARK: - Event selection

    /// The event happening now (start ≤ now ≤ end) or starting within the next 15 minutes.
    private static func currentEvent(in events: [CalendarEvent]) -> CalendarEvent? {
        let now = Date()
        let window: TimeInterval = 15 * 60
        let dated = events.compactMap { e -> (CalendarEvent, Date, Date)? in
            guard let start = parseDate(e.startTime) else { return nil }
            let end = parseDate(e.endTime) ?? start.addingTimeInterval(3600)
            return (e, start, end)
        }
        // Ongoing first, then soonest upcoming within the window.
        if let ongoing = dated.first(where: { $0.1 <= now && now <= $0.2 && !$0.0.isAllDay }) {
            return ongoing.0
        }
        return dated
            .filter { $0.1 > now && $0.1.timeIntervalSince(now) <= window && !$0.0.isAllDay }
            .sorted { $0.1 < $1.1 }
            .first?.0
    }

    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    // MARK: - Classification

    private static func classifyByRules(_ event: CalendarEvent) -> String? {
        let title = event.summary.lowercased()
        let hasExternalAttendee = event.attendees.contains { attendee in
            guard let domain = attendee.split(separator: "@").last.map(String.init) else { return false }
            // Very rough: common consumer/free domains aren't "external company" signals either way,
            // but any attendee outside a single dominant domain hints at an external meeting.
            return !domain.isEmpty
        }

        if title.contains("interview") || title.contains("面试") { return "interview" }
        if title.contains("negotiat") || title.contains("contract") || title.contains("terms") {
            return "negotiation"
        }
        if title.contains("demo") || title.contains("intro call") || title.contains("discovery")
            || title.contains("sales") || title.contains("pitch")
        {
            return "sales"
        }
        if title.contains("support") || title.contains("customer") || title.contains("onboarding") {
            return "support"
        }
        // Multi-party external-looking events with no clearer signal lean sales; otherwise meeting.
        if event.attendees.count >= 2 && hasExternalAttendee && title.contains("call") {
            return "sales"
        }
        if title.contains("sync") || title.contains("standup") || title.contains("1:1")
            || title.contains("review") || title.contains("meeting")
        {
            return "meeting"
        }
        return nil
    }

    private static func classifyByLLM(_ event: CalendarEvent) async -> String? {
        let ids = CopilotScenarioProfile.all.map(\.id).joined(separator: ", ")
        let prompt = """
            Calendar event title: "\(event.summary)"
            Attendees: \(event.attendees.prefix(6).joined(separator: ", "))
            Reply with EXACTLY one of these scenario ids and nothing else: \(ids)
            """
        do {
            let client = try GeminiClient(model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
            let text = try await client.sendTextRequest(
                prompt: prompt,
                systemPrompt: "You classify a calendar event into one copilot scenario id.",
                maxRetries: 0, timeout: 10, thinkingBudget: 0)
            let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return CopilotScenarioProfile.all.map(\.id).first { candidate.contains($0) }
        } catch {
            return nil
        }
    }
}
