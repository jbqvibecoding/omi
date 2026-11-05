import Combine
import Foundation

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — NotesEngine in
// Sources/LiveSubs/Notes.swift. See ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: lines come from omi's live transcript (kept here in full, since the transcript in
// memory is a 200-segment window); a session is only minuted once MinutesGate says it is a
// meeting; requests go through GeminiClient; the end-of-meeting pass runs on a snapshot so the
// next session can start at once, and its result is handed to the post-session archive; each
// session's minutes are saved as one JSON file; the minutes' terms feed push-to-talk's
// vocabulary; debug hooks are omi-ctl actions.

/// Keeps the current session's meeting minutes up to date: every 45 s with new speech, one model
/// call sends the current minutes plus the new lines and gets the whole updated minutes back.
/// A failed or odd reply never replaces good minutes. When the session ends the minutes are
/// rewritten once from the whole transcript.
@MainActor
final class MeetingMinutesEngine: ObservableObject {
    static let shared = MeetingMinutesEngine()

    enum State: Equatable {
        /// Not recording.
        case idle
        /// Recording, but nothing yet says this session is a meeting.
        case waiting
        /// Minuting; nothing in flight.
        case ready
        case updating
        /// The shared model budget said no; the next attempt waits longer.
        case rateLimited
        /// The plan or the AI setup doesn't allow it right now.
        case unavailable
        case failed
    }

    @Published private(set) var minutes = MeetingMinutes()
    @Published private(set) var state: State = .idle
    /// Topic titles and point texts the last live update added (shown as "new" for a minute).
    @Published private(set) var fresh: Set<String> = []
    @Published private(set) var summaryChangedAt: Date?
    /// Why the current session is being minuted; nil until it qualifies.
    @Published private(set) var trigger: MinutesTrigger?
    /// A session is being recorded.
    @Published private(set) var isLive = false
    /// An ended session's full minutes are being written.
    @Published private(set) var finalizing = false
    /// Time of the newest line the minutes have read ("live · up to 03:52").
    @Published private(set) var coveredUntil: Double?

    /// The session whose minutes `minutes` shows. Stays set after it ends, until the next one.
    private(set) var shownSessionId: Int64?

    private var sessionId: Int64?
    private var sessionStartedAt = Date()
    /// Every line of the current session. The app's own transcript keeps only the last 200
    /// segments in memory; an hour-long meeting needs all of them.
    private(set) var lines: [MinutesLine] = []
    private var lineIndex: [String: Int] = [:]
    /// Whether transcript lines are being collected: from the moment recording starts (the
    /// session's database row comes a moment later) until it stops.
    private var accepting = false
    private var speakerNames: () -> [Int: String] = { [:] }

    private var timer: Timer?
    private var inFlight = false
    /// A language change that arrived while an update was running: rewrite after it.
    private var pendingRewrite = false
    private var lastAttempt = Date.distantPast
    private var freshGeneration = 0
    /// Bumped when a session starts or ends, so a reply that arrives late can tell.
    private var generation = 0

    // Gate
    private var manualStart = false
    private var callSeen = false
    private var lastCallProbe = Date.distantPast
    private var callProbeInFlight = false
    private var soundSamples: [Bool] = []

    /// End-of-meeting passes, by session; the archive waits on them.
    private var finalJobs: [Int64: Task<MeetingMinutes?, Never>] = [:]
    /// The last few finished sessions' minutes, for a caller that asks after the job is done.
    private var finalResults: [(id: Int64, minutes: MeetingMinutes)] = []

    private var geminiClient: GeminiClient?
    private var cancellables = Set<AnyCancellable>()

    private let tickInterval: TimeInterval = 5
    private let callProbeInterval: TimeInterval = 15

