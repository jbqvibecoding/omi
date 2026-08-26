import Carbon
import Cocoa

/// Persistent settings for keyboard shortcuts.
@MainActor
class ShortcutSettings: ObservableObject {
    static let shared = ShortcutSettings()

    /// Notification posted when the Ask Omi shortcut changes so hotkeys can be re-registered.
    nonisolated static let askOmiShortcutChanged = Notification.Name("ShortcutSettings.askOmiShortcutChanged")

    /// Notification posted when the Copilot Snap shortcut changes so hotkeys can be re-registered.
    nonisolated static let copilotShortcutChanged = Notification.Name("ShortcutSettings.copilotShortcutChanged")

    /// Notification posted when the click-through shortcut changes so hotkeys can be re-registered.
    nonisolated static let clickThroughShortcutChanged = Notification.Name("ShortcutSettings.clickThroughShortcutChanged")
    nonisolated static let suggestNowShortcutChanged = Notification.Name("ShortcutSettings.suggestNowShortcutChanged")
    nonisolated static let snapRegionShortcutChanged = Notification.Name("ShortcutSettings.snapRegionShortcutChanged")
    nonisolated static let quickReplyShortcutChanged = Notification.Name("ShortcutSettings.quickReplyShortcutChanged")

    /// Notification posted when stealth mode is toggled so windows can refresh content protection.
    nonisolated static let stealthModeChanged = Notification.Name("ShortcutSettings.stealthModeChanged")

    struct KeyboardShortcut: Codable, Hashable {
        var keyCode: UInt16?
        var keyDisplay: String?
        var modifiersRawValue: UInt
        var modifierOnly: Bool
        var requiresRightCommand: Bool

        private static let supportedModifierMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control, .function]

        init(keyCode: UInt16, keyDisplay: String, modifiers: NSEvent.ModifierFlags = []) {
            self.keyCode = keyCode
            self.keyDisplay = keyDisplay
            self.modifiersRawValue = Self.normalizedModifiers(modifiers).rawValue
            self.modifierOnly = false
            self.requiresRightCommand = false
        }

        init(modifierOnly modifiers: NSEvent.ModifierFlags, requiresRightCommand: Bool = false) {
            let normalized = Self.normalizedModifiers(modifiers)
            self.keyCode = nil
            self.keyDisplay = nil
            self.modifiersRawValue = normalized.rawValue
            self.modifierOnly = true
            self.requiresRightCommand = requiresRightCommand && normalized == [.command]
        }

        var modifiers: NSEvent.ModifierFlags {
            Self.normalizedModifiers(NSEvent.ModifierFlags(rawValue: modifiersRawValue))
        }

        var supportsGlobalHotKey: Bool {
            !modifierOnly && keyCode != nil
        }

        var displayTokens: [String] {
            let modifierTokens = Self.modifierTokens(for: modifiers)
            if modifierOnly {
                if requiresRightCommand {
                    return ["Right ⌘"]
                }
                return modifierTokens
            }
            if let keyDisplay {
                return modifierTokens + [keyDisplay]
            }
            return modifierTokens
        }

        var displayLabel: String {
            if modifierOnly {
                if requiresRightCommand {
                    return "Right Cmd"
                }
                switch modifiers {
                case [.option]:
                    return "Option"
                case [.function]:
                    return "Fn"
                case [.command]:
                    return "Command"
                case [.control]:
                    return "Control"
                case [.shift]:
                    return "Shift"
                default:
                    return displayTokens.joined(separator: " ")
                }
            }
            return displayTokens.joined(separator: " ")
        }

        var promptLabel: String {
            if modifierOnly {
                if requiresRightCommand {
                    return "right cmd"
                }
                switch modifiers {
                case [.option]:
                    return "option"
                case [.function]:
                    return "fn"
                case [.command]:
                    return "command"
                case [.control]:
                    return "control"
                case [.shift]:
                    return "shift"
                default:
                    return displayLabel.lowercased()
                }
            }
            return displayLabel.lowercased()
        }

        var carbonModifiers: Int {
            var value = 0
            if modifiers.contains(.command) {
                value |= Int(cmdKey)
            }
            if modifiers.contains(.shift) {
                value |= Int(shiftKey)
            }
            if modifiers.contains(.option) {
                value |= Int(optionKey)
            }
            if modifiers.contains(.control) {
                value |= Int(controlKey)
            }
            if modifiers.contains(.function) {
                value |= Int(kEventKeyModifierFnMask)
            }
            return value
        }

