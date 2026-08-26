import AppKit
import ApplicationServices

/// Wakes up Electron apps' accessibility trees.
///
/// Ported from cetus (`src-tauri/src/ax.rs`, MIT).
///
/// Chromium-based apps (Slack, Discord, Lark/飞书, VS Code, Notion…) skip building their
/// AX tree until an assistive client announces itself, so a plain `AXFocusedUIElement`
/// read returns nothing. Without this step, reading the focused field silently fails in
/// exactly the apps people write in — which reads as "the feature doesn't work" rather
/// than "the tree wasn't built".
///
/// Two flags, because one isn't enough:
/// - `AXManualAccessibility` is what Electron documents for a third-party app to force
///   the tree on.
/// - `AXEnhancedUserInterface` is needed by editors that expose text only after the
///   assistive-client signal (notably VS Code/Monaco), and covers Electron builds
///   affected by electron#37465 that reject the manual flag.
///
/// **Only apps that actually ship `Electron Framework.framework` are touched.**
/// `AXEnhancedUserInterface` doubles as the "VoiceOver is running" signal, and setting it
/// on arbitrary native apps is known to change their behaviour (window-manager resize
/// glitches and similar).
@MainActor
enum ElectronAXWaker {
    /// pids already woken. The flags live in the target process, so they die with it —
    /// a relaunched app gets a new pid and is woken again on its own.
    private static var wokenPIDs: Set<pid_t> = []
    /// Apps checked for the Electron framework, so the filesystem probe runs once each.
    private static var electronByBundle: [String: Bool] = [:]

    /// Set the flags if `app` is Electron and hasn't been woken yet.
    ///
    /// The tree builds asynchronously after the flag lands, so a read issued in the same
    /// instant may still come back empty. Callers that can afford it should read again a
    /// moment later; the correction re-reads at +1.2s and +10s are well past this.
    static func wakeIfNeeded(app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, !wokenPIDs.contains(pid) else { return }
        guard isElectron(app) else {
            // Remember non-Electron apps too, so we don't re-probe the bundle every read.
            wokenPIDs.insert(pid)
            return
        }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        wokenPIDs.insert(pid)
        log("ElectronAXWaker: woke accessibility tree for \(app.localizedName ?? "pid \(pid)")")
    }

    /// Forget a pid so a relaunched app is woken again.
    static func forget(pid: pid_t) {
        wokenPIDs.remove(pid)
    }

    /// True when the bundle actually contains the Electron framework. This is the guard
    /// that keeps the enhanced-UI flag away from native apps.
    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let bundleId = app.bundleIdentifier else { return false }
        if let cached = electronByBundle[bundleId] { return cached }
        guard let bundleURL = app.bundleURL else {
            electronByBundle[bundleId] = false
            return false
        }
        let framework = bundleURL
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        let found = FileManager.default.fileExists(atPath: framework.path)
        electronByBundle[bundleId] = found
        return found
    }
}
