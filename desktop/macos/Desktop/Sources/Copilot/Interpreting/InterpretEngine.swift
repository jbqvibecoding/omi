import AVFoundation
import CoreAudio
import Foundation

#if compiler(>=6.2)
  import Speech
#endif

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — SpeakEngine in
// Sources/LiveSubs/SpeakEngine.swift. See ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: hearing the press falls back from Ming to Apple's recognizer (macOS 26) or omi's own
// transcription (older macOS); translation falls back to Apple's on-device translation or Gemini
// at the top of the shared budget; voices go Ming (cloned or built-in) → omi's speech service →
// the Mac's own, each falling through to the next if it fails before any sound; the bar is omi's
// subtitle bar; no meeting record or diagnostics of its own (omi's transcript already carries
// what you said, from the real microphone).

/// Hold the key, speak, let go: the microphone → what you said → its translation → a voice →
/// the virtual microphone, so the meeting hears the translation.
///
/// The hard rule, kept from Cicada: never speak the untranslated original into the room. If the
/// translation fails, the bar says so and nothing is sent.
@MainActor
final class InterpretEngine: ObservableObject {
    static let shared = InterpretEngine()

    enum Phase: Equatable { case idle, listening, translating, speaking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastHeard = ""
    @Published private(set) var lastSpoken = ""
    @Published private(set) var lastFailure: String?
    /// How the last sentence was voiced, for the settings page ("Ming", "omi", "this Mac").
    @Published private(set) var lastVoice = ""

    // Microphone
    private let mic = AVAudioEngine()
    private let micQueue = DispatchQueue(label: "com.omi.interpreter.mic", qos: .userInitiated)
    private nonisolated(unsafe) var feeding = false
    /// This press as 16 kHz mono 16-bit samples; only touched on `micQueue`.
    private nonisolated(unsafe) var pressSamples: [Int16] = []
    private nonisolated(unsafe) var pressConverter = PCMBufferConverter()
    private nonisolated static let pressFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// A press is meant for a sentence or two.
    private nonisolated static let pressLimit = 16_000 * 60
    private var pressStarted = Date()
    /// The on-device recognizer for this press (macOS 26): live words while the key is held, and
    /// the transcript when Ming isn't there. `Any` because the type only exists on macOS 26.
    private var pressRecognizer: Any?

    // Voice output
    private let synth = AVSpeechSynthesizer()
    private let out = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var outFormat: AVAudioFormat?
    private var outDeviceUID: String?

    private init() {
        out.attach(player)
    }

    // MARK: Languages

    /// The language you speak.
    var sourceCode: String {
        let choice = CopilotSettings.shared.interpreterFromLanguage
        return choice == CopilotSettings.followSystemLanguage ? MeetingLanguages.myLanguage() : choice
    }

    /// The language the other side hears: the meeting's, unless chosen. The meeting's language is
    /// what the other side has been speaking (or, before anyone spoke, not mine: English, or
    /// Chinese for an English speaker).
    var targetCode: String {
        let choice = CopilotSettings.shared.interpreterToLanguage
        if choice != CopilotSettings.meetingLanguage { return choice }
        let engine = MeetingMinutesEngine.shared
        if let heard = engine.meetingLanguage(lines: engine.lines),
            !MeetingLanguages.sameLanguage(heard, sourceCode)
        {
            return heard
        }
        return MeetingLanguages.sameLanguage(sourceCode, "en") ? "zh-CN" : "en"
    }

    // MARK: The key

    func pressBegan() {
        guard CopilotSettings.shared.interpreterEnabled, phase == .idle || phase == .speaking else { return }
        pressStarted = Date()
        phase = .listening
        lastFailure = nil
        micQueue.sync {
            pressSamples = []
            pressConverter = PCMBufferConverter()
        }
        SubtitleOverlayController.shared.setSpeaking(.init(phase: .listening, source: "", translation: ""))
        beginRecognizer()
        startMic()
    }

    /// The key turned out to be part of a chord: drop what was heard, send nothing.
    func pressCancelled() {
        guard phase == .listening else { return }
        stopMic()
        cancelRecognizer()
        micQueue.sync { pressSamples = [] }
        phase = .idle
        SubtitleOverlayController.shared.setSpeaking(nil)
    }

    func pressEnded() {
        guard phase == .listening else { return }
        // Keep the mic open a moment so the last syllable isn't cut off.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self.finishPress()
        }
    }