        func matchesKeyDown(_ event: NSEvent) -> Bool {
            guard !modifierOnly, event.type == .keyDown, let keyCode else { return false }
            return keyCode == event.keyCode && Self.normalizedModifiers(event.modifierFlags) == modifiers
        }

        func matchesKeyUp(_ event: NSEvent) -> Bool {
            guard !modifierOnly, event.type == .keyUp, let keyCode else { return false }
            return keyCode == event.keyCode && Self.normalizedModifiers(event.modifierFlags) == modifiers
        }

        func matchesFlagsChanged(_ event: NSEvent) -> Bool {
            guard modifierOnly, event.type == .flagsChanged else { return false }
            let activeModifiers = Self.normalizedModifiers(event.modifierFlags)
            guard activeModifiers == modifiers else { return false }
            if requiresRightCommand {
                return event.keyCode == 54
            }
            return true
        }

        static func fromRecordingEvent(_ event: NSEvent, allowModifierOnly: Bool) -> KeyboardShortcut? {
            switch event.type {
            case .keyDown:
                return KeyboardShortcut(
                    keyCode: event.keyCode,
                    keyDisplay: keyDisplay(for: event.keyCode, characters: event.charactersIgnoringModifiers),
                    modifiers: normalizedModifiers(event.modifierFlags)
                )
            case .flagsChanged:
                guard allowModifierOnly else { return nil }
                let modifiers = normalizedModifiers(event.modifierFlags)
                guard !modifiers.isEmpty else { return nil }
                return KeyboardShortcut(
                    modifierOnly: modifiers,
                    requiresRightCommand: modifiers == [.command] && event.keyCode == 54
                )
            default:
                return nil
            }
        }

