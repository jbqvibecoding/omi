import Foundation

/// Runs enabled watcher agents on independent loops, ported from Observer AI's main_loop:
/// each watcher has its own timer, an `isExecuting` non-overlap guard, a `sleepUntil`
/// self-suppression window, and reuse of the last response when sensors haven't changed
/// (via PerceptualChangeDetector). A single tick: resolve sensors → build prompt(+image)
/// → optional change gate → LLM → evaluate the declarative condition → run actions.
@MainActor
final class WatcherRuntime {
    static let shared = WatcherRuntime()

    private struct LoopState {
        var task: Task<Void, Never>?
        var isExecuting = false
        var sleepUntil: Date?
        var lastResponse: String?
        var baseline: WatcherSensorSnapshot?
        /// The schedule this loop is currently sleeping against — a change means the loop
        /// has to be restarted, otherwise an edit wouldn't take effect until it woke up
        /// (which for "daily at 9am" is up to a day later).
        var schedule: WatcherSchedule?
        /// When a self-pacing watcher asked to be woken next.
        var selfPacedUntil: Date?
    }

    private var loops: [String: LoopState] = [:]
    private var started = false

    /// Upper bound on a self-paced wake-up. A watcher that asks for a week off is almost
    /// certainly wrong, and a day is short enough that the mistake is cheap.
    private static let maxSelfPacedInterval: TimeInterval = 24 * 3600

    private init() {}

    /// Identifier for one run, used to name its artifacts directory.
    static func runId(at date: Date) -> String {
        "\(DossierStore.fileStamp(date))-\(String(UUID().uuidString.prefix(4)).lowercased())"
    }

    // MARK: - Lifecycle

