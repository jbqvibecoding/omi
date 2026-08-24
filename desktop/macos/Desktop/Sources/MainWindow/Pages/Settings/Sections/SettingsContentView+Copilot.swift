import SwiftUI

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

            Text("Copilot Snap: press your shortcut (default ⌃Return) for an instant answer about your screen. Double-press to talk live. Configure the shortcut under Shortcuts.")
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
