import Foundation

/// How consequential a watcher action is. Ported from OpenWorker's RiskClass: the whole
/// approval model hangs off this one static classification. Because omi's action set is a
/// fixed enum (we never execute user-written code), the table is compile-time complete —
/// strictly safer than a dynamic tool registry.
enum WatcherRiskClass: String, Codable {
    /// No side effects outside this Mac's UI. Always allowed.
    case read
    /// Mutates local state the user owns (the watcher's own memory).
    case writeLocal
    /// Changes what other agents do.
    case exec
    /// Leaves this Mac — a message/call to a human. Always the approval hook.
    case external

    var isConsequential: Bool { self != .read }
}

extension WatcherAction {
    /// The static risk of this action. New cases must be classified here explicitly.
    var riskClass: WatcherRiskClass {
        switch self {
        case .notifyHUD, .overlay, .sleep, .stopSelf:
            return .read
        case .appendMemory:
            return .writeLocal
        case .startAgent, .stopAgent:
            return .exec
        case .notifyChannel:
            return .external
        }
    }

    /// Short human label used on approval cards and in run history.
    var shortLabel: String {
        switch self {
        case .appendMemory: return "remember"
        case .notifyHUD: return "notify on this Mac"
        case .overlay: return "show an overlay"
        case .notifyChannel(let channel, _, _): return "send via \(channel.rawValue)"
        case .startAgent: return "start another watcher"
        case .stopAgent: return "stop another watcher"
        case .sleep: return "go quiet"
        case .stopSelf: return "stop itself"
        }
    }
}

/// Where an outbound channel actually delivers. Ported from OpenWorker's `scopeNote` — the
/// plain-words phrasing is what makes an approval card trustworthy at a glance.
enum WatcherScopeNote {
    static func text(for action: WatcherAction) -> (text: String, leavesMac: Bool) {
        switch action {
        case .notifyChannel(let channel, _, _):
            let destination: String
            switch channel {
            case .discord: destination = "Discord"
            case .telegram: destination = "Telegram"
            case .pushover: destination = "Pushover"
            case .sms: destination = "SMS"
            case .whatsapp: destination = "WhatsApp"
            case .call: destination = "a phone call"
            }
            return ("leaves this Mac → \(destination)", true)
        case .appendMemory:
            return ("stays on this Mac · writes to this watcher's memory", false)
        case .startAgent, .stopAgent:
            return ("stays on this Mac · changes another watcher", false)
        default:
            return ("stays on this Mac", false)
        }
    }
}

/// Three-valued permission outcome. The third state (`needsUser`) is the whole point —
/// without it an agent can only be fully trusted or fully useless.
struct WatcherDecision {
    let allowed: Bool
    let needsUser: Bool
    let reason: String
    /// The standing grant that auto-allowed this call, when one did.
    let rule: String?

    static func allow(_ reason: String, rule: String? = nil) -> WatcherDecision {
        WatcherDecision(allowed: true, needsUser: false, reason: reason, rule: rule)
    }
    static func ask(_ reason: String) -> WatcherDecision {
        WatcherDecision(allowed: false, needsUser: true, reason: reason, rule: nil)
    }
}

/// Per-watcher stance on consequential actions.
enum WatcherApprovalPolicy: String, Codable, CaseIterable {
    /// Ask before anything that leaves this Mac (default, and the safe one).
    case ask
    /// Act without asking. Only reachable if the user explicitly chooses it.
    case auto
}

/// Decides whether an action may run, needs approval, or is auto-allowed by a standing grant.
enum WatcherPermission {
    /// A standing grant binds ONE action kind to ONE exact target — never a wildcard.
    /// Stored on the watcher as "discord https://hooks…" (kind + single space + exact target).
    static func grantEntry(for action: WatcherAction) -> String? {
        guard case let .notifyChannel(channel, target, _) = action else { return nil }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Reject anything that looks like an attempt at a wildcard grant.
        guard !trimmed.contains("*") else { return nil }
        return "\(channel.rawValue) \(trimmed)"
    }

    /// Human rendering of a grant entry for the settings list.
    static func describeGrant(_ entry: String) -> String {
        let parts = entry.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return entry }
        return "\(parts[0]) → \(parts[1])"
    }

    static func decide(action: WatcherAction, watcher: WatcherAgent) -> WatcherDecision {
        let risk = action.riskClass
        // 1. Nothing consequential ever asks.
        guard risk.isConsequential else { return .allow("low risk") }
        // 2. Local-only consequences (memory writes, waking a sibling watcher) don't ask —
        //    they can't reach anyone and the user can see the result in the app.
        guard risk == .external else { return .allow("stays on this Mac") }
        // 3. The user explicitly put this watcher in auto mode.
        if watcher.effectiveApprovalPolicy == .auto { return .allow("watcher is set to act without asking") }
        // 4. A standing grant for this exact target.
        if let entry = grantEntry(for: action), watcher.standingGrantEntries.contains(entry) {
            return .allow("allowed by standing grant", rule: entry)
        }
        return .ask("sends something off this Mac")
    }
}
