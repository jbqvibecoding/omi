import SwiftUI

#if compiler(>=6.2)
  import Translation
#endif

/// Unified Copilot settings — one home for the proactive copilot across its modes
/// (Snap hotkey, Live Copilot, Screen-Op) plus learning, scenarios, and stealth.
extension SettingsContentView {
    var copilotSection: some View {
        VStack(spacing: 20) {
            // Live Copilot
            settingsCard(settingId: "copilot.live") {
                VStack(alignment: .leading, spacing: 16) {
                    copilotToggleRow(
                        icon: "waveform.badge.mic",
                        title: "Live Copilot",
                        subtitle:
                            "Real-time suggestions during meetings and calls while you're recording.",
                        isOn: $copilotLiveEnabled
                    ) { CopilotSettings.shared.isEnabled = $0 }

                    if copilotLiveEnabled {
                        HStack {
                            Text("Scenario").scaledFont(size: 14).foregroundColor(OmiColors.textPrimary)
                            Spacer()
                            Picker("", selection: $copilotScenarioId) {
                                ForEach(CopilotSettings.shared.availableScenarios) { profile in
                                    Text(profile.displayName).tag(profile.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 200)
                            .onChange(of: copilotScenarioId) { _, v in CopilotSettings.shared.scenarioId = v }
                            Button("Manage") { showCopilotProfilesManager = true }
                                .buttonStyle(.plain).scaledFont(size: 12)
                                .foregroundColor(OmiColors.textSecondary)
                        }

                        CopilotPrepSheetRow(scenarioId: copilotScenarioId) {
                            showCopilotPrepSheet = true
                        }

                        copilotSubToggle(
                            title: "Auto-pick scenario from calendar",
                            subtitle: "Chooses the profile from your current calendar event.",
                            isOn: $copilotAutoScenario
                        ) { CopilotSettings.shared.autoSelectScenario = $0 }

                        copilotSubToggle(
                            title: "Offer to start when a meeting is detected",
                            subtitle: "Shows a one-click card when a call starts while you're not recording.",
                            isOn: $copilotAutoDetectMeetings
                        ) { CopilotSettings.shared.autoDetectMeetings = $0 }

                        copilotSubToggle(
                            title: "Brief me before meetings",
                            subtitle: "Shows who's coming and what's still open with them — only when your notes know them.",
                            isOn: $copilotMeetingPrep
                        ) { CopilotSettings.shared.meetingPrepEnabled = $0 }

                        // Each toggle is grouped with the detail it reveals, which also keeps
                        // this block inside ViewBuilder's ten-child limit.
                        Group {
                            copilotSubToggle(
                                title: "Sound like me",
                                subtitle:
                                    "Rewrites the line you can say out loud in your own voice, learned from how you actually talk.",
                                isOn: $copilotStyleMatching
                            ) { CopilotSettings.shared.styleMatchingEnabled = $0 }

                            if copilotStyleMatching {
                                copilotStyleCardRow
                            }
                        }

                        Group {
                            copilotSubToggle(
                                title: "Remember people and projects",
                                subtitle:
                                    "Keeps a file per person, org, project and topic from your meetings, and tidies them up daily.",
                                isOn: $copilotDossiers
                            ) { CopilotSettings.shared.dossiersEnabled = $0 }

                            if copilotDossiers {
                                HStack {
                                    Text("Stored on this Mac as plain markdown you can read and edit.")
                                        .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                                    Spacer()
                                    Button("Browse") { showDossierBrowser = true }
                                        .buttonStyle(.plain).scaledFont(size: 12)
                                        .foregroundColor(OmiColors.textSecondary)
                                }
                            }
                        }

                        // When it speaks and how it answers — one concern, and grouping
                        // them keeps this block under ViewBuilder's ten-child limit.
                        Group {
                            CopilotTriggerPolicyRow()
                            CopilotAnswerStyleRow()
                            CopilotInsertModeRow()
                        }

                        copilotSubToggle(
                            title: "Export meetings as markdown",
                            subtitle: "Saves minutes + transcript to ~/Documents/Omi/Meetings after each session.",
                            isOn: $copilotExportMarkdown
                        ) { CopilotSettings.shared.exportMeetingMarkdown = $0 }

                        Group {
                            copilotSubToggle(
                                title: "Learn from my feedback",
                                subtitle: "Suggestion types you dismiss get quieter; ones you act on come readily.",
                                isOn: $copilotAdaptiveEnabled
                            ) { CopilotSettings.shared.adaptiveThresholdEnabled = $0 }

                            if copilotAdaptiveEnabled {
                                CopilotPreferencesRow()
                            }
                        }
                    }
                }
                .sheet(isPresented: $showCopilotProfilesManager) {
                    CopilotProfilesManagerView { showCopilotProfilesManager = false }
                }
                .sheet(isPresented: $showDossierBrowser) {
                    DossierBrowserView { showDossierBrowser = false }
                }
                .sheet(isPresented: $showCopilotPrepSheet) {
                    CopilotPrepSheetView { showCopilotPrepSheet = false }
                }
            }

            settingsCard(settingId: "copilot.minutes") {
                CopilotMinutesRow()
            }

            settingsCard(settingId: "copilot.subtitles") {
                CopilotSubtitlesRow()
            }

            settingsCard(settingId: "copilot.interpreter") {
                InterpreterSettingsCard()
            }

            settingsCard(settingId: "copilot.ambient") {
                CopilotAmbientContextRow()
            }

            settingsCard(settingId: "copilot.slides") {
                CopilotSlideTimelineRow()
            }

            // Answers from your notes (notes-folder retrieval)
            settingsCard(settingId: "copilot.notes") {
                VStack(alignment: .leading, spacing: 16) {
                    copilotToggleRow(
                        icon: "text.book.closed",
                        title: "Answers from your notes",
                        subtitle:
                            "When a key question comes up mid-meeting, surfaces the relevant points from your notes folder.",
                        isOn: $copilotNotesRagEnabled
                    ) { CopilotSettings.shared.notesRagEnabled = $0 }

                    if copilotNotesRagEnabled {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notes folder").scaledFont(size: 14)
                                    .foregroundColor(OmiColors.textPrimary)
                                Text(
                                    copilotNotesFolderPath.isEmpty
                                        ? "Pick a folder of .md/.txt notes (an Obsidian vault works)"
                                        : copilotNotesFolderPath
                                )
                                .scaledFont(size: 11)
                                .foregroundColor(OmiColors.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            }
                            Spacer()
                            Button(copilotNotesFolderPath.isEmpty ? "Choose..." : "Change...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                if !copilotNotesFolderPath.isEmpty {
                                    panel.directoryURL = URL(fileURLWithPath: copilotNotesFolderPath)
                                }
                                if panel.runModal() == .OK, let url = panel.url {
                                    copilotNotesFolderPath = url.path
                                    CopilotSettings.shared.notesFolderPath = url.path
                                    copilotNotesIndexStatus = "Indexing..."
                                    Task {
                                        let r = await NotesKnowledgeBase.shared.index()
                                        copilotNotesIndexStatus =
                                            r.error ?? "\(r.scannedFiles) files, \(r.totalChunks) chunks indexed"
                                    }
                                }
                            }
                            .scaledFont(size: 13)

                            if !copilotNotesFolderPath.isEmpty {
                                Button("Reindex") {
                                    copilotNotesIndexStatus = "Indexing..."
                                    Task {
                                        let r = await NotesKnowledgeBase.shared.index()
                                        copilotNotesIndexStatus =
                                            r.error ?? "\(r.scannedFiles) files, \(r.totalChunks) chunks indexed"
                                    }
                                }
                                .scaledFont(size: 13)
                            }
                        }

                        if !copilotNotesIndexStatus.isEmpty {
                            Text(copilotNotesIndexStatus)
                                .scaledFont(size: 11)
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    }
                }
            }

            // Screen-Op assist
            settingsCard(settingId: "copilot.screenop") {
                VStack(alignment: .leading, spacing: 16) {
                    copilotToggleRow(
                        icon: "sparkle.magnifyingglass",
                        title: "Screen help while you work",
                        subtitle: "Suggests a fix when you look stuck (repeating errors, no progress).",
                        isOn: $screenOpEnabled
                    ) { ScreenOpAssistantSettings.shared.isEnabled = $0 }

                    if screenOpEnabled {
                        copilotSubToggle(
                            title: "Only analyze when the screen changes",
                            subtitle: "Skips the AI call while your screen is idle — saves battery and cost.",
                            isOn: $screenOpOnlyOnChange
                        ) { ScreenOpAssistantSettings.shared.onlyOnSignificantChange = $0 }
                    }
                }
            }

            // Watchers (user-programmable proactive agents)
            settingsCard(settingId: "copilot.watchers") {
                HStack {
                    Image(systemName: "eye").scaledFont(size: 16).foregroundColor(OmiColors.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Watchers").scaledFont(size: 16, weight: .semibold)
                            .foregroundColor(OmiColors.textPrimary)
                        Text("Build your own agents that watch your screen/audio and notify you — even on your phone.")
                            .scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                    }
                    Spacer()
                    Button("Manage") { showWatchersManager = true }
                        .buttonStyle(.plain).scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                }
                .sheet(isPresented: $showWatchersManager) {
                    WatchersManagerView { showWatchersManager = false }
                }
            }

            // Stealth
            settingsCard(settingId: "copilot.stealth") {
                copilotToggleRow(
                    icon: "eye.slash",
                    title: "Hide from screen recordings & shares",
                    subtitle: "The copilot stays visible to you but never appears on a shared screen.",
                    isOn: $stealthModeEnabled
                ) { ShortcutSettings.shared.stealthModeEnabled = $0 }
            }

            Text("Copilot Snap: press your shortcut (default ⌃Return) for an instant answer about your screen. Double-press to talk live. Quick Reply (⌃⌥R) drafts the message you're about to type, wherever your cursor is. Configure the shortcuts under Shortcuts.")
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copilotToggleRow(
        icon: String, title: String, subtitle: String, isOn: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon).scaledFont(size: 16).foregroundColor(OmiColors.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(size: 16, weight: .semibold).foregroundColor(OmiColors.textPrimary)
                Text(subtitle).scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
                .onChange(of: isOn.wrappedValue) { _, v in onChange(v) }
        }
    }

    private var copilotStyleCardRow: some View {
        CopilotStyleCardRow()
    }

    private func copilotSubToggle(
        title: String, subtitle: String, isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(size: 14).foregroundColor(OmiColors.textPrimary)
                Text(subtitle).scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
                .onChange(of: isOn.wrappedValue) { _, v in onChange(v) }
        }
    }
}

/// What omi has learned about when to speak up, in words rather than a hidden threshold.
/// Editable, because the fastest way to fix a wrong rule is to delete the line.
private struct CopilotPreferencesRow: View {
    @State private var rulesText = ""
    @State private var rules: [String] = []
    @State private var correctionCount = 0
    @State private var isDistilling = false
    @State private var isEditing = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What omi has learned").scaledFont(size: 13)
                        .foregroundColor(OmiColors.textSecondary)
                    Text(subtitle).scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                }
                Spacer()
                if !rules.isEmpty {
                    Button(isEditing ? "Done" : "Edit") {
                        if isEditing { CopilotCorrectionLog.shared.setRulesText(rulesText) }
                        isEditing.toggle()
                        reload()
                    }
                    .buttonStyle(.plain).scaledFont(size: 12).foregroundColor(OmiColors.textSecondary)
                }
                Button(isDistilling ? "Thinking…" : "Update now") { distill() }
                    .buttonStyle(.plain).scaledFont(size: 12)
                    .foregroundColor(isDistilling ? OmiColors.textTertiary : OmiColors.textSecondary)
                    .disabled(isDistilling)
            }

            if isEditing {
                TextEditor(text: $rulesText)
                    .scaledFont(size: 11)
                    .frame(minHeight: 100, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(OmiColors.backgroundTertiary.opacity(0.5))
                    .cornerRadius(6)
            } else {
                ForEach(rules, id: \.self) { rule in
                    Text("· \(rule)").scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                }
            }

            if !status.isEmpty {
                Text(status).scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            }

            if !rules.isEmpty || correctionCount > 0 {
                Button("Forget all of this") {
                    CopilotCorrectionLog.shared.reset()
                    CopilotFeedbackTuner.shared.reset()
                    reload()
                    status = "Cleared."
                }
                .buttonStyle(.plain).scaledFont(size: 11).foregroundColor(OmiColors.error)
            }
        }
        .onAppear { reload() }
    }

    private var subtitle: String {
        if rules.isEmpty {
            return correctionCount == 0
                ? "Nothing yet — it learns from the suggestions you act on and the ones you wave away."
                : "\(correctionCount) signals collected; rules appear once there's a pattern."
        }
        return "\(rules.count) rules from \(correctionCount) signals. These override omi's defaults."
    }

    private func reload() {
        rulesText = CopilotCorrectionLog.shared.rulesText
        rules = CopilotCorrectionLog.shared.rules
        correctionCount = CopilotCorrectionLog.shared.all.count
    }

    private func distill() {
        isDistilling = true
        status = ""
        Task { @MainActor in
            let result = await CopilotCorrectionLog.shared.distill()
            isDistilling = false
            reload()
            if result == nil { status = "Not enough to go on yet." }
        }
    }
}

