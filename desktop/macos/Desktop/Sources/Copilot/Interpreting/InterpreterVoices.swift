import AVFoundation
import Foundation

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — VoiceOption, VoiceCatalog,
// VoiceReference and VoiceRecorder in Sources/LiveSubs/Voices.swift. See
// ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: an "omi voice" tier (the app's existing speech service) between Ming's voices and the
// Mac's own, so interpretation sounds natural without a Ling key; English labels; the sample is
// stored in omi's Application Support folder; on macOS before 26 the sample is transcribed with
// omi's own transcription service.

/// A voice the room can hear.
struct InterpreterVoice: Identifiable, Equatable {
    enum Kind: Equatable {
        /// One of Ming's voices (needs a Ling key).
        case ming(String)
        /// The user's own voice, cloned by Ming from their sample (needs a Ling key and a sample).
        case clone
        /// omi's speech service (no key needed).
        case omi(String)
        /// A voice installed on this Mac (works offline).
        case system(String)
    }
    /// Stored in settings: "ming:US_Emma", "clone", "omi:marin", "system:<identifier>".
    let id: String
    let name: String
    let detail: String
    let kind: Kind

    var needsLingKey: Bool {
        switch kind {
        case .ming, .clone: return true
        case .omi, .system: return false
        }
    }
}

enum InterpreterVoices {
    static func key(for code: String) -> String { MeetingLanguages.base(code) }

    /// Ming's `language_id` for languages that need it (zh and en work without).
    static func mingLanguage(for code: String) -> String? {
        let k = key(for: code)
        return ["ja", "ko", "de", "fr", "es"].contains(k) ? k : nil
    }

    /// Ming's hand-picked natural voices; for languages it has no native voice for, Emma and George
    /// speak it with `language_id`.
    static func ming(for language: String) -> [InterpreterVoice] {
        func v(_ voice: String, _ name: String, _ detail: String) -> InterpreterVoice {
            InterpreterVoice(id: "ming:\(voice)", name: name, detail: detail, kind: .ming(voice))
        }
        switch key(for: language) {
        case "en":
            return [v("US_Emma", "Emma", "female · American"), v("UK_George", "George", "male · British"),
                    v("UK_Charlotte", "Charlotte", "female · British")]
        case "zh":
            return [v("灵小雅", "小雅", "female · clear"), v("灵小棠", "小棠", "female · calm"),
                    v("灵小锋", "小锋", "male · warm"), v("灵卓然", "卓然", "male · steady")]
        case "ja", "ko", "de", "fr", "es":
            return [v("US_Emma", "Emma", "female"), v("UK_George", "George", "male")]
        default:
            return []
        }
    }

    /// omi's own speech service: one natural voice that speaks every language.
    static let omiVoice = InterpreterVoice(id: "omi:marin", name: "omi", detail: "natural · any language", kind: .omi("marin"))