    // MARK: Microphone

    private func startMic() {
        let device = SystemMic.shared.recordingDevice(chosen: CopilotSettings.shared.interpreterMicUID)
        AudioDevices.pinInput(mic, to: device)
        let input = mic.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            fail("No microphone to listen to")
            return
        }
        input.removeTap(onBus: 0)
        let queue = micQueue
        let recognizer = pressRecognizer
        feeding = true
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            queue.async {
                guard let self, self.feeding else { return }
                self.keepForPress(buffer)
                #if compiler(>=6.2)
                    if #available(macOS 26.0, *), let recognizer = recognizer as? PressRecognizer {
                        recognizer.feed(buffer)
                    }
                #endif
            }
        }
        do {
            try mic.start()
        } catch {
            input.removeTap(onBus: 0)
            fail("The microphone wouldn't start — check omi's microphone access")
        }
    }

    private nonisolated func keepForPress(_ buffer: AVAudioPCMBuffer) {
        guard pressSamples.count < Self.pressLimit,
            let c = pressConverter.convert(buffer, to: Self.pressFormat), let p = c.int16ChannelData
        else { return }
        pressSamples.append(contentsOf: UnsafeBufferPointer(start: p[0], count: Int(c.frameLength)))
    }

    private func stopMic() {
        micQueue.sync { feeding = false }
        if mic.isRunning {
            mic.inputNode.removeTap(onBus: 0)
            mic.stop()
        }
    }

    private func takePressSamples() -> [Int16] {
        micQueue.sync { () -> [Int16] in
            defer { pressSamples = [] }
            return pressSamples
        }
    }

    /// The press as a WAV file in memory (44-byte RIFF header + little-endian samples).
    nonisolated static func wav(_ samples: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8))
        u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)
        u16(1)
        u32(16_000)
        u32(32_000)
        u16(2)
        u16(16)
        d.append(contentsOf: Array("data".utf8))
        u32(bytes)
        d.append(raw(samples))
        return d
    }

    /// Little-endian 16-bit samples, as omi's transcription service takes them.
    nonisolated static func raw(_ samples: [Int16]) -> Data {
        var d = Data(capacity: samples.count * 2)
        samples.withUnsafeBufferPointer { buf in
            for s in buf { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }

    // MARK: On-device recognizer (macOS 26)

    private func beginRecognizer() {
        pressRecognizer = nil
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), TranscriberRouting.appleSpeechAvailable {
                let recognizer = PressRecognizer(locale: TranscriberRouting.speechLocale(for: sourceCode))
                recognizer.onText = { [weak self] text in
                    guard let self, self.phase == .listening else { return }
                    SubtitleOverlayController.shared.setSpeaking(.init(phase: .listening, source: text, translation: ""))
                }
                recognizer.begin()
                pressRecognizer = recognizer
            }
        #endif
    }

    private func finishRecognizer() async -> String {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), let recognizer = pressRecognizer as? PressRecognizer {
                pressRecognizer = nil
                return await recognizer.finish()
            }
        #endif
        return ""
    }

    private func cancelRecognizer() {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), let recognizer = pressRecognizer as? PressRecognizer {
                recognizer.cancel()
            }
        #endif
        pressRecognizer = nil
    }

    // MARK: The sentence

    private func finishPress() async {
        guard phase == .listening else { return }
        stopMic()
        phase = .translating
        let samples = takePressSamples()
        let from = sourceCode
        let to = targetCode
        let glossary = MeetingMinutesEngine.shared.glossary
        // Under a quarter of a second is a tap, not a sentence.
        guard samples.count >= 16_000 / 4 else {
            cancelRecognizer()
            phase = .idle
            SubtitleOverlayController.shared.setSpeaking(nil)
            return
        }
        // Ming hears the audio while the on-device recognizer finishes, so its fallback costs nothing.
        let wav = Self.wav(samples)
        let ming = Task { @MainActor () -> (original: String, translation: String)? in
            guard LingClient.shared.usable else { return nil }
            return await LingClient.shared.interpret(wav: wav, source: from, target: to, glossary: glossary)
        }
        var text = await finishRecognizer()
        if !text.isEmpty {
            SubtitleOverlayController.shared.setSpeaking(.init(phase: .translating, source: text, translation: ""))
        }
        let heard = await ming.value
        if let heard { text = heard.original }
        if text.isEmpty {
            // Before macOS 26 and without Ming: omi's own transcription of the press.
            text = (try? await TranscriptionService.batchTranscribe(
                audioData: Self.raw(samples), language: MeetingLanguages.base(from),
                contextKeywords: MeetingMinutesEngine.shared.vocabularyTerms()))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !text.isEmpty else {
            phase = .idle
            SubtitleOverlayController.shared.setSpeaking(nil)
            return
        }
        lastHeard = text
        SubtitleOverlayController.shared.setSpeaking(.init(phase: .translating, source: text, translation: ""))

        // Never speak the untranslated original into the room.
        var translated = heard?.translation
        if translated == nil { translated = await translate(text, from: from, to: to, glossary: glossary) }
        guard let translated, !translated.isEmpty else {
            log("Interpreter: translation failed, nothing sent")
            lastFailure = "Translation failed — this sentence was not sent"
            phase = .idle
            SubtitleOverlayController.shared.setSpeaking(
                .init(phase: .failed, source: text, translation: "Translation failed — not sent"))
            return
        }
        lastSpoken = translated
        phase = .speaking
        SubtitleOverlayController.shared.setSpeaking(.init(phase: .speaking, source: text, translation: translated))
        await speak(translated, language: to)
        if phase == .speaking { phase = .idle }
        SubtitleOverlayController.shared.setSpeaking(.init(phase: .idle, source: text, translation: translated))
        log("Interpreter: sentence sent in \(String(format: "%.1f", Date().timeIntervalSince(pressStarted)))s via \(lastVoice)")
    }

    private func translate(_ text: String, from: String, to: String, glossary: [String]) async -> String? {
        if MeetingLanguages.sameLanguage(from, to) { return text }
        let corrected = MinutesLogic.correct(text, terms: MeetingMinutesEngine.shared.minutes.terms)
        if let out = await SubtitleTranslator.shared.translateOnDevice(corrected, source: from, target: to) {
            return out
        }
        return await SubtitleTranslator.shared.translateWithModel(
            [corrected], source: from, target: to, glossary: glossary, priority: .interpret)?.first
    }

    private func fail(_ message: String) {
        lastFailure = message
        stopMic()
        cancelRecognizer()
        phase = .idle
        SubtitleOverlayController.shared.setSpeaking(.init(phase: .failed, source: "", translation: message))
    }

    // MARK: Debug (omi-ctl)

    /// Translate and speak a typed sentence as if it had been said with the key held — the whole
    /// path after recognition, so it can be checked without a microphone.
    func debugSay(_ text: String) async -> [String: String] {
        guard phase == .idle else { return ["error": "busy (\(phase))"] }
        let from = sourceCode
        let to = targetCode
        phase = .translating
        SubtitleOverlayController.shared.setSpeaking(.init(phase: .translating, source: text, translation: ""))
        guard let translated = await translate(text, from: from, to: to, glossary: MeetingMinutesEngine.shared.glossary),
            !translated.isEmpty
        else {
            phase = .idle
            SubtitleOverlayController.shared.setSpeaking(
                .init(phase: .failed, source: text, translation: "Translation failed — not sent"))
            return ["error": "translation failed — nothing was sent", "from": from, "to": to]
        }
        phase = .speaking
        SubtitleOverlayController.shared.setSpeaking(.init(phase: .speaking, source: text, translation: translated))
        await speak(translated, language: to)
        phase = .idle
        SubtitleOverlayController.shared.setSpeaking(.init(phase: .idle, source: text, translation: translated))
        return [
            "from": from, "to": to, "translation": translated, "voice": lastVoice,
            "device": outputDevice()?.name ?? "default output",
        ]
    }

    // MARK: Voice output

    /// Where the room hears the interpreter: the chosen output, else the virtual mic.
    func outputDevice() -> AudioDevice? {
        let all = AudioDevices.outputs()
        let chosen = CopilotSettings.shared.interpreterOutputUID
        if !chosen.isEmpty, let d = all.first(where: { $0.uid == chosen }) { return d }
        return all.first(where: \.isVirtualMic)
    }

    /// Speaks `text` and returns once it has played. The chosen voice first; one that fails before
    /// any sound falls through to the next, so the room always hears the sentence.
    func speak(_ text: String, language: String, to override: AudioDevice? = nil) async {
        let device = override ?? outputDevice()
        let hasKey = LingClient.shared.usable
        let chosen = InterpreterVoices.voice(
            id: CopilotSettings.shared.interpreterVoiceID(for: language), for: language, hasLingKey: hasKey)
        var order = [chosen.kind]
        if chosen.needsLingKey { order.append(InterpreterVoices.omiVoice.kind) }
        if let mac = InterpreterVoices.system(for: language).first { order.append(mac.kind) } else { order.append(.system("")) }
        for kind in order {
            if await speak(text, language: language, kind: kind, device: device) { return }
        }
    }

    /// Plays a voice sample through the speakers (not into the room).
    func preview(language: String) {
        Task { await speak(InterpreterVoices.sample(for: language), language: language, to: AudioDevices.defaultOutput) }
    }

    private func speak(_ text: String, language: String, kind: InterpreterVoice.Kind, device: AudioDevice?) async -> Bool {
        switch kind {
        case .clone:
            guard let reference = VoiceSample.reference() else { return false }
            lastVoice = "your voice (Ming)"
            return await speakStream(
                LingClient.shared.speech(
                    text, voice: nil, reference: reference, language: InterpreterVoices.mingLanguage(for: language)),
                device: device)
        case .ming(let voice):
            lastVoice = "Ming"
            return await speakStream(
                LingClient.shared.speech(text, voice: voice, language: InterpreterVoices.mingLanguage(for: language)),
                device: device)
        case .omi(let voice):
            lastVoice = "omi"
            do {
                let mp3 = try await APIClient.shared.synthesizeSpeech(
                    request: APIClient.TtsSynthesizeRequest(text: text, voiceId: voice, instructions: nil))
                guard let buffer = Self.decode(mp3) else { return false }
                return await play([buffer], device: device)
            } catch {
                log("Interpreter: omi voice failed (\(error.localizedDescription))")
                return false
            }
        case .system(let identifier):
            lastVoice = "this Mac"
            let buffers = await synthesize(text, language: language, voiceID: identifier.isEmpty ? nil : identifier)
            return await play(buffers, device: device)
        }
    }

    /// An MP3 from omi's speech service as one PCM buffer.
    private static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omi-interpreter-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil, let file = try? AVAudioFile(forReading: url),
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            (try? file.read(into: buffer)) != nil, buffer.frameLength > 0
        else { return nil }
        return buffer
    }

    private func voice(for code: String, identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let v = AVSpeechSynthesisVoice(identifier: identifier) { return v }
        let lang = code == "zh-CN" ? "zh-CN" : code == "zh-TW" ? "zh-TW" : code
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        return voices.max(by: { $0.quality.rawValue < $1.quality.rawValue }) ?? AVSpeechSynthesisVoice(language: lang)
    }

    private func synthesize(_ text: String, language: String, voiceID: String?) async -> [AVAudioPCMBuffer] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: language, identifier: voiceID)
        return await withCheckedContinuation { cont in
            var buffers: [AVAudioPCMBuffer] = []
            var done = false
            synth.write(utterance) { buf in
                guard !done else { return }
                guard let pcm = buf as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    done = true
                    cont.resume(returning: buffers)
                    return
                }
                buffers.append(pcm)
            }
        }
    }

    private func play(_ buffers: [AVAudioPCMBuffer], device: AudioDevice?) async -> Bool {
        guard let first = buffers.first else { return false }
        configureOutput(format: first.format, device: device)
        do {
            if !out.isRunning { try out.start() }
        } catch {
            log("Interpreter: voice output failed (\(error.localizedDescription))")
            return false
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            for (i, b) in buffers.enumerated() {
                if i == buffers.count - 1 {
                    player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack) { _ in cont.resume() }
                } else {
                    player.scheduleBuffer(b)
                }
            }
            player.play()
        }
        return true
    }

    /// Plays 24 kHz mono 16-bit PCM chunks as they arrive. Returns false if nothing came, so the
    /// caller can fall back to the next voice.
    private func speakStream(_ stream: AsyncThrowingStream<Data, Error>, device: AudioDevice?) async -> Bool {
        guard
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)
        else { return false }
        var carry = Data()
        var count = 0
        do {
            for try await chunk in stream {
                var bytes = carry + chunk
                if bytes.count % 2 == 1 {
                    carry = bytes.suffix(1)
                    bytes = bytes.dropLast()
                } else {
                    carry = Data()
                }
                let frames = bytes.count / 2
                guard frames > 0,
                    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                    let dst = buf.floatChannelData?[0]
                else { continue }
                buf.frameLength = AVAudioFrameCount(frames)
                bytes.withUnsafeBytes { raw in
                    for i in 0..<frames {
                        dst[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                    }
                }
                if count == 0 {
                    configureOutput(format: format, device: device)
                    if !out.isRunning { try out.start() }
                }
                player.scheduleBuffer(buf, completionHandler: nil)
                if !player.isPlaying { player.play() }
                count += 1
            }
        } catch {
            log("Interpreter: Ming voice failed (\(error))")
            if count == 0 { return false }
        }
        guard count > 0 else { return false }
        // Wait for the queued audio to finish before the next sentence.
        if let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240) {
            tail.frameLength = 240
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                player.scheduleBuffer(tail, completionCallbackType: .dataPlayedBack) { _ in cont.resume() }
            }
        }
        return true
    }

    /// Core Audio restarted (the virtual mic install): device IDs changed, rebuild the output.
    func resetOutput() {
        player.stop()
        out.stop()
        outFormat = nil
        outDeviceUID = nil
    }

    private func configureOutput(format: AVAudioFormat, device: AudioDevice?) {
        let uid = device?.uid ?? ""
        guard outFormat != format || outDeviceUID != uid else { return }
        player.stop()
        out.stop()
        if let device, let unit = out.outputNode.audioUnit {
            var id = device.id
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                UInt32(MemoryLayout<AudioObjectID>.size))
        }
        out.disconnectNodeOutput(player)
        out.connect(player, to: out.mainMixerNode, format: format)
        outFormat = format
        outDeviceUID = uid
    }
}