/// The learned voice, shown plainly and editable — you should be able to see exactly what
/// omi thinks you sound like, and correct it.
private struct CopilotStyleCardRow: View {
    @State private var card: String = ""
    @State private var isLearning = false
    @State private var status: String = ""
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your voice").scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                    Text(subtitle).scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                }
                Spacer()
                if !card.isEmpty {
                    Button(isExpanded ? "Hide" : "View") { isExpanded.toggle() }
                        .buttonStyle(.plain).scaledFont(size: 12)
                        .foregroundColor(OmiColors.textSecondary)
                }
                Button(isLearning ? "Learning…" : "Relearn") { relearn() }
                    .buttonStyle(.plain).scaledFont(size: 12)
                    .foregroundColor(isLearning ? OmiColors.textTertiary : OmiColors.textSecondary)
                    .disabled(isLearning)
            }

            if isExpanded {
                TextEditor(text: $card)
                    .scaledFont(size: 11)
                    .frame(minHeight: 120, maxHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(OmiColors.backgroundTertiary.opacity(0.5))
                    .cornerRadius(6)
                HStack {
                    Spacer()
                    Button("Save") { CopilotStyleLearner.shared.setCard(card) }
                        .buttonStyle(.plain).scaledFont(size: 12)
                        .foregroundColor(OmiColors.textSecondary)
                }
            }

            if !status.isEmpty {
                Text(status).scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            }
        }
        .onAppear { card = CopilotStyleLearner.shared.card ?? "" }
    }

    private var subtitle: String {
        if card.isEmpty {
            return "Not learned yet — record a meeting and omi picks it up from how you speak."
        }
        guard let at = CopilotStyleLearner.shared.cardUpdatedAt else { return "Learned from your own spoken lines." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return "Learned from your own spoken lines · updated \(formatter.string(from: at))"
    }

    private func relearn() {
        isLearning = true
        status = ""
        Task { @MainActor in
            let learned = await CopilotStyleLearner.shared.learnCard()
            isLearning = false
            if let learned {
                card = learned
                isExpanded = true
                status = ""
            } else {
                status = "Not enough of your own speech yet — record a meeting first."
            }
        }
    }
}

