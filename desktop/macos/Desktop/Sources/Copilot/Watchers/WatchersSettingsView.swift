import SwiftUI

/// Lists user-defined watchers and channel credentials; entry point for creating/editing.
struct WatchersManagerView: View {
    @ObservedObject private var store = WatcherStore.shared
    @State private var editing: WatcherAgent?
    @State private var showingNew = false
    @State private var telegramToken: String = ""
    @State private var pushoverToken: String = ""
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Watchers").scaledFont(size: 18, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
                Spacer()
                Button("New watcher") { showingNew = true }
            }

            Text("Watchers run on a loop: they look at your screen/audio/clipboard, ask the model, and act when a condition is met.")
                .scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)

            if store.watchers.isEmpty {
                Text("No watchers yet.").scaledFont(size: 13).foregroundColor(OmiColors.textTertiary)
            } else {
                ForEach(store.watchers) { watcher in
                    HStack {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { watcher.isEnabled },
                                set: { store.setEnabled(id: watcher.id, $0) })
                        ).toggleStyle(.switch).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(watcher.name).scaledFont(size: 14).foregroundColor(OmiColors.textPrimary)
                            Text("every \(watcher.effectiveInterval)s · \(watcher.actions.count) action(s)")
                                .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                        }
                        Spacer()
                        Button("Edit") { editing = watcher }.buttonStyle(.plain)
                            .foregroundColor(OmiColors.textSecondary)
                        Button("Delete") { store.delete(id: watcher.id) }.buttonStyle(.plain)
                            .foregroundColor(OmiColors.error)
                    }
                    .padding(.vertical, 3)
                }
            }

            Divider().background(OmiColors.backgroundQuaternary)

            Text("Notification channels").scaledFont(size: 13, weight: .semibold)
                .foregroundColor(OmiColors.textSecondary)
            Text("Discord needs no setup (paste a webhook URL as the action target). Telegram/Pushover need your own token.")
                .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            HStack {
                Text("Telegram bot token").scaledFont(size: 12).foregroundColor(OmiColors.textSecondary)
                    .frame(width: 140, alignment: .leading)
                SecureField("from @BotFather", text: $telegramToken)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: telegramToken) { _, v in WatcherChannelSettings.shared.telegramBotToken = v }
            }
            HStack {
                Text("Pushover app token").scaledFont(size: 12).foregroundColor(OmiColors.textSecondary)
                    .frame(width: 140, alignment: .leading)
                SecureField("application token", text: $pushoverToken)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: pushoverToken) { _, v in WatcherChannelSettings.shared.pushoverAppToken = v }
            }

            HStack { Spacer(); Button("Done") { onDismiss() } }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            telegramToken = WatcherChannelSettings.shared.telegramBotToken
            pushoverToken = WatcherChannelSettings.shared.pushoverAppToken
        }
        .sheet(isPresented: $showingNew) {
            WatcherEditorView(existing: nil) { showingNew = false }
        }
        .sheet(item: $editing) { watcher in
            WatcherEditorView(existing: watcher) { editing = nil }
        }
    }
}

/// Create or edit a single watcher, with optional AI drafting from a description.
struct WatcherEditorView: View {
    let existing: WatcherAgent?
    let onDismiss: () -> Void

    @State private var name: String
    @State private var systemPrompt: String
    @State private var interval: Int
    @State private var onlyOnChange: Bool
    @State private var conditionType: String
    @State private var conditionKeyword: String
    @State private var actions: [EditableAction]
    @State private var describeText: String = ""
    @State private var isGenerating = false
    @State private var generationError: String?

    private let sensorTokens = ["$SCREEN", "$SCREEN_OCR", "$CLIPBOARD", "$MEMORY", "$ALL_AUDIO", "$TIME"]