    private init() {
        // Delivered synchronously, not via `receive(on:)`: the transcript monitor is main-actor
        // already, and a hop through the main queue would let the last lines of one session land
        // after `endSession()` — in the next session's minutes.
        LiveTranscriptMonitor.shared.$segments
            .sink { [weak self] segments in
                MainActor.assumeIsolated { self?.ingest(segments) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Recording is about to start: collect lines from here, before the session has an id.
    func recordingWillStart() {
        lines = []
        lineIndex = [:]
        accepting = true
    }

    /// A recording session started (or the next one after "finish and continue").
    ///
    /// Lines that arrived before this — the database session is created asynchronously after
    /// recording starts — already belong to it and are kept.
    func startSession(sessionId id: Int64, speakerNames: @escaping () -> [Int: String] = { [:] }) {
        if sessionId != nil, sessionId != id { endSession() }
        guard sessionId != id else { return }
        sessionId = id
        shownSessionId = id
        accepting = true
        self.speakerNames = speakerNames
        sessionStartedAt = Date()
        generation &+= 1
        minutes = MeetingMinutes()
        fresh = []
        summaryChangedAt = nil
        coveredUntil = nil
        trigger = nil
        manualStart = false
        callSeen = false
        lastCallProbe = .distantPast
        soundSamples = []
        pendingRewrite = false
        lastAttempt = Date()
        isLive = true
        state = CopilotSettings.shared.minutesEnabled ? .waiting : .idle
        timer?.invalidate()
        let t = Timer(timeInterval: tickInterval, repeats: true) { _ in
            Task { @MainActor in MeetingMinutesEngine.shared.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
        log("MeetingMinutes: session \(id) started with \(lines.count) early lines")
    }

    /// The session ended: one last pass over the whole transcript, on a snapshot, so the next
    /// session can start right away. `continuing`: recording goes on into a new session ("finish
    /// and continue"), so the lines that follow are collected for it.
    func endSession(continuing: Bool = false) {
        timer?.invalidate()
        timer = nil
        isLive = false
        generation &+= 1
        let snapshotLines = lines
        lines = []
        lineIndex = [:]
        accepting = continuing
        guard let id = sessionId else {
            state = .idle
            return
        }
        sessionId = nil
        let live = minutes
        let wasMinuted = trigger != nil
        let languageCode = currentLanguageCode(lines: snapshotLines)
        let names = speakerNames()
        let startedAt = sessionStartedAt
        let trigger = self.trigger
        state = .idle
        guard wasMinuted, snapshotLines.filter({ !$0.deleted }).count >= 3 else {
            log("MeetingMinutes: session \(id) ended, not minuted (\(snapshotLines.count) lines)")
            return
        }
        finalizing = true
        let job = Task { @MainActor [weak self] () -> MeetingMinutes? in
            guard let self else { return nil }
            return await self.runFinal(
                id: id, lines: snapshotLines, live: live, languageCode: languageCode,
                names: names, startedAt: startedAt, trigger: trigger)
        }
        finalJobs[id] = job
    }

    /// Whether a session that ended has minutes coming (or already written).
    func hasFinalMinutes(for id: Int64) -> Bool {
        finalJobs[id] != nil || finalResults.contains { $0.id == id }
    }

    /// The finished minutes of a session that just ended, once its final pass is done; nil when
    /// it was not minuted. The archive waits on this rather than writing its own summary.
    func finalMinutes(for id: Int64) async -> MeetingMinutes? {
        if let job = finalJobs[id] { return await job.value }
        return finalResults.first { $0.id == id }?.minutes
    }

    /// The user asked for minutes of this session (an in-person meeting has no call to detect).
    func startManually() {
        guard sessionId != nil else { return }
        manualStart = true
        evaluateGate()
        if trigger != nil, minutes.isEmpty { Task { await update() } }
    }

    /// Update now instead of waiting for the next 45-second mark.
    func updateNow() {
        guard sessionId != nil else { return }
        if trigger == nil { manualStart = true; evaluateGate() }
        Task { await update() }
    }

    /// The minutes language changed during the meeting: rewrite the whole minutes in it now.
    func languageChanged() {
        guard sessionId != nil, trigger != nil, !minutes.isEmpty else { return }
        Task { await update(fresh: true) }
    }

    /// Lines the backend deleted (`segments_deleted`). They keep their numbers but stop counting
    /// as evidence.
    func markDeleted(lineIds: [String]) {
        for id in lineIds {
            if let i = lineIndex[id] { lines[i].deleted = true }
        }
    }

    // MARK: - Transcript

    private func ingest(_ segments: [SpeakerSegment]) {
        guard accepting else { return }
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let i = lineIndex[segment.id] {
                // Transcription revises itself: the same segment comes back with words fixed,
                // or a speaker the backend has now told apart.
                lines[i].text = text
                lines[i].t = segment.start
                lines[i].speakerId = segment.speaker
                lines[i].isUser = segment.isUser
            } else {
                lineIndex[segment.id] = lines.count
                lines.append(
                    MinutesLine(
                        id: segment.id, t: segment.start, speakerId: segment.speaker,
                        isUser: segment.isUser, text: text))
            }
        }
    }

    // MARK: - Tick

    private func tick() {
        guard sessionId != nil else { return }
        guard CopilotSettings.shared.minutesEnabled else {
            state = .idle
            return
        }
        soundSamples.append(AudioLevelMonitor.shared.systemLevel >= MinutesGate.soundLevel)
        if soundSamples.count > MinutesGate.sampleWindow {
            soundSamples.removeFirst(soundSamples.count - MinutesGate.sampleWindow)
        }
        if trigger == nil {
            probeCallIfDue()
            evaluateGate()
            guard trigger != nil else {
                state = .waiting
                return
            }
        }
        if state == .waiting { state = .ready }
        guard !inFlight, lines.count > minutes.covered else { return }
        let sinceLast = Date().timeIntervalSince(lastAttempt)
        let newLines = lines[min(minutes.covered, lines.count)...].filter { !$0.deleted }.count
        if let wait = Self.backoff(after: state) {
            // A failed attempt waits its turn even for the first minutes: retrying every tick
            // would spend the budget shared with the copilot on one stubborn request.
            if sinceLast >= wait { Task { await update() } }
        } else if minutes.isEmpty ? (newLines >= 3 || sinceLast > 20) : sinceLast >= MinutesLogic.interval {
            // First minutes as soon as there is something to say, then every 45 s.
            Task { await update() }
        }
    }

    private func evaluateGate() {
        guard trigger == nil else { return }
        let others = lines.filter { !$0.isUser && !$0.deleted }.count
        trigger = MinutesGate.trigger(
            enabled: CopilotSettings.shared.minutesEnabled, manual: manualStart, callSeen: callSeen,
            soundSamples: soundSamples, othersLines: others)
        if let trigger {
            // The 20-second first-version clock starts now, not when recording started.
            lastAttempt = Date()
            state = .ready
            log("MeetingMinutes: session \(sessionId ?? -1) is a meeting (\(trigger.rawValue)), minuting \(lines.count) lines")
        }
    }

    /// Whether a call app is in a call. The Core Audio process scan and the window list can
    /// block, so it runs off the main actor, at most every 15 s.
    private func probeCallIfDue() {
        guard !callSeen, !callProbeInFlight,
            Date().timeIntervalSince(lastCallProbe) >= callProbeInterval
        else { return }
        callProbeInFlight = true
        lastCallProbe = Date()
        Task.detached(priority: .utility) {
            var inCall = false
            if #available(macOS 14.4, *), ConferencingApps.callAppIsUsingMicrophone() { inCall = true }
            if !inCall { inCall = ConferencingApps.browserCallWindowPresent() }
            let detected = inCall
            await MainActor.run {
                let engine = MeetingMinutesEngine.shared
                engine.callProbeInFlight = false
                if detected { engine.callSeen = true }
            }
        }
    }

    // MARK: - Updating

    private func update(fresh rewrite: Bool = false) async {
        guard let id = sessionId, trigger != nil else { return }
        if inFlight {
            if rewrite { pendingRewrite = true }
            return
        }
        guard lines.contains(where: { !$0.deleted }) else { return }
        inFlight = true
        lastAttempt = Date()
        state = .updating
        let started = Date()
        let myGeneration = generation
        defer {
            inFlight = false
            if pendingRewrite, sessionId == id {
                pendingRewrite = false
                Task { await self.update(fresh: true) }
            }
        }

        let snapshot = lines
        let base = rewrite ? MeetingMinutes() : minutes
        let from = rewrite ? 0 : min(base.covered, snapshot.count)
        let languageCode = currentLanguageCode(lines: snapshot)
        let names = speakerNames()
        do {
            guard
                var next = try await request(
                    base: base, lines: snapshot, from: from, languageCode: languageCode,
                    final: false, retryLanguage: rewrite, names: names)
            else {
                if generation == myGeneration { state = .failed }
                log("MeetingMinutes: no usable reply, kept the previous minutes")
                return
            }
            // The session ended while this ran: the final pass takes it from here.
            guard generation == myGeneration, sessionId == id else { return }
            // The language changed while this ran: the queued rewrite replaces it.
            guard currentLanguageCode(lines: lines) == languageCode else {
                state = .ready
                return
            }
            MinutesLogic.carryEvidence(from: base, into: &next)
            // A reply without a name keeps the last one (not after a language change).
            if next.title == nil, !rewrite { next.title = minutes.title }
            next.covered = snapshot.count
            next.updatedAt = Date()
            next.final = false
            markFresh(old: minutes, new: next)
            if next.summary != minutes.summary { summaryChangedAt = Date() }
            minutes = next
            coveredUntil = snapshot.last(where: { !$0.deleted })?.t
            state = .ready
            persist(id: id, lines: snapshot, minutes: next, startedAt: sessionStartedAt, trigger: trigger)
            log("MeetingMinutes: live update \(snapshot.count - from) new lines → \(next.topics.count) topics, \(next.conclusions.count + next.todos.count) items, \(next.terms.count) terms in \(Int(Date().timeIntervalSince(started)))s")
        } catch {
            guard generation == myGeneration else { return }
            state = Self.state(for: error)
            logError("MeetingMinutes: live update failed", error: error)
        }
    }

    private func runFinal(
        id: Int64, lines snapshot: [MinutesLine], live: MeetingMinutes, languageCode: String,
        names: [Int: String], startedAt: Date, trigger: MinutesTrigger?
    ) async -> MeetingMinutes? {
        let started = Date()
        var result = live
        do {
            if var next = try await request(
                base: MeetingMinutes(), lines: snapshot, from: 0, languageCode: languageCode,
                final: true, retryLanguage: true, names: names)
            {
                MinutesLogic.carryEvidence(from: live, into: &next)
                if next.title == nil { next.title = live.title }
                next.covered = snapshot.count
                next.updatedAt = Date()
                next.final = true
                result = next
                log("MeetingMinutes: final pass for session \(id): \(next.topics.count) topics in \(Int(Date().timeIntervalSince(started)))s")
            } else {
                log("MeetingMinutes: final pass for session \(id) gave nothing usable, keeping the live minutes")
            }
        } catch {
            logError("MeetingMinutes: final pass for session \(id) failed, keeping the live minutes", error: error)
        }
        finalJobs[id] = nil
        finalizing = !finalJobs.isEmpty
        guard !result.isEmpty else { return nil }
        persist(id: id, lines: snapshot, minutes: result, startedAt: startedAt, trigger: trigger)
        finalResults.removeAll { $0.id == id }
        finalResults.append((id: id, minutes: result))
        if finalResults.count > 3 { finalResults.removeFirst(finalResults.count - 3) }
        if shownSessionId == id, sessionId == nil {
            fresh = []
            minutes = result
            coveredUntil = snapshot.last(where: { !$0.deleted })?.t
        }
        return result
    }

    /// One minutes request: prompt, call, lenient parse, and — for a rewrite from nothing, which
    /// has no minutes in the reader's language to follow — one more try when the reply came back
    /// in the transcript's language instead.
    private func request(
        base: MeetingMinutes, lines snapshot: [MinutesLine], from: Int, languageCode: String,
        final: Bool, retryLanguage: Bool, names: [Int: String]
    ) async throws -> MeetingMinutes? {
        let language = MeetingLanguages.englishName(languageCode)
        let labels = MinutesLogic.Labels.forLanguage(languageCode)
        let system = MinutesLogic.prompt(
            minutes: base, lines: snapshot, from: from, language: language, final: final,
            labels: labels, names: names)
        let client = try cachedClient()
        let startedAt = snapshot.first(where: { !$0.deleted })?.t ?? 0
        for attempt in 1...(retryLanguage ? 2 : 1) {
            let raw = try await client.sendTextRequest(
                prompt: MinutesLogic.instruction(language: language), systemPrompt: system,
                maxRetries: final ? 1 : 0, timeout: final ? 150 : 75, thinkingBudget: 0,
                jsonOutput: true)
            guard
                let parsed = MinutesLogic.parse(
                    raw, lines: snapshot, startedAt: startedAt, who: { labels.who($0, names: names) })
            else { return nil }
            if MinutesLogic.written(parsed, in: language) { return parsed }
            log("MeetingMinutes: reply not in \(language) (attempt \(attempt)), dropped")
        }
        return nil
    }

    private func cachedClient() throws -> GeminiClient {
        if let geminiClient { return geminiClient }
        let client = try GeminiClient(model: ModelQoS.Gemini.proactive, fallbackModel: "gemini-2.5-flash")
        geminiClient = client
        return client
    }

    /// How long to wait after an attempt that didn't work. A refusal from the shared budget
    /// waits twice the interval; the plan not allowing it right now waits five minutes.
    private static func backoff(after state: State) -> TimeInterval? {
        switch state {
        case .rateLimited: return MinutesLogic.interval * 2
        case .unavailable: return 300
        case .failed: return MinutesLogic.interval
        default: return nil
        }
    }

    private static func state(for error: Error) -> State {
        let message = ((error as? GeminiClient.GeminiClientError)?.internalMessage ?? error.localizedDescription)
            .lowercased()
        if (error as? GeminiClient.GeminiClientError)?.isExpectedProductState == true { return .unavailable }
        if message.contains("429") || message.contains("rate limit") || message.contains("resource exhausted") {
            return .rateLimited
        }
        return .failed
    }

    /// "New" marks what the last live update added, for a minute.
    private func markFresh(old: MeetingMinutes, new: MeetingMinutes) {
        freshGeneration += 1
        fresh = MinutesLogic.freshKeys(old: old, new: new)
        guard !fresh.isEmpty else { return }
        let marked = freshGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, self.freshGeneration == marked else { return }
            self.fresh = []
        }
    }

    // MARK: - Language

    /// The language the minutes are written in, as a translation code.
    func currentLanguageCode(lines snapshot: [MinutesLine]? = nil) -> String {
        let choice = CopilotSettings.shared.minutesLanguage
        switch choice {
        case CopilotSettings.followSystemLanguage:
            return MeetingLanguages.myLanguage()
        case CopilotSettings.meetingLanguage:
            return meetingLanguage(lines: snapshot ?? lines) ?? MeetingLanguages.myLanguage()
        default:
            return choice
        }
    }

    /// The language the other side speaks: read off the transcript itself when there is enough
    /// of it, else the language transcription was set to.
    func meetingLanguage(lines snapshot: [MinutesLine]) -> String? {
        let theirs = snapshot.filter { !$0.isUser && !$0.deleted }.suffix(60).map(\.text).joined(separator: " ")
        if let detected = MeetingLanguages.dominantScript(of: theirs) { return detected }
        let configured = AssistantSettings.shared.transcriptionLanguage
        return configured == "multi" ? nil : MeetingLanguages.translationCode(forSystemLanguage: configured)
    }

    // MARK: - Hand-offs

    /// Correct spellings of the names and terms in the current minutes, for push-to-talk's
    /// vocabulary: the meeting already told us how its names are spelled.
    func vocabularyTerms() -> [String] {
        MinutesTerm.ordered(minutes.terms).prefix(20).map(\.name)
    }

    /// Glossary lines for a translation prompt.
    var glossary: [String] { MinutesLogic.glossary(minutes.terms) }

    // MARK: - Persistence

    struct Record: Codable, Sendable {
        let sessionId: Int64
        let startedAt: Date
        let trigger: MinutesTrigger?
        let lines: [MinutesLine]
        let minutes: MeetingMinutes
    }

    static func directory() -> URL {
        DesktopLocalProfile.applicationSupportURL()
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(RewindDatabase.currentUserId ?? "anonymous", isDirectory: true)
            .appendingPathComponent("meeting-minutes", isDirectory: true)
    }

    static func fileURL(for sessionId: Int64) -> URL {
        directory().appendingPathComponent("\(sessionId).json")
    }

    /// One JSON file per session, written atomically off the main actor. No database schema
    /// change: the minutes are a document about a session, not rows anything queries.
    private func persist(
        id: Int64, lines snapshot: [MinutesLine], minutes: MeetingMinutes, startedAt: Date,
        trigger: MinutesTrigger?
    ) {
        let record = Record(sessionId: id, startedAt: startedAt, trigger: trigger, lines: snapshot, minutes: minutes)
        let url = Self.fileURL(for: id)
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(record).write(to: url, options: .atomic)
            } catch {
                logError("MeetingMinutes: failed to save minutes for session \(id)", error: error)
            }
        }
    }

    static func loadRecord(sessionId: Int64) -> Record? {
        guard let data = try? Data(contentsOf: fileURL(for: sessionId)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Record.self, from: data)
    }

    // MARK: - Debug (omi-ctl)

    func debugDump() -> [String: String] {
        [
            "enabled": CopilotSettings.shared.minutesEnabled ? "true" : "false",
            "state": "\(state)",
            "session": sessionId.map(String.init) ?? "-",
            "shown_session": shownSessionId.map(String.init) ?? "-",
            "trigger": trigger?.rawValue ?? "-",
            "call_seen": callSeen ? "true" : "false",
            "sound_samples": "\(soundSamples.filter { $0 }.count)/\(soundSamples.count)",
            "lines": String(lines.count),
            "covered": String(minutes.covered),
            "final": minutes.final ? "true" : "false",
            "language": currentLanguageCode(),
            "title": minutes.title ?? "-",
            "topics": minutes.topics.map(\.title).joined(separator: " | "),
            "conclusions": String(minutes.conclusions.count),
            "todos": String(minutes.todos.count),
            "terms": minutes.terms.map(\.name).joined(separator: ", "),
            "unsourced": String(
                (minutes.conclusions + minutes.todos).filter { $0.evidence.isEmpty }.count),
            "summary": minutes.summary,
        ]
    }

    /// Rebuild a stored session's minutes the way a live meeting would, a few lines at a time,
    /// then the final pass. For checking that topics stay stable; writes nothing to disk.
    func replay(sessionId id: Int64, step: Int = 6) async -> [String: String] {
        guard let record = Self.loadRecord(sessionId: id) else {
            return ["error": "no saved minutes for session \(id)"]
        }
        guard sessionId == nil else { return ["error": "a session is recording; replay when it has ended"] }
        let all = record.lines
        let languageCode = currentLanguageCode(lines: all)
        shownSessionId = id
        minutes = MeetingMinutes()
        var calls = 0
        var topicCounts: [Int] = []
        let step = max(1, step)
        var upto = min(step, all.count)
        while upto <= all.count, upto > 0 {
            let slice = Array(all.prefix(upto))
            let base = minutes
            if var next = try? await request(
                base: base, lines: slice, from: min(base.covered, slice.count), languageCode: languageCode,
                final: false, retryLanguage: false, names: [:])
            {
                MinutesLogic.carryEvidence(from: base, into: &next)
                next.covered = slice.count
                minutes = next
                topicCounts.append(next.topics.count)
            }
            calls += 1
            if upto == all.count { break }
            upto = min(upto + step, all.count)
        }
        if var finished = try? await request(
            base: MeetingMinutes(), lines: all, from: 0, languageCode: languageCode, final: true,
            retryLanguage: true, names: [:])
        {
            finished.covered = all.count
            finished.final = true
            minutes = finished
        }
        return [
            "lines": String(all.count),
            "live_calls": String(calls),
            "topics_over_time": topicCounts.map(String.init).joined(separator: ","),
            "final_topics": minutes.topics.map(\.title).joined(separator: " | "),
            "final": minutes.final ? "true" : "false",
        ]
    }
}
