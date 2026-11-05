import Foundation

/// Watches for a conferencing call starting while the app is otherwise idle and offers,
/// via a floating-bar card, to start the live copilot for it (Meetily-style meeting
/// auto-detection, reusing omi's existing `MeetingDetector` probe: a call app using the
/// microphone, or a browser call window).
///
/// Never auto-starts silently — the card is an offer; one click starts transcription
/// (which brings up the live copilot, session summary, and calendar scenario selection).
@MainActor
final class MeetingAutoDetectMonitor {
    static let shared = MeetingAutoDetectMonitor()

    /// Minimum time between two prompts, even across separate detected meetings —
    /// protects against detector flapping.
    private let promptCooldown: TimeInterval = 10 * 60

    private var detector: MeetingDetector?
    private var hasPromptedThisMeeting = false
    private var lastPromptAt: Date = .distantPast
    private var settingsObserver: NSObjectProtocol?
    /// Polls the calendar for a meeting worth briefing ahead of time.
    private var prepTimer: Timer?
    private let prepCheckInterval: TimeInterval = 15 * 60

    private init() {}

    /// Called once at app startup (from CopilotOrchestrator.setup()).
    func start() {
        refresh()
        startPrepTimer()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .assistantSettingsDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in MeetingAutoDetectMonitor.shared.refresh() }
        }
    }

    /// Align the detector's running state with the current settings.
    private func refresh() {
        let shouldWatch = CopilotSettings.shared.isEnabled && CopilotSettings.shared.autoDetectMeetings
        if shouldWatch, detector == nil {
            let d = MeetingDetector(onChange: { [weak self] active in
                self?.handleMeetingChange(active: active)
            })
            detector = d
            d.start()
            log("MeetingAutoDetectMonitor: watching for meetings")
        } else if !shouldWatch, let d = detector {
            d.stop()
            detector = nil
            hasPromptedThisMeeting = false
            log("MeetingAutoDetectMonitor: stopped watching")
        }
    }

    private func handleMeetingChange(active: Bool) {
        guard active else {
            // Meeting ended — the next one may prompt again.
            hasPromptedThisMeeting = false
            return
        }
        guard !hasPromptedThisMeeting else { return }
        // Already in a session (recording started manually or via a previous prompt).
        guard !LiveSuggestionsMonitor.shared.isSessionActive else {
            hasPromptedThisMeeting = true
            return
        }
        guard Date().timeIntervalSince(lastPromptAt) >= promptCooldown else { return }
        guard !AppState.isPaywalledEffective else { return }

        hasPromptedThisMeeting = true
        lastPromptAt = Date()
        prompt()
    }

    // MARK: - Pre-meeting brief

    private func startPrepTimer() {
        prepTimer?.invalidate()
        prepTimer = Timer.scheduledTimer(withTimeInterval: prepCheckInterval, repeats: true) { _ in
            Task { @MainActor in await MeetingAutoDetectMonitor.shared.checkForPrep() }
        }
        // Also check shortly after launch so a meeting starting soon isn't missed.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await self.checkForPrep()
        }
    }

    /// Brief the next meeting inside the lead-time window, once.
    func checkForPrep() async {
        guard CopilotSettings.shared.isEnabled, CopilotSettings.shared.meetingPrepEnabled else { return }
        guard !AppState.isPaywalledEffective else { return }
        guard let event = await MeetingPrepService.upcomingUnbriefedEvent() else { return }
        guard let brief = await MeetingPrepService.prepare(for: event) else {
            // Nothing known about anyone — mark it so we don't retry every 15 minutes.
            MeetingPrepService.markBriefed(eventId: event.id)
            return
        }
        MeetingPrepService.markBriefed(eventId: event.id)
        presentBrief(brief)
        // Watchers listening for "a meeting about X is coming up" get a shot at this too.
        WatcherEventRouter.calendarEventStarting(
            title: event.summary, detail: brief.contextBlock)
    }

    private func presentBrief(_ brief: MeetingPrepBrief) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        log("MeetingAutoDetectMonitor: presenting prep brief for \(brief.title)")
        PostHogManager.shared.track(
            "copilot_meeting_prep_shown",
            properties: ["matched": brief.matchedCount, "open_items": brief.openItems.count])
        NotificationService.shared.sendNotification(
            title: "\(formatter.string(from: brief.startsAt)) · \(brief.title)",
            message: brief.hudMessage,
            assistantId: "copilot",
            sound: .none,
            context: FloatingBarNotificationContext(
                sourceTitle: "Meeting prep",
                assistantId: "copilot",
                sourceApp: nil,
                windowTitle: nil,
                contextSummary: nil,
                currentActivity: nil,
                reasoning: "meeting_prep",
                detail: brief.sourceBreadcrumbs.isEmpty
                    ? nil : "From your notes: " + brief.sourceBreadcrumbs.prefix(3).joined(separator: ", "),
                feedbackBucket: "meeting_prep:brief"
            ),
            respectFrequency: false)
    }

    private func prompt() {
        log("MeetingAutoDetectMonitor: meeting detected — offering to start the copilot")
        PostHogManager.shared.track("copilot_meeting_detected_prompt", properties: [:])
        NotificationService.shared.sendNotification(
            title: "Meeting detected",
            message: "Start the live copilot for this call?",
            assistantId: "copilot_meeting",
            sound: .none,
            context: FloatingBarNotificationContext(
                sourceTitle: "Copilot",
                assistantId: "copilot_meeting",
                sourceApp: nil,
                windowTitle: nil,
                contextSummary: nil,
                currentActivity: nil,
                reasoning: nil,
                detail: nil,
                feedbackBucket: "meeting_detect:prompt"
            ),
            respectFrequency: false
        )
    }

    // MARK: - Debug (automation bridge)

    /// Force the prompt card regardless of detector state and cooldowns.
    func debugPrompt() -> [String: String] {
        prompt()
        return [
            "prompted": "true",
            "watching": detector == nil ? "false" : "true",
            "meeting_active": detector?.isMeetingActive == true ? "true" : "false",
        ]
    }
}
