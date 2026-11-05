import Combine
import Foundation

/// What the other side is saying right now, before it is a transcript line: the recognizer's
/// words in progress (macOS 26), the language each finished line was heard in, and a status for
/// the bar ("downloading the speech model…").
@MainActor
final class SubtitleFeed: ObservableObject {
    static let shared = SubtitleFeed()

    @Published private(set) var partial = ""
    @Published private(set) var partialLanguage: String?
    @Published private(set) var status: String?
    /// Transcript segment id → the language the recognizer heard it in.
    private(set) var lineLanguages: [String: String] = [:]

    private init() {}

    func setPartial(_ text: String, language: String?) {
        // Language first: subscribers to `partial` hear about it before it changes (willSet),
        // and read the language as they do.
        if partialLanguage != language { partialLanguage = language }
        if partial != text { partial = text }
    }

    func noteLanguage(lineId: String, code: String) {
        lineLanguages[lineId] = code
        if lineLanguages.count > 400 { lineLanguages.removeAll() }
    }

    func setStatus(_ text: String?) {
        status = text
    }
}

/// Live bilingual subtitles for whatever the other side says — in a call, a livestream, a video.
///
/// Finished lines come from the transcript (every recognizer, cloud included); on macOS 26 the
/// words in progress come from Apple's recognizer too, so the bar moves while they talk. Each
/// finished line is translated once, written back into the transcript (it shows bilingual in the
/// main window and is saved with it), and shown on the bar.
@MainActor
final class SubtitleController: ObservableObject {
    static let shared = SubtitleController()

    struct Line: Equatable {
        let id: String
        var text: String
        var source: String?
        var translation: String?
        /// The text the translation was made from: a line revised since is translated again.
        var translatedFrom: String?
        var at: Date
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var draftTranslation = ""
    @Published private(set) var translationUnavailable = false
    @Published private(set) var isRecording = false

    /// Writes a translation into the transcript (set by AppState for the recording).
    private var writeBack: ((_ segmentId: String, _ lang: String, _ text: String) -> Void)?
    /// Re-picks the other side's recognizer when subtitles are turned on mid-recording.
    var onRoutingNeedsRefresh: (() -> Void)?

    private var pending: [String] = []
    /// The other side's words in progress, as last published (the feed's own property still
    /// holds the old value while its subscribers run).
    private var currentPartial = ""
    private var pumping = false
    private var draftInFlight = false
    private var lastDraftSent = ""
    private var draftEpoch = 0
    private var cancellables = Set<AnyCancellable>()
    private var pumpTimer: Timer?
    private let maxShownLines = 3
    private let batchSize = 6

    private init() {
        LiveTranscriptMonitor.shared.$segments
            .sink { [weak self] segments in
                MainActor.assumeIsolated { self?.ingest(segments) }
            }
            .store(in: &cancellables)
        SubtitleFeed.shared.$partial
            .sink { [weak self] text in
                MainActor.assumeIsolated { self?.partialChanged(text) }
            }
            .store(in: &cancellables)
    }

    var enabled: Bool { CopilotSettings.shared.subtitlesEnabled }

    /// The language subtitles are translated into for a line in `source`.
    func target(for source: String?) -> String {
        let choice = CopilotSettings.shared.subtitleLanguage
        if choice == CopilotSettings.followSystemLanguage {
            return MeetingLanguages.followSystemTarget(source: source)
        }
        return choice
    }

    // MARK: Lifecycle

