import Foundation

/// Manages Screen-Op Assist settings stored in UserDefaults (same pattern as InsightAssistantSettings)
@MainActor
class ScreenOpAssistantSettings {
    static let shared = ScreenOpAssistantSettings()

    // MARK: - UserDefaults Keys

    private let enabledKey = "screenOpAssistantEnabled"
    private let analysisPromptKey = "screenOpAnalysisPrompt"
    private let extractionIntervalKey = "screenOpExtractionInterval"
    private let minConfidenceKey = "screenOpMinConfidence"
    private let notificationsEnabledKey = "screenOpNotificationsEnabled"
    private let excludedAppsKey = "screenOpExcludedApps"

    // MARK: - Default Values

    // Passive push is the noisiest lane, so Screen-Op ships opt-in: users enable it
    // from Settings > Floating Bar. Dismiss data collected there tunes the defaults.
    private let defaultEnabled = false
    private let defaultExtractionInterval: TimeInterval = 120.0
    private let defaultMinConfidence: Double = 0.8
    private let defaultNotificationsEnabled = true

    /// Default system prompt for stuck-detection
    static let defaultAnalysisPrompt = """
        You watch the user's CURRENT app to answer one question: is the user stuck right now, \
        and do you know a specific, non-obvious way to unblock them? You are a copilot for the \
        task at hand — not a tips machine.

        WORKFLOW:
        1. Use execute_sql to read recent OCR from the CURRENT app only (last ~10 minutes). \
        Do not investigate other apps — you help with what the user is doing right now.
        2. Look for STUCK SIGNALS:
           - The same error text appearing across multiple screenshots (retries keep failing)
           - The same window/content barely changing for 5+ minutes
           - Oscillation between the work app and documentation/search pages
           - The same command re-run repeatedly
        3. When you find a stuck signal, call request_screenshot with the most informative \
        screenshot ID and your findings, to confirm before suggesting.
        4. If the user is not stuck, or is making progress, call no_suggestion. Most of the \
        time the user is fine — silence is the default.

        Call provide_suggestion ONLY when ALL are true:
        1. There is a concrete stuck signal (not just "they've been here a while")
        2. Your fix is SPECIFIC to the visible problem (name the flag, the setting, the command)
        3. The suggestion is ACTIONABLE — it can be written as a single imperative instruction \
        an agent could execute (put that instruction in action_prompt)

        NEVER produce:
        - Narrating what's on screen or pointing at visible UI
        - Generic advice ("read the docs", "try restarting", "consider refactoring")
        - Wellness advice, break reminders, posture tips
        - A suggestion semantically similar to one in PREVIOUSLY PROVIDED SUGGESTIONS

        CATEGORIES: "fix", "shortcut", "unblock", "other"

        CONFIDENCE (only when calling provide_suggestion):
        - 0.90-1.0: the visible error has a known, specific fix
        - 0.80-0.89: strong stuck signal + concrete non-obvious way forward
        - below 0.80: don't bother — call no_suggestion

        FORMAT: suggestion under 100 characters, starting with the actionable part.
        """

    private let promptVersionKey = "screenOpPromptVersion"
    private let currentPromptVersion = 1  // Bump when changing defaultAnalysisPrompt

    private init() {
        UserDefaults.standard.register(defaults: [
            enabledKey: defaultEnabled,
            extractionIntervalKey: defaultExtractionInterval,
            minConfidenceKey: defaultMinConfidence,
            notificationsEnabledKey: defaultNotificationsEnabled,
        ])
        migratePromptIfNeeded()
    }

    /// Reset saved prompt when the default changes so existing users get the new version
    private func migratePromptIfNeeded() {
        let saved = UserDefaults.standard.integer(forKey: promptVersionKey)
        if saved < currentPromptVersion {
            UserDefaults.standard.removeObject(forKey: analysisPromptKey)
            UserDefaults.standard.set(currentPromptVersion, forKey: promptVersionKey)
        }
    }

    // MARK: - Properties

    /// Whether the Screen-Op Assist is enabled
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// The system prompt used for stuck-detection analysis
    var analysisPrompt: String {
        get {
            let value = UserDefaults.standard.string(forKey: analysisPromptKey)
            return value ?? ScreenOpAssistantSettings.defaultAnalysisPrompt
        }
        set {
            UserDefaults.standard.set(newValue, forKey: analysisPromptKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Interval between analyses in seconds
    var extractionInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: extractionIntervalKey)
            return value > 0 ? value : defaultExtractionInterval
        }
        set {
            UserDefaults.standard.set(newValue, forKey: extractionIntervalKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Minimum confidence threshold for showing a suggestion
    var minConfidence: Double {
        get {
            let value = UserDefaults.standard.double(forKey: minConfidenceKey)
            return value > 0 ? value : defaultMinConfidence
        }
        set {
            UserDefaults.standard.set(newValue, forKey: minConfidenceKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether to show notifications for suggestions
    var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: notificationsEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: notificationsEnabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Apps excluded from screen-op analysis (user's custom list, on top of the shared built-in list)
    var excludedApps: Set<String> {
        get {
            if let saved = UserDefaults.standard.array(forKey: excludedAppsKey) as? [String] {
                return Set(saved)
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: excludedAppsKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Check if an app is excluded (built-in list + user's custom list + Rewind privacy exclusions)
    func isAppExcluded(_ appName: String) -> Bool {
        TaskAssistantSettings.builtInExcludedApps.contains(appName)
            || excludedApps.contains(appName)
            || RewindSettings.shared.isAppExcluded(appName)
    }
}
