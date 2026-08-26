import SwiftUI

/// Fill in what this kind of session needs before you walk into it.
///
/// The slots change with the scenario, because what an interview needs and what a sales
/// call needs are not the same question. Values are kept per scenario, so switching to
/// Interview brings back the résumé you pasted last time rather than a blank form.
struct CopilotPrepSheetView: View {
    @ObservedObject private var store = CopilotPrepSheetStore.shared
    @State private var values: [String: String] = [:]
    @State private var scenarioId: String = ""
    let onDismiss: () -> Void

    private var profile: CopilotScenarioProfile { CopilotSettings.shared.scenario }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Prep for \(profile.displayName)").scaledFont(size: 18, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
                Spacer()
            }

            Text(
                "The copilot reads this before it says anything. Without it, it can only give you advice that would fit anyone."
            )
            .scaledFont(size: 12).foregroundColor(OmiColors.textTertiary)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(profile.effectivePrepSlots) { slot in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(slot.label).scaledFont(size: 13, weight: .medium)
                                    .foregroundColor(OmiColors.textSecondary)
                                Spacer()
                                Text(counter(for: slot.key)).scaledFont(size: 10)
                                    .foregroundColor(OmiColors.textTertiary)
                            }
                            TextEditor(
                                text: Binding(
                                    get: { values[slot.key] ?? "" },
                                    set: { values[slot.key] = $0 })
                            )
                            .font(.system(size: 12))
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(OmiColors.backgroundTertiary.opacity(0.5))
                            .cornerRadius(6)
                            Text(slot.placeholder).scaledFont(size: 11)
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    }
                }
            }

            Text("Stays on this Mac, and only goes to the model while this scenario is active.")
                .scaledFont(size: 11).foregroundColor(OmiColors.textTertiary)

            HStack {
                Button("Clear") {
                    store.clear(scenarioId: profile.id)
                    values = [:]
                }
                .buttonStyle(.plain).foregroundColor(OmiColors.error)
                Spacer()
                Button("Cancel") { onDismiss() }.buttonStyle(.plain)
                    .foregroundColor(OmiColors.textSecondary)
                Button("Save") {
                    save()
                    onDismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
        .onAppear { load() }
    }

    private func counter(for key: String) -> String {
        let count = (values[key] ?? "").count
        guard count > 0 else { return "" }
        let max = CopilotPrepSheet.maxCharactersPerSlot
        // Truncation is silent at save time, so say it before it happens.
        return count > max ? "\(count) chars — will keep the first \(max)" : "\(count) chars"
    }

    private func load() {
        scenarioId = profile.id
        let sheet = store.sheet(for: profile.id)
        var loaded: [String: String] = [:]
        for slot in profile.effectivePrepSlots {
            loaded[slot.key] = sheet?.value(for: slot.key) ?? ""
        }
        values = loaded
    }

    private func save() {
        for slot in profile.effectivePrepSlots {
            store.setValue(values[slot.key] ?? "", forSlot: slot.key, scenarioId: profile.id)
        }
    }
}
