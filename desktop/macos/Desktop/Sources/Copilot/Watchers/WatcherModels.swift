import Foundation

/// A user-defined "watcher" micro-agent: on a loop it gathers sensors (screen / OCR /
/// audio / clipboard / memory) into a prompt, runs the LLM, and — when a declarative
/// condition on the response is met — fires declarative actions (notify / remember /
/// overlay). Ported in spirit from Observer AI's agent model, but with a fixed typed
/// action set instead of a JavaScript sandbox (Apple-safe: the model response is data,
/// never executed as code).
struct WatcherAgent: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    /// System prompt containing sensor placeholders ($SCREEN, $SCREEN_OCR, $MEMORY, …).
    var systemPrompt: String
    /// How often the loop runs. Clamped to `minLoopIntervalSeconds` at runtime.
    var loopIntervalSeconds: Int
    /// Skip the LLM call when sensors haven't meaningfully changed since last tick.
    var onlyOnSignificantChange: Bool
    /// Gate on the model response deciding whether the actions fire.
    var condition: WatcherCondition
    /// Actions to run in order when `condition` passes.
    var actions: [WatcherAction]
    var isEnabled: Bool
    /// Inference backend (nil = cloud Gemini default). Optional so older stored watchers decode.
    var backend: WatcherBackendKind?
    /// Model id for the chosen backend (e.g. an Ollama model like "gemma3"); nil = default.
    var modelId: String?
    /// Whether actions that leave this Mac ask first. nil = ask (the safe default).
    var approvalPolicy: WatcherApprovalPolicy?
    /// Standing grants, each binding one action kind to one EXACT target
    /// ("discord https://hooks…"). Never wildcards; minted only by the user.
    var standingGrants: [String]?
    /// When this watcher runs. nil = the legacy `loopIntervalSeconds` polling loop.
    var schedule: WatcherSchedule?
    /// Last *successful* run. Advances only on success, so a failing watcher stays "due"
    /// and a missed wall-clock run can be caught up after the Mac wakes.
    var lastRunAt: Date?
    /// Last attempt of any outcome — the anchor for failure backoff.
    var lastAttemptAt: Date?
    /// Consecutive failures. Reset on success; at `maxConsecutiveFailures` the watcher
    /// pauses itself rather than burning tokens on a broken loop.
    var failCount: Int?

    static let minLoopIntervalSeconds = 15
    static let defaultLoopIntervalSeconds = 60
    /// Backoff after a failed attempt, so a broken watcher doesn't retry at full speed.
    static let failureBackoffSeconds: TimeInterval = 300
    static let maxConsecutiveFailures = 5

    var effectiveInterval: Int { max(Self.minLoopIntervalSeconds, loopIntervalSeconds) }
    /// The schedule to run on, falling back to the interval loop for watchers created
    /// before schedules existed.
    var effectiveSchedule: WatcherSchedule {
        schedule ?? .interval(seconds: effectiveInterval)
    }
    var consecutiveFailures: Int { failCount ?? 0 }
    var effectiveBackend: WatcherBackendKind { backend ?? .gemini }
    var effectiveModelId: String? { modelId?.isEmpty == false ? modelId : nil }
    /// Ask before anything leaves this Mac unless the user opted out.
    var effectiveApprovalPolicy: WatcherApprovalPolicy { approvalPolicy ?? .ask }
    var standingGrantEntries: [String] { standingGrants ?? [] }

    init(
        id: String = "watcher_\(UUID().uuidString.prefix(8))",
        name: String,
        systemPrompt: String,
        loopIntervalSeconds: Int = WatcherAgent.defaultLoopIntervalSeconds,
        onlyOnSignificantChange: Bool = true,
        condition: WatcherCondition = .always,
        actions: [WatcherAction] = [],
        isEnabled: Bool = false,
        backend: WatcherBackendKind? = nil,
        modelId: String? = nil,
        approvalPolicy: WatcherApprovalPolicy? = nil,
        standingGrants: [String]? = nil,
        schedule: WatcherSchedule? = nil,
        lastRunAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        failCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.loopIntervalSeconds = loopIntervalSeconds
        self.onlyOnSignificantChange = onlyOnSignificantChange
        self.condition = condition
        self.actions = actions
        self.isEnabled = isEnabled
        self.backend = backend
        self.modelId = modelId
        self.approvalPolicy = approvalPolicy
        self.standingGrants = standingGrants
        self.schedule = schedule
        self.lastRunAt = lastRunAt
        self.lastAttemptAt = lastAttemptAt
        self.failCount = failCount
    }

    // Explicit Codable so adding fields never breaks decoding of previously stored watchers
    // (Swift's synthesized decode does not apply property defaults on missing keys).
    enum CodingKeys: String, CodingKey {
        case id, name, systemPrompt, loopIntervalSeconds, onlyOnSignificantChange
        case condition, actions, isEnabled, backend, modelId
        case approvalPolicy, standingGrants
        case schedule, lastRunAt, lastAttemptAt, failCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Watcher"
        systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? ""
        loopIntervalSeconds =
            (try? c.decode(Int.self, forKey: .loopIntervalSeconds)) ?? Self.defaultLoopIntervalSeconds
        onlyOnSignificantChange = (try? c.decode(Bool.self, forKey: .onlyOnSignificantChange)) ?? true
        condition = (try? c.decode(WatcherCondition.self, forKey: .condition)) ?? .always
        actions = (try? c.decode([WatcherAction].self, forKey: .actions)) ?? []
        isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? false
        backend = try? c.decodeIfPresent(WatcherBackendKind.self, forKey: .backend)
        modelId = try? c.decodeIfPresent(String.self, forKey: .modelId)
        approvalPolicy = try? c.decodeIfPresent(WatcherApprovalPolicy.self, forKey: .approvalPolicy)
        standingGrants = try? c.decodeIfPresent([String].self, forKey: .standingGrants)
        schedule = try? c.decodeIfPresent(WatcherSchedule.self, forKey: .schedule)
        lastRunAt = try? c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        lastAttemptAt = try? c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        failCount = try? c.decodeIfPresent(Int.self, forKey: .failCount)
    }
}