    /// The Mac's best installed female and male voice for the language (no novelty voices).
    static func system(for language: String) -> [InterpreterVoice] {
        let k = key(for: language)
        let prefix = language.hasPrefix("zh-TW") ? "zh-TW" : k == "zh" ? "zh-CN" : k
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice)
                && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        var out: [InterpreterVoice] = []
        for gender in [AVSpeechSynthesisVoiceGender.female, .male] {
            guard let best = all.filter({ $0.gender == gender }).max(by: { $0.quality.rawValue < $1.quality.rawValue })
            else { continue }
            let quality = best.quality == .premium ? "premium" : best.quality == .enhanced ? "enhanced" : "standard"
            out.append(
                InterpreterVoice(
                    id: "system:\(best.identifier)", name: best.name,
                    detail: "\(gender == .female ? "female" : "male") · this Mac · \(quality)", kind: .system(best.identifier)))
        }
        return out
    }

    static let cloneVoice = InterpreterVoice(id: "clone", name: "My own voice", detail: "cloned from your sample", kind: .clone)

    /// Everything that can speak `language`, best first.
    static func options(for language: String, hasLingKey: Bool) -> [InterpreterVoice] {
        var out: [InterpreterVoice] = []
        if hasLingKey {
            if VoiceSample.exists { out.append(cloneVoice) }
            out += ming(for: language)
        }
        out.append(omiVoice)
        out += system(for: language)
        return out
    }

    /// What a language uses until the user picks: their own voice when there is a sample and a
    /// key, else Ming's first voice, else omi's.
    static func defaultVoice(for language: String, hasLingKey: Bool) -> InterpreterVoice {
        options(for: language, hasLingKey: hasLingKey).first ?? omiVoice
    }

    static func voice(id: String, for language: String, hasLingKey: Bool) -> InterpreterVoice {
        options(for: language, hasLingKey: hasLingKey).first { $0.id == id }
            ?? defaultVoice(for: language, hasLingKey: hasLingKey)
    }

    /// A short line to try a voice with, in the language it will speak.
    static func sample(for language: String) -> String {
        switch key(for: language) {
        case "zh": return "谢谢大家。我们来看一下上线时间表，并确定谁负责麦克风测试。"
        case "ja": return "皆さん、ありがとうございます。発売スケジュールを確認しましょう。"
        case "ko": return "감사합니다. 출시 일정을 함께 확인해 보겠습니다."
        case "es": return "Gracias a todos. Revisemos el calendario de lanzamiento."
        case "fr": return "Merci à tous. Regardons ensemble le calendrier de lancement."
        case "de": return "Danke an alle. Schauen wir uns den Zeitplan für den Start an."
        case "pt": return "Obrigado a todos. Vamos ver o cronograma de lançamento."
        default: return "Thanks everyone. Let's look at the launch timeline and decide who owns the microphone tests."
        }
    }
}

// MARK: - The user's own voice

