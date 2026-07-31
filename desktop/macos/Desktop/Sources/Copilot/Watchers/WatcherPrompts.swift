import Foundation

/// Prompt + schema for generating a watcher agent from a one-line natural-language
/// description, ported from Observer AI's agent-creation flow (sensor + action vocabulary,
/// the Looper/Watcher/Thinker patterns, and the anti-spam rules). Reuses omi's existing
/// structured-generation approach (cf. CopilotPrompts custom-profile generation).
enum WatcherPrompts {
    static let generationSystemPrompt = """
        You design a "watcher" agent from a one-line description. A watcher runs on a loop:
        every N seconds it gathers sensors into a prompt, an LLM responds, and if a rule on \
        the response matches, it runs actions.

        Available SENSOR placeholders to embed in system_prompt (use only what's needed):
        - $SCREEN — a screenshot (use for anything visual).
        - $SCREEN_OCR — recent on-screen text (cheaper than $SCREEN when text is enough).
        - $CAMERA — one webcam frame (use for the physical world in front of the user).
        - $CLIPBOARD — current clipboard text.
        - $MEMORY — this watcher's own notes from previous runs.
        - $MEMORY@otherId — another watcher's notes (for multi-agent handoffs).
        - $MICROPHONE / $ALL_AUDIO — recent speech transcript.
        - $TIME — current time.

        Write system_prompt so the model emits a SHORT, decidable response — e.g. "If the \
        build has finished, reply DONE, otherwise reply WAIT." Then set the condition to \
        match that keyword.

        Actions (each has a `type`; fill only the relevant fields):
        - appendMemory: text = what to remember (supports $RESPONSE, $TIME).
        - notifyHUD: text = the message shown on this Mac's floating bar.
        - overlay: text = a brief overlay message.
        - notifyChannel: channel = discord|telegram|pushover, target = webhook URL (discord) \
          / chat id (telegram) / user key (pushover), text = the message.
        - sleep: seconds = how long to stay quiet after acting (ALWAYS pair an outbound \
          notifyChannel/notifyHUD with a sleep so it doesn't fire every loop).
        - stopSelf: run once then stop.

        Rules:
        - Default only_on_significant_change to true for screen watchers (saves compute).
        - loop_interval_seconds: 30–120 for most tasks; never below 15.
        - Keep the condition tight so actions fire only when they should.
        """

    /// System prompt for improving an existing watcher from its recent runs (Observer @agent#N).
    static let improveSystemPrompt = """
        You improve an existing "watcher" agent. You are given its current configuration and a
        log of its recent runs (the model's response and whether it acted). Diagnose why it
        under- or over-fired and return an improved configuration in the same schema. Common
        fixes: tighten or loosen the condition keyword, make the instruction demand a clearer
        decidable reply, adjust the interval, or add a sleep after an outbound action. Keep the
        same sensors unless they're the problem. Only return the improved config.
        """

    @MainActor
    static func generationUserPrompt(description: String) -> String {
        var out = "Watcher to build: \(description)"
        // The same learned preferences that govern live suggestions — a watcher the user
        // builds should start out already knowing how they like to be interrupted.
        if let preferences = CopilotCorrectionLog.shared.promptBlock() {
            out += "\n\n\(preferences)"
        }
        return out
    }

    static func improveUserPrompt(current: WatcherAgent, recentRuns: String, instruction: String) -> String {
        """
        Current watcher:
        - name: \(current.name)
        - system_prompt: \(current.systemPrompt)
        - loop_interval_seconds: \(current.effectiveInterval)
        - condition: \(current.condition)
        - actions: \(current.actions.count)

        Recent runs (most recent last):
        \(recentRuns)

        Improvement request: \(instruction.isEmpty ? "Make it fire more accurately." : instruction)
        """
    }

    static let generationSchema = GeminiRequest.GenerationConfig.ResponseSchema(
        type: "object",
        properties: [
            "name": .init(type: "string", enum: nil, description: "Short display name"),
            "system_prompt": .init(
                type: "string", enum: nil,
                description: "Prompt with sensor placeholders; instruct a short decidable reply"),
            "loop_interval_seconds": .init(
                type: "number", enum: nil, description: "Loop period in seconds (>=15)"),
            "only_on_significant_change": .init(
                type: "boolean", enum: nil, description: "Skip LLM when sensors unchanged"),
            "condition_type": .init(
                type: "string", enum: ["always", "contains", "matches"],
                description: "How to decide if actions fire"),
            "condition_keyword": .init(
                type: "string", enum: nil,
                description: "Keyword (contains) or regex (matches); empty for always"),
            "actions": .init(
                type: "array", enum: nil, description: "Actions to run when the condition is met",
                items: .init(
                    type: "object",
                    properties: [
                        "type": .init(
                            type: "string",
                            enum: ["appendMemory", "notifyHUD", "overlay", "notifyChannel", "sleep", "stopSelf"],
                            description: "Action kind"),
                        "text": .init(type: "string", enum: nil, description: "Message/template"),
                        "channel": .init(
                            type: "string", enum: ["discord", "telegram", "pushover"],
                            description: "For notifyChannel"),
                        "target": .init(
                            type: "string", enum: nil,
                            description: "notifyChannel target (webhook/chat id/user key)"),
                        "seconds": .init(type: "number", enum: nil, description: "For sleep"),
                    ],
                    required: ["type"])),
        ],
        required: ["name", "system_prompt", "loop_interval_seconds", "condition_type", "actions"]
    )
}

