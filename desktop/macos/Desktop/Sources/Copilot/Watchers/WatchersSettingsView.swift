import AppKit
import SwiftUI

/// Lists user-defined watchers and channel credentials; entry point for creating/editing.
struct WatchersManagerView: View {
    @ObservedObject private var store = WatcherStore.shared
    @ObservedObject private var approvals = WatcherApprovalStore.shared
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
                            Text(subtitle(for: watcher))
                                .scaledFont(size: 11)
                                .foregroundColor(
                                    watcher.consecutiveFailures > 0 ? OmiColors.error : OmiColors.textTertiary)
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

            if !approvals.pending.isEmpty {
                Divider().background(OmiColors.backgroundQuaternary)
                Text("Waiting for you (\(approvals.pending.count))")
                    .scaledFont(size: 13, weight: .semibold).foregroundColor(OmiColors.textSecondary)
                Text("Nothing is sent until you approve it.")
                    .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                ForEach(approvals.pending) { item in
                    WatcherApprovalRow(item: item)
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

    private func subtitle(for watcher: WatcherAgent) -> String {
        var parts = [watcher.effectiveSchedule.humanLabel, "\(watcher.actions.count) action(s)"]
        if watcher.consecutiveFailures > 0 {
            parts.append("failed \(watcher.consecutiveFailures)×")
        } else if watcher.isEnabled, let next = watcher.effectiveSchedule.nextFireDate(after: Date()) {
            parts.append("next \(WatcherEditorView.relativeLabel(next))")
        }
        let unread = WatcherRunStore.shared.unreadCount(watcherId: watcher.id)
        if unread > 0 { parts.append("\(unread) new run(s)") }
        return parts.joined(separator: " · ")
    }
}

/// One parked approval: the draft is editable, and nothing leaves this Mac until Send.
struct WatcherApprovalRow: View {
    let item: WatcherApprovalItem
    @State private var draft: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(item.watcherName) — \(item.kind)")
                    .scaledFont(size: 13, weight: .medium).foregroundColor(OmiColors.textPrimary)
                Spacer()
                Text(item.scopeNote)
                    .scaledFont(size: 10)
                    .foregroundColor(item.risk == .external ? OmiColors.warning : OmiColors.textTertiary)
            }
            if let target = item.target, !target.isEmpty {
                Text("To: \(target)").scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            TextEditor(text: $draft)
                .font(.system(size: 12))
                .frame(minHeight: 60)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(OmiColors.backgroundQuaternary))
            HStack {
                Spacer()
                Button("Discard") {
                    _ = WatcherApprovalStore.shared.resolve(id: item.id, resolution: "deny")
                }
                .buttonStyle(.plain).scaledFont(size: 12).foregroundColor(OmiColors.textSecondary)
                if item.grantEntry != nil {
                    Button("Send, always allow this target") {
                        _ = WatcherApprovalStore.shared.resolve(
                            id: item.id, resolution: "always", editedBody: draft)
                    }
                    .scaledFont(size: 12)
                }
                Button("Send") {
                    _ = WatcherApprovalStore.shared.resolve(
                        id: item.id, resolution: "allow", editedBody: draft)
                }
                .scaledFont(size: 12)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            guard !loaded else { return }
            draft = item.finalBody
            loaded = true
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
    @State private var backendKind: WatcherBackendKind
    @State private var modelId: String
    @State private var approvalPolicy: WatcherApprovalPolicy
    @State private var standingGrants: [String]
    @State private var describeText: String = ""
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var scheduleKind: String
    @State private var scheduleTime: Date
    @State private var scheduleDate: Date
    @State private var scheduleDays: [Int]
    @State private var scheduleDay: Int
    @State private var cronExpression: String
    @State private var allowSelfPacing: Bool
    @State private var eventCriteria: String
    @State private var documentMode: Bool

    private let sensorTokens = ["$SCREEN", "$SCREEN_OCR", "$CAMERA", "$CLIPBOARD", "$MEMORY", "$ALL_AUDIO", "$TIME"]

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
        _backendKind = State(initialValue: existing?.effectiveBackend ?? .gemini)
        _modelId = State(initialValue: existing?.modelId ?? "")
        _approvalPolicy = State(initialValue: existing?.effectiveApprovalPolicy ?? .ask)
        _standingGrants = State(initialValue: existing?.standingGrantEntries ?? [])

        // Unpack the stored schedule into the editor's flat fields.
        let calendar = Calendar.current
        let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        var kind = "interval"
        var time = nineAM
        var days = [2]
        var monthDay = 1
        var cron = "0 9 * * 1-5"
        var onceAt = Date().addingTimeInterval(3600)
        switch existing?.schedule {
        case let .daily(hour, minute):
            kind = "daily"
            time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? nineAM
        case let .weekdays(hour, minute):
            kind = "weekdays"
            time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? nineAM
        case let .weekly(weekdays, hour, minute):
            kind = "weekly"
            days = weekdays
            time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? nineAM
        case let .monthly(day, hour, minute):
            kind = "monthly"
            monthDay = day
            time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? nineAM
        case let .cron(expression):
            kind = "cron"
            cron = expression
        case let .once(at):
            kind = "once"
            onceAt = at
        default:
            kind = "interval"
        }
        _scheduleKind = State(initialValue: kind)
        _scheduleTime = State(initialValue: time)
        _scheduleDate = State(initialValue: onceAt)
        _scheduleDays = State(initialValue: days)
        _scheduleDay = State(initialValue: monthDay)
        _cronExpression = State(initialValue: cron)
        _allowSelfPacing = State(initialValue: existing?.isSelfPaced ?? false)
        _eventCriteria = State(initialValue: existing?.eventCriteria ?? "")
        _documentMode = State(initialValue: existing?.isDocumentMode ?? false)
    }

    private func buildSchedule() -> WatcherSchedule {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: scheduleTime)
        let hour = parts.hour ?? 9
        let minute = parts.minute ?? 0
        switch scheduleKind {
        case "daily": return .daily(hour: hour, minute: minute)
        case "weekdays": return .weekdays(hour: hour, minute: minute)
        case "weekly":
            return .weekly(days: scheduleDays.isEmpty ? [2] : scheduleDays.sorted(), hour: hour, minute: minute)
        case "monthly":
            return .monthly(day: max(1, min(31, scheduleDay)), hour: hour, minute: minute)
        case "cron":
            // An unparseable expression would silently never fire, so fall back to the
            // interval loop rather than leaving a watcher that looks armed but is dead.
            return WatcherCron.parse(cronExpression) == nil
                ? .interval(seconds: max(WatcherAgent.minLoopIntervalSeconds, interval))
                : .cron(expression: cronExpression)
        case "once": return .once(at: scheduleDate)
        default: return .interval(seconds: max(WatcherAgent.minLoopIntervalSeconds, interval))
        }
    }

