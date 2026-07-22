import AppKit
import Foundation

/// Resolves sensor placeholders in a watcher's system prompt into text (substituted in
/// place) and images (stripped to '' and returned on a side-channel), mirroring Observer
/// AI's pre-processor. Reuses omi's existing sensors — no new capture code.
///
/// Placeholders (v1):
///   $SCREEN            → screenshot JPEG (image side-channel)
///   $SCREEN_OCR        → recent on-screen OCR text (Rewind, via CopilotContextEngine)
///   $CLIPBOARD         → current clipboard text
///   $MEMORY / $MEMORY@id → the watcher's scratchpad (defaults to self)
///   $MICROPHONE        → recent mic transcript window
///   $ALL_AUDIO         → recent mixed mic+system transcript window
///   $TIME              → current time
/// ($CAMERA is intentionally not implemented — omi has no camera capture yet.)
@MainActor
enum WatcherSensorResolver {
    struct Resolved {
        let text: String
        let images: [Data]
    }

    /// Compact JPEG for change detection / prompts (reuses the proactive compressor).
    static func resolve(prompt: String, watcherId: String) async -> Resolved {
        var text = prompt
        var images: [Data] = []

        // Lazily assemble the OCR/transcript snapshot only if a placeholder needs it.
        let needsSnapshot =
            text.contains("$SCREEN_OCR") || text.contains("$MICROPHONE") || text.contains("$ALL_AUDIO")
        var snapshot: CopilotContextEngine.Snapshot?
        if needsSnapshot {
            snapshot = await CopilotContextEngine.shared.snapshot()
        }

        // Image sensor: $SCREEN (but not $SCREEN_OCR). Negative lookahead guards the OCR token.
        if let re = try? NSRegularExpression(pattern: "\\$SCREEN(?!_OCR)") {
            let range = NSRange(text.startIndex..., in: text)
            if re.firstMatch(in: text, range: range) != nil {
                if let raw = ScreenCaptureManager.captureScreenJPEG() {
                    images.append(GeminiImageCompression.compress(raw) ?? raw)
                }
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
        }

        // Text sensors.
        text = text.replacingOccurrences(of: "$SCREEN_OCR", with: snapshot?.recentOCR ?? "")
        text = text.replacingOccurrences(of: "$MICROPHONE", with: snapshot?.transcriptWindow ?? "")
        text = text.replacingOccurrences(of: "$ALL_AUDIO", with: snapshot?.transcriptWindow ?? "")
        text = text.replacingOccurrences(of: "$CLIPBOARD", with: NSPasteboard.general.string(forType: .string) ?? "")

        // $MEMORY and $MEMORY@otherId (defaults to the current watcher).
        text = resolveMemory(in: text, currentWatcherId: watcherId)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        text = text.replacingOccurrences(of: "$TIME", with: fmt.string(from: Date()))

        return Resolved(text: text, images: images)
    }

    /// Which sensors a prompt references (for UI hints / diagnostics).
    static func referencedSensors(in prompt: String) -> [String] {
        let all = ["$SCREEN_OCR", "$SCREEN", "$CLIPBOARD", "$MEMORY", "$MICROPHONE", "$ALL_AUDIO", "$TIME"]
        var found: [String] = []
        for token in all {
            // Avoid double-counting $SCREEN inside $SCREEN_OCR.
            if token == "$SCREEN" {
                if (try? NSRegularExpression(pattern: "\\$SCREEN(?!_OCR)"))?
                    .firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)) != nil
                {
                    found.append(token)
                }
            } else if prompt.contains(token) {
                found.append(token)
            }
        }
        return found
    }

    private static func resolveMemory(in text: String, currentWatcherId: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\$MEMORY(?:@([a-zA-Z0-9_]+))?") else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let targetId: String
            if match.range(at: 1).location != NSNotFound {
                targetId = ns.substring(with: match.range(at: 1))
            } else {
                targetId = currentWatcherId
            }
            result += WatcherMemoryStore.shared.get(watcherId: targetId)
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