    func recordingStarted(writeBack: @escaping (_ segmentId: String, _ lang: String, _ text: String) -> Void) {
        writeBackIsStandIn = false
        self.writeBack = writeBack
        isRecording = true
        lines = []
        pending = []
        draftTranslation = ""
        translationUnavailable = false
        pumpTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in SubtitleController.shared.pump() }
        }
        pumpTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        SubtitleOverlayController.shared.refresh()
    }

    /// The next conversation began ("finish and continue"): its lines start on a clean bar.
    func conversationRotated() {
        lines = []
        pending = []
        draftTranslation = ""
    }

    func recordingStopped() {
        isRecording = false
        writeBack = nil
        onRoutingNeedsRefresh = nil
        pumpTimer?.invalidate()
        pumpTimer = nil
        lines = []
        pending = []
        draftTranslation = ""
        SubtitleFeed.shared.setPartial("", language: nil)
        SubtitleOverlayController.shared.refresh()
    }

    /// Subtitles were turned on or off.
    func settingChanged() {
        if enabled { onRoutingNeedsRefresh?() }
        SubtitleOverlayController.shared.refresh()
    }

    // MARK: Lines

    private func ingest(_ segments: [SpeakerSegment]) {
        guard isRecording, enabled else { return }
        // Only the other side: subtitles are for understanding them, and your own words are
        // the ones the interpreter carries.
        let theirs = segments.suffix(8).filter { !$0.isUser }
        for segment in theirs {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let hint = SubtitleFeed.shared.lineLanguages[segment.id]
            let source = SubtitleTranslator.language(of: text, hint: hint)
            let target = target(for: source)
            // The backend may already have translated it into this language.
            let existing = segment.translations.first { MeetingLanguages.sameLanguage($0.lang, target) }?.text
            if let i = lines.firstIndex(where: { $0.id == segment.id }) {
                guard lines[i].text != text || (existing != nil && lines[i].translation == nil) else { continue }
                lines[i].text = text
                lines[i].source = source
                lines[i].at = Date()
                if let existing {
                    lines[i].translation = existing
                    lines[i].translatedFrom = text
                } else if MeetingLanguages.sameLanguage(source ?? target, target) {
                    lines[i].translation = text
                    lines[i].translatedFrom = text
                } else if lines[i].translatedFrom != text, !pending.contains(segment.id) {
                    pending.append(segment.id)
                }
            } else {
                // A segment that arrived long ago (the transcript re-published its window) is not news.
                guard segment.end + 120 >= (theirs.last?.end ?? segment.end) else { continue }
                var line = Line(id: segment.id, text: text, source: source, translation: existing,
                                translatedFrom: existing == nil ? nil : text, at: Date())
                if MeetingLanguages.sameLanguage(source ?? target, target) {
                    // They speak the language you read: the subtitle is the line itself.
                    line.translation = text
                    line.translatedFrom = text
                }
                lines.append(line)
                if line.translatedFrom == nil { pending.append(segment.id) }
                if lines.count > 12 { lines.removeFirst(lines.count - 12) }
            }
        }
        render()
    }

    /// Translates what is waiting: one line at a time on this Mac, or up to six per model call.
    private func pump() {
        guard isRecording, enabled, !pumping, !pending.isEmpty else { return }
        let ids = pending
        let waiting = ids.compactMap { id in lines.first { $0.id == id } }
        guard let first = waiting.first else {
            pending = []
            return
        }
        pumping = true
        let source = first.source
        let target = target(for: source)
        let glossary = MeetingMinutesEngine.shared.glossary
        let terms = MeetingMinutesEngine.shared.minutes.terms
        Task { @MainActor in
            defer { self.pumping = false }
            // Lines in the same language go together; the rest wait for the next round.
            let batch = Array(waiting.filter { $0.source == source }.prefix(self.batchSize))
            let corrected = batch.map { MinutesLogic.correct($0.text, terms: terms) }
            var results: [String?] = Array(repeating: nil, count: batch.count)
            if let source, await SubtitleTranslator.shared.onDeviceAvailable(source: source, target: target) {
                for (i, text) in corrected.enumerated() {
                    results[i] = await SubtitleTranslator.shared.translateOnDevice(text, source: source, target: target)
                }
            } else if let out = await SubtitleTranslator.shared.translateWithModel(
                corrected, source: source, target: target, glossary: glossary)
            {
                for (i, text) in out.enumerated() where i < results.count { results[i] = text }
            }
            var anyTranslated = false
            for (i, line) in batch.enumerated() {
                guard let translation = results[i], !translation.isEmpty else { continue }
                anyTranslated = true
                self.pending.removeAll { $0 == line.id }
                guard let index = self.lines.firstIndex(where: { $0.id == line.id }) else { continue }
                // Revised while this ran: the newer text is translated next round.
                guard self.lines[index].text == line.text else {
                    if !self.pending.contains(line.id) { self.pending.append(line.id) }
                    continue
                }
                self.lines[index].translation = translation
                self.lines[index].translatedFrom = line.text
                self.writeBack?(line.id, target, translation)
            }
            self.translationUnavailable = !anyTranslated && !batch.isEmpty
            // Lines that have scrolled off the bar aren't worth a call any more.
            let shown = Set(self.lines.suffix(self.maxShownLines + 2).map(\.id))
            self.pending.removeAll { !shown.contains($0) }
            self.render()
        }
    }

    // MARK: The line in progress

    private func partialChanged(_ text: String) {
        currentPartial = text
        guard isRecording, enabled else { return }
        if text.isEmpty {
            draftEpoch += 1
            draftTranslation = ""
            lastDraftSent = ""
        } else {
            translateDraftIfDue(text)
        }
        render()
    }

    /// Drafts go to the on-device translator only, at most one in flight: free, and it keeps up.
    private func translateDraftIfDue(_ text: String) {
        guard !draftInFlight, text.count >= 2, text != lastDraftSent else { return }
        let source = SubtitleFeed.shared.partialLanguage ?? SubtitleTranslator.language(of: text)
        guard let source else { return }
        let target = target(for: source)
        guard !MeetingLanguages.sameLanguage(source, target) else {
            draftTranslation = ""
            return
        }
        lastDraftSent = text
        draftInFlight = true
        let epoch = draftEpoch
        let terms = MeetingMinutesEngine.shared.minutes.terms
        Task { @MainActor in
            let out = await SubtitleTranslator.shared.translateOnDevice(
                MinutesLogic.correct(text, terms: terms), source: source, target: target)
            self.draftInFlight = false
            guard let out, epoch == self.draftEpoch, self.isRecording else { return }
            self.draftTranslation = out
            self.render()
            // The words moved on while this ran.
            let now = self.currentPartial
            if now != text, !now.isEmpty { self.translateDraftIfDue(now) }
        }
    }

    // MARK: Output

    private func render() {
        let recent = Array(lines.suffix(maxShownLines))
        let partial = currentPartial
        var source = recent.last?.text ?? ""
        if !partial.isEmpty {
            let joiner = MeetingLanguages.isCJK(SubtitleFeed.shared.partialLanguage ?? "") ? "" : " "
            source = source.isEmpty ? partial : source + joiner + partial
        }
        var parts = recent.compactMap(\.translation)
        if !draftTranslation.isEmpty { parts.append(draftTranslation) }
        let targetIsCJK = MeetingLanguages.isCJK(target(for: recent.last?.source))
        var translation = parts.joined(separator: targetIsCJK ? "" : " ")
        if translation.isEmpty, translationUnavailable, !source.isEmpty {
            translation = "Translation unavailable right now"
        }
        SubtitleOverlayController.shared.setSubtitle(source: source, translation: translation)
    }

    // MARK: Debug (omi-ctl)

    /// Show a line as if the other side had said it — translation, write-back and bar included —
    /// so the subtitle path can be checked without a call. Outside a recording it opens a
    /// 20-second stand-in session.
    func debugSay(_ text: String) -> [String: String] {
        guard enabled else { return ["error": "subtitles are off (Settings › Copilot › Live subtitles)"] }
        if !isRecording {
            recordingStarted(writeBack: { _, _, _ in })
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if self.writeBackIsStandIn { self.recordingStopped() }
            }
            writeBackIsStandIn = true
        }
        let id = "debug-\(UUID().uuidString)"
        ingest([SpeakerSegment(segmentId: id, speaker: 1, text: text, start: 0, end: 1, isUser: false)])
        return ["line": id, "queued": pending.contains(id) ? "true" : "false"]
    }

    /// The current session was opened by `debugSay`, not by a recording.
    private var writeBackIsStandIn = false

    func debugDump() -> [String: String] {
        [
            "enabled": enabled ? "true" : "false",
            "recording": isRecording ? "true" : "false",
            "lines": String(lines.count),
            "translated": String(lines.filter { $0.translation != nil }.count),
            "pending": String(pending.count),
            "partial": currentPartial,
            "draft": draftTranslation,
            "latest": lines.last.map { "\($0.text) → \($0.translation ?? "-")" } ?? "-",
            "target": target(for: lines.last?.source),
            "overlay": SubtitleOverlayController.shared.stateDescription,
        ]
    }
}