        static func normalizedModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
            flags.intersection(supportedModifierMask)
        }

        static func modifierTokens(for flags: NSEvent.ModifierFlags) -> [String] {
            var tokens: [String] = []
            if flags.contains(.control) {
                tokens.append("⌃")
            }
            if flags.contains(.option) {
                tokens.append("⌥")
            }
            if flags.contains(.shift) {
                tokens.append("⇧")
            }
            if flags.contains(.command) {
                tokens.append("⌘")
            }
            if flags.contains(.function) {
                tokens.append("fn")
            }
            return tokens
        }

        static func keyDisplay(for keyCode: UInt16, characters: String?) -> String {
            switch keyCode {
            case 36:
                return "↩"
            case 48:
                return "Tab"
            case 49:
                return "Space"
            case 51:
                return "⌫"
            case 53:
                return "Esc"
            case 71:
                return "⌧"
            case 76:
                return "Enter"
            case 96:
                return "F5"
            case 97:
                return "F6"
            case 98:
                return "F7"
            case 99:
                return "F3"
            case 100:
                return "F8"
            case 101:
                return "F9"
            case 103:
                return "F11"
            case 105:
                return "F13"
            case 106:
                return "F16"
            case 107:
                return "F14"
            case 109:
                return "F10"
            case 111:
                return "F12"
            case 113:
                return "F15"
            case 114:
                return "Help"
            case 115:
                return "Home"
            case 116:
                return "PgUp"
            case 117:
                return "⌦"
            case 118:
                return "F4"
            case 119:
                return "End"
            case 120:
                return "F2"
            case 121:
                return "PgDn"
            case 122:
                return "F1"
            case 123:
                return "←"
            case 124:
                return "→"
            case 125:
                return "↓"
            case 126:
                return "↑"
            default:
                if let characters {
                    let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed.uppercased()
                    }
                }
                return "Key \(keyCode)"
            }
        }
    }

    static let askOmiCommandOShortcut = KeyboardShortcut(keyCode: 31, keyDisplay: "O", modifiers: .command)
    static let askOmiCommandReturnShortcut = KeyboardShortcut(keyCode: 36, keyDisplay: "↩", modifiers: .command)
    static let askOmiCommandShiftReturnShortcut = KeyboardShortcut(
        keyCode: 36,
        keyDisplay: "↩",
        modifiers: [.command, .shift]
    )
    static let askOmiCommandJShortcut = KeyboardShortcut(keyCode: 38, keyDisplay: "J", modifiers: .command)
    static let defaultAskOmiShortcut = askOmiCommandOShortcut

    // Copilot Snap presets. Default is ⌃↩ — ⌥↩ stays available as a preset, but
    // option-based combos conflict with the default hold-⌥ push-to-talk shortcut,
    // so it is not the default.
    static let copilotControlReturnShortcut = KeyboardShortcut(keyCode: 36, keyDisplay: "↩", modifiers: .control)
    static let copilotOptionReturnShortcut = KeyboardShortcut(keyCode: 36, keyDisplay: "↩", modifiers: .option)
    static let defaultCopilotShortcut = copilotControlReturnShortcut

    static let copilotPresets: [KeyboardShortcut] = [
        copilotControlReturnShortcut,
        askOmiCommandShiftReturnShortcut,
        copilotOptionReturnShortcut,
    ]

    // "Suggest now" — ask the live copilot for a suggestion mid-conversation. ⌃⇧↩ sits
    // next to the copilot key so the two read as one family under the same thumb.
    static let suggestNowShortcut = KeyboardShortcut(
        keyCode: 36, keyDisplay: "↩", modifiers: [.control, .shift])
    static let defaultSuggestNowShortcut = suggestNowShortcut

    // Snap a selected region instead of the whole screen. ⌥⌃↩ keeps it in the copilot
    // family — same Return key, one extra modifier for "let me pick the part".
    static let snapRegionShortcut = KeyboardShortcut(
        keyCode: 36, keyDisplay: "↩", modifiers: [.control, .option])
    static let defaultSnapRegionShortcut = snapRegionShortcut

    // Quick Reply — draft the message you're about to type. ⌃⌥R, deliberately NOT cetus's
    // double-tap right ⌥: omi's push-to-talk default is hold-⌥, and a double-tap on the
    // same key would fight it every time.
    static let quickReplyShortcut = KeyboardShortcut(
        keyCode: 15, keyDisplay: "R", modifiers: [.control, .option])
    static let defaultQuickReplyShortcut = quickReplyShortcut

    // Click-through toggle (default ⌘M, matching cheating-daddy/glass Cmd+M convention).
    static let clickThroughCommandMShortcut = KeyboardShortcut(keyCode: 46, keyDisplay: "M", modifiers: .command)
    static let defaultClickThroughShortcut = clickThroughCommandMShortcut

    static let askOmiPresets: [KeyboardShortcut] = [
        askOmiCommandOShortcut,
        askOmiCommandReturnShortcut,
        askOmiCommandShiftReturnShortcut,
        askOmiCommandJShortcut,
    ]

    static let pttPresets: [KeyboardShortcut] = [
        KeyboardShortcut(modifierOnly: .option),
        KeyboardShortcut(modifierOnly: .command, requiresRightCommand: true),
        KeyboardShortcut(modifierOnly: .function),
        KeyboardShortcut(modifierOnly: .control),
    ]

    @Published var pttShortcut: KeyboardShortcut {
        didSet {
            persistShortcut(pttShortcut, forKey: Self.pttShortcutDefaultsKey)
        }
    }

    @Published var askOmiShortcut: KeyboardShortcut {
        didSet {
            persistShortcut(askOmiShortcut, forKey: Self.askOmiShortcutDefaultsKey)
            NotificationCenter.default.post(name: Self.askOmiShortcutChanged, object: nil)
        }
    }

    @Published var askOmiEnabled: Bool {
        didSet {
            UserDefaults.standard.set(askOmiEnabled, forKey: "shortcut_askOmiEnabled")
            NotificationCenter.default.post(name: Self.askOmiShortcutChanged, object: nil)
        }
    }

    @Published var copilotShortcut: KeyboardShortcut {
        didSet {
            persistShortcut(copilotShortcut, forKey: Self.copilotShortcutDefaultsKey)
            NotificationCenter.default.post(name: Self.copilotShortcutChanged, object: nil)
        }
    }

    @Published var copilotEnabled: Bool {
        didSet {
            UserDefaults.standard.set(copilotEnabled, forKey: "shortcut_copilotEnabled")
            NotificationCenter.default.post(name: Self.copilotShortcutChanged, object: nil)
        }
    }

    /// Ask the live copilot for a suggestion on demand, mid-conversation.
    @Published var suggestNowShortcut: KeyboardShortcut {
        didSet {
            persistShortcut(suggestNowShortcut, forKey: Self.suggestNowShortcutDefaultsKey)
            NotificationCenter.default.post(name: Self.suggestNowShortcutChanged, object: nil)
        }
    }

    @Published var suggestNowEnabled: Bool {
        didSet {
            UserDefaults.standard.set(suggestNowEnabled, forKey: "shortcut_suggestNowEnabled")
            NotificationCenter.default.post(name: Self.suggestNowShortcutChanged, object: nil)
        }
    }

    /// Drag out a region and snap only that.
    @Published var snapRegionShortcut: KeyboardShortcut {
        didSet {
            persistShortcut(snapRegionShortcut, forKey: Self.snapRegionShortcutDefaultsKey)
            NotificationCenter.default.post(name: Self.snapRegionShortcutChanged, object: nil)
        }
    }

    @Published var snapRegionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(snapRegionEnabled, forKey: "shortcut_snapRegionEnabled")
            NotificationCenter.default.post(name: Self.snapRegionShortcutChanged, object: nil)
        }
    }

    /// Draft a reply into whatever text field is focused.
    @Published var quickReplyShortcut: KeyboardShortcut {
        didSet {
            persistShortcut(quickReplyShortcut, forKey: Self.quickReplyShortcutDefaultsKey)
            NotificationCenter.default.post(name: Self.quickReplyShortcutChanged, object: nil)
        }
    }

    @Published var quickReplyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(quickReplyEnabled, forKey: "shortcut_quickReplyEnabled")
            NotificationCenter.default.post(name: Self.quickReplyShortcutChanged, object: nil)
        }
    }

    /// When true, the copilot HUD is hidden from screen recordings, screenshots, and
    /// screen sharing (NSWindow.sharingType = .none) — the "invisible copilot" property.
    @Published var stealthModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(stealthModeEnabled, forKey: "shortcut_stealthModeEnabled")
            NotificationCenter.default.post(name: Self.stealthModeChanged, object: nil)
        }
    }

    @Published var clickThroughShortcut: KeyboardShortcut {
        didSet {
            persistShortcut(clickThroughShortcut, forKey: Self.clickThroughShortcutDefaultsKey)
            NotificationCenter.default.post(name: Self.clickThroughShortcutChanged, object: nil)
        }
    }

    @Published var clickThroughEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clickThroughEnabled, forKey: "shortcut_clickThroughEnabled")
            NotificationCenter.default.post(name: Self.clickThroughShortcutChanged, object: nil)
        }
    }

    @Published var pttEnabled: Bool {
        didSet { UserDefaults.standard.set(pttEnabled, forKey: "shortcut_pttEnabled") }
    }

    @Published var doubleTapForLock: Bool {
        didSet { UserDefaults.standard.set(doubleTapForLock, forKey: "shortcut_doubleTapForLock") }
    }

    /// When true, the floating bar uses a solid dark background instead of semi-transparent blur.
    @Published var solidBackground: Bool {
        didSet { UserDefaults.standard.set(solidBackground, forKey: "shortcut_solidBackground") }
    }

    /// When true, push-to-talk plays start/end sounds.
    @Published var pttSoundsEnabled: Bool {
        didSet { UserDefaults.standard.set(pttSoundsEnabled, forKey: "shortcut_pttSoundsEnabled") }
    }

    /// When true, holding push-to-talk mutes any audio playing on the default output
    /// device (e.g. music) for the duration of dictation, then restores it on release —
    /// like Wispr Flow. The track keeps playing silently rather than being paused.
    @Published var pttMuteSystemAudio: Bool {
        didSet { UserDefaults.standard.set(pttMuteSystemAudio, forKey: "shortcut_pttMuteSystemAudio") }
    }

    /// Selected AI model for Ask Omi.
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "shortcut_selectedModel") }
    }

    /// Available models for Ask Omi (driven by QoS tier).
    static var availableModels: [(id: String, label: String)] { ModelQoS.Claude.availableModels }

    /// Push-to-talk transcription mode.
    enum PTTTranscriptionMode: String, CaseIterable {
        case live = "Live"
        case batch = "Batch"

        var description: String {
            switch self {
            case .live: return "Real-time transcription as you speak"
            case .batch: return "Transcribe after recording for better accuracy"
            }
        }
    }

    @Published var pttTranscriptionMode: PTTTranscriptionMode {
        didSet { UserDefaults.standard.set(pttTranscriptionMode.rawValue, forKey: "shortcut_pttTranscriptionMode") }
    }

    /// When true, the floating bar can be repositioned by dragging. Off by default.
    @Published var draggableBarEnabled: Bool {
        didSet { UserDefaults.standard.set(draggableBarEnabled, forKey: "shortcut_draggableBarEnabled") }
    }

    /// Push-to-talk replies are always spoken aloud.
    let floatingBarVoiceAnswersEnabled: Bool = true

    /// When true, typed floating-bar questions receive spoken replies.
    @Published var floatingBarTypedQuestionVoiceAnswersEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                floatingBarTypedQuestionVoiceAnswersEnabled,
                forKey: "shortcut_floatingBarTypedQuestionVoiceAnswersEnabled"
            )
            if !hasAnyFloatingBarVoiceAnswersEnabled {
                FloatingBarVoicePlaybackService.shared.stop()
            }
        }
    }

    /// Voice playback speed (0.8x – 2.0x). Default 1.4x.
    @Published var voicePlaybackSpeed: Float {
        didSet {
            UserDefaults.standard.set(voicePlaybackSpeed, forKey: "shortcut_voicePlaybackSpeed")
        }
    }

    /// Speed presets for the voice speed slider (6 steps).
    static let voiceSpeedSteps: [Float] = [0.8, 1.0, 1.2, 1.4, 1.6, 2.0]

    static func voiceSpeedLabel(for speed: Float) -> String {
        if speed <= 0.8 { return "Slow" }
        if speed <= 1.0 { return "Normal" }
        if speed <= 1.2 { return "Fast" }
        if speed <= 1.4 { return "Faster" }
        if speed <= 1.6 { return "Very Fast" }
        return "Maximum"
    }

    /// A selectable voice for floating-bar replies.
    struct VoiceOption: Identifiable, Equatable, Sendable {
        enum Gender: String, Sendable {
            case female
            case male
        }

        enum Provider: String, Sendable {
            case localSystem
            case openAI
        }

        let id: String
        let name: String
        let gender: Gender
        let description: String
        let provider: Provider
        let openAIVoice: String?
        let openAIInstructions: String?
        let preferredSystemVoiceIdentifiers: [String]
        let preferredSystemVoiceNames: [String]

        var isLocalSystem: Bool {
            provider == .localSystem
        }

        var isOpenAI: Bool {
            provider == .openAI
        }
    }

    static let openAIShimmerVoiceID = "openai:shimmer"
    static let openAIOnyxVoiceID = "openai:onyx"

    /// Curated OpenAI voices available from the voice picker.
    static let availableVoices: [VoiceOption] = [
        VoiceOption(
            id: openAIOnyxVoiceID,
            name: "Onyx",
            gender: .male,
            description: "OpenAI, deep, grounded",
            provider: .openAI,
            openAIVoice: "onyx",
            openAIInstructions:
                "Speak in a deep, natural, grounded voice with calm confidence and smooth pacing.",
            preferredSystemVoiceIdentifiers: [],
            preferredSystemVoiceNames: []
        ),
        VoiceOption(
            id: openAIShimmerVoiceID,
            name: "Shimmer",
            gender: .female,
            description: "OpenAI, warm human, cheap",
            provider: .openAI,
            openAIVoice: "shimmer",
            openAIInstructions:
                "Speak naturally in a warm, relaxed adult tone. Keep it conversational, calm, and human without sounding exaggerated.",
            preferredSystemVoiceIdentifiers: [],
            preferredSystemVoiceNames: []
        ),
        VoiceOption(
            id: "openai:coral",
            name: "Coral",
            gender: .female,
            description: "OpenAI, bright, expressive",
            provider: .openAI,
            openAIVoice: "coral",
            openAIInstructions:
                "Speak naturally in a warm, expressive human tone with smooth pacing and light emotional color.",
            preferredSystemVoiceIdentifiers: [],
            preferredSystemVoiceNames: []
        ),
        VoiceOption(
            id: "openai:nova",
            name: "Nova",
            gender: .female,
            description: "OpenAI, clear, friendly",
            provider: .openAI,
            openAIVoice: "nova",
            openAIInstructions:
                "Speak in a natural, friendly, confident tone with clear articulation and relaxed pacing.",
            preferredSystemVoiceIdentifiers: [],
            preferredSystemVoiceNames: []
        ),
    ]

    static let defaultVoiceID = openAIShimmerVoiceID

    static func voiceOption(for id: String) -> VoiceOption {
        availableVoices.first(where: { $0.id == id })
            ?? availableVoices.first(where: { $0.id == defaultVoiceID })
            ?? availableVoices[0]
    }

    /// Selected voice ID for floating-bar TTS replies.
    @Published var selectedVoiceID: String {
        didSet {
            guard selectedVoiceID != oldValue else { return }
            UserDefaults.standard.set(selectedVoiceID, forKey: "shortcut_selectedVoiceID")
            FloatingBarVoicePlaybackService.shared.playVoiceSample(voiceID: selectedVoiceID)
            FloatingBarVoicePlaybackService.shared.prewarmBackgroundAgentKickoffPhrases()
        }
    }

    var hasAnyFloatingBarVoiceAnswersEnabled: Bool {
        true
    }

    func shouldSpeakFloatingBarResponse(forVoiceQuery: Bool) -> Bool {
        forVoiceQuery || floatingBarTypedQuestionVoiceAnswersEnabled
    }

    var askOmiUsesCustomShortcut: Bool {
        !Self.askOmiPresets.contains(askOmiShortcut)
    }

    var copilotUsesCustomShortcut: Bool {
        !Self.copilotPresets.contains(copilotShortcut)
    }

    var pttUsesCustomShortcut: Bool {
        !Self.pttPresets.contains(pttShortcut)
    }

    private static let askOmiShortcutDefaultsKey = "shortcut_askOmiKey"
    private static let pttShortcutDefaultsKey = "shortcut_pttKey"
    private static let copilotShortcutDefaultsKey = "shortcut_copilotKey"
    private static let clickThroughShortcutDefaultsKey = "shortcut_clickThroughKey"
    private static let suggestNowShortcutDefaultsKey = "shortcut_suggestNowKey"
    private static let snapRegionShortcutDefaultsKey = "shortcut_snapRegionKey"
    private static let quickReplyShortcutDefaultsKey = "shortcut_quickReplyKey"

    private init() {
        self.pttShortcut = Self.loadShortcut(
            forKey: Self.pttShortcutDefaultsKey,
            legacyMapper: Self.legacyPTTShortcut
        ) ?? Self.pttPresets[0]

        self.askOmiShortcut = Self.loadShortcut(
            forKey: Self.askOmiShortcutDefaultsKey,
            legacyMapper: Self.legacyAskOmiShortcut
        ) ?? Self.defaultAskOmiShortcut

        self.copilotShortcut = Self.loadShortcut(
            forKey: Self.copilotShortcutDefaultsKey,
            legacyMapper: { _ in nil }
        ) ?? Self.defaultCopilotShortcut

        self.clickThroughShortcut = Self.loadShortcut(
            forKey: Self.clickThroughShortcutDefaultsKey,
            legacyMapper: { _ in nil }
        ) ?? Self.defaultClickThroughShortcut

        self.suggestNowShortcut = Self.loadShortcut(
            forKey: Self.suggestNowShortcutDefaultsKey,
            legacyMapper: { _ in nil }
        ) ?? Self.defaultSuggestNowShortcut

        self.snapRegionShortcut = Self.loadShortcut(
            forKey: Self.snapRegionShortcutDefaultsKey,
            legacyMapper: { _ in nil }
        ) ?? Self.defaultSnapRegionShortcut

        self.quickReplyShortcut = Self.loadShortcut(
            forKey: Self.quickReplyShortcutDefaultsKey,
            legacyMapper: { _ in nil }
        ) ?? Self.defaultQuickReplyShortcut

        self.askOmiEnabled = UserDefaults.standard.object(forKey: "shortcut_askOmiEnabled") as? Bool ?? true
        self.copilotEnabled = UserDefaults.standard.object(forKey: "shortcut_copilotEnabled") as? Bool ?? true
        self.stealthModeEnabled = UserDefaults.standard.object(forKey: "shortcut_stealthModeEnabled") as? Bool ?? true
        self.clickThroughEnabled = UserDefaults.standard.object(forKey: "shortcut_clickThroughEnabled") as? Bool ?? true
        self.suggestNowEnabled = UserDefaults.standard.object(forKey: "shortcut_suggestNowEnabled") as? Bool ?? true
        self.snapRegionEnabled = UserDefaults.standard.object(forKey: "shortcut_snapRegionEnabled") as? Bool ?? true
        self.quickReplyEnabled = UserDefaults.standard.object(forKey: "shortcut_quickReplyEnabled") as? Bool ?? true
        self.pttEnabled = UserDefaults.standard.object(forKey: "shortcut_pttEnabled") as? Bool ?? true
        self.doubleTapForLock = UserDefaults.standard.object(forKey: "shortcut_doubleTapForLock") as? Bool ?? true
        self.solidBackground = UserDefaults.standard.object(forKey: "shortcut_solidBackground") as? Bool ?? false
        self.pttSoundsEnabled = UserDefaults.standard.object(forKey: "shortcut_pttSoundsEnabled") as? Bool ?? true
        self.pttMuteSystemAudio = UserDefaults.standard.object(forKey: "shortcut_pttMuteSystemAudio") as? Bool ?? true
        self.selectedModel = ModelQoS.Claude.sanitizedSelection(
            UserDefaults.standard.string(forKey: "shortcut_selectedModel")
        )
        if let saved = UserDefaults.standard.string(forKey: "shortcut_pttTranscriptionMode"),
           let mode = PTTTranscriptionMode(rawValue: saved) {
            self.pttTranscriptionMode = mode
        } else {
            self.pttTranscriptionMode = .batch
        }
        self.draggableBarEnabled = UserDefaults.standard.object(forKey: "shortcut_draggableBarEnabled") as? Bool ?? false
        self.floatingBarTypedQuestionVoiceAnswersEnabled =
            UserDefaults.standard.object(forKey: "shortcut_floatingBarTypedQuestionVoiceAnswersEnabled") as? Bool ?? false
        self.voicePlaybackSpeed = UserDefaults.standard.object(forKey: "shortcut_voicePlaybackSpeed") as? Float ?? 1.4
        let storedVoiceID = UserDefaults.standard.string(forKey: "shortcut_selectedVoiceID") ?? Self.defaultVoiceID
        let validVoiceID = Self.availableVoices.contains(where: { $0.id == storedVoiceID })
            ? storedVoiceID
            : Self.defaultVoiceID
        self.selectedVoiceID = validVoiceID

        NotificationCenter.default.addObserver(forName: .modelTierDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selectedModel = ModelQoS.Claude.sanitizedSelection(self.selectedModel)
            }
        }

        Task { @MainActor in
            FloatingBarVoicePlaybackService.shared.prewarmBackgroundAgentKickoffPhrases()
        }
    }

    private func persistShortcut(_ shortcut: KeyboardShortcut, forKey key: String) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func loadShortcut(
        forKey key: String,
        legacyMapper: (String) -> KeyboardShortcut?
    ) -> KeyboardShortcut? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            return decoded
        }
        if let legacyValue = defaults.string(forKey: key),
           let migrated = legacyMapper(legacyValue) {
            return migrated
        }
        return nil
    }

    private static func legacyAskOmiShortcut(_ value: String) -> KeyboardShortcut? {
        switch value {
        case "⌘ Enter":
            return askOmiCommandReturnShortcut
        case "⌘⇧ Enter":
            return askOmiCommandShiftReturnShortcut
        case "⌘J":
            return askOmiCommandJShortcut
        case "⌘O":
            return askOmiCommandOShortcut
        default:
            return nil
        }
    }

    private static func legacyPTTShortcut(_ value: String) -> KeyboardShortcut? {
        switch value {
        case "Option (⌥)":
            return pttPresets[0]
        case "Right Command (⌘)":
            return pttPresets[1]
        case "Fn / Globe":
            return pttPresets[2]
        default:
            return nil
        }
    }
}