    static func relativeLabel(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
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
                    if existing != nil {
                        Button(isGenerating ? "Improving…" : "Improve from recent runs") {
                            Task { await improveFromRuns() }
                        }
                        .buttonStyle(.plain).scaledFont(size: 12).foregroundColor(OmiColors.textSecondary)
                        .disabled(isGenerating)
                    }
                }

                Divider().background(OmiColors.backgroundQuaternary)

                // Grouped by what the user is deciding — which also keeps this block inside
                // ViewBuilder's ten-child limit.
                Group {
                    field("Name") {
                        TextField("Watcher name", text: $name).textFieldStyle(.roundedBorder)
                    }
                    field("Instruction (use sensor placeholders)") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $systemPrompt)
                                .font(.system(size: 12)).frame(minHeight: 100)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(OmiColors.backgroundQuaternary))
                            HStack {
                                ForEach(sensorTokens, id: \.self) { token in
                                    Button(token) {
                                        systemPrompt += (systemPrompt.isEmpty ? "" : " ") + token
                                    }
                                    .buttonStyle(.plain).scaledFont(size: 10)
                                    .foregroundColor(OmiColors.textSecondary)
                                }
                            }
                        }
                    }
                }

                Group {
                field("When it runs") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $scheduleKind) {
                            Text("Every N seconds").tag("interval")
                            Text("Every day").tag("daily")
                            Text("Weekdays").tag("weekdays")
                            Text("Certain days").tag("weekly")
                            Text("Monthly").tag("monthly")
                            Text("Once").tag("once")
                            Text("Advanced (cron)").tag("cron")
                        }.pickerStyle(.menu).frame(width: 200)

                        switch scheduleKind {
                        case "interval":
                            HStack {
                                TextField("60", value: $interval, format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 80)
                                Text("seconds").scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)
                            }
                        case "cron":
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("0 9 * * 1-5", text: $cronExpression).textFieldStyle(.roundedBorder)
                                Text(
                                    WatcherCron.parse(cronExpression) == nil
                                        ? "Not a valid 5-field cron expression."
                                        : "minute hour day month weekday · your local time"
                                )
                                .scaledFont(size: 11)
                                .foregroundColor(
                                    WatcherCron.parse(cronExpression) == nil
                                        ? OmiColors.error : OmiColors.textTertiary)
                            }
                        case "once":
                            DatePicker("", selection: $scheduleDate).labelsHidden()
                        default:
                            VStack(alignment: .leading, spacing: 6) {
                                if scheduleKind == "weekly" {
                                    HStack(spacing: 4) {
                                        ForEach(1...7, id: \.self) { day in
                                            Button(WatcherSchedule.weekdayName(day)) {
                                                if scheduleDays.contains(day) {
                                                    scheduleDays.removeAll { $0 == day }
                                                } else {
                                                    scheduleDays.append(day)
                                                }
                                            }
                                            .buttonStyle(.plain).scaledFont(size: 11)
                                            .foregroundColor(
                                                scheduleDays.contains(day)
                                                    ? OmiColors.textPrimary : OmiColors.textTertiary)
                                        }
                                    }
                                }
                                if scheduleKind == "monthly" {
                                    HStack {
                                        Text("Day").scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)
                                        TextField("1", value: $scheduleDay, format: .number)
                                            .textFieldStyle(.roundedBorder).frame(width: 50)
                                    }
                                }
                                DatePicker(
                                    "", selection: $scheduleTime, displayedComponents: .hourAndMinute
                                ).labelsHidden()
                            }
                        }

                        if let next = buildSchedule().nextFireDate(after: Date()) {
                            Text("Next run \(Self.relativeLabel(next))")
                                .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                        }
                    }
                }

                Toggle("Only when the screen changes", isOn: $onlyOnChange)
                    .scaledFont(size: 13).foregroundColor(OmiColors.textPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Let it decide when to look again", isOn: $allowSelfPacing)
                        .scaledFont(size: 13).foregroundColor(OmiColors.textPrimary)
                    Text("It can ask to be woken sooner than the schedule when something is about to change. It can never ask to skip a run.")
                        .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                }

                field("Also run when something happens (optional)") {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            "e.g. any meeting where a competitor launch comes up",
                            text: $eventCriteria
                        ).textFieldStyle(.roundedBorder)
                        Text("Plain English. Leave empty to run on the schedule only.")
                            .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                    }
                }
                }

                Group {
                field("What it does") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $documentMode) {
                            Text("Take actions").tag(false)
                            Text("Keep a document up to date").tag(true)
                        }.pickerStyle(.radioGroup)
                        if documentMode {
                            Text(
                                "Writes to "
                                    + WatcherDocument.directory
                                    .appendingPathComponent(
                                        "\(WatcherDocument.safeName(name)).md"
                                    ).path)
                                .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }

                field("Before sending anything off this Mac") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $approvalPolicy) {
                            Text("Ask me first (recommended)").tag(WatcherApprovalPolicy.ask)
                            Text("Send without asking").tag(WatcherApprovalPolicy.auto)
                        }.pickerStyle(.radioGroup)
                        if !standingGrants.isEmpty {
                            Text("Allowed without asking")
                                .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
                            ForEach(standingGrants, id: \.self) { entry in
                                HStack {
                                    Text(WatcherPermission.describeGrant(entry))
                                        .scaledFont(size: 11).foregroundColor(OmiColors.textSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Button("Revoke") { standingGrants.removeAll { $0 == entry } }
                                        .buttonStyle(.plain).scaledFont(size: 11)
                                        .foregroundColor(OmiColors.error)
                                }
                            }
                        }
                    }
                }

                field("Model") {
                    HStack {
                        Picker("", selection: $backendKind) {
                            Text("Omi (cloud)").tag(WatcherBackendKind.gemini)
                            Text("Ollama (local)").tag(WatcherBackendKind.ollama)
                        }.pickerStyle(.menu).frame(width: 150)
                        if backendKind == .ollama {
                            TextField("model, e.g. gemma3", text: $modelId).textFieldStyle(.roundedBorder)
                        }
                    }
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

                // Actions — irrelevant in document mode, where the file is the output.
                if !documentMode {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Actions").scaledFont(size: 13, weight: .medium)
                                .foregroundColor(OmiColors.textSecondary)
                            Spacer()
                            Button("Add action") { actions.append(EditableAction()) }
                                .buttonStyle(.plain).scaledFont(size: 12)
                                .foregroundColor(OmiColors.textSecondary)
                        }
                        ForEach($actions) { $action in
                            actionRow($action)
                        }
                    }
                }
                }

                if let existing {
                    Divider().background(OmiColors.backgroundQuaternary)
                    WatcherRunHistoryView(watcherId: existing.id)
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
                Text("start agent").tag("startAgent")
                Text("stop agent").tag("stopAgent")
                Text("sleep").tag("sleep")
                Text("stop self").tag("stopSelf")
            }.pickerStyle(.menu).frame(width: 130)

            switch action.wrappedValue.type {
            case "notifyChannel":
                Picker("", selection: action.channel) {
                    ForEach(WatcherNotificationChannel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).frame(width: 90)
                TextField("target (webhook / chat id / user key / +phone)", text: action.target).textFieldStyle(.roundedBorder)
                TextField("message", text: action.text).textFieldStyle(.roundedBorder)
            case "startAgent", "stopAgent":
                Picker("", selection: action.target) {
                    Text("(pick watcher)").tag("")
                    ForEach(WatcherStore.shared.watchers.filter { $0.id != existing?.id }) { w in
                        Text(w.name).tag(w.id)
                    }
                }.pickerStyle(.menu)
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
            isEnabled: existing?.isEnabled ?? false,
            backend: backendKind,
            modelId: backendKind == .ollama ? modelId.trimmingCharacters(in: .whitespaces) : nil,
            approvalPolicy: approvalPolicy,
            standingGrants: standingGrants.isEmpty ? nil : standingGrants,
            schedule: buildSchedule(),
            lastRunAt: existing?.lastRunAt,
            lastAttemptAt: existing?.lastAttemptAt,
            // Editing a broken watcher is the user saying "try again" — clear the strikes
            // so a fixed watcher isn't still sitting in backoff.
            failCount: 0,
            allowSelfPacing: allowSelfPacing,
            eventMatchCriteria: eventCriteria.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: documentMode ? "document" : "action")
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

    private func improveFromRuns() async {
        guard let existing else { return }
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }
        do {
            let improved = try await WatcherAICreator.improve(
                existing: existing, instruction: describeText)
            name = improved.name
            systemPrompt = improved.systemPrompt
            interval = improved.effectiveInterval
            onlyOnChange = improved.onlyOnSignificantChange
            switch improved.condition {
            case let .responseContains(keyword, _): conditionType = "contains"; conditionKeyword = keyword
            case let .responseMatches(regex): conditionType = "matches"; conditionKeyword = regex
            default: conditionType = "always"; conditionKeyword = ""
            }
            actions = improved.actions.map(EditableAction.init(from:))
        } catch {
            generationError = "Couldn't improve — try editing manually."
        }
    }
}

