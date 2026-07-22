import Foundation

/// Persists user-created watcher agents in UserDefaults (JSON). Mirrors CustomProfileStore.
/// Posts `.watchersDidChange` so the runtime can reconcile running loops.
@MainActor
final class WatcherStore: ObservableObject {
    static let shared = WatcherStore()

    private let storeKey = "copilotWatchers"

    @Published private(set) var watchers: [WatcherAgent]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
            let decoded = try? JSONDecoder().decode([WatcherAgent].self, from: data)
        {
            watchers = decoded
        } else {
            watchers = []
        }
    }

    func watcher(id: String) -> WatcherAgent? {
        watchers.first { $0.id == id }
    }

    /// Create or update a watcher. Returns the stored value.
    @discardableResult
    func upsert(_ watcher: WatcherAgent) -> WatcherAgent {
        if let idx = watchers.firstIndex(where: { $0.id == watcher.id }) {
            watchers[idx] = watcher
        } else {
            watchers.append(watcher)
        }
        persist()
        return watcher
    }

    func setEnabled(id: String, _ enabled: Bool) {
        guard let idx = watchers.firstIndex(where: { $0.id == id }) else { return }
        watchers[idx].isEnabled = enabled
        persist()
    }

    func delete(id: String) {
        watchers.removeAll { $0.id == id }
        WatcherMemoryStore.shared.clear(watcherId: id)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(watchers) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
        NotificationCenter.default.post(name: .watchersDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted when the watcher set or their enabled state changes.
    static let watchersDidChange = Notification.Name("copilotWatchersDidChange")
}
