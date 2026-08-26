import Foundation

/// Template-driven meeting minutes, generated once at session end (ported from Meetily's
/// summary pipeline). Short transcripts get a single template-fill pass; long ones run
/// chunk → per-chunk summary → combine → template fill, so a two-hour meeting is never
/// truncated. Templates are chosen from the active copilot scenario.
enum MeetingMinutesGenerator {

    // MARK: - Templates (adapted from Meetily's templates/*.json)

    struct SummaryTemplate {
        let id: String
        let name: String
        let sections: [Section]

        struct Section {
            let title: String
            let instruction: String
            /// "paragraph", "list", or "table" (with headerRow describing the columns).
            let format: String
            var headerRow: String? = nil
        }

        /// The section list rendered as prompt instructions (Meetily's to_section_instructions).
        var sectionInstructions: String {
            sections.map { section in
                var line = "## \(section.title)\nInstruction: \(section.instruction) Format: \(section.format)."
                if let headerRow = section.headerRow {
                    line += " Use a markdown table with exactly this header:\n\(headerRow)"
                }
                return line
            }.joined(separator: "\n\n")
        }
    }

    static let standard = SummaryTemplate(
        id: "standard", name: "Meeting Notes",
        sections: [
            .init(
                title: "Summary",
                instruction: "Provide a brief, one-paragraph executive summary of the entire meeting.",
                format: "paragraph"),
            .init(
                title: "Key Decisions",
                instruction: "List the most important decisions made during the meeting.",
                format: "list"),
            .init(
                title: "Action Items",
                instruction: "List all assigned tasks with their owners and due dates where stated, "
                    + "plus a short quote of the transcript moment they came from.",
                format: "table",
                headerRow: "| Owner | Task | Due | Reference |\n| --- | --- | --- | --- |"),
            .init(
                title: "Discussion Highlights",
                instruction: "Summarize the main topics of discussion, key arguments, and important insights.",
                format: "paragraph"),
        ])

    static let salesCall = SummaryTemplate(
        id: "sales_call", name: "Sales Call Notes",
        sections: [
            .init(
                title: "Summary",
                instruction: "One-paragraph executive summary of the call and where the deal stands.",
                format: "paragraph"),
            .init(
                title: "Customer Needs & Pain Points",
                instruction: "List the needs, pain points, and priorities the customer expressed.",
                format: "list"),
            .init(
                title: "Objections & Responses",
                instruction: "List each objection or concern raised and how it was addressed (or left open).",
                format: "list"),
            .init(
                title: "Commitments & Next Steps",
                instruction: "List every commitment made by either side, with owner and timing where stated.",
                format: "table",
                headerRow: "| Owner | Commitment | When | Reference |\n| --- | --- | --- | --- |"),
        ])

    static let interview = SummaryTemplate(
        id: "interview", name: "Interview Notes",
        sections: [
            .init(
                title: "Summary",
                instruction: "One-paragraph summary of how the interview went overall.",
                format: "paragraph"),
            .init(
                title: "Questions & Answers",
                instruction: "List the main questions asked and a concise account of each answer given.",
                format: "list"),
            .init(
                title: "Strengths & Concerns",
                instruction: "List notable strengths demonstrated and any concerns or gaps that surfaced.",
                format: "list"),
            .init(
                title: "Follow-ups",
                instruction: "List agreed follow-ups and next steps in the process, with timing where stated.",
                format: "list"),
        ])

    static let support = SummaryTemplate(
        id: "support", name: "Support Call Notes",
        sections: [
            .init(
                title: "Summary",
                instruction: "One-paragraph summary of the issue and the outcome of the call.",
                format: "paragraph"),
            .init(
                title: "Issue & Diagnosis",
                instruction: "Describe the reported problem, reproduction details, and what was diagnosed.",
                format: "paragraph"),
            .init(
                title: "Resolution & Next Steps",
                instruction: "List what was resolved on the call and every outstanding follow-up with owner.",
                format: "table",
                headerRow: "| Owner | Step | When | Reference |\n| --- | --- | --- | --- |"),
        ])