/// How the copilot answers: which language, and how much of it.
///
/// The language control exists for one case a global setting usually gets wrong — you work
/// in your own language but the meeting is in another one — so the row says out loud that
/// the line you say to the room stays in the room's language.
private struct CopilotAnswerStyleRow: View {
    @State private var languageId: String = CopilotAnswerLanguage.auto.id
    @State private var length: CopilotResponseLength = .adaptive

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Answer in").scaledFont(size: 14).foregroundColor(OmiColors.textPrimary)
                    Text(languageSubtitle).scaledFont(size: 12)
                        .foregroundColor(OmiColors.textTertiary)
                }
                Spacer()
                Picker("", selection: $languageId) {
                    ForEach(CopilotAnswerLanguage.all) { language in
                        Text(language.displayName).tag(language.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                .onChange(of: languageId) { _, value in
                    CopilotSettings.shared.answerLanguage = CopilotAnswerLanguage.byId(value)
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Answer length").scaledFont(size: 14)
                        .foregroundColor(OmiColors.textPrimary)
                    Text(length.subtitle).scaledFont(size: 12)
                        .foregroundColor(OmiColors.textTertiary)
                }
                Spacer()
                Picker("", selection: $length) {
                    ForEach(CopilotResponseLength.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
                .onChange(of: length) { _, value in
                    CopilotSettings.shared.responseLength = value
                }
            }
        }
        .onAppear {
            languageId = CopilotSettings.shared.answerLanguage.id
            length = CopilotSettings.shared.responseLength
        }
    }

    private var languageSubtitle: String {
        languageId == CopilotAnswerLanguage.auto.id
            ? "Matches whatever is being said or shown."
            : "Explanations only — a line you say out loud stays in the room's language."
    }
}

/// When the copilot may speak up on its own.
///
/// Worth its own row because the honest answer for some rooms is "not unless I ask", and
/// until now the only way to get that was switching the copilot off — which also switched
/// off the transcript, the notes and the summary.
private struct CopilotTriggerPolicyRow: View {
    @State private var policy: CopilotTriggerPolicy = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speak up").scaledFont(size: 14).foregroundColor(OmiColors.textPrimary)
                    Text(policy.subtitle).scaledFont(size: 12)
                        .foregroundColor(OmiColors.textTertiary)
                }
                Spacer()
                Picker("", selection: $policy) {
                    ForEach(CopilotTriggerPolicy.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 220)
                .onChange(of: policy) { _, value in
                    CopilotSettings.shared.triggerPolicy = value
                }
            }

            Text(
                "However you set this, \(ShortcutSettings.shared.suggestNowShortcut.displayLabel) always asks for one on the spot."
            )
            .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
        }
        .onAppear { policy = CopilotSettings.shared.triggerPolicy }
    }
}

