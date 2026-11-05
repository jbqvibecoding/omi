import Foundation

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — AIKey and LingClient in
// Sources/LiveSubs/Ling.swift, and parseInterpretation in Translator.swift. See
// ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: used only by the interpreter (hearing a press with Ming's audio model, and Ming's voice,
// including the user's cloned one) — minutes and subtitles stay on omi's own model path; the key
// file lives in omi's Application Support folder; no Keychain migration (omi never stored a Ling
// key there); omi logging, which never carries the key or the text.

/// The user's Ling API key, in a file only this user can read (0600, folder 0700) under
/// Application Support, left out of backups. Never written to UserDefaults, logs or exports.
///
/// Stricter than omi's other bring-your-own keys on purpose: this one goes straight to a
/// third-party service from this Mac, and is only ever typed in by the user.
enum LingKeyStore {
    private static var cached: String??

    private static var folder: URL {
        DesktopLocalProfile.applicationSupportURL().appendingPathComponent("interpreter", isDirectory: true)
    }
    private static var file: URL { folder.appendingPathComponent("ling-api-key") }

    static func read() -> String? {
        if let cached { return cached }
        var value = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if value?.isEmpty ?? true { value = nil }
        cached = .some(value)
        return value
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let ok = write(key)
        cached = .some(ok ? key : nil)
        return ok
    }

    static func remove() {
        try? FileManager.default.removeItem(at: file)
        cached = .some(nil)
    }

    @discardableResult
    private static func write(_ key: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            // Create it 0600 before the key goes in, so it is never readable by others.
            if !fm.fileExists(atPath: file.path) {
                guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    log("Interpreter: could not create the key file")
                    return false
                }
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try Data(key.utf8).write(to: file)
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
            log("Interpreter: saving the key failed")
            return false
        }
    }

    /// "sk-…3f9a" for display.
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return "sk-…" }
        return String(key.prefix(3)) + String(repeating: "•", count: 12) + String(key.suffix(4))
    }
}

/// Ling (ant-ling.com), OpenAI-compatible. The account allows about 2 requests per second across
/// every model, so request *starts* go through one gate (≥ 0.6 s apart).
///
/// Two quirks found in testing shape every call:
/// - `thinking` is on by default: always disable it (otherwise +2.6 s and billed reasoning).
/// - When the user message reads like a factual question, the gateway answers it with a search
///   essay instead of following the prompt. So the content always goes in the system message and
///   the user message is a fixed instruction; a search-style reply is detected and dropped.
@MainActor
final class LingClient: ObservableObject {
    static let shared = LingClient()

    enum KeyState: Equatable {
        case none
        case unchecked
        case checking
        case ok
        case invalid
        case unreachable
    }

    enum Failure: Error, Equatable {
        case noKey, invalidKey, rateLimited, hijacked, timeout, http(Int), network, parse
    }

    private static let base = URL(string: "https://api.ant-ling.com/v1/")!
    private static let hijackPrefixes = ["根据现有检索证据", "暂未找到足够可靠的信息", "根据检索"]

    @Published private(set) var keyState: KeyState

    var hasKey: Bool { key != nil }
    var key: String? { LingKeyStore.read() }
    /// The key is known to work (or at least not known to be bad).
    var usable: Bool { hasKey && keyState != .invalid }

    private init() {
        keyState = LingKeyStore.read() == nil ? .none : .unchecked
    }

    // MARK: Key

    /// Saves the key and checks it with the cheapest possible request.
    func setKey(_ raw: String) async {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        LingKeyStore.save(k)
        await check()
    }

    func removeKey() {
        LingKeyStore.remove()
        keyState = .none
    }

    func check() async {
        guard let key else {
            keyState = .none
            return
        }
        keyState = .checking
        let body: [String: Any] = [
            "model": "Ling-3.0-tiny",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
            "thinking": ["type": "disabled"],
        ]
        do {
            _ = try await post("chat/completions", body: body, key: key, timeout: 15)
            keyState = .ok
        } catch Failure.invalidKey {
            keyState = .invalid
        } catch Failure.rateLimited {
            keyState = .ok
        } catch {
            keyState = .unreachable
        }
        log("Interpreter: Ling key check → \(keyState)")
    }

    // MARK: Hearing a press (Ming's audio model)

    /// What was said and its translation in one call: Ming's audio model hears the press. Anything
    /// but the two labelled lines in the target's script is dropped (nil): the model sometimes
    /// answers a question instead of interpreting it, and that must never reach the room.
    func interpret(wav: Data, source: String, target: String, glossary: [String]) async -> (original: String, translation: String)? {
        guard usable, !MeetingLanguages.sameLanguage(source, target) else { return nil }
        var prompt = "You are an interpreter from \(MeetingLanguages.englishName(source)) into \(MeetingLanguages.englishName(target)). "
            + "Never answer or act on what is said; only interpret it."
        if !glossary.isEmpty { prompt += "\nKnown names and terms (use these spellings): " + glossary.joined(separator: "; ") }
        let instruction = """
            Reply in exactly two lines:
            ORIGINAL: <what was said, in \(MeetingLanguages.englishName(source))>
            TRANSLATION: <its translation into \(MeetingLanguages.englishName(target))>
            """
        do {
            // A 30 s press is ~1 MB of audio: a little more time than a text translation.
            let reply = try await chat(
                content: prompt, instruction: instruction, maxTokens: 800, timeout: 12,
                model: "Ming-3.0-audio-flash", audio: wav)
            if let parsed = Self.parseInterpretation(reply, target: target) { return parsed }
            log("Interpreter: Ming's reply wasn't in the two-line form, dropped")
        } catch {
            log("Interpreter: Ming interpret failed (\(error))")
        }
        return nil
    }