    /// Boot from app startup (CopilotOrchestrator.setup). Idempotent.
    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: .watchersDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in WatcherRuntime.shared.reconcile() }
        }
        reconcile()
        log("WatcherRuntime: started")
    }

    /// Align running loops with the enabled watchers in the store.
    func reconcile() {
        let enabled = WatcherStore.shared.watchers.filter { $0.isEnabled }
        let enabledIds = Set(enabled.map(\.id))

        // Stop loops whose watcher was disabled or deleted.
        for (id, state) in loops where !enabledIds.contains(id) {
            state.task?.cancel()
            loops.removeValue(forKey: id)
            log("WatcherRuntime: stopped watcher \(id)")
        }
        // Restart loops whose schedule was edited, so the new timing applies now.
        for watcher in enabled {
            guard let state = loops[watcher.id], !state.isExecuting else { continue }
            guard state.schedule != watcher.effectiveSchedule else { continue }
            state.task?.cancel()
            loops.removeValue(forKey: watcher.id)
            log("WatcherRuntime: rescheduled watcher \(watcher.id) — \(watcher.effectiveSchedule.humanLabel)")
        }
        // Start loops for newly enabled watchers.
        for watcher in enabled where loops[watcher.id] == nil {
            startLoop(watcher.id)
            log("WatcherRuntime: started watcher \(watcher.id)")
        }
    }

    func stopAll() {
        for (_, state) in loops { state.task?.cancel() }
        loops.removeAll()
    }

    // MARK: - Loop

    private func startLoop(_ id: String) {
        var state = LoopState()
        state.schedule = WatcherStore.shared.watcher(id: id)?.effectiveSchedule
        loops[id] = state
        let task = Task { [weak self] in
            var isFirstPass = true
            while !Task.isCancelled {
                guard let self else { return }
                guard let watcher = WatcherStore.shared.watcher(id: id), watcher.isEnabled else { break }

                // A wall-clock run that came due while the Mac was asleep (or the app was
                // closed) is caught up exactly once on the way back — not replayed for every
                // occurrence missed, which is how a "daily 9am" watcher fires eight times
                // after a week away.
                if isFirstPass, watcher.effectiveSchedule.isWallClock, Self.isOverdue(watcher) {
                    await self.tickIfReady(watcher, trigger: .catchup)
                }
                isFirstPass = false

                guard let fresh = WatcherStore.shared.watcher(id: id), fresh.isEnabled else { break }
                let sleepSeconds = Self.secondsUntilNextRun(
                    fresh, selfPacedUntil: self.loops[id]?.selfPacedUntil)
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let due = WatcherStore.shared.watcher(id: id), due.isEnabled else { break }
                await self.tickIfReady(due, trigger: .schedule)
            }
            await MainActor.run { self?.loops.removeValue(forKey: id) }
        }
        loops[id]?.task = task
    }

    /// A wall-clock schedule is overdue when its next fire after the last success has
    /// already passed.
    private static func isOverdue(_ watcher: WatcherAgent) -> Bool {
        guard let lastRun = watcher.lastRunAt else { return false }
        guard let due = watcher.effectiveSchedule.nextFireDate(after: lastRun) else { return false }
        return due <= Date()
    }

    /// How long to sleep before the next attempt, honoring self-pacing and failure backoff.
    private static func secondsUntilNextRun(_ watcher: WatcherAgent, selfPacedUntil: Date? = nil)
        -> Double
    {
        let now = Date()
        var next = watcher.effectiveSchedule.nextFireDate(after: now)
            ?? now.addingTimeInterval(TimeInterval(watcher.effectiveInterval))
        // A self-paced watcher just told us when it wants to look again. Take whichever
        // comes first — the model can ask to be woken sooner, never to skip its schedule.
        if watcher.isSelfPaced, let asked = selfPacedUntil, asked > now, asked < next {
            next = asked
        }
        // After a failure, hold off — a watcher whose model call is broken shouldn't retry
        // at full speed. The schedule still wins if it's further out.
        if watcher.consecutiveFailures > 0, let attempt = watcher.lastAttemptAt {
            let backoff = attempt.addingTimeInterval(WatcherAgent.failureBackoffSeconds)
            if backoff > next { next = backoff }
        }
        return max(1, next.timeIntervalSince(now))
    }

    /// Reads an optional `next_check_seconds: N` the model may append when self-pacing is on.
    /// Clamped hard — the model gets to hint, not to decide it never runs again.
    static func parseSelfPacedInterval(from response: String) -> TimeInterval? {
        guard let regex = try? NSRegularExpression(
            pattern: #"next_check_seconds\D{0,4}(\d+)"#, options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(response.startIndex..., in: response)
        guard let match = regex.firstMatch(in: response, range: range),
            let numberRange = Range(match.range(at: 1), in: response),
            let seconds = Double(response[numberRange])
        else { return nil }
        return min(
            max(seconds, Double(WatcherAgent.minLoopIntervalSeconds)), maxSelfPacedInterval)
    }

    private func tickIfReady(_ watcher: WatcherAgent, trigger: WatcherRunTrigger) async {
        guard var state = loops[watcher.id] else { return }
        // Skip-on-overlap: a long run swallows its own next slot rather than stacking.
        if state.isExecuting {
            WatcherRunStore.shared.record(
                WatcherRun(
                    watcherId: watcher.id, at: Date(), responseHead: "", reused: false,
                    conditionMet: false, actions: "", error: nil, trigger: trigger,
                    status: .skipped, durationMs: 0))
            return
        }
        if let until = state.sleepUntil, Date() < until { return }
        state.sleepUntil = nil
        state.isExecuting = true
        loops[watcher.id] = state
        _ = await runTick(watcher, trigger: trigger)
        loops[watcher.id]?.isExecuting = false
    }

    // MARK: - Single iteration

    /// Runs one iteration and returns diagnostics (also used by the omi-ctl force-run).
    @discardableResult
    func runTick(
        _ watcher: WatcherAgent, force: Bool = false, trigger: WatcherRunTrigger = .manual,
        event: WatcherEvent? = nil
    ) async -> [String: String] {
        let startedAt = Date()
        let runId = WatcherRuntime.runId(at: startedAt)
        let resolved = await WatcherSensorResolver.resolve(
            prompt: watcher.systemPrompt, watcherId: watcher.id)
        var prompt = resolved.text
        if let event {
            // Second pass of event routing: the router was told to be liberal, so the
            // watcher itself gets the final say on whether this is actually its business.
            prompt =
                "\(event.promptBlock)\n\nIf, having looked properly, this event is not what "
                + "you watch for, say so plainly and do nothing else.\n\n\(prompt)"
        }
        let snapshot = PerceptualChangeDetector.snapshot(
            text: prompt, image: resolved.images.first)

        var response: String
        var reused = false
        let baseline = loops[watcher.id]?.baseline
        if !force, watcher.onlyOnSignificantChange,
            let lastResponse = loops[watcher.id]?.lastResponse,
            !PerceptualChangeDetector.isSignificant(previous: baseline, current: snapshot)
        {
            response = lastResponse
            reused = true
        } else {
            do {
                response = try await callModel(watcher: watcher, prompt: prompt, images: resolved.images)
            } catch {
                logError("WatcherRuntime: model call failed for \(watcher.id)", error: error)
                WatcherRunStore.shared.record(
                    WatcherRun(
                        watcherId: watcher.id, at: Date(), responseHead: "", reused: false,
                        conditionMet: false, actions: "", error: error.localizedDescription,
                        trigger: trigger, status: .error,
                        durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)))
                recordFailure(watcher)
                return ["error": error.localizedDescription]
            }
            if loops[watcher.id] != nil {
                loops[watcher.id]?.lastResponse = response
                loops[watcher.id]?.baseline = snapshot
            }
        }

        // Self-pacing: the model may say when it wants to look again. Recorded before the
        // condition runs, so it applies even on a tick that decides to do nothing.
        if watcher.isSelfPaced, let asked = Self.parseSelfPacedInterval(from: response) {
            loops[watcher.id]?.selfPacedUntil = Date().addingTimeInterval(asked)
            log("WatcherRuntime: \(watcher.id) asked to be woken in \(Int(asked))s")
        }

        let artifactsDirectory = WatcherArtifacts.prepare(for: watcher, runId: runId)
        var conditionMet = watcher.condition.isMet(response: response)
        var actionsRun: [String] = []
        if watcher.isDocumentMode {
            // A document watcher doesn't interrupt anyone — it keeps a file current. The
            // declarative condition/actions don't apply.
            conditionMet = true
            actionsRun.append(
                await WatcherDocument.update(
                    watcher: watcher, observation: response, snapshotTo: artifactsDirectory))
        } else if conditionMet {
            // One key per (watcher, tick, action slot) so a replayed tick reuses the same
            // approval item instead of asking the user twice.
            for (index, action) in watcher.actions.enumerated() {
                let label = await execute(
                    action, watcher: watcher, response: response,
                    actionKey: "\(watcher.id):\(runId):\(index)")
                actionsRun.append(label)
            }
        }

        // Anything the run left behind in its own output directory is worth keeping a
        // pointer to; a run that produced nothing doesn't get a folder at all.
        let producedArtifacts = !WatcherArtifacts.files(in: artifactsDirectory).isEmpty

        WatcherRunStore.shared.record(
            WatcherRun(
                watcherId: watcher.id, at: Date(), responseHead: String(response.prefix(120)),
                reused: reused, conditionMet: conditionMet,
                actions: actionsRun.joined(separator: ","), error: nil, trigger: trigger,
                status: .ok, durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                artifactsPath: producedArtifacts ? artifactsDirectory.path : nil))
        recordSuccess(watcher)

        log(
            "WatcherRuntime: tick \(watcher.id) — reused=\(reused) condition=\(conditionMet) "
                + "actions=\(actionsRun.joined(separator: ","))")
        return [
            "response": String(response.prefix(300)),
            "reused_last": reused ? "true" : "false",
            "condition_met": conditionMet ? "true" : "false",
            "actions": actionsRun.joined(separator: ","),
            "sensors": WatcherSensorResolver.referencedSensors(in: watcher.systemPrompt).joined(separator: ","),
        ]
    }

    // MARK: - Run health

    /// `lastRunAt` advances only here, so a wall-clock watcher that failed still reads as
    /// overdue and gets caught up rather than quietly skipping the day.
    private func recordSuccess(_ watcher: WatcherAgent) {
        guard var stored = WatcherStore.shared.watcher(id: watcher.id) else { return }
        let now = Date()
        // A fast polling watcher would otherwise rewrite the store (and wake every observer)
        // once a minute forever. Wall-clock schedules always persist — catch-up depends on it.
        if !stored.effectiveSchedule.isWallClock, stored.consecutiveFailures == 0,
            let last = stored.lastRunAt, now.timeIntervalSince(last) < 300
        {
            return
        }
        stored.lastRunAt = now
        stored.lastAttemptAt = now
        stored.failCount = 0
        // A one-shot schedule is done the moment it succeeds.
        if case .once = stored.effectiveSchedule {
            stored.isEnabled = false
        }
        WatcherStore.shared.upsert(stored)
    }

    private func recordFailure(_ watcher: WatcherAgent) {
        guard var stored = WatcherStore.shared.watcher(id: watcher.id) else { return }
        let failures = stored.consecutiveFailures + 1
        stored.lastAttemptAt = Date()
        stored.failCount = failures
        if failures >= WatcherAgent.maxConsecutiveFailures {
            stored.isEnabled = false
            NotificationService.shared.sendNotification(
                title: "\(stored.name) paused",
                message: "It failed \(failures) times in a row, so omi stopped running it. "
                    + "Open Watchers to check its setup.",
                assistantId: "watcher", sound: .none, respectFrequency: false)
            log("WatcherRuntime: auto-paused \(stored.id) after \(failures) consecutive failures")
        }
        WatcherStore.shared.upsert(stored)
    }

    private func callModel(watcher: WatcherAgent, prompt: String, images: [Data]) async throws -> String {
        var systemPrompt =
            "You are a watcher agent. Follow the user's instruction below and respond concisely. "
            + "Your response is evaluated by a rule to decide whether to act."
        if watcher.isDocumentMode {
            systemPrompt =
                "You are a watcher agent. Follow the user's instruction below and report what "
                + "you observe, concisely and factually. Your report is folded into a living "
                + "document, so state what is true now rather than narrating the check itself."
        }
        if watcher.isSelfPaced {
            // A hint, not a decision — the runtime clamps whatever comes back.
            systemPrompt +=
                "\n\nWhen you can tell how soon this is worth checking again, end your reply "
                + "with a line `next_check_seconds: N`. Base it on what you just saw — "
                + "something that just started needs longer than something about to finish."
        }
        let backend = WatcherInferenceBackendFactory.make(for: watcher)
        return try await backend.complete(
            systemPrompt: systemPrompt, userPrompt: prompt, images: images)
    }

    // MARK: - Actions

    /// Returns a short label of what ran (for diagnostics).
    ///
    /// Consequential actions pass through the permission gate first: anything that leaves this
    /// Mac is drafted, parked for the user's consent, and only delivered once they approve —
    /// the watcher never sends on its own unless the user granted this exact target.
    private func execute(
        _ action: WatcherAction, watcher: WatcherAgent, response: String, actionKey: String = ""
    ) async -> String {
        let decision = WatcherPermission.decide(action: action, watcher: watcher)
        if !decision.allowed && decision.needsUser {
            return await requestApprovalAndRun(
                action, watcher: watcher, response: response,
                actionKey: actionKey.isEmpty ? "\(watcher.id):\(UUID().uuidString)" : actionKey)
        }
        return await perform(action, watcher: watcher, response: response)
    }

    /// Drafts the message, parks it for consent, and delivers only on approval.
    private func requestApprovalAndRun(
        _ action: WatcherAction, watcher: WatcherAgent, response: String, actionKey: String
    ) async -> String {
        guard case let .notifyChannel(channel, target, message) = action else {
            // Only outbound channels reach the gate today; anything else is a no-op rather
            // than a silent send.
            return "blocked:\(action.shortLabel)"
        }
        let draft = WatcherTemplate.render(message, response: response)
        // Away = the floating bar is snoozed or the screen is locked; the ask queues in the
        // inbox instead of flashing a card nobody is there to see.
        let visibility =
            FloatingControlBarManager.shared.isSnoozed
            ? WatcherApprovalItem.visibilityInbox : WatcherApprovalItem.visibilityInline

        let item = WatcherApprovalStore.shared.add(
            watcher: watcher, actionKey: actionKey, action: action, body: draft,
            visibility: visibility)
        guard item.isPending else {
            // Already answered (durable replay) — honor the earlier decision, don't re-ask.
            return await deliverIfApproved(item, channel: channel, target: target, watcher: watcher)
        }

        if visibility == WatcherApprovalItem.visibilityInline {
            presentApprovalCard(item, watcher: watcher)
        }
        log("WatcherRuntime: \(watcher.id) awaiting approval to \(action.shortLabel)")

        guard let resolved = await WatcherApprovalStore.shared.wait(id: item.id) else {
            return "approval:lost"
        }
        return await deliverIfApproved(resolved, channel: channel, target: target, watcher: watcher)
    }

    private func deliverIfApproved(
        _ item: WatcherApprovalItem, channel: WatcherNotificationChannel, target: String,
        watcher: WatcherAgent
    ) async -> String {
        switch item.resolution {
        case "allow", "always":
            if item.resolution == "always", let entry = item.grantEntry {
                mintStandingGrant(entry, for: watcher)
            }
            let result = await WatcherNotifier.send(
                channel: channel, target: target, message: item.finalBody)
            let edited = item.editedBody != nil ? ",edited" : ""
            return "sent:\(channel.rawValue)(\(result.ok ? "ok" : result.detail))\(edited)"
        case "timeout":
            log("WatcherRuntime: approval timed out for \(watcher.id) — not sent")
            return "approval:timeout"
        default:
            // A refused send is the clearest preference signal there is: the watcher was
            // sure enough to draft it and the user said no.
            CopilotCorrectionLog.shared.record(
                scenario: "watcher", type: "send:\(channel.rawValue)",
                situation: "\(watcher.name) drafted: \(String(item.body.prefix(240)))",
                agentVerdict: "worth sending", userVerdict: "not worth sending")
            return "approval:denied"
        }
    }

    /// Persist a "this exact target never asks again" grant on the watcher.
    private func mintStandingGrant(_ entry: String, for watcher: WatcherAgent) {
        guard var stored = WatcherStore.shared.watcher(id: watcher.id) else { return }
        var grants = stored.standingGrantEntries
        guard !grants.contains(entry) else { return }
        grants.append(entry)
        stored.standingGrants = grants
        WatcherStore.shared.upsert(stored)
        log("WatcherRuntime: minted standing grant \(entry) for \(watcher.id)")
    }

    private func presentApprovalCard(_ item: WatcherApprovalItem, watcher: WatcherAgent) {
        NotificationService.shared.sendNotification(
            title: "\(watcher.name) wants to \(item.kind)",
            message: String(item.body.prefix(240)),
            assistantId: "watcher_approval",
            sound: .none,
            context: FloatingBarNotificationContext(
                sourceTitle: watcher.name,
                assistantId: "watcher_approval",
                sourceApp: nil,
                windowTitle: nil,
                contextSummary: item.id,
                currentActivity: item.grantEntry,
                reasoning: item.scopeNote,
                detail: item.body
            ),
            respectFrequency: false)
    }

    /// Runs an action that has already cleared the permission gate.
    private func perform(_ action: WatcherAction, watcher: WatcherAgent, response: String) async
        -> String
    {
        switch action {
        case let .appendMemory(template):
            WatcherMemoryStore.shared.append(
                watcherId: watcher.id, WatcherTemplate.render(template, response: response))
            return "appendMemory"

        case let .notifyHUD(title, message):
            NotificationService.shared.sendNotification(
                title: WatcherTemplate.render(title, response: response),
                message: WatcherTemplate.render(message, response: response),
                assistantId: "watcher",
                sound: .none,
                context: FloatingBarNotificationContext(
                    sourceTitle: watcher.name, assistantId: "watcher", sourceApp: nil,
                    windowTitle: nil, contextSummary: nil, currentActivity: nil,
                    reasoning: nil, detail: nil),
                respectFrequency: false)
            return "notifyHUD"

        case let .overlay(body):
            NotificationService.shared.sendNotification(
                title: watcher.name,
                message: WatcherTemplate.render(body, response: response),
                assistantId: "watcher", sound: .none, respectFrequency: false)
            return "overlay"

        case let .notifyChannel(channel, target, message):
            let result = await WatcherNotifier.send(
                channel: channel, target: target,
                message: WatcherTemplate.render(message, response: response))
            return "notifyChannel:\(channel.rawValue)(\(result.ok ? "ok" : result.detail))"

        case .stopSelf:
            WatcherStore.shared.setEnabled(id: watcher.id, false)
            return "stopSelf"

        case let .sleep(seconds):
            loops[watcher.id]?.sleepUntil = Date().addingTimeInterval(TimeInterval(seconds))
            return "sleep:\(seconds)s"

        case let .startAgent(watcherId):
            // Hand off to another watcher — enabling it lets reconcile() start its loop;
            // it reads this watcher's output via $MEMORY@<thisId>.
            WatcherStore.shared.setEnabled(id: watcherId, true)
            return "startAgent:\(watcherId)"

        case let .stopAgent(watcherId):
            WatcherStore.shared.setEnabled(id: watcherId, false)
            return "stopAgent:\(watcherId)"
        }
    }

    // MARK: - Debug (omi-ctl)

    /// Force one tick regardless of interval / change gate / sleep. Returns diagnostics.
    func forceRun(id: String) async -> [String: String] {
        guard let watcher = WatcherStore.shared.watcher(id: id) else {
            return ["error": "no watcher with id \(id)"]
        }
        return await runTick(watcher, force: true)
    }
}
