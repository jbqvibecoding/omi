// Built only with the macOS 26 SDK (Xcode 26 / Swift 6.2): SpeechAnalyzer doesn't exist before it.
#if compiler(>=6.2)

  import AVFoundation
  import CoreMedia
  import Foundation
  import Speech

  // Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — Sources/LiveSubs/ListenEngine.swift
  // (SpeechTranscriber with volatile and final results, ending a long line at a small pause,
  // spoken-language detection and the switch with replay, failure backoff), AudioRouter.swift
  // (PCMConverter, the analyzer feed, pause and silence tracking, the ring kept for detection and
  // replay) and LanguageDetector.swift. See ThirdPartyLicenses/cicada-LICENSE.txt.
  // Changes: fed with omi's 16 kHz Int16 capture chunks instead of its own system-audio tap;
  // finished lines become omi transcript segments on the session clock, and a sentence a pause cut
  // in two is re-sent under its first piece's segment id once joined (HeardText); the line in
  // progress goes to the subtitle feed; translation, notes and the subtitle bar live elsewhere;
  // one recognizer per channel, and only the other side's detects the language; an unsupported
  // language or a recognizer that keeps failing hands the session back to the cloud.

  /// Moves capture chunks off the capture thread, converts them for the analyzer, feeds it, and
  /// keeps a short ring for language detection and replay.
  @available(macOS 26.0, *)
  final class SpeechAudioRouter: @unchecked Sendable {
    struct Stats {
      var voicedTotal: Double
      var silenceRun: Double
      /// Seconds of audio since the last pause of ≥ `gapSeconds`.
      var sinceGap: Double
      var recentVoiced: Double
    }

    static let gapSeconds = 1.5

    private let queue = DispatchQueue(label: "com.omi.speech-router", qos: .userInitiated)
    private let converter = PCMBufferConverter()
    private let inputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var format: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var ring: [(buffer: AVAudioPCMBuffer, seconds: Double, voiced: Bool)] = []
    private var ringSeconds = 0.0
    private let ringLimit = 10.0
    private var voicedTotal = 0.0
    private var silenceRun = 0.0
    private var sinceGap = 0.0
    /// The last short pause between words, on the analyzer's clock: where it ended and how long.
    private var pause: (end: Double, length: Double) = (0, 0)
    /// Seconds of audio given to the current analyzer, replay included: the analyzer's clock.
    private var fed = 0.0
    /// Seconds of audio this channel has carried since it started: the session's clock.
    private var total = 0.0
    private var accepting = true
    /// Below this RMS a block counts as silence (≈ -40 dBFS).
    private let voiceThreshold: Float = 0.01

    func push(_ data: Data) {
      queue.async { [self] in process(data) }
    }

    private func process(_ data: Data) {
      guard accepting else { return }
      let n = data.count / 2
      guard n > 0,
        let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(n)),
        let channel = buffer.floatChannelData?[0]
      else { return }
      buffer.frameLength = AVAudioFrameCount(n)
      var sum: Float = 0
      data.withUnsafeBytes { raw in
        for i in 0..<n {
          let v = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
          channel[i] = v
          sum += v * v
        }
      }
      let rms = (sum / Float(n)).squareRoot()
      let seconds = Double(n) / 16_000
      let voiced = rms >= voiceThreshold
      if voiced {
        if silenceRun >= 0.12, continuation != nil { pause = (fed, silenceRun) }
        if silenceRun >= Self.gapSeconds { sinceGap = 0 }
        voicedTotal += seconds
        silenceRun = 0
      } else {
        silenceRun += seconds
      }
      sinceGap += seconds
      total += seconds

      guard let format, let converted = converter.convert(buffer, to: format) else { return }
      continuation?.yield(AnalyzerInput(buffer: converted))
      if continuation != nil { fed += seconds }
      ring.append((buffer: converted, seconds: seconds, voiced: voiced))
      ringSeconds += seconds
      while ringSeconds > ringLimit, !ring.isEmpty {
        ringSeconds -= ring.removeFirst().seconds
      }
    }

    /// Analyzer clock now, the silence running at the end of it, and the last pause before that.
    func clock() -> (fed: Double, silence: Double, pause: (end: Double, length: Double)) {
      queue.sync { (fed, silenceRun, pause) }
    }

    /// Feeds a new analyzer. `replaySeconds` re-feeds recent audio so a newly detected language
    /// doesn't lose the words spoken while detection ran. Returns the session time the analyzer's
    /// clock starts at.
    func attach(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, replaySeconds: Double = 0)
      -> Double
    {
      queue.sync {
        fed = 0
        pause = (0, 0)
        var replayed = 0.0
        if self.format != format {
          ring.removeAll()
          ringSeconds = 0
        } else if replaySeconds > 0 {
          var replay: [AVAudioPCMBuffer] = []
          for item in ring.reversed() {
            if replayed >= replaySeconds { break }
            replayed += item.seconds
            replay.append(item.buffer)
          }
          for buffer in replay.reversed() { continuation.yield(AnalyzerInput(buffer: buffer)) }
          fed = replayed
        }
        self.format = format
        self.continuation?.finish()
        self.continuation = continuation
        return total - replayed
      }
    }

    /// Ends the analyzer's input.
    func detach() {
      queue.sync {
        continuation?.finish()
        continuation = nil
      }
    }

    /// Stops taking capture chunks (the channel is being retired).
    func stopAccepting() {
      queue.sync { accepting = false }
    }

    func stats(window: Double = 6) -> Stats {
      queue.sync {
        var acc = 0.0
        var voiced = 0.0
        for item in ring.reversed() {
          if acc >= window { break }
          acc += item.seconds
          if item.voiced { voiced += item.seconds }
        }
        return Stats(voicedTotal: voicedTotal, silenceRun: silenceRun, sinceGap: sinceGap, recentVoiced: voiced)
      }
    }

    func snapshot(seconds: Double) -> [AVAudioPCMBuffer] {
      queue.sync {
        var acc = 0.0
        var out: [AVAudioPCMBuffer] = []
        for item in ring.reversed() {
          if acc >= seconds { break }
          acc += item.seconds
          out.append(item.buffer)
        }
        return out.reversed()
      }
    }
  }

  /// Detects the spoken language by transcribing the same short clip with every installed
  /// on-device model and comparing how confident each one is. The right model is typically
  /// ≥0.85 confident; wrong ones produce little text or score well below that.
  @available(macOS 26.0, *)
  enum SpeechLanguageDetector {
    struct Candidate {
      let locale: String
      let confidence: Double
      let chars: Int
      let score: Double
    }

    static func rank(_ clip: [AVAudioPCMBuffer], candidates: [String]) async -> [Candidate] {
      await withTaskGroup(of: Candidate?.self) { group in
        for locale in candidates {
          group.addTask { await evaluate(clip, locale: locale) }
        }
        var out: [Candidate] = []
        for await c in group { if let c { out.append(c) } }
        return out.sorted { $0.score > $1.score }
      }
    }

    private static func evaluate(_ clip: [AVAudioPCMBuffer], locale: String) async -> Candidate? {
      let transcriber = SpeechTranscriber(
        locale: Locale(identifier: locale), transcriptionOptions: [], reportingOptions: [],
        attributeOptions: [.transcriptionConfidence])
      guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        return nil
      }
      let converter = PCMBufferConverter()
      let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
      for buffer in clip {
        if let b = converter.convert(buffer, to: format) { continuation.yield(AnalyzerInput(buffer: b)) }
      }
      continuation.finish()

      let collector = Task { () -> (String, Double, Int) in
        var text = ""
        var weighted = 0.0
        var chars = 0
        for try await result in transcriber.results {
          text += String(result.text.characters)
          for run in result.text.runs {
            guard let c = run.transcriptionConfidence else { continue }
            let len = result.text[run.range].characters.filter { !$0.isWhitespace && !$0.isPunctuation }.count
            weighted += c * Double(len)
            chars += len
          }
        }
        return (text, chars > 0 ? weighted / Double(chars) : 0, chars)
      }
      do {
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (text, conf, chars) = try await collector.value
        return Candidate(
          locale: locale, confidence: conf, chars: chars,
          score: score(conf: conf, chars: chars, text: text, locale: locale))
      } catch {
        collector.cancel()
        return nil
      }
    }

    static func score(conf: Double, chars: Int, text: String, locale: String) -> Double {
      guard chars > 0 else { return 0 }
      // Very short output means the model mostly heard noise.
      let lengthFactor = min(1.0, Double(chars) / 6.0)
      // A CJK model that mostly writes Latin letters is transcribing a foreign language.
      var scriptFactor = 1.0
      if MeetingLanguages.isCJK(locale) {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let latin = letters.filter { $0.isASCII }.count
        if !letters.isEmpty, Double(latin) / Double(letters.count) > 0.5 { scriptFactor = 0.75 }
      }
      return conf * lengthFactor * scriptFactor
    }
  }

  /// One channel transcribed by Apple's on-device recognizer (macOS 26): words as they are said,
  /// sentences ended at small pauses rather than only at long ones, and — for the other side —
  /// the language detected from what they actually speak.
  @available(macOS 26.0, *)
  @MainActor
  final class AppleSpeechTranscriptionService: LocalSegmentTranscriber {
    typealias SegmentsHandler = LocalTranscriptionService.SegmentsHandler

    nonisolated let router = SpeechAudioRouter()

    private let isUser: Bool
    private let speakerId: Int
    private let speakerLabel: String
    private let preferredLocale: String
    private let detectLanguage: Bool

    private var onSegments: SegmentsHandler?
    private var onModelLoadFailed: (@MainActor () -> Void)?
    private var running = false
    private var reportedFailure = false

    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var generation = 0
    private(set) var activeLocale: String
    /// Session time at which the current analyzer's clock reads zero.
    private var clockBase = 0.0
    private var failureStreak = 0

    // Language detection (the other side only)
    private var candidates: [String] = []
    private var languageConfirmed = false
    private var pendingSwitch: String?
    private var needsDetection = true
    private var nextPeriodicDetection = 30.0
    private var lastDetectionAt = Date.distantPast
    private var ambiguousDetections = 0
    private var detecting = false
    /// Lines finished before detection settled the language: sent once it confirms the language
    /// they were heard in, dropped on a switch (the replay into the new model redoes them).
    private var unconfirmed: [(text: String, start: Double, end: Double, cut: Bool)] = []
    private var recordable: Bool {
      !detectLanguage || candidates.count < 2 || languageConfirmed || ambiguousDetections >= 2
    }

    // The line in progress
    private var volatileText = ""
    private var volatileStartedAt = Date()
    private var volatileStartClock = 0.0
    private var volatileChangedAt = Date()
    private var cutting = false
    private var lastCut = ""
    private var lastCutThrough = 0.0
    /// A cut was asked for: the next final line ends at our pause, not the speaker's.
    private var cutAsked = false
    /// The last line sent, so the piece that finishes it can be joined on.
    private var lastLine: (id: String, text: String, start: Double, end: Double, cut: Bool)?

    private var tickTimer: Timer?
    private var ticks = 0

    private static let lastDetectedKey = "omi.appleSpeech.lastDetectedLocale"

    init(language: String, isUser: Bool, detectLanguage: Bool) {
      self.isUser = isUser
      speakerId = isUser ? 0 : 1
      speakerLabel = isUser ? "SPEAKER_00" : "SPEAKER_01"
      preferredLocale = TranscriberRouting.speechLocale(for: language)
      self.detectLanguage = detectLanguage
      activeLocale = preferredLocale
    }

    // MARK: LocalSegmentTranscriber

    func start(onSegments: @escaping SegmentsHandler, onModelLoadFailed: (@MainActor () -> Void)?) {
      guard !running else { return }
      self.onSegments = onSegments
      self.onModelLoadFailed = onModelLoadFailed
      guard SpeechTranscriber.isAvailable else {
        log("AppleSpeech[\(channel)]: not available on this Mac")
        fail()
        return
      }
      running = true
      startTickTimer()
      Task {
        await refreshCandidates()
        await switchTranscriber(to: initialLocale())
        // The other side may well not speak the user's language: make sure English can be
        // told apart too, in the background, so the next meeting detects it.
        if detectLanguage, !MeetingLanguages.sameLanguage(preferredLocale, "en"),
          !candidates.contains(where: { MeetingLanguages.sameLanguage($0, "en") })
        {
          await installInBackground("en-US")
        }
      }
    }

    nonisolated func appendAudio(_ data: Data) {
      router.push(data)
    }

    func stop() {
      Task { await self.finish() }
    }

    func finish() async {
      guard running else { return }
      router.stopAccepting()
      tickTimer?.invalidate()
      tickTimer = nil
      if let analyzer {
        // End the input and let the recognizer finish what it has heard, so the last words
        // land in this session.
        router.detach()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        if let resultsTask {
          let drained = Task { await resultsTask.value }
          let deadline = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            resultsTask.cancel()
          }
          await drained.value
          deadline.cancel()
        }
      }
      flushUnconfirmed()
      running = false
      analyzer = nil
      resultsTask = nil
      if !isUser { SubtitleFeed.shared.setPartial("", language: nil) }
      log("AppleSpeech[\(channel)]: finished")
    }

    // MARK: Models

    private var channel: String { isUser ? "mic" : "sys" }

    private func refreshCandidates() async {
      let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
      var wanted = [preferredLocale, "en-US"]
      for code in Locale.preferredLanguages.map(MeetingLanguages.translationCode(forSystemLanguage:)) {
        let locale = TranscriberRouting.speechLocale(for: code)
        if TranscriberRouting.appleSpeechSupports(code), !wanted.contains(locale) { wanted.append(locale) }
      }
      candidates = wanted.filter { installed.contains($0) }
      log("AppleSpeech[\(channel)]: installed models \(installed.sorted()), detection candidates \(candidates)")
    }

    private func initialLocale() -> String {
      guard detectLanguage else { return preferredLocale }
      if let last = UserDefaults.standard.string(forKey: Self.lastDetectedKey), candidates.contains(last) {
        return last
      }
      return preferredLocale
    }

    private struct Unsupported: Error {}

    private func ensureModel(for transcriber: SpeechTranscriber, locale: String) async throws {
      let status = await AssetInventory.status(forModules: [transcriber])
      if status == .installed { return }
      guard status != .unsupported else { throw Unsupported() }
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        log("AppleSpeech[\(channel)]: downloading the \(locale) model")
        if !isUser { SubtitleFeed.shared.setStatus("Downloading the speech model…") }
        try await request.downloadAndInstall()
        if !isUser { SubtitleFeed.shared.setStatus(nil) }
        await refreshCandidates()
      }
    }

    private func installInBackground(_ locale: String) async {
      let transcriber = SpeechTranscriber(
        locale: Locale(identifier: locale), transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
      do {
        guard await AssetInventory.status(forModules: [transcriber]) != .unsupported,
          let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        else { return }
        try await request.downloadAndInstall()
        await refreshCandidates()
      } catch {
        log("AppleSpeech[\(channel)]: background install of \(locale) failed: \(error.localizedDescription)")
      }
    }

    // MARK: Recognizer

    private func switchTranscriber(to locale: String, replaySeconds: Double = 0) async {
      generation += 1
      let gen = generation
      router.detach()
      resultsTask?.cancel()
      resultsTask = nil
      if let old = analyzer {
        analyzer = nil
        await old.cancelAndFinishNow()
      }
      guard running, gen == generation else { return }
      activeLocale = locale
      volatileText = ""
      cutAsked = false
      publishPartial("")

      let transcriber = SpeechTranscriber(
        locale: Locale(identifier: locale), transcriptionOptions: [],
        reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.transcriptionConfidence])
      do {
        try await ensureModel(for: transcriber, locale: locale)
        guard running, gen == generation else { return }
        let format =
          await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
          ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        guard running, gen == generation else {
          await analyzer.cancelAndFinishNow()
          return
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        clockBase = router.attach(format: format, continuation: continuation, replaySeconds: replaySeconds)
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
          do {
            for try await result in transcriber.results {
              self?.handle(result, generation: gen)
            }
          } catch {
            self?.recognitionFailed(error, generation: gen)
          }
        }
        try await analyzer.start(inputSequence: stream)
        log("AppleSpeech[\(channel)]: recognizer started (\(locale))")
      } catch is Unsupported {
        log("AppleSpeech[\(channel)]: \(locale) is not supported on this Mac")
        // Detection may have picked a language we can't read: stay with the user's own.
        if locale != preferredLocale {
          await switchTranscriber(to: preferredLocale)
        } else {
          fail()
        }
      } catch {
        recognitionFailed(error, generation: gen)
      }
    }

    private func recognitionFailed(_ error: Error, generation gen: Int) {
      guard gen == generation, running else { return }
      failureStreak += 1
      log("AppleSpeech[\(channel)]: recognition error (\(failureStreak)): \(error.localizedDescription)")
      // A recognizer that keeps failing isn't coming back this session: let the cloud take it.
      guard failureStreak < 5 else {
        fail()
        return
      }
      let delay = min(30.0, 2.0 * pow(2.0, Double(failureStreak - 1)))
      let locale = activeLocale
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard let self, self.running, gen == self.generation else { return }
        await self.switchTranscriber(to: locale)
      }
    }

    /// Hand the session back (the caller falls back to cloud transcription). Once.
    private func fail() {
      guard !reportedFailure else { return }
      reportedFailure = true
      running = false
      tickTimer?.invalidate()
      tickTimer = nil
      onModelLoadFailed?()
    }

    private func handle(_ result: SpeechTranscriber.Result, generation gen: Int) {
      guard gen == generation, running else { return }
      failureStreak = 0
      var text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
      if result.isFinal {
        text = HeardText.clean(text)
        volatileText = ""
        publishPartial("")
        // A "." or "…" from a breath or a click is no sentence.
        guard text.contains(where: \.isLetter) else { return }
        var weighted = 0.0
        var chars = 0
        for run in result.text.runs {
          guard let c = run.transcriptionConfidence else { continue }
          let len = result.text[run.range].characters.count
          weighted += c * Double(len)
          chars += len
        }
        let conf = chars > 0 ? weighted / Double(chars) : 1
        let start = clockBase + CMTimeGetSeconds(result.range.start)
        let end = clockBase + CMTimeGetSeconds(result.range.end)
        let cut = cutAsked
        cutAsked = false
        if recordable {
          emit(text: text, start: start, end: end, cut: cut)
        } else {
          unconfirmed.append((text: text, start: start, end: end, cut: cut))
        }
        if detectLanguage, conf < 0.6, text.count >= 4 { needsDetection = true }
      } else {
        if volatileText.isEmpty {
          volatileStartedAt = Date()
          volatileStartClock = router.clock().fed
        }
        if text != volatileText { volatileChangedAt = Date() }
        volatileText = text
        publishPartial(text)
      }
    }

    /// Sends a finished line, or — when it finishes the previous one (a pause cut one sentence
    /// in two) — the joined sentence under the previous line's id, which the transcript updates
    /// in place.
    private func emit(text: String, start: Double, end: Double, cut: Bool) {
      let id: String
      let line: String
      let from: Double
      if let last = lastLine, HeardText.continues(last.text, text, gap: start - last.end, cut: last.cut) {
        id = last.id
        line = HeardText.join(last.text, text)
        from = last.start
      } else {
        id = UUID().uuidString
        line = text
        from = start
      }
      lastLine = (id: id, text: line, start: from, end: end, cut: cut)
      if !isUser {
        SubtitleFeed.shared.noteLanguage(lineId: id, code: MeetingLanguages.translationCode(forSystemLanguage: activeLocale))
      }
      let segment = TranscriptionService.BackendSegment(
        id: id, text: line, speaker: speakerLabel, speaker_id: speakerId, is_user: isUser, person_id: nil,
        start: from, end: max(end, from), translations: nil)
      onSegments?([segment])
    }

    private func flushUnconfirmed() {
      let held = unconfirmed
      unconfirmed = []
      for h in held { emit(text: h.text, start: h.start, end: h.end, cut: h.cut) }
    }

    private func publishPartial(_ text: String) {
      guard !isUser else { return }
      SubtitleFeed.shared.setPartial(
        text, language: MeetingLanguages.translationCode(forSystemLanguage: activeLocale))
    }

    // MARK: Ticks: cutting long lines, detecting the language

    private func startTickTimer() {
      tickTimer?.invalidate()
      // Pauses are short: look for one four times a second; detection runs once a second.
      let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.maybeCutSentence()
          self.ticks += 1
          guard self.ticks % 4 == 0 else { return }
          self.maybeDetectLanguage()
        }
      }
      tickTimer = timer
      RunLoop.main.add(timer, forMode: .common)
    }

    /// The recognizer ends a sentence only at a clear pause; in a quick conversation that can
    /// take 15–20 s, and the subtitle stays a draft that long (the minutes wait for it too). A
    /// long line in progress is ended at the next small pause: a dip in the sound, or no new
    /// words for a moment.
    private func maybeCutSentence() {
      guard running, !cutting, let analyzer, !volatileText.isEmpty, volatileText != lastCut else { return }
      let cjk = MeetingLanguages.isCJK(activeLocale)
      let long = cjk ? volatileText.count >= 24 : volatileText.split(separator: " ").count >= 10
      guard long else { return }
      // The longer the line has run, the smaller the pause that may end it.
      let held = Date().timeIntervalSince(volatileStartedAt)
      let needed = held >= 8 ? 0.15 : 0.3
      let c = router.clock()
      let mid = c.pause.end - c.pause.length / 2
      let through: Double
      if c.silence >= needed {
        through = c.fed
      } else if c.pause.length >= needed, mid > volatileStartClock + 1.5, mid > lastCutThrough, c.pause.end <= c.fed {
        through = mid  // a pause already behind us: end the line there
      } else if Date().timeIntervalSince(volatileChangedAt) >= (held >= 8 ? 0.6 : 1.2) {
        through = c.fed  // stalled
      } else {
        return
      }
      cutting = true
      cutAsked = true
      lastCut = volatileText
      lastCutThrough = through
      Task { [weak self] in
        do {
          try await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 1000))
        } catch {
          self?.cutAsked = false
        }
        self?.cutting = false
      }
    }

    private func maybeDetectLanguage() {
      guard running, detectLanguage, !detecting, candidates.count >= 2 else { return }
      var stats = router.stats(window: 6)
      if stats.silenceRun >= SpeechAudioRouter.gapSeconds { needsDetection = true }
      if stats.voicedTotal >= nextPeriodicDetection { needsDetection = true }
      guard needsDetection, Date().timeIntervalSince(lastDetectionAt) >= 3 else { return }
      let clipSeconds = min(6, stats.sinceGap)
      guard clipSeconds >= 3 else { return }
      stats = router.stats(window: clipSeconds)
      guard stats.recentVoiced >= 2.5 else { return }

      needsDetection = false
      lastDetectionAt = Date()
      detecting = true
      nextPeriodicDetection = stats.voicedTotal + 20
      let clip = router.snapshot(seconds: clipSeconds)
      let candidates = self.candidates
      Task { [weak self] in
        let ranked = await SpeechLanguageDetector.rank(clip, candidates: candidates)
        guard let self else { return }
        self.detecting = false
        guard self.running else { return }
        self.applyDetection(ranked)
      }
    }

    private func applyDetection(_ ranked: [SpeechLanguageDetector.Candidate]) {
      guard let best = ranked.first else { return }
      let runnerUp = ranked.dropFirst().first?.score ?? 0
      guard best.confidence >= 0.6, best.score - runnerUp >= 0.08 else {
        ambiguousDetections += 1
        if !languageConfirmed { needsDetection = true }
        if recordable { flushUnconfirmed() }
        return
      }
      if best.locale == activeLocale {
        languageConfirmed = true
        flushUnconfirmed()
        pendingSwitch = nil
        UserDefaults.standard.set(best.locale, forKey: Self.lastDetectedKey)
        return
      }
      let currentScore = ranked.first(where: { $0.locale == activeLocale })?.score ?? 0
      let overwhelming = best.score - currentScore >= 0.30
      if !languageConfirmed || overwhelming || pendingSwitch == best.locale {
        log("AppleSpeech[\(channel)]: language \(activeLocale) → \(best.locale)")
        languageConfirmed = true
        unconfirmed = []
        pendingSwitch = nil
        lastLine = nil
        UserDefaults.standard.set(best.locale, forKey: Self.lastDetectedKey)
        Task { await switchTranscriber(to: best.locale, replaySeconds: 8) }
      } else {
        pendingSwitch = best.locale
        needsDetection = true
      }
    }
  }

#endif