    /// Template for the active scenario. Custom profiles and unmapped scenarios fall back
    /// to the standard template.
    static func template(forScenario scenarioId: String) -> SummaryTemplate {
        switch scenarioId {
        case "sales", "negotiation": return salesCall
        case "interview": return interview
        case "support": return support
        default: return standard
        }
    }

    // MARK: - Generation pipeline (Meetily processor.rs flow)

    /// Above this size the transcript is chunked and combined instead of one-shot.
    private static let chunkThresholdChars = 60_000
    private static let chunkSizeChars = 24_000
    /// Transcript lines carried over between chunks for continuity.
    private static let chunkOverlapLines = 12
    private static let perCallTimeout: Double = 45

    /// Generates template-driven minutes markdown from a speaker-labelled transcript.
    static func generateMinutes(
        transcript: String, scenarioId: String, client: GeminiClient
    ) async throws -> String {
        let template = template(forScenario: scenarioId)

        let sourceMaterial: String
        if transcript.count <= chunkThresholdChars {
            sourceMaterial = transcript
        } else {
            // Long transcript: summarize chunks, then fill the template from the combined notes.
            let chunks = chunkTranscript(transcript)
            var chunkSummaries: [String] = []
            for (i, chunk) in chunks.enumerated() {
                let summary = try await client.sendTextRequest(
                    prompt: "Segment \(i + 1) of \(chunks.count) of a meeting transcript:\n\n\(chunk)",
                    systemPrompt:
                        "Extract the essential content of this transcript segment as dense notes: "
                        + "decisions, action items (with owner/timing where stated), key facts and "
                        + "numbers, and the topics discussed. No preamble.",
                    maxRetries: 0,
                    timeout: perCallTimeout,
                    thinkingBudget: 0
                )
                chunkSummaries.append(summary)
            }
            sourceMaterial =
                "Combined notes from \(chunks.count) sequential segments of the meeting:\n\n"
                + chunkSummaries.enumerated()
                .map { "--- Segment \($0.offset + 1) ---\n\($0.element)" }
                .joined(separator: "\n\n")
        }

        let markdown = try await client.sendTextRequest(
            prompt: "Source material:\n\n\(sourceMaterial)",
            systemPrompt: """
                You write final meeting minutes from the provided source material (a transcript \
                or combined segment notes). Produce markdown with EXACTLY these sections, in this \
                order, using '## ' headings:

                \(template.sectionInstructions)

                Rules: be factual and specific — names, numbers, quotes. If a section has no \
                content, write "None." under its heading. Output only the markdown, no preamble.
                """,
            maxRetries: 0,
            timeout: perCallTimeout,
            thinkingBudget: 0
        )
        return cleanLLMMarkdownOutput(markdown)
    }

    /// Splits a line-per-utterance transcript into chunks on line boundaries, carrying a
    /// small line overlap between chunks for continuity.
    static func chunkTranscript(_ transcript: String) -> [String] {
        let lines = transcript.components(separatedBy: .newlines)
        var chunks: [String] = []
        var current: [String] = []
        var currentChars = 0

        for line in lines {
            current.append(line)
            currentChars += line.count + 1
            if currentChars >= chunkSizeChars {
                chunks.append(current.joined(separator: "\n"))
                current = Array(current.suffix(chunkOverlapLines))
                currentChars = current.reduce(0) { $0 + $1.count + 1 }
            }
        }
        if !current.isEmpty {
            let tail = current.joined(separator: "\n")
            // Avoid a trailing chunk that is only the overlap of the previous one.
            if chunks.isEmpty || tail.count > chunkOverlapLines * 40 {
                chunks.append(tail)
            }
        }
        return chunks.isEmpty ? [transcript] : chunks
    }

    /// Strips <think> blocks and a surrounding markdown code fence (Meetily's
    /// clean_llm_markdown_output).
    static func cleanLLMMarkdownOutput(_ text: String) -> String {
        var result = text

        // Remove <think>...</think> reasoning blocks.
        while let start = result.range(of: "<think>"), let end = result.range(of: "</think>") {
            guard start.lowerBound < end.upperBound else { break }
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }

        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Unwrap a whole-output ```markdown fence.
        if result.hasPrefix("```") {
            var lines = result.components(separatedBy: .newlines)
            if lines.count >= 2, lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeFirst()
                lines.removeLast()
                result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}