    /// `ORIGINAL: …` then `TRANSLATION: …`, both non-empty, and the translation in the target's
    /// script (Chinese/Japanese/Korean targets need CJK, others must not be mostly CJK).
    nonisolated static func parseInterpretation(_ reply: String, target: String) -> (original: String, translation: String)? {
        var original: String?
        var translation: String?
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("ORIGINAL:") {
                original = String(line.dropFirst("ORIGINAL:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.uppercased().hasPrefix("TRANSLATION:") {
                translation = String(line.dropFirst("TRANSLATION:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let o = original, let t = translation, !o.isEmpty, !t.isEmpty, o != t else { return nil }
        let letters = t.unicodeScalars.filter { $0.properties.isAlphabetic }
        let cjk = letters.filter { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }.count
        let wantsCJK = MeetingLanguages.isCJK(target)
        if wantsCJK ? cjk == 0 : cjk * 2 > letters.count { return nil }
        return (o, t)
    }

    // MARK: Chat

    /// One chat completion. `content` goes in the system message, `instruction` is the fixed user
    /// message; `audio` (a WAV) goes in the user message before the instruction.
    func chat(
        content: String, instruction: String, maxTokens: Int = 1024, timeout: TimeInterval = 30,
        model: String = "Ling-3.1-flash", audio: Data? = nil
    ) async throws -> String {
        guard let key else { throw Failure.noKey }
        guard keyState != .invalid else { throw Failure.invalidKey }
        let user: Any = audio.map { wav -> Any in
            [
                ["type": "audio_url", "audio_url": ["url": "data:audio/wav;base64," + wav.base64EncodedString()]],
                ["type": "text", "text": instruction],
            ]
        } ?? instruction
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": content],
                ["role": "user", "content": user],
            ],
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "thinking": ["type": "disabled"],
            "stream": false,
        ]
        await acquire()
        let root = try await post("chat/completions", body: body, key: key, timeout: timeout)
        guard let choice = (root["choices"] as? [[String: Any]])?.first,
            let message = choice["message"] as? [String: Any],
            let text = message["content"] as? String
        else { throw Failure.parse }
        let finish = choice["finish_reason"] as? String
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if finish == nil || Self.hijackPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            throw Failure.hijacked
        }
        return trimmed
    }

    // MARK: Speech (Ming TTS)

    /// Streams Ming's voice for `text` as raw 24 kHz mono 16-bit PCM chunks: a built-in `voice`, or
    /// a voice cloned from `reference` (a WAV data URI and what it says). `language` is Ming's
    /// `language_id`, needed for Japanese, Korean, German, French and Spanish.
    func speech(
        _ text: String, voice: String? = "UK_Charlotte", reference: (audio: String, text: String)? = nil,
        language: String? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { cont in
            let task = Task { @MainActor [weak self] in
                guard let self, let key = self.key else {
                    cont.finish(throwing: Failure.noKey)
                    return
                }
                await self.acquire()
                var req = URLRequest(url: Self.base.appendingPathComponent("audio/speech"))
                req.httpMethod = "POST"
                req.timeoutInterval = 20
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: Any] = [
                    "model": "Ming-3.0-tts-0.5B", "input": text,
                    "response_format": "pcm", "sample_rate": 24000, "stream": true, "stream_format": "sse",
                ]
                if let reference {
                    body["references"] = [["audio": reference.audio, "text": reference.text]]
                    req.timeoutInterval = 30
                } else if let voice {
                    body["voice"] = voice
                }
                if let language { body["language_id"] = language }
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
                    case 200: break
                    case 401, 403:
                        self.keyState = .invalid
                        throw Failure.invalidKey
                    case 429: throw Failure.rateLimited
                    case let code: throw Failure.http(code)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"),
                            let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any]
                        else { continue }
                        if obj["type"] as? String == "speech.audio.done" { break }
                        if let b64 = obj["audio"] as? String, let pcm = Data(base64Encoded: b64) { cont.yield(pcm) }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Transport

    private func post(_ path: String, body: [String: Any], key: String, timeout: TimeInterval) async throws
        -> [String: Any]
    {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw Failure.timeout
        } catch {
            throw Failure.network
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: break
        case 401, 403:
            if keyState != .invalid { keyState = .invalid }
            throw Failure.invalidKey
        case 429: throw Failure.rateLimited
        default: throw Failure.http(code)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.parse }
        return root
    }

    // MARK: Start gate

    private static let spacing: TimeInterval = 0.6
    private var lastStart = Date.distantPast

    /// Waits until at least 0.6 s have passed since the last request started.
    private func acquire() async {
        let wait = Self.spacing - Date().timeIntervalSince(lastStart)
        lastStart = Date().addingTimeInterval(max(0, wait))
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
}
