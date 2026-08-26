import AppKit
import CoreGraphics
import Foundation

/// A running, plain-text record of what the user has been looking at.
///
/// Ported from cetus (`src-tauri/src/ambient.rs`, MIT). The port is worth it for one thing
/// omi cannot get any other way: **the actual URL**. OCR can tell you a page says "Sign
/// in"; it cannot tell you whose page it is, and it does not survive a redirect. The
/// address bar is structured truth.
///
/// The whole design is the tiered polling, and that is not an optimization — it is the
/// reason this can run all day where a screenshot-and-OCR loop cannot. Each accessibility
/// attribute read is a synchronous IPC round-trip into another process:
///
/// - Every 2s: a **cheap probe** — the frontmost app's identity (no IPC at all) plus the
///   focused window's title (two AX reads). This is what runs 99% of the time.
/// - Only when the probe *changed* — a different app, a different window, a switched tab —
///   or when 30s have passed in the same place: the bounded visible-text walk.
/// - Only on a changed tick, and only in a known browser: the AppleScript URL read. The
///   steady state never touches it, which matters because it spawns a process.
///
/// Content is hashed and an unchanged snapshot is dropped, so sitting still writes nothing,
/// and nothing is captured at all while the screen is idle.
///
/// Held in memory only, with a retention window. It is off by default; excluded apps come
/// from the same list that governs screen recording, so there is one place to say "not
/// this app" rather than two.
@MainActor
final class AmbientTextContext: ObservableObject {
    static let shared = AmbientTextContext()

    /// One reading of what was on screen.
    struct Entry: Identifiable {
        let id = UUID()
        let at: Date
        let app: String
        let windowTitle: String
        /// The page address, when the app was a browser and it answered.
        let url: String?
        let text: String
    }

    private let probeInterval: TimeInterval = 2
    /// How long the same app/window may go without a fresh reading. Covers the case the
    /// cheap probe is blind to: content changing under a title that doesn't.
    private let slowRefreshInterval: TimeInterval = 30
    /// No input for this long means whatever is on screen isn't being looked at.
    private let idleThreshold: TimeInterval = 90
    private let retention: TimeInterval = 30 * 60
    private let maxEntries = 120

    @Published private(set) var entries: [Entry] = []

