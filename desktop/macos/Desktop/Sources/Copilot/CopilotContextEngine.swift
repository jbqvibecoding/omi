import AppKit
import Foundation

/// Assembles a multimodal context snapshot for copilot calls: live transcript,
/// recent OCR from the Rewind database, active app, and the AI user profile.
/// Every source degrades to empty on failure — a snap must never fail because
/// one context source is unavailable.
@MainActor
final class CopilotContextEngine {
    static let shared = CopilotContextEngine()

    struct Snapshot {
        let capturedAt: Date
        let activeApp: String?
        let windowTitle: String?
        /// Speaker-labelled transcript lines from the current (or just-ended) recording session.
        let transcriptWindow: String
        /// Recent OCR text, current app first. Privacy exclusions applied.
        let recentOCR: String
        let userProfile: String?
    }

    private init() {}

    func snapshot(maxTranscriptWords: Int = 300, maxOCRChars: Int = 4000) async -> Snapshot {
        let activeApp = NSWorkspace.shared.frontmostApplication?.localizedName

        let transcript = buildTranscriptWindow(maxWords: maxTranscriptWords)
        let ocr = await buildRecentOCR(activeApp: activeApp, maxChars: maxOCRChars)
        let profile = await AIUserProfileService.shared.getLatestProfile()?.profileText

        return Snapshot(
            capturedAt: Date(),
            activeApp: activeApp,
            windowTitle: nil,
            transcriptWindow: transcript,
            recentOCR: ocr,
            userProfile: profile
        )
    }

    // MARK: - Transcript

    private func buildTranscriptWindow(maxWords: Int) -> String {
        var segments = LiveTranscriptMonitor.shared.segments
        if segments.isEmpty {
            segments = LiveTranscriptMonitor.shared.savedSegments
        }
        guard !segments.isEmpty else { return "" }

        // Take trailing segments up to the word budget, keeping chronological order.
        var lines: [String] = []
        var wordCount = 0
        for segment in segments.reversed() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = segment.isUser ? "You" : "Speaker \(segment.speaker)"
            lines.append("\(speaker): \(text)")
            wordCount += text.split(separator: " ").count
            if wordCount >= maxWords { break }
        }
        return lines.reversed().joined(separator: "\n")
    }

    // MARK: - Recent OCR

    /// Pulls OCR text from screenshots captured in the last few minutes.
    /// Privacy rule: app exclusions apply to OCR pulls, not just frame capture —
    /// rows from excluded apps must never reach a prompt.
    private func buildRecentOCR(activeApp: String?, maxChars: Int) async -> String {
        let lookback: TimeInterval = 5 * 60
        let now = Date()

        let screenshots: [Screenshot]
        do {
            screenshots = try await RewindDatabase.shared.getScreenshots(
                from: now.addingTimeInterval(-lookback), to: now, limit: 40
            )
        } catch {
            return ""
        }

        let settings = RewindSettings.shared
        let included = screenshots.filter { !settings.isAppExcluded($0.appName) }
        guard !included.isEmpty else { return "" }

        // Current app first (that's what the user is looking at), then the rest,
        // newest first. Deduplicate consecutive identical OCR blobs.
        let (currentApp, otherApps) = included.reduce(into: ([Screenshot](), [Screenshot]())) { acc, shot in
            if let activeApp, shot.appName == activeApp {
                acc.0.append(shot)
            } else {
                acc.1.append(shot)
            }
        }

        var result = ""
        var lastText = ""
        for shot in currentApp + otherApps {
            guard let text = shot.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text != lastText else { continue }
            lastText = text
            let block = "[\(shot.appName)] \(text)\n"
            if result.count + block.count > maxChars {
                let remaining = maxChars - result.count
                if remaining > 80 { result += String(block.prefix(remaining)) }
                break
            }
            result += block
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
