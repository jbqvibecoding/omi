import Foundation

// The priority order is Cicada's (github.com/wquguru/cicada, Apache-2.0 — LingClient's gate in
// Sources/LiveSubs/Ling.swift: speak > translate > notes). Changes: Cicada spaced requests to one
// provider's per-second limit; omi's limit is a per-user budget per minute shared with every AI
// feature, so this counts calls in a rolling minute and refuses the lower priorities first.

/// How many meeting-feature model calls a rolling minute may carry, by priority.
///
/// The model proxy gives each user 30 requests a minute for everything — the copilot, watchers,
/// chat, all of it. Subtitles that called the model once per sentence would take that whole
/// budget in a lively meeting. So translations get at most 8 a minute (they batch when there is
/// a backlog, and Apple's on-device translation takes them first when it can), minutes and
/// translations together at most 18, and interpretation — the user is waiting with their mouth
/// open — always goes.
struct GeminiCallBudget {
    enum Kind: Int, Comparable {
        case minutes = 0
        case translate = 1
        case interpret = 2

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    static let window: TimeInterval = 60
    static let translateLimit = 8
    /// Leaves the rest of the 30 to the copilot and everything else.
    static let totalLimit = 18

    private(set) var calls: [(at: Date, kind: Kind)] = []
    private var pausedUntil: [Kind: Date] = [:]

    /// Whether a call of this kind may go now; when it may, it is counted.
    mutating func allow(_ kind: Kind, now: Date = Date()) -> Bool {
        calls.removeAll { now.timeIntervalSince($0.at) >= Self.window }
        if kind != .interpret, let until = pausedUntil[kind], now < until { return false }
        switch kind {
        case .interpret:
            break
        case .translate:
            guard calls.filter({ $0.kind == .translate }).count < Self.translateLimit,
                calls.count < Self.totalLimit
            else { return false }
        case .minutes:
            guard calls.count < Self.totalLimit else { return false }
        }
        calls.append((at: now, kind: kind))
        return true
    }

    /// The proxy refused one (429): the shared budget is spent, so back off — translations for
    /// 20 seconds, minutes for a minute. Interpretation still tries; it fails visibly if refused.
    mutating func noteRateLimited(now: Date = Date()) {
        pausedUntil[.translate] = now.addingTimeInterval(20)
        pausedUntil[.minutes] = now.addingTimeInterval(60)
    }

    func count(_ kind: Kind, now: Date = Date()) -> Int {
        calls.filter { $0.kind == kind && now.timeIntervalSince($0.at) < Self.window }.count
    }
}

/// The one gate the meeting features' model calls go through.
actor GeminiCallGate {
    static let shared = GeminiCallGate()

    private var budget = GeminiCallBudget()

    func acquire(_ kind: GeminiCallBudget.Kind) -> Bool {
        budget.allow(kind)
    }

    func noteRateLimited() {
        budget.noteRateLimited()
    }

    /// Whether an error from a gated call was the proxy refusing it for rate.
    static func isRateLimit(_ error: Error) -> Bool {
        let message = ((error as? GeminiClient.GeminiClientError)?.internalMessage ?? error.localizedDescription)
            .lowercased()
        return message.contains("429") || message.contains("rate limit") || message.contains("resource exhausted")
    }

    func debugDump() -> [String: String] {
        [
            "translate_last_minute": String(budget.count(.translate)),
            "minutes_last_minute": String(budget.count(.minutes)),
            "interpret_last_minute": String(budget.count(.interpret)),
        ]
    }
}