#if compiler(>=6.2)
  /// One press = one recognizer over a finite stream. Finishing the stream and awaiting
  /// `finalizeAndFinishThroughEndOfInput` guarantees every word said during the press is in the
  /// result before it is translated.
  @available(macOS 26.0, *)
  final class PressRecognizer: @unchecked Sendable {
    private let locale: String
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private let converter = PCMBufferConverter()
    private var task: Task<String, Never>?
    private var finals: [String] = []
    private var volatile = ""
    /// The words so far, on the main actor.
    var onText: (@MainActor (String) -> Void)?

    init(locale: String) {
      self.locale = locale
    }

    func begin() {
      let transcriber = SpeechTranscriber(
        locale: Locale(identifier: locale), transcriptionOptions: [],
        reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
      let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
      lock.lock()
      continuation = cont
      lock.unlock()
      task = Task { [weak self] () -> String in
        guard await AssetInventory.status(forModules: [transcriber]) == .installed,
          let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { return "" }
        self?.setFormat(format)
        let collector = Task { [weak self] in
          do {
            for try await r in transcriber.results { self?.handle(r) }
          } catch {}
        }
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber])
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await collector.value
        return self?.text ?? ""
      }
    }

    private func setFormat(_ format: AVAudioFormat) {
      lock.lock()
      self.format = format
      lock.unlock()
    }

    /// From the microphone's queue.
    func feed(_ buffer: AVAudioPCMBuffer) {
      lock.lock()
      let format = self.format
      let continuation = self.continuation
      lock.unlock()
      // Words said before the model's format was known are still in the press audio for Ming
      // and the cloud; the live text just starts a moment later.
      guard let format, let continuation, let converted = converter.convert(buffer, to: format) else { return }
      continuation.yield(AnalyzerInput(buffer: converted))
    }

    private func handle(_ r: SpeechTranscriber.Result) {
      let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
      lock.lock()
      if r.isFinal {
        if !text.isEmpty { finals.append(text) }
        volatile = ""
      } else {
        volatile = text
      }
      lock.unlock()
      let now = self.text
      let callback = onText
      Task { @MainActor in callback?(now) }
    }

    private var text: String {
      lock.lock()
      defer { lock.unlock() }
      let joiner = MeetingLanguages.isCJK(locale) ? "" : " "
      return (finals + [volatile]).filter { !$0.isEmpty }.joined(separator: joiner)
    }

    func finish() async -> String {
      lock.lock()
      let continuation = self.continuation
      self.continuation = nil
      lock.unlock()
      continuation?.finish()
      return await task?.value ?? ""
    }

    func cancel() {
      lock.lock()
      let continuation = self.continuation
      self.continuation = nil
      lock.unlock()
      continuation?.finish()
      task?.cancel()
    }
  }
#endif
