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
                            title: "Export meetings as markdown",
                            subtitle: "Saves minutes + transcript to ~/Documents/Omi/Meetings after each session.",
                            isOn: $copilotExportMarkdown
                        ) { CopilotSettings.shared.exportMeetingMarkdown = $0 }

                        copilotSubToggle(
                            title: "Learn from my feedback",
                            subtitle: "Suggestion types you dismiss get quieter; ones you act on come readily.",
                            isOn: $copilotAdaptiveEnabled
                        ) { CopilotSettings.shared.adaptiveThresholdEnabled = $0 }

                        if copilotAdaptiveEnabled && !CopilotFeedbackTuner.shared.adaptationSummary().isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(CopilotFeedbackTuner.shared.adaptationSummary(), id: \.bucket) { item in
                                    Text("· \(item.bucket): \(item.direction)")
                                        .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                                }
                                Button("Reset learning") { CopilotFeedbackTuner.shared.reset() }
                                    .scaledFont(size: 12).buttonStyle(.plain)
                                    .foregroundColor(OmiColors.textSecondary)
                            }
                        }
                    }
                }
                .sheet(isPresented: $showCopilotProfilesManager) {
                    CopilotProfilesManagerView { showCopilotProfilesManager = false }
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
                copilotToggleRow(
                    icon: "sparkle.magnifyingglass",
                    title: "Screen help while you work",
                    subtitle: "Suggests a fix when you look stuck (repeating errors, no progress).",
                    isOn: $screenOpEnabled
                ) { ScreenOpAssistantSettings.shared.isEnabled = $0 }
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