/// Live subtitles — what the other side says, translated, on a bar over everything.
private struct CopilotSubtitlesRow: View {
    @State private var enabled = false
    @State private var language = CopilotSettings.followSystemLanguage
    @State private var visibleInShares = false

    private var shortcutLabel: String { ShortcutSettings.shared.subtitlesShortcut.displayLabel }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "captions.bubble").scaledFont(size: 16)
                    .foregroundColor(OmiColors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live subtitles").scaledFont(size: 16, weight: .semibold)
                        .foregroundColor(OmiColors.textPrimary)
                    Text(
                        "A bar with what the other side says and its translation, over any app — "
                            + "Zoom, Tencent Meeting, Feishu, a YouTube livestream. \(shortcutLabel) shows or hides it."
                    )
                    .scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                    .onChange(of: enabled) { _, value in
                        guard value != CopilotSettings.shared.subtitlesEnabled else { return }
                        CopilotSettings.shared.subtitlesEnabled = value
                        SubtitleController.shared.settingChanged()
                    }
            }

            if enabled {
                HStack {
                    Text("Translate into").scaledFont(size: 13)
                        .foregroundColor(OmiColors.textSecondary)
                    Spacer()
                    Picker("", selection: $language) {
                        Text("My language (\(MeetingLanguages.displayName(MeetingLanguages.myLanguage())))")
                            .tag(CopilotSettings.followSystemLanguage)
                        Divider()
                        ForEach(MeetingLanguages.readable) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .onChange(of: language) { _, value in
                        CopilotSettings.shared.subtitleLanguage = value
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show in screen shares and recordings").scaledFont(size: 13)
                            .foregroundColor(OmiColors.textSecondary)
                        Text("Off: you see the bar, the people you share your screen with don't.")
                            .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $visibleInShares).toggleStyle(.switch).labelsHidden()
                        .onChange(of: visibleInShares) { _, value in
                            CopilotSettings.shared.subtitlesVisibleInScreenShare = value
                            SubtitleOverlayController.shared.refresh()
                        }
                }
                Text(recognizerNote)
                    .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                #if compiler(>=6.2)
                    if #available(macOS 26.0, *) {
                        OfflineTranslationRow()
                    }
                #endif
            }
        }
        .onAppear {
            enabled = CopilotSettings.shared.subtitlesEnabled
            language = CopilotSettings.shared.subtitleLanguage
            visibleInShares = CopilotSettings.shared.subtitlesVisibleInScreenShare
        }
    }

    private var recognizerNote: String {
        if TranscriberRouting.appleSpeechAvailable {
            return "Words appear as they are said, recognized on this Mac in the language they speak. "
                + "Shows while omi is recording, with system audio on."
        }
        return "Lines appear once each sentence is transcribed (a few seconds behind; live words need "
            + "macOS 26). Shows while omi is recording, with system audio on."
    }
}

