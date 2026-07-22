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
    private var geminiClient: GeminiClient?
    private var started = false

    private static let outputSchema = GeminiRequest.GenerationConfig.ResponseSchema(
        type: "object",
        properties: [
            "output": .init(
                type: "string", enum: nil,
                description: "Your full response for this observation.")
        ],
        required: ["output"]
    )

    private struct WatcherOutput: Decodable { let output: String }

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
                response = try await callModel(prompt: resolved.text, image: resolved.images.first)
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
            for action in watcher.actions {
                let label = await execute(action, watcher: watcher, response: response)
                actionsRun.append(label)
            }
        }

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

    private func callModel(prompt: String, image: Data?) async throws -> String {
        let client = try cachedGeminiClient()
        let systemPrompt =
            "You are a watcher agent. Follow the user's instruction below and respond concisely. "
            + "Your response is evaluated by a rule to decide whether to act."
        if let image {
            let json = try await client.sendRequest(
                prompt: prompt, imageData: image, systemPrompt: systemPrompt,
                responseSchema: Self.outputSchema, thinkingBudget: 0)
            let parsed = try JSONDecoder().decode(WatcherOutput.self, from: Data(json.utf8))
            return parsed.output
        } else {
            return try await client.sendTextRequest(
                prompt: prompt, systemPrompt: systemPrompt, maxRetries: 1, timeout: 60, thinkingBudget: 0)
        }
    }

    // MARK: - Actions

    /// Returns a short label of what ran (for diagnostics).
    private func execute(_ action: WatcherAction, watcher: WatcherAgent, response: String) async -> String {
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
        }
    }

    private func cachedGeminiClient() throws -> GeminiClient {
        if let geminiClient { return geminiClient }
        let client = try GeminiClient(model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
        geminiClient = client
        return client
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