/// The flat, LLM-friendly draft that `generationSchema` produces; mapped to a WatcherAgent.
struct WatcherDraft: Decodable {
    let name: String
    let systemPrompt: String
    let loopIntervalSeconds: Int
    let onlyOnSignificantChange: Bool?
    let conditionType: String
    let conditionKeyword: String?
    let actions: [DraftAction]

    struct DraftAction: Decodable {
        let type: String
        let text: String?
        let channel: String?
        let target: String?
        let seconds: Int?
    }

    enum CodingKeys: String, CodingKey {
        case name
        case systemPrompt = "system_prompt"
        case loopIntervalSeconds = "loop_interval_seconds"
        case onlyOnSignificantChange = "only_on_significant_change"
        case conditionType = "condition_type"
        case conditionKeyword = "condition_keyword"
        case actions
    }

    /// Map the draft into a concrete (disabled) WatcherAgent the user can review/enable.
    func toWatcher() -> WatcherAgent {
        let condition: WatcherCondition
        switch conditionType {
        case "contains":
            condition = .responseContains(keyword: conditionKeyword ?? "", caseInsensitive: true)
        case "matches":
            condition = .responseMatches(regex: conditionKeyword ?? "")
        default:
            condition = .always
        }

        let mapped: [WatcherAction] = actions.compactMap { a in
            switch a.type {
            case "appendMemory":
                return .appendMemory(template: a.text ?? "$RESPONSE")
            case "notifyHUD":
                return .notifyHUD(title: name, message: a.text ?? "$RESPONSE")
            case "overlay":
                return .overlay(body: a.text ?? "$RESPONSE")
            case "notifyChannel":
                return .notifyChannel(
                    channel: WatcherNotificationChannel(rawValue: a.channel ?? "discord") ?? .discord,
                    target: a.target ?? "", message: a.text ?? "$RESPONSE")
            case "sleep":
                return .sleep(seconds: a.seconds ?? 600)
            case "stopSelf":
                return .stopSelf
            default:
                return nil
            }
        }

        return WatcherAgent(
            name: name,
            systemPrompt: systemPrompt,
            loopIntervalSeconds: max(WatcherAgent.minLoopIntervalSeconds, loopIntervalSeconds),
            onlyOnSignificantChange: onlyOnSignificantChange ?? true,
            condition: condition,
            actions: mapped,
            isEnabled: false
        )
    }
}

/// Generates a watcher draft from a natural-language description.
@MainActor
enum WatcherAICreator {
    static func generate(description: String) async throws -> WatcherAgent {
        let client = try GeminiClient(model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
        let json = try await client.sendRequest(
            prompt: WatcherPrompts.generationUserPrompt(description: description),
            systemPrompt: WatcherPrompts.generationSystemPrompt,
            responseSchema: WatcherPrompts.generationSchema,
            thinkingBudget: 0)
        let draft = try JSONDecoder().decode(WatcherDraft.self, from: Data(json.utf8))
        return draft.toWatcher()
    }

    /// Improve an existing watcher using its recent run history (keeps id/enabled/backend).
    static func improve(existing: WatcherAgent, instruction: String) async throws -> WatcherAgent {
        let recentRuns = WatcherRunStore.shared.recentContext(watcherId: existing.id)
        let client = try GeminiClient(model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
        let json = try await client.sendRequest(
            prompt: WatcherPrompts.improveUserPrompt(
                current: existing, recentRuns: recentRuns, instruction: instruction),
            systemPrompt: WatcherPrompts.improveSystemPrompt,
            responseSchema: WatcherPrompts.generationSchema,
            thinkingBudget: 0)
        let draft = try JSONDecoder().decode(WatcherDraft.self, from: Data(json.utf8))
        var improved = draft.toWatcher()
        // Preserve identity + runtime state so the same watcher is updated in place.
        improved = WatcherAgent(
            id: existing.id, name: improved.name, systemPrompt: improved.systemPrompt,
            loopIntervalSeconds: improved.loopIntervalSeconds,
            onlyOnSignificantChange: improved.onlyOnSignificantChange,
            condition: improved.condition, actions: improved.actions,
            isEnabled: existing.isEnabled, backend: existing.backend, modelId: existing.modelId)
        return improved
    }
}