#if compiler(>=6.2)
    /// Whether this Mac can translate the likely language pair offline, and a way to get it.
    /// Offline translation is what keeps subtitles free and fast: without it every finished line
    /// costs a model call from a shared budget.
    @available(macOS 26.0, *)
    private struct OfflineTranslationRow: View {
        @State private var status: LanguageAvailability.Status?
        @State private var configuration: TranslationSession.Configuration?

        private var target: String { MeetingLanguages.myLanguage() }
        private var source: String { MeetingLanguages.followSystemTarget(source: target) }

        private func language(_ code: String) -> Locale.Language {
            Locale.Language(identifier: code == "zh-CN" ? "zh-Hans" : code == "zh-TW" ? "zh-Hant" : code)
        }

        var body: some View {
            HStack {
                Text("Offline translation, \(MeetingLanguages.displayName(source)) → \(MeetingLanguages.displayName(target))")
                    .scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                Spacer()
                switch status {
                case .installed:
                    Text("On this Mac").scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)
                case .supported:
                    Button("Download") {
                        configuration = TranslationSession.Configuration(
                            source: language(source), target: language(target))
                    }
                case .unsupported:
                    Text("Not available").scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .task { await check() }
            .translationTask(configuration) { session in
                // Shows the system's download prompt for the pair.
                try? await session.prepareTranslation()
                await check()
            }
        }

        private func check() async {
            status = await LanguageAvailability().status(from: language(source), to: language(target))
        }
    }
#endif

/// Live meeting minutes — summary, topics, fishbone diagrams, and conclusions and to-dos that
/// each show the words they came from.
///
/// Says when it runs, because "on by default" for something that calls a model every 45
/// seconds needs the other half of the sentence: only in meetings.
private struct CopilotMinutesRow: View {
    @State private var enabled = true
    @State private var language = CopilotSettings.followSystemLanguage
    @State private var endOnHangUp = true
    @State private var endOnSilence = "prompt"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "list.bullet.rectangle").scaledFont(size: 16)
                    .foregroundColor(OmiColors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live meeting minutes").scaledFont(size: 16, weight: .semibold)
                        .foregroundColor(OmiColors.textPrimary)
                    Text(
                        "A summary, topics and fishbone diagrams, updated every 45 seconds. Every "
                            + "conclusion and to-do shows who said it and when, and jumps to the line."
                    )
                    .scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                    .onChange(of: enabled) { _, value in
                        CopilotSettings.shared.minutesEnabled = value
                    }
            }

            if enabled {
                HStack {
                    Text("Write minutes in").scaledFont(size: 13)
                        .foregroundColor(OmiColors.textSecondary)
                    Spacer()
                    Picker("", selection: $language) {
                        Text("My language (\(MeetingLanguages.displayName(MeetingLanguages.myLanguage())))")
                            .tag(CopilotSettings.followSystemLanguage)
                        Text("The meeting's language").tag(CopilotSettings.meetingLanguage)
                        Divider()
                        ForEach(MeetingLanguages.readable) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .onChange(of: language) { _, value in
                        guard value != CopilotSettings.shared.minutesLanguage else { return }
                        CopilotSettings.shared.minutesLanguage = value
                        // A meeting in progress is rewritten in the new language right away.
                        MeetingMinutesEngine.shared.languageChanged()
                    }
                }
                Text(
                    "Runs on its own in calls (Zoom, Teams, Meet, Tencent Meeting, Feishu…) and when "
                        + "your Mac plays people talking. For an in-person meeting, start it from the "
                        + "Minutes tab while recording."
                )
                .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("End the meeting when the call hangs up").scaledFont(size: 13)
                            .foregroundColor(OmiColors.textSecondary)
                        Text("30 seconds after the meeting app lets go of the microphone; recording carries on into the next conversation.")
                            .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $endOnHangUp).toggleStyle(.switch).labelsHidden()
                        .onChange(of: endOnHangUp) { _, value in CopilotSettings.shared.endMeetingOnHangUp = value }
                }
                HStack {
                    Text("When nobody talks for 10 minutes").scaledFont(size: 13)
                        .foregroundColor(OmiColors.textSecondary)
                    Spacer()
                    Picker("", selection: $endOnSilence) {
                        Text("Ask, then end in a minute").tag("prompt")
                        Text("End the meeting").tag("end")
                        Text("Keep recording").tag("off")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .onChange(of: endOnSilence) { _, value in CopilotSettings.shared.endMeetingOnSilence = value }
                }
            }
        }
        .onAppear {
            enabled = CopilotSettings.shared.minutesEnabled
            language = CopilotSettings.shared.minutesLanguage
            endOnHangUp = CopilotSettings.shared.endMeetingOnHangUp
            endOnSilence = CopilotSettings.shared.endMeetingOnSilence
        }
    }
}

