import Foundation

/// Live Copilot settings stored in UserDefaults (same pattern as InsightAssistantSettings).
@MainActor
class CopilotSettings {
    static let shared = CopilotSettings()

    // MARK: - UserDefaults Keys

    private let enabledKey = "copilotLiveEnabled"
    private let scenarioIdKey = "copilotLiveScenarioId"
    private let examUnlockedKey = "copilotLiveExamUnlocked"
    private let adaptiveThresholdKey = "copilotLiveAdaptiveThreshold"
    private let autoSelectScenarioKey = "copilotLiveAutoSelectScenario"
    private let minConfidenceKey = "copilotLiveMinConfidence"
    private let suggestionCooldownKey = "copilotLiveSuggestionCooldown"
    private let maxPerSessionKey = "copilotLiveMaxSuggestionsPerSession"
    private let notesFolderPathKey = "copilotNotesFolderPath"
    private let notesRagEnabledKey = "copilotNotesRagEnabled"
    private let autoDetectMeetingsKey = "copilotAutoDetectMeetings"
    private let exportMeetingMarkdownKey = "copilotExportMeetingMarkdown"
    private let meetingPrepEnabledKey = "copilotMeetingPrepEnabled"
    private let styleMatchingEnabledKey = "copilotStyleMatchingEnabled"
    private let dossiersEnabledKey = "copilotDossiersEnabled"
    private let answerLanguageKey = "copilotAnswerLanguage"
    private let responseLengthKey = "copilotResponseLength"
    private let triggerPolicyKey = "copilotTriggerPolicy"
    private let insertModeKey = "copilotInsertMode"

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
            adaptiveThresholdKey: true,
            autoSelectScenarioKey: true,
            notesRagEnabledKey: true,
            autoDetectMeetingsKey: true,
            meetingPrepEnabledKey: true,
            styleMatchingEnabledKey: true,
            dossiersEnabledKey: true,
            answerLanguageKey: CopilotAnswerLanguage.auto.id,
            responseLengthKey: CopilotResponseLength.adaptive.rawValue,
            triggerPolicyKey: CopilotTriggerPolicy.auto.rawValue,
            insertModeKey: TextInsertion.InsertMode.type.rawValue,
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

    /// Whether the ethically-sensitive exam/study profile is unlocked. Off by default;
    /// the user must explicitly enable it (with an ethics note) in Settings.
    var examProfileUnlocked: Bool {
        get { UserDefaults.standard.bool(forKey: examUnlockedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: examUnlockedKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Profiles to show in the picker (built-ins, exam only when unlocked, plus custom).
    var availableScenarios: [CopilotScenarioProfile] {
        CopilotScenarioProfile.allAvailable
    }

    /// Whether the copilot adapts its confidence threshold from your feedback (dismiss/accept).
    var adaptiveThresholdEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: adaptiveThresholdKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: adaptiveThresholdKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether the scenario profile is auto-selected from the calendar at session start.
    var autoSelectScenario: Bool {
        get { UserDefaults.standard.bool(forKey: autoSelectScenarioKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: autoSelectScenarioKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
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

    /// Notes folder indexed for live retrieval (Obsidian vault / any .md/.txt directory).
    /// nil = feature not configured.
    var notesFolderPath: String? {
        get {
            let value = UserDefaults.standard.string(forKey: notesFolderPathKey)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set {
            UserDefaults.standard.set(newValue ?? "", forKey: notesFolderPathKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether the live copilot retrieves from the notes folder (only effective once
    /// a folder is configured).
    var notesRagEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: notesRagEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: notesRagEnabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// True when notes retrieval is both enabled and configured.
    var notesRagActive: Bool {
        notesRagEnabled && notesFolderPath != nil
    }

    /// Whether to watch for conferencing calls while idle and offer to start the copilot.
    var autoDetectMeetings: Bool {
        get { UserDefaults.standard.bool(forKey: autoDetectMeetingsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: autoDetectMeetingsKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether talk tracks are rewritten to sound like the user (learned from their own
    /// spoken lines in past meetings).
    var styleMatchingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: styleMatchingEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: styleMatchingEnabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Which language the copilot answers in. Defaults to following the conversation.
    var answerLanguage: CopilotAnswerLanguage {
        get {
            CopilotAnswerLanguage.byId(
                UserDefaults.standard.string(forKey: answerLanguageKey) ?? CopilotAnswerLanguage.auto.id)
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: answerLanguageKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// How long an answer should be.
    var responseLength: CopilotResponseLength {
        get {
            CopilotResponseLength(
                rawValue: UserDefaults.standard.string(forKey: responseLengthKey) ?? "") ?? .adaptive
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: responseLengthKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// When the live copilot is allowed to speak up on its own.
    var triggerPolicy: CopilotTriggerPolicy {
        get {
            CopilotTriggerPolicy(
                rawValue: UserDefaults.standard.string(forKey: triggerPolicyKey) ?? "") ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: triggerPolicyKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// How "Insert" puts text into the app you were typing in. Typing is the default
    /// because it never touches the clipboard; pasting exists for terminals and the
    /// Electron builds that ignore synthetic Unicode keystrokes.
    var insertMode: TextInsertion.InsertMode {
        get {
            TextInsertion.InsertMode(
                rawValue: UserDefaults.standard.string(forKey: insertModeKey) ?? "") ?? .type
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: insertModeKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether omi keeps entity files (people, orgs, projects, topics) from your meetings.
    var dossiersEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: dossiersEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: dossiersEnabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether a brief is surfaced before meetings with people you have notes on.
    var meetingPrepEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: meetingPrepEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: meetingPrepEnabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether each finished session is also exported as a markdown file
    /// (minutes + timestamped transcript) under ~/Documents/Omi/Meetings.
    var exportMeetingMarkdown: Bool {
        get { UserDefaults.standard.bool(forKey: exportMeetingMarkdownKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: exportMeetingMarkdownKey)
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
