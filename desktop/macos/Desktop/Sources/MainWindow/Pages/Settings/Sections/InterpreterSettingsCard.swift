import SwiftUI

// The settings for simultaneous interpretation. The checklist, the "who hears the translation"
// list and the voice sample follow Cicada's settings (github.com/wquguru/cicada, Apache-2.0 —
// SettingsWindow.swift, MicUsersView.swift, VoicePicker.swift), rewritten for omi's settings page.

/// Simultaneous interpretation — hold right ⌥, speak, and the meeting hears the translation.
struct InterpreterSettingsCard: View {
    @ObservedObject private var controller = InterpreterController.shared
    @ObservedObject private var installer = VirtualMicInstaller.shared
    @ObservedObject private var ling = LingClient.shared
    @ObservedObject private var engine = InterpretEngine.shared

    @State private var enabled = false
    @State private var fromLanguage = CopilotSettings.followSystemLanguage
    @State private var toLanguage = CopilotSettings.meetingLanguage
    @State private var voiceID = ""
    @State private var keyDraft = ""
    @State private var micUID = ""
    @State private var outputUID = ""
    @State private var users: [MicUser] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if enabled {
                Group {
                    onlyTranslationNotice
                    checklist
                    whoHears
                    languages
                    voice
                }
                Group {
                    MyVoiceSampleRow(language: engine.sourceCode)
                    lingKey
                    devices
                }
            }
        }
        .onAppear(perform: load)
        .task(id: enabled) {
            // Who reads which microphone changes as calls start and end: keep the list current
            // while the page is open.
            while enabled, !Task.isCancelled {
                refreshUsers()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func load() {
        let settings = CopilotSettings.shared
        enabled = settings.interpreterEnabled
        fromLanguage = settings.interpreterFromLanguage
        toLanguage = settings.interpreterToLanguage
        micUID = settings.interpreterMicUID
        outputUID = settings.interpreterOutputUID
        voiceID = settings.interpreterVoiceID(for: engine.targetCode)
    }

    private func refreshUsers() {
        if #available(macOS 14.4, *) { users = MicUsers.current() }
    }

    // MARK: Parts

    private var header: some View {
        HStack {
            Image(systemName: "person.wave.2").scaledFont(size: 16).foregroundColor(OmiColors.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Simultaneous interpretation").scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
                Text(
                    "Hold right ⌥ and speak: the meeting hears it in their language, through a virtual "
                        + "microphone — Zoom, Tencent Meeting, Feishu, a livestream. Left ⌥ still asks omi."
                )
                .scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $enabled).toggleStyle(.switch).labelsHidden()
                .onChange(of: enabled) { _, value in
                    guard value != CopilotSettings.shared.interpreterEnabled else { return }
                    controller.setEnabled(value)
                }
        }
    }

    private var onlyTranslationNotice: some View {
        Text(
            "While this is on, the meeting hears only the translation: your own voice goes to the "
                + "virtual microphone's other side. Turn it off to talk to them directly."
        )
        .scaledFont(size: 11)
        .foregroundColor(OmiColors.textSecondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(OmiColors.backgroundTertiary))
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Virtual microphone").scaledFont(size: 13, weight: .semibold).foregroundColor(OmiColors.textPrimary)
            step(1, "Install BlackHole 2ch (downloaded from its maker and checked)", done: installer.isOnDisk || installer.isLoaded)
            step(2, "Let the system load it — sound stops for about a second, so not mid-call", done: installer.isLoaded)
            step(3, testLine, done: installer.passed)
            HStack(spacing: 10) {
                Button(nextLabel) { installer.next() }
                    .disabled(installer.busy)
                if installer.busy { ProgressView().controlSize(.small) }
                if case .failed(let message) = installer.state {
                    Text(message).scaledFont(size: 11).foregroundColor(OmiColors.warning)
                }
            }
            if let state = systemMicLine {
                Text(state).scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            }
        }
    }

    private func step(_ n: Int, _ text: String, done: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .scaledFont(size: 12)
                .foregroundColor(done ? OmiColors.success : OmiColors.textTertiary)
            Text(text).scaledFont(size: 12).foregroundColor(done ? OmiColors.textSecondary : OmiColors.textPrimary)
        }
    }

    private var testLine: String {
        guard let test = installer.test else { return "Sound test: omi speaks into it and listens back" }
        if test.heard { return test.text.isEmpty ? "Sound test passed" : "Sound test passed — heard “\(test.text)”" }
        return test.problem ?? "Nothing came back — try the test again"
    }

    private var nextLabel: String {
        switch installer.state {
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        case .reloading: return "Restarting audio…"
        case .testing: return "Testing…"
        default:
            if !installer.isOnDisk && !installer.isLoaded { return "Install" }
            if !installer.isLoaded { return "Restart audio" }
            return installer.passed ? "Test again" : "Test"
        }
    }

    private var systemMicLine: String? {
        switch controller.systemMicState {
        case .off: return installer.isLoaded ? "The system microphone isn't switched yet." : nil
        case .switched(let original):
            return "The system microphone is the virtual mic while this is on; \(original.isEmpty ? "your microphone" : original) comes back when you turn it off."
        case .moved(let to):
            return "Something switched the system microphone to \(to) — apps on “default” no longer hear the translation."
        case .notRestored(let original):
            return "The system microphone is still the virtual mic; \(original) will be put back."
        }
    }

    @ViewBuilder
    private var whoHears: some View {
        if !users.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Who hears the translation").scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
                ForEach(users) { user in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(user.state)).scaledFont(size: 11).foregroundColor(color(user.state))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(user.name).scaledFont(size: 12, weight: .medium).foregroundColor(OmiColors.textPrimary)
                            Text(detail(user.state)).scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                        }
                    }
                }
            }
        }
    }

    private func icon(_ state: MicUser.State) -> String {
        switch state {
        case .virtualMic: return "checkmark.circle.fill"
        case .otherMic: return "xmark.circle.fill"
        case .idle: return "circle"
        }
    }

    private func color(_ state: MicUser.State) -> Color {
        switch state {
        case .virtualMic: return OmiColors.success
        case .otherMic: return OmiColors.warning
        case .idle: return OmiColors.textQuaternary
        }
    }

    private func detail(_ state: MicUser.State) -> String {
        switch state {
        case .virtualMic: return "Hears the translation"
        case .otherMic(let mic):
            return "Uses \(mic.isEmpty ? "another microphone" : mic) — choose “BlackHole 2ch” as the microphone in its audio settings"
        case .idle: return "Not in a call"
        }
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("I speak").scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                Spacer()
                Picker("", selection: $fromLanguage) {
                    Text("My language (\(MeetingLanguages.displayName(MeetingLanguages.myLanguage())))")
                        .tag(CopilotSettings.followSystemLanguage)
                    Divider()
                    ForEach(MeetingLanguages.readable) { Text($0.name).tag($0.code) }
                }
                .labelsHidden().frame(maxWidth: 220)
                .onChange(of: fromLanguage) { _, value in CopilotSettings.shared.interpreterFromLanguage = value }
            }
            HStack {
                Text("They hear").scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                Spacer()
                Picker("", selection: $toLanguage) {
                    Text("The meeting's language (now \(MeetingLanguages.displayName(engine.targetCode)))")
                        .tag(CopilotSettings.meetingLanguage)
                    Divider()
                    ForEach(MeetingLanguages.readable) { Text($0.name).tag($0.code) }
                }
                .labelsHidden().frame(maxWidth: 220)
                .onChange(of: toLanguage) { _, value in
                    CopilotSettings.shared.interpreterToLanguage = value
                    voiceID = CopilotSettings.shared.interpreterVoiceID(for: engine.targetCode)
                }
            }
        }
    }

    private var voice: some View {
        let language = engine.targetCode
        let options = InterpreterVoices.options(for: language, hasLingKey: ling.usable)
        let current = InterpreterVoices.voice(id: voiceID, for: language, hasLingKey: ling.usable)
        return HStack {
            Text("Voice").scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
            Spacer()
            Picker("", selection: Binding(get: { current.id }, set: { voiceID = $0 })) {
                ForEach(options) { option in
                    Text("\(option.name) — \(option.detail)").tag(option.id)
                }
            }
            .labelsHidden().frame(maxWidth: 260)
            .onChange(of: voiceID) { _, value in CopilotSettings.shared.setInterpreterVoiceID(value, for: language) }
            Button("Preview") { engine.preview(language: language) }
        }
    }

    private var lingKey: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ling key (optional)").scaledFont(size: 13, weight: .semibold).foregroundColor(OmiColors.textPrimary)
            Text(
                "With a key from ant-ling.com, interpretation can speak in your own voice and hears names "
                    + "better. It is kept in a file only you can read — never in settings, logs or exports."
            )
            .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            if let key = ling.key {
                HStack(spacing: 10) {
                    Text(LingKeyStore.masked(key)).scaledFont(size: 12, design: .monospaced)
                        .foregroundColor(OmiColors.textSecondary)
                    Text(keyStatus).scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                    Spacer()
                    Button("Remove") { ling.removeKey() }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("sk-…", text: $keyDraft).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Button("Save") {
                        let draft = keyDraft
                        keyDraft = ""
                        Task { await ling.setKey(draft) }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var keyStatus: String {
        switch ling.keyState {
        case .none: return ""
        case .unchecked: return "Not checked yet"
        case .checking: return "Checking…"
        case .ok: return "Works"
        case .invalid: return "Ling refused this key"
        case .unreachable: return "Can't reach Ling — check the network"
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Record from").scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                Spacer()
                Picker("", selection: $micUID) {
                    Text("My microphone (automatic)").tag("")
                    ForEach(SystemMic.shared.realInputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().frame(maxWidth: 260)
                .onChange(of: micUID) { _, value in CopilotSettings.shared.interpreterMicUID = value }
            }
            HStack {
                Text("Speak into").scaledFont(size: 13).foregroundColor(OmiColors.textSecondary)
                Spacer()
                Picker("", selection: $outputUID) {
                    Text("The virtual microphone").tag("")
                    ForEach(AudioDevices.outputs(), id: \.uid) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().frame(maxWidth: 260)
                .onChange(of: outputUID) { _, value in CopilotSettings.shared.interpreterOutputUID = value }
            }
            if let failure = engine.lastFailure {
                Text(failure).scaledFont(size: 11).foregroundColor(OmiColors.warning)
            } else if !engine.lastSpoken.isEmpty {
                Text("Last sent (\(engine.lastVoice)): \(engine.lastSpoken)").scaledFont(size: 11)
                    .foregroundColor(OmiColors.textTertiary).lineLimit(2)
            }
        }
    }
}

/// Recording the sample Ming clones your voice from.
private struct MyVoiceSampleRow: View {
    let language: String
    @StateObject private var recorder = VoiceSampleRecorder()
    @ObservedObject private var ling = LingClient.shared
    @State private var hasSample = VoiceSample.exists

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("My own voice").scaledFont(size: 13, weight: .semibold).foregroundColor(OmiColors.textPrimary)
            Text(
                "Read a short passage (8–30 seconds) and the room hears the translation in your voice. "
                    + "The recording stays on this Mac; it goes to Ling only inside a request to speak, and "
                    + "no voiceprint is kept."
            )
            .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            if !ling.usable {
                Text("Needs a Ling key (below).").scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            } else {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch recorder.phase {
        case .recording:
            Text(VoiceSample.passage(for: language)).scaledFont(size: 12).foregroundColor(OmiColors.textPrimary)
                .padding(8).background(RoundedRectangle(cornerRadius: 6).fill(OmiColors.backgroundTertiary))
            HStack {
                ProgressView(value: Double(recorder.level)).frame(width: 80)
                Text(String(format: "%.0f s", recorder.seconds)).scaledFont(size: 11).monospacedDigit()
                    .foregroundColor(OmiColors.textSecondary)
                Button("Stop") { recorder.finish() }
                Button("Cancel") { recorder.cancel() }
            }
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking the recording…").scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            }
        case .ready:
            Text("Heard: “\(recorder.transcript)”").scaledFont(size: 11).foregroundColor(OmiColors.textSecondary)
            HStack {
                Button("Use this") { hasSample = recorder.keep() || VoiceSample.exists }
                Button("Record again") {
                    recorder.start(language: language, device: SystemMic.shared.recordingDevice(chosen: CopilotSettings.shared.interpreterMicUID))
                }
            }
        case .failed(let message):
            Text(message).scaledFont(size: 11).foregroundColor(OmiColors.warning)
            recordButton(hasSample ? "Record again" : "Record my voice")
        case .idle:
            if hasSample {
                HStack {
                    Text(String(format: "Recorded (%.0f s)", VoiceSample.duration)).scaledFont(size: 12)
                        .foregroundColor(OmiColors.textSecondary)
                    Spacer()
                    recordButton("Record again")
                    Button("Delete") {
                        VoiceSample.remove()
                        hasSample = false
                    }
                }
            } else {
                recordButton("Record my voice")
            }
        }
    }

    private func recordButton(_ title: String) -> some View {
        Button(title) {
            recorder.start(
                language: language,
                device: SystemMic.shared.recordingDevice(chosen: CopilotSettings.shared.interpreterMicUID))
        }
    }
}