/// Slide tracking — the deck timeline for a recorded session.
///
/// Says out loud that it reads the frames screen capture already takes, because the honest
/// answer to "does this cost me battery" is no, and the honest answer to "does it work
/// with screen capture off" is also no.
private struct CopilotSlideTimelineRow: View {
    @State private var enabled = false
    @ObservedObject private var timeline = SlideTimeline.shared

    private var screenCaptureOn: Bool { AssistantSettings.shared.screenAnalysisEnabled }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.on.rectangle").scaledFont(size: 16)
                    .foregroundColor(OmiColors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Follow the slides").scaledFont(size: 16, weight: .semibold)
                        .foregroundColor(OmiColors.textPrimary)
                    Text(
                        "Notices when the deck moves on and records what was said over each "
                            + "slide, so the summary reads in the order it happened."
                    )
                    .scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                    .disabled(!screenCaptureOn)
                    .onChange(of: enabled) { _, value in
                        CopilotSettings.shared.slideTimelineEnabled = value
                    }
            }

            if !screenCaptureOn {
                Text(
                    "Needs screen capture on — it reads the frames that are already being "
                        + "taken rather than taking its own."
                )
                .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            } else if enabled {
                Text(statusLine)
                    .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            }
        }
        .onAppear { enabled = CopilotSettings.shared.slideTimelineEnabled }
    }

    private var statusLine: String {
        guard timeline.isRunning || !timeline.slides.isEmpty else {
            return "One AI call per slide change, only while you're recording."
        }
        let captioned = timeline.slides.filter { !$0.caption.isEmpty }.count
        return "\(captioned) of \(timeline.slides.count) slides described this session."
    }
}