/// The recording Ming clones the user's voice from: `voice/sample.wav` (16 kHz mono, ≤ 30 s) and
/// `voice/sample.txt` (what it says). Stays on this Mac except inside a speech request to Ling;
/// Ming clones zero-shot from it each time and keeps no voiceprint.
enum VoiceSample {
    static var folder: URL {
        DesktopLocalProfile.applicationSupportURL()
            .appendingPathComponent("interpreter", isDirectory: true)
            .appendingPathComponent("voice", isDirectory: true)
    }
    static var audioURL: URL { folder.appendingPathComponent("sample.wav") }
    static var textURL: URL { folder.appendingPathComponent("sample.txt") }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: audioURL.path) && !(text ?? "").isEmpty
    }
    static var text: String? { try? String(contentsOf: textURL, encoding: .utf8) }

    static var duration: Double {
        guard let f = try? AVAudioFile(forReading: audioURL) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// What Ming needs: the clip as a data URI and its transcript.
    static func reference() -> (audio: String, text: String)? {
        guard let data = try? Data(contentsOf: audioURL), let text, !text.isEmpty else { return nil }
        return ("data:audio/wav;base64," + data.base64EncodedString(), text)
    }

    static func save(wav: URL, text: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        if fm.fileExists(atPath: audioURL.path) { try fm.removeItem(at: audioURL) }
        try fm.copyItem(at: wav, to: audioURL)
        try Data(text.utf8).write(to: textURL)
        for url in [audioURL, textURL] {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var u = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? u.setResourceValues(values)
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The passage to read, in the user's own language.
    static func passage(for language: String) -> String {
        switch MeetingLanguages.base(language) {
        case "zh":
            return "大家好，我是这次会议的主持人。今天我们主要讨论新产品的上线计划，包括时间安排、测试范围和市场推广。请大家先看一下屏幕上的议程。"
        case "ja":
            return "皆さん、こんにちは。今日の会議では、新製品の発売計画について話し合います。スケジュール、テストの範囲、そしてマーケティングについて順番に確認しましょう。"
        default:
            return "Hello everyone, thanks for joining. Today we'll walk through the launch plan for the new product: the schedule, what we still need to test, and how we'll tell people about it. Let's start with the agenda on the screen."
        }
    }
}

/// Records the microphone for the voice sample: 16 kHz mono into a temporary WAV, with a level for
/// the meter. Stops by itself at 30 s.
@MainActor
final class VoiceSampleRecorder: ObservableObject {
    enum Phase: Equatable { case idle, recording, checking, ready, failed(String) }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    /// What the recording says, used as the clone's reference text.
    @Published private(set) var transcript = ""

    static let maxSeconds = 30.0
    static let minSeconds = 8.0

    private let engine = AVAudioEngine()
    private nonisolated(unsafe) var file: AVAudioFile?
    private nonisolated(unsafe) var converter: AVAudioConverter?
    private var timer: Timer?
    private var started = Date()
    private(set) var url = FileManager.default.temporaryDirectory.appendingPathComponent("omi-voice-\(UUID().uuidString).wav")
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var language = "en"

    /// `device`: the real mic; the system default may be the virtual mic while interpreting.
    func start(language: String, device: AudioDevice?) {
        stopEngine()
        self.language = language
        transcript = ""
        try? FileManager.default.removeItem(at: url)
        let input = engine.inputNode
        AudioDevices.pinInput(engine, to: device)
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
            let f = try? AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true),
            let conv = AVAudioConverter(from: inFormat, to: format)
        else {
            phase = .failed("The microphone isn't giving any sound — check omi's microphone access.")
            return
        }
        file = f
        converter = conv
        let outFormat = format
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let conv = self.converter, let file = self.file else { return }
            let ratio = outFormat.sampleRate / buffer.format.sampleRate
            guard
                let out = AVAudioPCMBuffer(
                    pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32)
            else { return }
            var fed = false
            conv.convert(to: out, error: nil) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            try? file.write(from: out)
            var peak: Float = 0
            if let ch = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[i])) }
            }
            Task { @MainActor in self.level = min(1, peak * 2.5) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            phase = .failed("The microphone wouldn't open: \(error.localizedDescription)")
            return
        }
        started = Date()
        seconds = 0
        phase = .recording
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.seconds = Date().timeIntervalSince(self.started)
                if self.seconds >= Self.maxSeconds { self.finish() }
            }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// Stops recording and transcribes it; `ready` when it is long enough and recognisable.
    func finish() {
        guard phase == .recording else { return }
        stopEngine()
        guard seconds >= Self.minSeconds else {
            phase = .failed("Too short — read for at least \(Int(Self.minSeconds)) seconds.")
            return
        }
        phase = .checking
        let url = url
        let language = language
        Task {
            let text = await Self.transcribe(url, language: language)
            self.transcript = text
            self.phase = text.count >= 6 ? .ready : .failed("Couldn't make out the recording — try again somewhere quieter.")
        }
    }

    /// Keeps the recording as the voice sample.
    func keep() -> Bool {
        guard phase == .ready else { return false }
        do {
            try VoiceSample.save(wav: url, text: transcript)
            try? FileManager.default.removeItem(at: url)
            phase = .idle
            return true
        } catch {
            phase = .failed("Couldn't save the sample: \(error.localizedDescription)")
            return false
        }
    }

    func cancel() {
        stopEngine()
        phase = .idle
        try? FileManager.default.removeItem(at: url)
    }

    private func stopEngine() {
        timer?.invalidate()
        timer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        converter = nil
        level = 0
    }

    private static func transcribe(_ url: URL, language: String) async -> String {
        // macOS 26: on this Mac.
        if let f = try? AVAudioFile(forReading: url),
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
            (try? f.read(into: buf)) != nil
        {
            let onDevice = await LoopbackTest.transcribe([buf], locale: TranscriberRouting.speechLocale(for: language))
            if !onDevice.isEmpty { return onDevice }
        }
        // Before macOS 26 (or without the model): omi's own transcription, from the raw samples.
        guard let f = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true),
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
            (try? f.read(into: buf)) != nil,
            let samples = buf.int16ChannelData?[0]
        else { return "" }
        let data = Data(bytes: samples, count: Int(buf.frameLength) * 2)
        let text = try? await TranscriptionService.batchTranscribe(
            audioData: data, language: MeetingLanguages.base(language))
        // `try?` flattens the optional result: nil for an error and for no transcript alike.
        return text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
