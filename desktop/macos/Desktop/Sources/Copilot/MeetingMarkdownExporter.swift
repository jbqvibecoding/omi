import Foundation

/// Stateless markdown export of a finished meeting — YAML frontmatter, the generated
/// minutes/notes, and the full timestamped transcript — written to
/// `~/Documents/Omi/Meetings/` so it lands in the user's own files (Obsidian-friendly).
/// Ported from OpenOats' MarkdownMeetingWriter, adapted to omi's session types.
enum MeetingMarkdownExporter {

    static var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Omi/Meetings", isDirectory: true)
    }

    /// Writes the export and returns the file URL, or nil when there is nothing to write.
    @discardableResult
    static func export(
        title: String,
        startedAt: Date,
        scenarioName: String?,
        sessionId: Int64?,
        segments: [SpeakerSegment],
        notesMarkdown: String?
    ) -> URL? {
        let transcriptLines = segments.compactMap { segment -> String? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = segment.isUser ? "You" : "Speaker \(segment.speaker)"
            return "[\(timestamp(segment.start))] \(speaker): \(text)"
        }
        guard !transcriptLines.isEmpty || !(notesMarkdown ?? "").isEmpty else { return nil }

        let duration = segments.last.map { Int($0.end.rounded()) } ?? 0
        let dateFormatter = ISO8601DateFormatter()

        var lines: [String] = ["---"]
        lines.append("schema: omi-meeting/v1")
        lines.append("title: \(yamlEscape(title))")
        lines.append("date: \(dateFormatter.string(from: startedAt))")
        lines.append("duration_seconds: \(duration)")
        if let scenarioName, !scenarioName.isEmpty {
            lines.append("scenario: \(yamlEscape(scenarioName))")
        }
        if let sessionId {
            lines.append("session_id: \(sessionId)")
        }
        lines.append("recorder: Omi Desktop")
        lines.append("---")
        lines.append("")

        if let notesMarkdown, !notesMarkdown.isEmpty {
            lines.append("## Notes")
            lines.append("")
            lines.append(notesMarkdown)
            lines.append("")
        }
        if !transcriptLines.isEmpty {
            lines.append("## Transcript")
            lines.append("")
            lines.append(contentsOf: transcriptLines)
            lines.append("")
        }
        let content = lines.joined(separator: "\n")

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let fileURL = availableFileURL(title: title, startedAt: startedAt)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            log("MeetingMarkdownExporter: wrote \(fileURL.path)")
            return fileURL
        } catch {
            logError("MeetingMarkdownExporter: export failed", error: error)
            return nil
        }
    }

    // MARK: - Helpers

    /// `YYYY-MM-DD-HHMM-<slug>.md`, with `-2`, `-3`… on collision.
    private static func availableFileURL(title: String, startedAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let base = "\(formatter.string(from: startedAt))-\(slug(title))"

        let fm = FileManager.default
        var candidate = outputDirectory.appendingPathComponent("\(base).md")
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = outputDirectory.appendingPathComponent("\(base)-\(counter).md")
            counter += 1
        }
        return candidate
    }

    private static func slug(_ title: String) -> String {
        let words = CopilotTextSimilarity.normalizedWords(in: title).prefix(6)
        let joined = words.joined(separator: "-")
        return joined.isEmpty ? "meeting" : joined
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private static func yamlEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