/// Ambient text context — the running record of what's on screen.
///
/// Off by default and said plainly, because "reads the text of every app you use" is a
/// bigger ask than a screenshot even though it costs the machine less. The excluded-apps
/// list is the screen-recording one on purpose: two lists that both mean "not this app"
/// would be a trap.
private struct CopilotAmbientContextRow: View {
    @State private var enabled = false
    @State private var entryCount = 0
    @State private var latest = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.viewfinder").scaledFont(size: 16)
                    .foregroundColor(OmiColors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read what's on screen as text").scaledFont(size: 16, weight: .semibold)
                        .foregroundColor(OmiColors.textPrimary)
                    Text(
                        "Lets the copilot see the app's own text and the real page URL, not just "
                            + "a picture of it. Costs far less than screenshots."
                    )
                    .scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                    .onChange(of: enabled) { _, value in
                        CopilotSettings.shared.ambientTextEnabled = value
                        refresh()
                    }
            }

            if enabled {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kept in memory for 30 minutes, never written to disk.")
                            .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                        Text(statusLine)
                            .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Refresh") { refresh() }
                        .buttonStyle(.plain).scaledFont(size: 12)
                        .foregroundColor(OmiColors.textSecondary)
                    Button("Forget all") {
                        AmbientTextContext.shared.clear()
                        refresh()
                    }
                    .buttonStyle(.plain).scaledFont(size: 12)
                    .foregroundColor(OmiColors.textSecondary)
                }

