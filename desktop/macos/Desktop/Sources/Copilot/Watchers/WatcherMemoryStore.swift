import Foundation

/// Per-watcher scratchpad memory: a plain text append-log the model can write (via the
/// appendMemory action) and read back next tick (via the $MEMORY placeholder). This is a
/// cheap working-memory channel distinct from omi's vector memory — ported from Observer's
/// flat per-agent memory. Persisted in UserDefaults (JSON dict keyed by watcher id).
@MainActor
final class WatcherMemoryStore {
    static let shared = WatcherMemoryStore()

    private let storeKey = "copilotWatcherMemories"
    /// Cap per-watcher memory so a runaway appender can't grow unbounded.
    private let maxChars = 8000

    private var memories: [String: String]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            memories = decoded
        } else {
            memories = [:]
        }
    }

    func get(watcherId: String) -> String {
        memories[watcherId] ?? ""
    }

    func set(watcherId: String, _ content: String) {
        memories[watcherId] = String(content.suffix(maxChars))
        persist()
    }

    func append(watcherId: String, _ content: String, separator: String = "\n") {
        let existing = memories[watcherId] ?? ""
        let combined = existing.isEmpty ? content : existing + separator + content
        memories[watcherId] = String(combined.suffix(maxChars))
        persist()
    }

    func clear(watcherId: String) {
        memories.removeValue(forKey: watcherId)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(memories) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