    init(existing: WatcherAgent?, onDismiss: @escaping () -> Void) {
        self.existing = existing
        self.onDismiss = onDismiss
        _name = State(initialValue: existing?.name ?? "")
        _systemPrompt = State(initialValue: existing?.systemPrompt ?? "")
        _interval = State(initialValue: existing?.effectiveInterval ?? WatcherAgent.defaultLoopIntervalSeconds)
        _onlyOnChange = State(initialValue: existing?.onlyOnSignificantChange ?? true)
        switch existing?.condition {
        case let .responseContains(keyword, _):
            _conditionType = State(initialValue: "contains")
            _conditionKeyword = State(initialValue: keyword)
        case let .responseMatches(regex):
            _conditionType = State(initialValue: "matches")
            _conditionKeyword = State(initialValue: regex)
        default:
            _conditionType = State(initialValue: "always")
            _conditionKeyword = State(initialValue: "")
        }
        _actions = State(initialValue: (existing?.actions ?? []).map(EditableAction.init(from:)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(existing == nil ? "New watcher" : "Edit watcher")
                    .scaledFont(size: 18, weight: .semibold).foregroundColor(OmiColors.textPrimary)

                // AI drafting
                VStack(alignment: .leading, spacing: 6) {
                    Text("Describe what it should watch for (optional)")
                        .scaledFont(size: 13, weight: .medium).foregroundColor(OmiColors.textSecondary)
                    HStack {
                        TextField("e.g. tell me on Telegram when my build finishes", text: $describeText)
                            .textFieldStyle(.roundedBorder)
                        Button(isGenerating ? "Generating…" : "Generate with AI") {
                            Task { await generate() }
                        }
                        .disabled(isGenerating || describeText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let generationError {
                        Text(generationError).scaledFont(size: 11).foregroundColor(OmiColors.error)
                    }
                }

                Divider().background(OmiColors.backgroundQuaternary)

                field("Name") {
                    TextField("Watcher name", text: $name).textFieldStyle(.roundedBorder)
                }
                field("Instruction (use sensor placeholders)") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $systemPrompt)
                            .font(.system(size: 12)).frame(minHeight: 100)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(OmiColors.backgroundQuaternary))
                        HStack {
                            ForEach(sensorTokens, id: \.self) { token in
                                Button(token) { systemPrompt += (systemPrompt.isEmpty ? "" : " ") + token }
                                    .buttonStyle(.plain).scaledFont(size: 10)
                                    .foregroundColor(OmiColors.textSecondary)
                            }
                        }
                    }
                }

                HStack(spacing: 20) {
                    field("Every (seconds)") {
                        TextField("60", value: $interval, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    Toggle("Only when the screen changes", isOn: $onlyOnChange)
                        .scaledFont(size: 13).foregroundColor(OmiColors.textPrimary)
                }

                field("Act when the response…") {
                    HStack {
                        Picker("", selection: $conditionType) {
                            Text("always").tag("always")
                            Text("contains").tag("contains")
                            Text("matches (regex)").tag("matches")
                        }.pickerStyle(.menu).frame(width: 160)
                        if conditionType != "always" {
                            TextField(conditionType == "matches" ? "regex" : "keyword", text: $conditionKeyword)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                // Actions
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Actions").scaledFont(size: 13, weight: .medium).foregroundColor(OmiColors.textSecondary)
                        Spacer()
                        Button("Add action") { actions.append(EditableAction()) }
                            .buttonStyle(.plain).scaledFont(size: 12).foregroundColor(OmiColors.textSecondary)
                    }
                    ForEach($actions) { $action in
                        actionRow($action)
                    }
                }

                HStack {
                    Spacer()
                    Button("Cancel") { onDismiss() }.buttonStyle(.plain).foregroundColor(OmiColors.textSecondary)
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
    }

    @ViewBuilder
    private func actionRow(_ action: Binding<EditableAction>) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: action.type) {
                Text("append memory").tag("appendMemory")
                Text("notify HUD").tag("notifyHUD")
                Text("overlay").tag("overlay")
                Text("notify channel").tag("notifyChannel")
                Text("sleep").tag("sleep")
                Text("stop self").tag("stopSelf")
            }.pickerStyle(.menu).frame(width: 130)

            switch action.wrappedValue.type {
            case "notifyChannel":
                Picker("", selection: action.channel) {
                    ForEach(WatcherNotificationChannel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).frame(width: 90)
                TextField("target (webhook/chat id/user key)", text: action.target).textFieldStyle(.roundedBorder)
                TextField("message", text: action.text).textFieldStyle(.roundedBorder)
            case "sleep":
                TextField("seconds", value: action.seconds, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
            case "stopSelf":
                Spacer()
            default:
                TextField("text ($RESPONSE, $TIME)", text: action.text).textFieldStyle(.roundedBorder)
            }

            Button {
                actions.removeAll { $0.id == action.wrappedValue.id }
            } label: { Image(systemName: "trash").foregroundColor(OmiColors.error) }
                .buttonStyle(.plain)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).scaledFont(size: 13, weight: .medium).foregroundColor(OmiColors.textSecondary)
            content()
        }
    }

    private func buildCondition() -> WatcherCondition {
        switch conditionType {
        case "contains": return .responseContains(keyword: conditionKeyword, caseInsensitive: true)
        case "matches": return .responseMatches(regex: conditionKeyword)
        default: return .always
        }
    }

    private func save() {
        let watcher = WatcherAgent(
            id: existing?.id ?? "watcher_\(UUID().uuidString.prefix(8))",
            name: name.trimmingCharacters(in: .whitespaces),
            systemPrompt: systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            loopIntervalSeconds: max(WatcherAgent.minLoopIntervalSeconds, interval),
            onlyOnSignificantChange: onlyOnChange,
            condition: buildCondition(),
            actions: actions.map { $0.toAction() },
            isEnabled: existing?.isEnabled ?? false)
        WatcherStore.shared.upsert(watcher)
        onDismiss()
    }

    private func generate() async {
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }
        do {
            let draft = try await WatcherAICreator.generate(description: describeText)
            name = draft.name
            systemPrompt = draft.systemPrompt
            interval = draft.effectiveInterval
            onlyOnChange = draft.onlyOnSignificantChange
            switch draft.condition {
            case let .responseContains(keyword, _): conditionType = "contains"; conditionKeyword = keyword
            case let .responseMatches(regex): conditionType = "matches"; conditionKeyword = regex
            default: conditionType = "always"; conditionKeyword = ""
            }
            actions = draft.actions.map(EditableAction.init(from:))
        } catch {
            generationError = "Couldn't generate — fill the fields manually."
        }
    }
}

/// Editable, flat mirror of a WatcherAction for the form.
struct EditableAction: Identifiable {
    let id = UUID()
    var type: String = "notifyHUD"
    var text: String = "$RESPONSE"
    var channel: WatcherNotificationChannel = .discord
    var target: String = ""
    var seconds: Int = 600

    init() {}

    init(from action: WatcherAction) {
        switch action {
        case let .appendMemory(template): type = "appendMemory"; text = template
        case let .notifyHUD(_, message): type = "notifyHUD"; text = message
        case let .overlay(body): type = "overlay"; text = body
        case let .notifyChannel(ch, tgt, message):
            type = "notifyChannel"; channel = ch; target = tgt; text = message
        case let .sleep(secs): type = "sleep"; seconds = secs
        case .stopSelf: type = "stopSelf"
        }
    }

    func toAction() -> WatcherAction {
        switch type {
        case "appendMemory": return .appendMemory(template: text)
        case "overlay": return .overlay(body: text)
        case "notifyChannel": return .notifyChannel(channel: channel, target: target, message: text)
        case "sleep": return .sleep(seconds: seconds)
        case "stopSelf": return .stopSelf
        default: return .notifyHUD(title: "Watcher", message: text)
        }
    }
}
