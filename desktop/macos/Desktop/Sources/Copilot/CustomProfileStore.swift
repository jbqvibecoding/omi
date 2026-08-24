import Foundation

/// Persists user-created copilot scenario profiles in UserDefaults (JSON). Built-in
/// profiles stay as code constants; these are additive and merged into the picker.
@MainActor
final class CustomProfileStore: ObservableObject {
    static let shared = CustomProfileStore()

    private let storeKey = "copilotCustomProfiles"

    @Published private(set) var profiles: [CopilotScenarioProfile]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let decoded = try? JSONDecoder().decode([CopilotScenarioProfile].self, from: data) {
            profiles = decoded.map { var p = $0; p = Self.markCustom(p); return p }
        } else {
            profiles = []
        }
    }

    private static func markCustom(_ p: CopilotScenarioProfile) -> CopilotScenarioProfile {
        CopilotScenarioProfile(
            id: p.id, displayName: p.displayName, systemPromptBlock: p.systemPromptBlock,
            triggerVocabulary: p.triggerVocabulary, isCustom: true, prepSlots: p.prepSlots)
    }

    /// Create or update a custom profile. Returns the stored profile (with a stable id).
    @discardableResult
    func upsert(id: String?, displayName: String, systemPromptBlock: String, triggerVocabulary: [String])
        -> CopilotScenarioProfile
    {
        let profileId = id ?? "custom_\(UUID().uuidString.prefix(8))"
        let profile = CopilotScenarioProfile(
            id: profileId, displayName: displayName, systemPromptBlock: systemPromptBlock,
            triggerVocabulary: triggerVocabulary, isCustom: true,
            // Keep whatever prep slots this profile already had; the editor doesn't
            // define them, so re-saving must not silently drop them.
            prepSlots: profiles.first { $0.id == profileId }?.prepSlots)
        if let idx = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        persist()
        return profile
    }

    func delete(id: String) {
        profiles.removeAll { $0.id == id }
        persist()
        // If the deleted profile was active, fall back to the default.
        if CopilotSettings.shared.scenarioId == id {
            CopilotSettings.shared.scenarioId = CopilotScenarioProfile.meeting.id
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
        NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
    }
}
