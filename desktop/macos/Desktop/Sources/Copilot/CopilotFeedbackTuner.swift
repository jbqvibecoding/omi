import Foundation

/// Learns from how the user reacts to copilot suggestion cards and adapts the
/// confidence threshold per (scenario × suggestion-type) bucket over time.
///
/// The signal is each card's fate: accepted (Copy / Execute / expand-to-chat) vs
/// ignored (manual dismiss / auto-timeout). Buckets that get dismissed a lot raise
/// their bar (fewer, higher-confidence suggestions); buckets that get acted on lower
/// it. Rule-based and fully transparent — surfaced in Settings and resettable — so
/// the product never silently "gets weird". Counts decay exponentially so recent
/// behavior dominates.
@MainActor
final class CopilotFeedbackTuner {
    static let shared = CopilotFeedbackTuner()

    enum Outcome {
        case accepted
        case ignored
    }

    private struct BucketStats: Codable {
        var accepted: Double = 0
        var ignored: Double = 0
        var updatedAt: Date = Date()

        var total: Double { accepted + ignored }
        var dismissRate: Double { total > 0 ? ignored / total : 0 }
        var acceptRate: Double { total > 0 ? accepted / total : 0 }
    }

    private let statsKey = "copilotFeedbackStats"
    private let dismissedTextsKey = "copilotDismissedTexts"

    /// Exponential decay applied to the opposing signal on each event (recent-weighted).
    private let decay = 0.9
    /// Minimum observed events in a bucket before we adjust its threshold.
    private let minSamples: Double = 5
    private let maxAdjustUp = 0.20   // ceiling delta so effective stays <= 0.95 from a 0.75 base
    private let confidenceCeiling = 0.95
    private let confidenceFloor = 0.70

    private var stats: [String: BucketStats]
    /// Recently ignored suggestion texts per scenario, for semantic suppression.
    private var dismissedTextsByScenario: [String: [String]]
    /// First outcome per notification wins (guards Copy→dismiss double counting).
    private var recorded: Set<UUID> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: statsKey),
           let decoded = try? JSONDecoder().decode([String: BucketStats].self, from: data) {
            stats = decoded
        } else {
            stats = [:]
        }
        if let data = UserDefaults.standard.data(forKey: dismissedTextsKey),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
            dismissedTextsByScenario = decoded
        } else {
            dismissedTextsByScenario = [:]
        }
    }

    // MARK: - Recording

    /// Record a card's outcome. Idempotent per notification id (first outcome wins).
    /// `bucket` is "scenario:type"; nil buckets (non-copilot cards) are ignored.
    func record(notificationId: UUID, bucket: String?, outcome: Outcome, suggestionText: String? = nil) {
        guard let bucket, !bucket.isEmpty else { return }
        guard !recorded.contains(notificationId) else { return }
        recorded.insert(notificationId)

        var s = stats[bucket] ?? BucketStats()
        switch outcome {
        case .accepted:
            s.accepted += 1
            s.ignored *= decay
        case .ignored:
            s.ignored += 1
            s.accepted *= decay
        }
        s.updatedAt = Date()
        stats[bucket] = s
        persistStats()

        if outcome == .ignored, let text = suggestionText, !text.isEmpty {
            let scenario = String(bucket.split(separator: ":").first ?? "")
            var list = dismissedTextsByScenario[scenario] ?? []
            list.append(text)
            if list.count > 12 { list.removeFirst(list.count - 12) }
            dismissedTextsByScenario[scenario] = list
            persistDismissedTexts()
        }

        PostHogManager.shared.track(
            "copilot_feedback_recorded",
            properties: ["bucket": bucket, "outcome": outcome == .accepted ? "accepted" : "ignored"]
        )
    }

    // MARK: - Adaptation

    /// The effective minimum confidence for a bucket, adjusted from the user's baseline.
    func effectiveMinConfidence(baseline: Double, scenario: String, type: String) -> Double {
        let bucket = "\(scenario):\(type)"
        guard let s = stats[bucket], s.total >= minSamples else { return baseline }
        var adjusted = baseline
        if s.dismissRate > 0.6 {
            adjusted = min(baseline + 0.05, min(confidenceCeiling, baseline + maxAdjustUp))
        } else if s.acceptRate > 0.4 {
            adjusted = max(baseline - 0.03, confidenceFloor)
        }
        return adjusted
    }

    /// Recently ignored suggestion texts for a scenario (semantic suppression in the gate prompt).
    func dismissedTexts(scenario: String, limit: Int = 5) -> [String] {
        Array((dismissedTextsByScenario[scenario] ?? []).suffix(limit))
    }

    /// Human-readable adaptation state for the Settings page.
    func adaptationSummary() -> [(bucket: String, direction: String, samples: Int)] {
        stats.compactMap { key, s in
            guard s.total >= minSamples else { return nil }
            let direction: String
            if s.dismissRate > 0.6 {
                direction = "more selective"
            } else if s.acceptRate > 0.4 {
                direction = "more proactive"
            } else {
                return nil
            }
            return (bucket: key, direction: direction, samples: Int(s.total.rounded()))
        }
        .sorted { $0.bucket < $1.bucket }
    }

    func reset() {
        stats = [:]
        dismissedTextsByScenario = [:]
        recorded = []
        UserDefaults.standard.removeObject(forKey: statsKey)
        UserDefaults.standard.removeObject(forKey: dismissedTextsKey)
        NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
    }

    /// Diagnostics dump for the omi-ctl test action.
    func debugDump() -> [String: String] {
        var out: [String: String] = [:]
        for (bucket, s) in stats.sorted(by: { $0.key < $1.key }) {
            out[bucket] = String(
                format: "accepted=%.1f ignored=%.1f dismissRate=%.2f", s.accepted, s.ignored, s.dismissRate)
        }
        if out.isEmpty { out["state"] = "no feedback recorded yet" }
        return out
    }

    // MARK: - Persistence

    private func persistStats() {
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: statsKey)
        }
    }

    private func persistDismissedTexts() {
        if let data = try? JSONEncoder().encode(dismissedTextsByScenario) {
            UserDefaults.standard.set(data, forKey: dismissedTextsKey)
        }
    }
}
