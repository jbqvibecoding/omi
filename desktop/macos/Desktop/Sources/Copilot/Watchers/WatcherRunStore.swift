import Foundation

/// Why a run happened. Worth recording because "it fired at 9am" and "it fired because
/// your Mac was asleep at 9am and caught up at 10:14" are very different stories.
enum WatcherRunTrigger: String, Codable {
    case schedule
    case manual
    case catchup
    case event
}

/// How a run ended.
enum WatcherRunStatus: String, Codable {
    case ok
    case error
    case skipped
}

/// One recorded watcher tick, for the history view and for feeding self-improving edits
/// (Observer's @agent#N "edit with recent run context").
struct WatcherRun: Codable, Identifiable, Equatable {
    var id: String { "\(watcherId)-\(at.timeIntervalSince1970)" }
    let watcherId: String
    let at: Date
    let responseHead: String
    let reused: Bool
    let conditionMet: Bool
    let actions: String
    let error: String?
    /// Optional so runs recorded before these fields existed still decode.
    let trigger: WatcherRunTrigger?
    let status: WatcherRunStatus?
    let durationMs: Int?

    init(
        watcherId: String, at: Date, responseHead: String, reused: Bool, conditionMet: Bool,
        actions: String, error: String?, trigger: WatcherRunTrigger? = nil,
        status: WatcherRunStatus? = nil, durationMs: Int? = nil
    ) {
        self.watcherId = watcherId
        self.at = at
        self.responseHead = responseHead
        self.reused = reused
        self.conditionMet = conditionMet
        self.actions = actions
        self.error = error
        self.trigger = trigger
        self.status = status
        self.durationMs = durationMs
    }

    var effectiveStatus: WatcherRunStatus {
        status ?? (error != nil ? .error : .ok)
    }

    var effectiveTrigger: WatcherRunTrigger { trigger ?? .schedule }

    /// One line a human can read in the history list.
    var summaryLine: String {
        if let error { return "Failed — \(error)" }
        if !conditionMet { return "Checked, nothing to do" }
        return actions.isEmpty ? "Condition met" : "Ran \(actions)"
    }
}

/// Keeps the last N runs per watcher (UserDefaults JSON, ring buffer). Ported from
/// Observer's IterationStore, trimmed to what the improve-edit and a history view need.
@MainActor
final class WatcherRunStore {
    static let shared = WatcherRunStore()

    private let storeKey = "copilotWatcherRuns"
    private let seenKey = "copilotWatcherRunsSeenAt"
    private let maxPerWatcher = 20

    private var runs: [String: [WatcherRun]]
    /// When the user last looked at each watcher's history — frozen on open so the "new"
    /// badge doesn't blink out from under them mid-read.
    private var seenAt: [String: Date]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
            let decoded = try? JSONDecoder().decode([String: [WatcherRun]].self, from: data)
        {
            runs = decoded
        } else {
            runs = [:]
        }
        if let data = UserDefaults.standard.data(forKey: seenKey),
            let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        {
            seenAt = decoded
        } else {
            seenAt = [:]
        }
    }

    func record(_ run: WatcherRun) {
        var list = runs[run.watcherId] ?? []
        list.append(run)
        if list.count > maxPerWatcher { list.removeFirst(list.count - maxPerWatcher) }
        runs[run.watcherId] = list
        persist()
    }

    func recent(watcherId: String, limit: Int = 10) -> [WatcherRun] {
        Array((runs[watcherId] ?? []).suffix(limit))
    }

    func clear(watcherId: String) {
        runs.removeValue(forKey: watcherId)
        persist()
    }

    // MARK: - Unread marks

    /// Runs the user hasn't seen since they last opened this watcher's history.
    func unreadCount(watcherId: String) -> Int {
        let since = seenAt[watcherId] ?? .distantPast
        return (runs[watcherId] ?? []).filter { $0.at > since }.count
    }

    func isUnread(_ run: WatcherRun) -> Bool {
        run.at > (seenAt[run.watcherId] ?? .distantPast)
    }

    /// Mark everything currently recorded as seen. Call when the history list opens.
    func markSeen(watcherId: String) {
        seenAt[watcherId] = runs[watcherId]?.last?.at ?? Date()
        if let data = try? JSONEncoder().encode(seenAt) {
            UserDefaults.standard.set(data, forKey: seenKey)
        }
    }

    /// Compact text block of recent runs, for feeding a self-improving edit prompt.
    func recentContext(watcherId: String, limit: Int = 8) -> String {
        let items = recent(watcherId: watcherId, limit: limit)
        guard !items.isEmpty else { return "(no runs recorded yet)" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return items.map { r in
            let outcome = r.error.map { "ERROR \($0)" } ?? (r.conditionMet ? "acted(\(r.actions))" : "no-op")
            return "[\(fmt.string(from: r.at))] resp=\"\(r.responseHead)\" \(outcome)"
        }.joined(separator: "\n")
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(runs) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