/// Which inference backend runs a watcher's model call.
enum WatcherBackendKind: String, Codable, CaseIterable {
    case gemini
    case ollama
}

/// Declarative gate on the model response (replaces Observer's `if(response.includes(...))`).
enum WatcherCondition: Codable, Equatable {
    /// Fire actions on every tick.
    case always
    /// Fire when the response contains a keyword.
    case responseContains(keyword: String, caseInsensitive: Bool)
    /// Fire when the response matches a regular expression.
    case responseMatches(regex: String)

    /// Evaluate against a model response.
    func isMet(response: String) -> Bool {
        switch self {
        case .always:
            return true
        case let .responseContains(keyword, caseInsensitive):
            guard !keyword.isEmpty else { return true }
            return caseInsensitive
                ? response.range(of: keyword, options: .caseInsensitive) != nil
                : response.contains(keyword)
        case let .responseMatches(regex):
            guard let re = try? NSRegularExpression(pattern: regex) else { return false }
            let range = NSRange(response.startIndex..., in: response)
            return re.firstMatch(in: response, range: range) != nil
        }
    }

    // Codable via a tagged representation so the enum with associated values round-trips.
    private enum CodingKeys: String, CodingKey { case type, keyword, caseInsensitive, regex }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try c.encode("always", forKey: .type)
        case let .responseContains(keyword, caseInsensitive):
            try c.encode("contains", forKey: .type)
            try c.encode(keyword, forKey: .keyword)
            try c.encode(caseInsensitive, forKey: .caseInsensitive)
        case let .responseMatches(regex):
            try c.encode("matches", forKey: .type)
            try c.encode(regex, forKey: .regex)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "contains":
            self = .responseContains(
                keyword: (try? c.decode(String.self, forKey: .keyword)) ?? "",
                caseInsensitive: (try? c.decode(Bool.self, forKey: .caseInsensitive)) ?? true)
        case "matches":
            self = .responseMatches(regex: (try? c.decode(String.self, forKey: .regex)) ?? "")
        default:
            self = .always
        }
    }
}

