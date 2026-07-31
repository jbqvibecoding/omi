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
    }

    private var loops: [String: LoopState] = [:]
    private var started = false

    private init() {}

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
        loops[id] = LoopState()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let watcher = WatcherStore.shared.watcher(id: id), watcher.isEnabled else { break }
                await self.tickIfReady(watcher)
                let seconds = watcher.effectiveInterval
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
            await MainActor.run { self?.loops.removeValue(forKey: id) }
        }
        loops[id]?.task = task
    }

    private func tickIfReady(_ watcher: WatcherAgent) async {
        guard var state = loops[watcher.id] else { return }
        if state.isExecuting { return }
        if let until = state.sleepUntil, Date() < until { return }
        state.sleepUntil = nil
        state.isExecuting = true
        loops[watcher.id] = state
        _ = await runTick(watcher)
        loops[watcher.id]?.isExecuting = false
    }

    // MARK: - Single iteration

    /// Runs one iteration and returns diagnostics (also used by the omi-ctl force-run).
    @discardableResult
    func runTick(_ watcher: WatcherAgent, force: Bool = false) async -> [String: String] {
        let resolved = await WatcherSensorResolver.resolve(
            prompt: watcher.systemPrompt, watcherId: watcher.id)
        let snapshot = PerceptualChangeDetector.snapshot(
            text: resolved.text, image: resolved.images.first)

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
                response = try await callModel(watcher: watcher, prompt: resolved.text, images: resolved.images)
            } catch {
                logError("WatcherRuntime: model call failed for \(watcher.id)", error: error)
                return ["error": error.localizedDescription]
            }
            if loops[watcher.id] != nil {
                loops[watcher.id]?.lastResponse = response
                loops[watcher.id]?.baseline = snapshot
            }
        }

        let conditionMet = watcher.condition.isMet(response: response)
        var actionsRun: [String] = []
        if conditionMet {
            // One key per (watcher, tick, action slot) so a replayed tick reuses the same
            // approval item instead of asking the user twice.
            let tickKey = "\(watcher.id):\(Int(Date().timeIntervalSince1970))"
            for (index, action) in watcher.actions.enumerated() {
                let label = await execute(
                    action, watcher: watcher, response: response,
                    actionKey: "\(tickKey):\(index)")
                actionsRun.append(label)
            }
        }

        WatcherRunStore.shared.record(
            WatcherRun(
                watcherId: watcher.id, at: Date(), responseHead: String(response.prefix(120)),
                reused: reused, conditionMet: conditionMet,
                actions: actionsRun.joined(separator: ","), error: nil))

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

    private func callModel(watcher: WatcherAgent, prompt: String, images: [Data]) async throws -> String {
        let systemPrompt =
            "You are a watcher agent. Follow the user's instruction below and respond concisely. "
            + "Your response is evaluated by a rule to decide whether to act."
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
