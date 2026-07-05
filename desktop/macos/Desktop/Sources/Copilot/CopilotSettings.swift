import Foundation

/// Live Copilot settings stored in UserDefaults (same pattern as InsightAssistantSettings).
@MainActor
class CopilotSettings {
    static let shared = CopilotSettings()

    // MARK: - UserDefaults Keys

    private let enabledKey = "copilotLiveEnabled"
    private let scenarioIdKey = "copilotLiveScenarioId"
    private let minConfidenceKey = "copilotLiveMinConfidence"
    private let suggestionCooldownKey = "copilotLiveSuggestionCooldown"
    private let maxPerSessionKey = "copilotLiveMaxSuggestionsPerSession"

    // MARK: - Default Values

    private let defaultEnabled = true
    private let defaultScenarioId = "meeting"
    private let defaultMinConfidence: Double = 0.75
    private let defaultSuggestionCooldown: TimeInterval = 90
    private let defaultMaxPerSession = 12

    private init() {
        UserDefaults.standard.register(defaults: [
            enabledKey: defaultEnabled,
            scenarioIdKey: defaultScenarioId,
            minConfidenceKey: defaultMinConfidence,
            suggestionCooldownKey: defaultSuggestionCooldown,
            maxPerSessionKey: defaultMaxPerSession,
        ])
    }

    // MARK: - Properties

    /// Whether the live copilot runs during recording sessions
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Active scenario profile id (see CopilotScenarioProfile.all)
    var scenarioId: String {
        get { UserDefaults.standard.string(forKey: scenarioIdKey) ?? defaultScenarioId }
        set {
            UserDefaults.standard.set(newValue, forKey: scenarioIdKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    var scenario: CopilotScenarioProfile {
        CopilotScenarioProfile.byId(scenarioId)
    }

    /// Minimum confidence for showing a live suggestion
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

    /// Minimum seconds between two shown suggestions
    var suggestionCooldown: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: suggestionCooldownKey)
            return value > 0 ? value : defaultSuggestionCooldown
        }
        set {
            UserDefaults.standard.set(newValue, forKey: suggestionCooldownKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Hard cap on suggestions per recording session
    var maxSuggestionsPerSession: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: maxPerSessionKey)
            return value > 0 ? value : defaultMaxPerSession
        }
        set {
            UserDefaults.standard.set(newValue, forKey: maxPerSessionKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }
}
