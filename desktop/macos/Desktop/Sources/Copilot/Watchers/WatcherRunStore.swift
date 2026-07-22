import Foundation

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
}

/// Keeps the last N runs per watcher (UserDefaults JSON, ring buffer). Ported from
/// Observer's IterationStore, trimmed to what the improve-edit and a history view need.
@MainActor
final class WatcherRunStore {
    static let shared = WatcherRunStore()

    private let storeKey = "copilotWatcherRuns"
    private let maxPerWatcher = 20

    private var runs: [String: [WatcherRun]]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
            let decoded = try? JSONDecoder().decode([String: [WatcherRun]].self, from: data)
        {
            runs = decoded
        } else {
            runs = [:]
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
