import SwiftUI

/// Sheet to create or edit a custom copilot scenario profile, with optional AI drafting
/// from a one-line description.
struct CustomProfileEditorView: View {
    /// The profile being edited, or nil to create a new one.
    let existing: CopilotScenarioProfile?
    let onDismiss: () -> Void

    @State private var displayName: String
    @State private var systemPromptBlock: String
    @State private var triggerText: String
    @State private var describeText: String = ""
    @State private var isGenerating = false
    @State private var generationError: String?

    init(existing: CopilotScenarioProfile?, onDismiss: @escaping () -> Void) {
        self.existing = existing
        self.onDismiss = onDismiss
        _displayName = State(initialValue: existing?.displayName ?? "")
        _systemPromptBlock = State(initialValue: existing?.systemPromptBlock ?? "")
        _triggerText = State(initialValue: (existing?.triggerVocabulary ?? []).joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "New scenario" : "Edit scenario")
                .scaledFont(size: 18, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)

            // AI drafting
            VStack(alignment: .leading, spacing: 6) {
                Text("Describe your scenario (optional)")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundColor(OmiColors.textSecondary)
                HStack {
                    TextField("e.g. I'm a cross-border e-commerce support agent", text: $describeText)
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
                TextField("Scenario name", text: $displayName).textFieldStyle(.roundedBorder)
            }
            field("Guidance (what counts as a high-value suggestion)") {
                TextEditor(text: $systemPromptBlock)
                    .font(.system(size: 12))
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(OmiColors.backgroundQuaternary))
            }
            field("Trigger words (comma-separated)") {
                TextField("price, competitor, concern", text: $triggerText).textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }.buttonStyle(.plain)
                Button("Save") { save() }
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty
                        || systemPromptBlock.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).scaledFont(size: 13, weight: .medium).foregroundColor(OmiColors.textSecondary)
            content()
        }
    }

    private func save() {
        let vocab = triggerText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        CustomProfileStore.shared.upsert(
            id: existing?.id, displayName: displayName.trimmingCharacters(in: .whitespaces),
            systemPromptBlock: systemPromptBlock.trimmingCharacters(in: .whitespacesAndNewlines),
            triggerVocabulary: vocab)
        onDismiss()
    }

    private func generate() async {
        isGenerating = true
        generationError = nil
        defer { isGenerating = false }
        do {
            let client = try GeminiClient(model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
            let imageData: Data = {
                guard let raw = ScreenCaptureManager.captureScreenJPEG() else { return Data() }
                return GeminiImageCompression.compress(raw) ?? raw
            }()
            let text = try await client.sendRequest(
                prompt: CopilotPrompts.customProfileUserPrompt(description: describeText),
                imageData: imageData,
                systemPrompt: CopilotPrompts.customProfileSystemPrompt,
                responseSchema: CopilotPrompts.customProfileSchema,
                thinkingBudget: 0)
            let draft = try JSONDecoder().decode(CopilotCustomProfileDraft.self, from: Data(text.utf8))
            displayName = draft.displayName
            systemPromptBlock = draft.systemPromptBlock
            triggerText = draft.triggerVocabulary.joined(separator: ", ")
        } catch {
            generationError = "Couldn't generate — edit the fields manually."
        }
    }
}

/// Lists built-in and custom scenarios; entry point for creating/editing custom ones.
struct CopilotProfilesManagerView: View {
    @ObservedObject private var store = CustomProfileStore.shared
    @State private var editing: CopilotScenarioProfile?
    @State private var showingNew = false
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scenarios").scaledFont(size: 18, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
                Spacer()
                Button("New scenario") { showingNew = true }
            }

            ForEach(CopilotScenarioProfile.allAvailable) { profile in
                HStack {
                    Text(profile.displayName).scaledFont(size: 14).foregroundColor(OmiColors.textPrimary)
                    if profile.isCustom {
                        Text("custom").scaledFont(size: 10).foregroundColor(OmiColors.textTertiary)
                    }
                    Spacer()
                    if profile.isCustom {
                        Button("Edit") { editing = profile }.buttonStyle(.plain)
                            .foregroundColor(OmiColors.textSecondary)
                        Button("Delete") { store.delete(id: profile.id) }.buttonStyle(.plain)
                            .foregroundColor(OmiColors.error)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack { Spacer(); Button("Done") { onDismiss() } }
        }
        .padding(20)
        .frame(width: 420)
        .sheet(isPresented: $showingNew) {
            CustomProfileEditorView(existing: nil) { showingNew = false }
        }
        .sheet(item: $editing) { profile in
            CustomProfileEditorView(existing: profile) { editing = nil }
        }
    }
}
