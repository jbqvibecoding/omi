import AppKit

/// Stealth window helpers for the copilot HUD.
///
/// `sharingType = .none` is the macOS equivalent of Electron's
/// `setContentProtection(true)` (used by glass / cheating-daddy): the window is
/// excluded from screen recordings, screenshots, and screen-sharing — so the
/// copilot's suggestions stay visible to the user but never appear on a shared
/// screen or in a recording. This is the core "invisible copilot" property for
/// meeting / interview / presentation scenarios.
///
/// Click-through (`ignoresMouseEvents`) lets the HUD float over content the user
/// is presenting without intercepting clicks.
enum StealthWindowController {

    /// Apply (or remove) content protection so the window is hidden from capture.
    static func applyContentProtection(_ window: NSWindow, enabled: Bool) {
        // .none = excluded from capture; .readOnly = normal (capturable) default.
        window.sharingType = enabled ? .none : .readOnly
    }

    /// Toggle click-through: when enabled, mouse events pass through to whatever is beneath.
    static func applyClickThrough(_ window: NSWindow, enabled: Bool) {
        window.ignoresMouseEvents = enabled
    }

    /// Apply the user's current stealth preference to a window. Called at window
    /// setup and whenever the setting changes.
    @MainActor
    static func applyCurrentStealthPreference(to window: NSWindow) {
        applyContentProtection(window, enabled: ShortcutSettings.shared.stealthModeEnabled)
    }
}