                Text("Apps you excluded from screen recording are skipped here too.")
                    .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            }
        }
        .onAppear {
            enabled = CopilotSettings.shared.ambientTextEnabled
            refresh()
        }
    }

    private var statusLine: String {
        guard entryCount > 0 else { return "Nothing captured yet." }
        return latest.isEmpty
            ? "\(entryCount) readings held."
            : "\(entryCount) readings held · latest: \(latest)"
    }

    private func refresh() {
        let dump = AmbientTextContext.shared.debugDump()
        entryCount = Int(dump["entries"] ?? "0") ?? 0
        let app = dump["latest_app"] ?? "-"
        latest = app == "-" ? "" : app
    }
}

/// How "Insert" puts an answer back into the app you were in.
///
/// Typing is the default because it leaves the clipboard alone. It's a setting rather than
/// something we detect, because the apps that swallow synthetic Unicode keystrokes —
/// terminals, some Electron builds — fail silently, and "nothing happened" is not a signal
/// we can act on from here.
private struct CopilotInsertModeRow: View {
    @State private var mode: TextInsertion.InsertMode = .type

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Insert answers by").scaledFont(size: 14)
                    .foregroundColor(OmiColors.textPrimary)
                Text(mode.subtitle).scaledFont(size: 12)
                    .foregroundColor(OmiColors.textTertiary)
            }
            Spacer()
            Picker("", selection: $mode) {
                ForEach(TextInsertion.InsertMode.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 200)
            .onChange(of: mode) { _, value in
                CopilotSettings.shared.insertMode = value
            }
        }
        .onAppear { mode = CopilotSettings.shared.insertMode }
    }
}

/// Entry point to the prep sheet, showing at a glance whether this scenario has anything
/// filled in — an empty prep sheet is the difference between grounded suggestions and
/// generic ones, so it should be visible without opening it.
private struct CopilotPrepSheetRow: View {
    @ObservedObject private var store = CopilotPrepSheetStore.shared
    let scenarioId: String
    let onOpen: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Prep for this scenario").scaledFont(size: 14)
                    .foregroundColor(OmiColors.textPrimary)
                Text(subtitle).scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)
            }
            Spacer()
            Button(store.sheet(for: scenarioId) == nil ? "Fill in" : "Edit") { onOpen() }
                .buttonStyle(.plain).scaledFont(size: 12)
                .foregroundColor(OmiColors.textSecondary)
        }
    }

    private var subtitle: String {
        guard let sheet = store.sheet(for: scenarioId) else {
            return "Paste your résumé, the deal, the deck — whatever this kind of session runs on."
        }
        let filled = sheet.values.count
        return "\(filled) filled in. The copilot reads this before every suggestion."
    }
}
