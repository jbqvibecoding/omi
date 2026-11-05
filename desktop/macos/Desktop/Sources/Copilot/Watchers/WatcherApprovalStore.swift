import Foundation

/// A parked request for the user's consent before a watcher does something consequential.
/// For outbound channels this doubles as the **draft**: `body` is what the watcher wants to
/// send, `editedBody` is the user's version — both are kept so we can learn from the diff.
struct WatcherApprovalItem: Codable, Identifiable, Equatable {
    let id: String
    let watcherId: String
    let watcherName: String
    /// Idempotency key — "<watcherId>:<runId>:<actionIndex>". A replayed tick reuses the item
    /// instead of asking twice.
    let actionKey: String
    /// Action kind label ("notifyChannel").
    let kind: String
    let risk: WatcherRiskClass
    /// Grant entry this would mint if the user picks "always" (nil = not eligible).
    let grantEntry: String?
    let channel: String?
    let target: String?
    let scopeNote: String
    /// The drafted message.
    let body: String
    /// The user's edited version, when they changed it before approving.
    var editedBody: String?
    var state: String  // pending | resolved
    var resolution: String?  // allow | always | deny | timeout
    /// inline = surfaced on the HUD (user is here) · inbox = queued (user is away).
    let visibility: String
    let createdAt: Date
    var resolvedAt: Date?

    static let statePending = "pending"
    static let stateResolved = "resolved"
    static let visibilityInline = "inline"
    static let visibilityInbox = "inbox"

    /// What actually gets sent if approved.
    var finalBody: String { editedBody ?? body }
    var isPending: Bool { state == Self.statePending }
}

/// Durable store of parked approvals. Contract (ported from OpenWorker's Inbox):
/// each item is `pending → resolved`, resolved **exactly once**, first responder wins — so
/// answering from the HUD, the settings inbox, or omi-ctl is all safe.
@MainActor
final class WatcherApprovalStore: ObservableObject {
    static let shared = WatcherApprovalStore()

    private let storeKey = "copilotWatcherApprovals"
    /// A watcher tick blocks while waiting. Auto-deny past this so a forgotten card can't
    /// wedge the watcher forever (OpenWorker's version has no timeout and can strand a run).
    static let defaultTimeout: TimeInterval = 30 * 60
    /// Resolved items are kept this long for the "what did it ask while I was away" recap.
    private let retention: TimeInterval = 7 * 24 * 3600

    @Published private(set) var items: [WatcherApprovalItem]

    /// Continuations of ticks currently suspended on an item id.
    private var waiters: [String: CheckedContinuation<WatcherApprovalItem, Never>] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
            let decoded = try? JSONDecoder().decode([WatcherApprovalItem].self, from: data)
        {
            // Anything left pending from a previous launch can never be answered by a live
            // waiter — surface it as timed out rather than pretending it's still actionable.
            items = decoded.map { item in
                guard item.isPending else { return item }
                var stale = item
                stale.state = WatcherApprovalItem.stateResolved
                stale.resolution = "timeout"
                stale.resolvedAt = Date()
                return stale
            }
        } else {
            items = []
        }
    }

    var pending: [WatcherApprovalItem] { items.filter { $0.isPending } }

    func item(id: String) -> WatcherApprovalItem? { items.first { $0.id == id } }

    /// Create (or reuse) a parked request. Idempotent by `actionKey`.
    @discardableResult
    func add(
        watcher: WatcherAgent, actionKey: String, action: WatcherAction, body: String,
        visibility: String
    ) -> WatcherApprovalItem {
        if let existing = items.first(where: { $0.actionKey == actionKey }) {
            return existing
        }
        var channel: String?
        var target: String?
        if case let .notifyChannel(ch, tgt, _) = action {
            channel = ch.rawValue
            target = tgt
        }
        let scope = WatcherScopeNote.text(for: action)
        let item = WatcherApprovalItem(
            id: "appr_\(UUID().uuidString.prefix(8))",
            watcherId: watcher.id,
            watcherName: watcher.name,
            actionKey: actionKey,
            kind: action.shortLabel,
            risk: action.riskClass,
            grantEntry: WatcherPermission.grantEntry(for: action),
            channel: channel,
            target: target,
            scopeNote: scope.text,
            body: body,
            editedBody: nil,
            state: WatcherApprovalItem.statePending,
            resolution: nil,
            visibility: visibility,
            createdAt: Date(),
            resolvedAt: nil
        )
        items.append(item)
        persist()
        return item
    }

    /// Resolve exactly once. Later attempts are no-ops and return false.
    @discardableResult
    func resolve(id: String, resolution: String, editedBody: String? = nil) -> Bool {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].isPending else {
            return false
        }
        if let editedBody, editedBody != items[idx].body {
            items[idx].editedBody = editedBody
        }
        items[idx].state = WatcherApprovalItem.stateResolved
        items[idx].resolution = resolution
        items[idx].resolvedAt = Date()
        let resolved = items[idx]
        persist()

        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: resolved)
        }
        return true
    }

    /// Save an edit without resolving (the settings inbox edits before approving).
    func updateDraft(id: String, editedBody: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].isPending else { return }
        items[idx].editedBody = editedBody
        persist()
    }

    /// Suspend until the item is resolved, or until `timeout` elapses (then auto-deny).
    func wait(id: String, timeout: TimeInterval = WatcherApprovalStore.defaultTimeout) async
        -> WatcherApprovalItem?
    {
        guard let current = item(id: id) else { return nil }
        if !current.isPending { return current }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { _ = self?.resolve(id: id, resolution: "timeout") }
        }
        let resolved = await withCheckedContinuation { (cont: CheckedContinuation<WatcherApprovalItem, Never>) in
            // Re-check inside the continuation: it may have been resolved between the guard
            // above and here.
            if let now = item(id: id), !now.isPending {
                cont.resume(returning: now)
                return
            }
            waiters[id] = cont
        }
        timeoutTask.cancel()
        return resolved
    }

    /// Items answered while the user was away, for the "here's what happened" recap.
    func recentlyResolved(limit: Int = 10) -> [WatcherApprovalItem] {
        Array(items.filter { !$0.isPending }.suffix(limit).reversed())
    }

    func clearResolved() {
        items.removeAll { !$0.isPending }
        persist()
    }

    private func persist() {
        // Drop old resolved items so the store can't grow forever.
        let cutoff = Date().addingTimeInterval(-retention)
        items.removeAll { !$0.isPending && ($0.resolvedAt ?? .distantPast) < cutoff }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