    private var loop: Task<Void, Never>?
    private var lastProbeKey = ""
    private var lastCaptureAt: Date?
    private var lastContentHash = 0
    private var settingsObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    /// Start (or stop) the loop according to the setting, and keep following it.
    func start() {
        if settingsObserver == nil {
            settingsObserver = NotificationCenter.default.addObserver(
                forName: .assistantSettingsDidChange, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in AmbientTextContext.shared.applySetting() }
            }
        }
        applySetting()
    }

    private func applySetting() {
        if CopilotSettings.shared.ambientTextEnabled {
            guard loop == nil else { return }
            log("AmbientTextContext: starting (probe every \(Int(probeInterval))s)")
            let interval = UInt64(probeInterval * 1_000_000_000)
            loop = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: interval)
                    guard !Task.isCancelled else { return }
                    await AmbientTextContext.shared.tick()
                }
            }
        } else {
            guard loop != nil else { return }
            log("AmbientTextContext: stopping")
            loop?.cancel()
            loop = nil
            // Turning it off should not leave the last half hour sitting in memory.
            clear()
        }
    }

    /// Forget everything captured so far.
    func clear() {
        entries.removeAll()
        lastProbeKey = ""
        lastCaptureAt = nil
        lastContentHash = 0
    }

    // MARK: - The tiers

    private func tick() async {
        guard CopilotSettings.shared.ambientTextEnabled else { return }
        guard !isScreenIdle else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }

        let appName = app.localizedName ?? ""
        // The same exclusions that govern screen recording. One list, one mental model.
        guard !RewindSettings.shared.isAppExcluded(appName) else {
            lastProbeKey = ""
            return
        }

        // Tier 1 — the cheap probe. Two AX reads and no walk.
        let pid = app.processIdentifier
        ElectronAXWaker.wakeIfNeeded(app: app)
        let title = await Task.detached(priority: .utility) {
            AXVisibleText.focusedWindowTitle(pid: pid)
        }.value
        let probeKey = "\(app.bundleIdentifier ?? appName)|\(title ?? "")"
        let changed = probeKey != lastProbeKey
        let stale =
            lastCaptureAt.map { Date().timeIntervalSince($0) >= slowRefreshInterval } ?? true
        guard changed || stale else { return }
        lastProbeKey = probeKey

        // Tier 2 — the bounded walk, off the main actor.
        guard let result = await Task.detached(priority: .utility, operation: {
            AXVisibleText.capture(pid: pid)
        }).value else { return }
        lastCaptureAt = Date()

        // Tier 3 — the URL, only on a change and only in a browser. Never in steady state.
        var url: String?
        if changed, BrowserURL.isBrowser(bundleId: app.bundleIdentifier) {
            url = await BrowserURL.current(bundleId: app.bundleIdentifier)
        } else {
            url = entries.last.flatMap { $0.app == appName ? $0.url : nil }
        }

        // Dedupe on content, so staring at one page for an hour writes one entry.
        var hasher = Hasher()
        hasher.combine(result.text)
        hasher.combine(url)
        let contentHash = hasher.finalize()
        guard contentHash != lastContentHash else { return }
        lastContentHash = contentHash

        append(
            Entry(
                at: Date(), app: appName, windowTitle: result.windowTitle, url: url,
                text: result.text))
    }

    /// Asked one concrete event type at a time on purpose. CoreGraphics has an
    /// "any input event" sentinel, but its raw value has no case in the Swift-imported
    /// enum, so building it goes through a failable initializer that returns nil — and the
    /// obvious fallback silently reports "idle forever", which would switch this feature
    /// off with nothing to see. The minimum across the real types is exact and can't fail.
    private static let inputEventTypes: [CGEventType] = [
        .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .mouseMoved, .scrollWheel,
    ]

    private var isScreenIdle: Bool {
        let idle =
            Self.inputEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0
        return idle > idleThreshold
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        trim()
    }

    private func trim() {
        let cutoff = Date().addingTimeInterval(-retention)
        entries.removeAll { $0.at < cutoff }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    // MARK: - Consumption

    /// The recent readings as a prompt block, newest last, under `maxChars`.
    ///
    /// Kept separate from `recentOCR` rather than merged into it: OCR is noisy pixels and
    /// the model should discount it accordingly, while this is the app's own text and the
    /// URL is exact. Collapsing them would throw that distinction away.
    func promptBlock(maxChars: Int = 3000) -> String {
        trim()
        guard !entries.isEmpty else { return "" }
        var blocks: [String] = []
        var used = 0
        for entry in entries.reversed() {
            var header = "[\(entry.app)"
            if !entry.windowTitle.isEmpty { header += " — \(entry.windowTitle)" }
            header += "]"
            if let url = entry.url { header += "\n\(url)" }
            let block = "\(header)\n\(entry.text)"
            guard used + block.count <= maxChars else { break }
            used += block.count + 2
            blocks.append(block)
        }
        return blocks.reversed().joined(separator: "\n\n")
    }

    /// The URL of the page the user is on right now, if the most recent reading had one.
    var currentURL: String? {
        entries.last?.url
    }

    // MARK: - Debug (omi-ctl)

    func debugDump() -> [String: String] {
        trim()
        let withURL = entries.filter { $0.url != nil }.count
        return [
            "enabled": CopilotSettings.shared.ambientTextEnabled ? "true" : "false",
            "running": loop == nil ? "false" : "true",
            "entries": String(entries.count),
            "with_url": String(withURL),
            "latest_app": entries.last?.app ?? "-",
            "latest_url": entries.last?.url ?? "-",
            "chars": String(entries.reduce(0) { $0 + $1.text.count }),
        ]
    }
}