/// What this watcher has actually been doing. An automation you can't see the history of
/// is one you can't trust, so this is plain: when, why it fired, and what came of it.
struct WatcherRunHistoryView: View {
    let watcherId: String
    @State private var runs: [WatcherRun] = []
    @State private var unread = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent runs").scaledFont(size: 13, weight: .medium)
                    .foregroundColor(OmiColors.textSecondary)
                if unread > 0 {
                    Text("\(unread) new").scaledFont(size: 10)
                        .foregroundColor(OmiColors.textPrimary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(OmiColors.backgroundQuaternary).cornerRadius(4)
                }
                Spacer()
                if !runs.isEmpty {
                    Button("Clear") {
                        WatcherRunStore.shared.clear(watcherId: watcherId)
                        runs = []
                        unread = 0
                    }
                    .buttonStyle(.plain).scaledFont(size: 11).foregroundColor(OmiColors.textSecondary)
                }
            }

            if runs.isEmpty {
                Text("Hasn't run yet.").scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)
            } else {
                ForEach(runs.reversed()) { run in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(color(for: run)).frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(run.summaryLine).scaledFont(size: 11)
                                .foregroundColor(OmiColors.textSecondary).lineLimit(2)
                            Text(subtitle(for: run)).scaledFont(size: 10)
                                .foregroundColor(OmiColors.textTertiary)
                        }
                        Spacer()
                        if let path = run.artifactsPath {
                            Button("Files") {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: path)
                                ])
                            }
                            .buttonStyle(.plain).scaledFont(size: 10)
                            .foregroundColor(OmiColors.textSecondary)
                            .help("Show what this run produced in Finder")
                        }
                    }
                }
            }
        }
        .onAppear {
            // Freeze the unread count before marking seen, so the badge doesn't vanish
            // from under the user the instant they open it.
            unread = WatcherRunStore.shared.unreadCount(watcherId: watcherId)
            runs = WatcherRunStore.shared.recent(watcherId: watcherId, limit: 20)
            WatcherRunStore.shared.markSeen(watcherId: watcherId)
        }
    }

    private func color(for run: WatcherRun) -> Color {
        switch run.effectiveStatus {
        case .ok: return run.conditionMet ? OmiColors.success : OmiColors.textTertiary
        case .error: return OmiColors.error
        case .skipped: return OmiColors.warning
        }
    }

    private func subtitle(for run: WatcherRun) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, HH:mm"
        var parts = [fmt.string(from: run.at)]
        switch run.effectiveTrigger {
        case .schedule: break
        case .manual: parts.append("run by hand")
        case .catchup: parts.append("caught up after your Mac woke")
        case .event: parts.append("triggered by an event")
        }
        if run.reused { parts.append("nothing changed, reused last answer") }
        if let ms = run.durationMs, ms > 0 { parts.append("\(ms) ms") }
        return parts.joined(separator: " · ")
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
        case let .startAgent(watcherId): type = "startAgent"; target = watcherId
        case let .stopAgent(watcherId): type = "stopAgent"; target = watcherId
        }
    }

    func toAction() -> WatcherAction {
        switch type {
        case "appendMemory": return .appendMemory(template: text)
        case "overlay": return .overlay(body: text)
        case "notifyChannel": return .notifyChannel(channel: channel, target: target, message: text)
        case "startAgent": return .startAgent(watcherId: target)
        case "stopAgent": return .stopAgent(watcherId: target)
        case "sleep": return .sleep(seconds: seconds)
        case "stopSelf": return .stopSelf
        default: return .notifyHUD(title: "Watcher", message: text)
        }
    }
}
