import AppKit
import Foundation
import UniformTypeIdentifiers

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — TranscriptExport.srt in
// Sources/LiveSubs/SessionStore.swift. See ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: built from omi's transcript segments (with the translations subtitles wrote back);
// the full transcript is read from omi's own store rather than the in-memory window; saving goes
// through a save panel from the minutes panel.

/// A finished meeting as files: bilingual SRT subtitles, and the Markdown record.
enum MeetingExport {
    struct Line: Equatable {
        let t: Double
        let speaker: String
        let text: String
        /// What subtitles translated it into, when that differs from the line itself.
        let translation: String?
    }

    enum Format { case markdown, srt }

    /// Bilingual subtitles: each cue ends where the next line starts, at least 1 s and at most 8 s
    /// after it begins; the last one gets 4 s. A translation identical to the line isn't repeated.
    static func srt(_ lines: [Line]) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((max(0, t) * 1000).rounded())
            return String(
                format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out = ""
        for (i, l) in lines.enumerated() {
            let next = i + 1 < lines.count ? lines[i + 1].t : l.t + 4
            let end = max(l.t + 1, min(next, l.t + 8))
            out += "\(i + 1)\n\(ts(l.t)) --> \(ts(end))\n\(l.text)\n"
            if let d = l.translation, d != l.text { out += "\(d)\n" }
            out += "\n"
        }
        return out
    }

    /// The lines of a transcript, oldest first, named the way the transcript names them.
    static func lines(from segments: [SpeakerSegment], names: [Int: String] = [:]) -> [Line] {
        segments.sorted { $0.start < $1.start }.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = segment.isUser ? "You" : names[segment.speaker] ?? "Speaker \(segment.speaker)"
            return Line(t: segment.start, speaker: speaker, text: text, translation: translation(of: segment))
        }
    }

    /// The translation a segment carries, if it says something the line itself doesn't.
    static func translation(of segment: SpeakerSegment) -> String? {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return segment.translations
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != text }
    }

    /// A session's stored transcript as segments, translations included — all of it, where the
    /// live transcript in memory keeps only the last 200 segments.
    static func segments(from records: [TranscriptionSegmentRecord]) -> [SpeakerSegment] {
        let decoder = JSONDecoder()
        return records.map { record in
            let translations = record.translationsJson
                .flatMap { try? decoder.decode([TranscriptTranslation].self, from: Data($0.utf8)) }?
                .map { SegmentTranslation(lang: $0.lang, text: $0.text) } ?? []
            return SpeakerSegment(
                segmentId: record.segmentId, speaker: record.speaker, text: record.text,
                start: record.startTime, end: record.endTime, isUser: record.isUser,
                personId: record.personId, translations: translations)
        }
    }

    /// The whole stored transcript of a session; empty when there is none.
    static func storedSegments(sessionId: Int64) async -> [SpeakerSegment] {
        guard let records = try? await TranscriptionStorage.shared.getSegments(sessionId: sessionId) else { return [] }
        return segments(from: records)
    }

    /// Save the meeting the minutes panel shows, as Markdown or SRT, where the user picks.
    @MainActor
    static func exportShownSession(_ format: Format) async {
        let engine = MeetingMinutesEngine.shared
        guard let id = engine.shownSessionId else { return }
        let record = MeetingMinutesEngine.loadRecord(sessionId: id)
        var segments = await storedSegments(sessionId: id)
        if segments.isEmpty, let record {
            segments = record.lines.filter { !$0.deleted }.map {
                SpeakerSegment(segmentId: $0.id, speaker: $0.speakerId, text: $0.text, start: $0.t, end: $0.t, isUser: $0.isUser)
            }
        }
        let minutes = engine.minutes
        let title = minutes.title ?? "Meeting"
        let startedAt = record?.startedAt ?? Date()
        let content: String
        let ext: String
        switch format {
        case .markdown:
            content =
                MeetingMarkdownExporter.render(
                    title: title, startedAt: startedAt, scenarioName: nil, sessionId: id, segments: segments,
                    notesMarkdown: minutes.isEmpty ? nil : MinutesLogic.markdown(minutes)) ?? ""
            ext = "md"
        case .srt:
            content = srt(lines(from: segments))
            ext = "srt"
        }
        guard !content.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(MeetingMarkdownExporter.fileBaseName(title: title, startedAt: startedAt)).\(ext)"
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            log("MeetingExport: wrote \(ext) for session \(id)")
        } catch {
            logError("MeetingExport: saving failed", error: error)
        }
    }
}