/// Outbound channels for `notifyChannel`. Discord/Telegram/Pushover go direct from the
/// client; SMS/WhatsApp/call route through the omi backend's Twilio tools.
enum WatcherNotificationChannel: String, Codable, CaseIterable {
    case discord
    case telegram
    case pushover
    case sms
    case whatsapp
    case call
}

/// Declarative action fired when a watcher's condition is met. Template strings support
/// `$RESPONSE` (the model output) and `$TIME` interpolation.
enum WatcherAction: Codable, Equatable {
    /// Append to this watcher's scratchpad memory (surfaced next tick via $MEMORY).
    case appendMemory(template: String)
    /// Show a card in the floating bar HUD.
    case notifyHUD(title: String, message: String)
    /// Send via an outbound channel (target = webhook URL / chat id / user key).
    case notifyChannel(channel: WatcherNotificationChannel, target: String, message: String)
    /// Push a message to the overlay (delivered via the HUD for v1).
    case overlay(body: String)
    /// Stop this watcher after this tick (Observer's "run once" idiom).
    case stopSelf
    /// Suppress this watcher for N seconds (self-throttle, avoids notification spam).
    case sleep(seconds: Int)
    /// Enable another watcher (hand off work — it reads this one's memory via $MEMORY@id).
    case startAgent(watcherId: String)
    /// Disable another watcher.
    case stopAgent(watcherId: String)

    private enum CodingKeys: String, CodingKey {
        case type, template, title, message, channel, target, body, seconds, watcherId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .appendMemory(template):
            try c.encode("appendMemory", forKey: .type)
            try c.encode(template, forKey: .template)
        case let .notifyHUD(title, message):
            try c.encode("notifyHUD", forKey: .type)
            try c.encode(title, forKey: .title)
            try c.encode(message, forKey: .message)
        case let .notifyChannel(channel, target, message):
            try c.encode("notifyChannel", forKey: .type)
            try c.encode(channel, forKey: .channel)
            try c.encode(target, forKey: .target)
            try c.encode(message, forKey: .message)
        case let .overlay(body):
            try c.encode("overlay", forKey: .type)
            try c.encode(body, forKey: .body)
        case .stopSelf:
            try c.encode("stopSelf", forKey: .type)
        case let .sleep(seconds):
            try c.encode("sleep", forKey: .type)
            try c.encode(seconds, forKey: .seconds)
        case let .startAgent(watcherId):
            try c.encode("startAgent", forKey: .type)
            try c.encode(watcherId, forKey: .watcherId)
        case let .stopAgent(watcherId):
            try c.encode("stopAgent", forKey: .type)
            try c.encode(watcherId, forKey: .watcherId)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "appendMemory":
            self = .appendMemory(template: (try? c.decode(String.self, forKey: .template)) ?? "$RESPONSE")
        case "notifyHUD":
            self = .notifyHUD(
                title: (try? c.decode(String.self, forKey: .title)) ?? "Watcher",
                message: (try? c.decode(String.self, forKey: .message)) ?? "$RESPONSE")
        case "notifyChannel":
            self = .notifyChannel(
                channel: (try? c.decode(WatcherNotificationChannel.self, forKey: .channel)) ?? .discord,
                target: (try? c.decode(String.self, forKey: .target)) ?? "",
                message: (try? c.decode(String.self, forKey: .message)) ?? "$RESPONSE")
        case "overlay":
            self = .overlay(body: (try? c.decode(String.self, forKey: .body)) ?? "$RESPONSE")
        case "sleep":
            self = .sleep(seconds: (try? c.decode(Int.self, forKey: .seconds)) ?? 600)
        case "startAgent":
            self = .startAgent(watcherId: (try? c.decode(String.self, forKey: .watcherId)) ?? "")
        case "stopAgent":
            self = .stopAgent(watcherId: (try? c.decode(String.self, forKey: .watcherId)) ?? "")
        default:
            self = .stopSelf
        }
    }
}

/// Interpolates `$RESPONSE` and `$TIME` in an action's template string.
enum WatcherTemplate {
    static func render(_ template: String, response: String) -> String {
        var out = template.replacingOccurrences(of: "$RESPONSE", with: response)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        out = out.replacingOccurrences(of: "$TIME", with: fmt.string(from: Date()))
        return out
    }
}
