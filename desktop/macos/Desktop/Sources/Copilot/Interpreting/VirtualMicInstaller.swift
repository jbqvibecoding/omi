import AVFoundation
import AppKit
import CoreAudio
import CryptoKit
import Foundation

#if compiler(>=6.2)
  import Speech
#endif

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — VirtualMicInstaller, LoopbackTest
// and LoopbackRecorder in Sources/LiveSubs/VirtualMic.swift. See ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: omi's wording and logging; the test phrase is played by omi's interpreter output; the
// transcript of the test only on macOS 26 (on older systems a heard signal is the pass).

/// Sets up the BlackHole 2ch virtual microphone without the Terminal, in three steps shown as a
/// checklist: install → let the system load it → sound test.
///
/// Install: download the official, Apple-notarized package, verify its SHA-256, run it through
/// the standard administrator prompt. (Downloaded, not bundled: BlackHole is GPL, and omi does not
/// redistribute it.) Core Audio doesn't load a new HAL plug-in until `coreaudiod` restarts, so the
/// same prompt restarts it — which cuts all sound for about a second, so not in the middle of a call.
///
/// Test: speak a phrase into the virtual mic and listen back from its input side, so we know the
/// whole path the meeting app will use works — not just that a device with the name exists.
@MainActor
final class VirtualMicInstaller: ObservableObject {
    static let shared = VirtualMicInstaller()

    enum State: Equatable {
        case idle
        case downloading
        case installing
        case reloading
        case testing
        case failed(String)
    }

    struct TestResult: Equatable {
        var heard: Bool
        var text: String
        var levels: [Float]
        /// Why nothing was heard, shown instead of the generic line.
        var problem: String? = nil
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var test: TestResult?
    /// Bumped after Core Audio restarts so views re-read the device list.
    @Published private(set) var generation = 0

    static let packageURL = URL(string: "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg")!
    static let packageSHA256 = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf"
    static let driverPath = "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"
    static let testPhrase = "Hi, can you hear me?"

    private init() {}

    var device: AudioDevice? { AudioDevices.virtualMic }
    var isLoaded: Bool { device != nil }
    /// Installed on disk; may not be loaded until Core Audio restarts.
    var isOnDisk: Bool { FileManager.default.fileExists(atPath: Self.driverPath) }
    var busy: Bool { [.downloading, .installing, .reloading, .testing].contains(state) }
    var passed: Bool { test?.heard == true }

    /// The next thing to do, whatever state the Mac is in.
    func next() {
        if !isOnDisk && !isLoaded {
            install()
        } else if !isLoaded {
            reload()
        } else {
            runTest()
        }
    }

    func install() {
        guard !busy else { return }
        Task {
            guard let pkg = await download() else { return }
            state = .installing
            try? await Task.sleep(nanoseconds: 200_000_000)  // let "Installing" show before the dialog
            let cmd = "/usr/sbin/installer -pkg " + shellQuote(pkg.path) + " -target / && " + Self.restartAudio
            guard runPrivileged(cmd, prompt: "omi wants to install a virtual microphone so people in your meetings hear your translated voice.") else { return }
            state = .reloading
            await waitForDevice()
        }
    }

    /// The driver is on disk but Core Audio hasn't loaded it: restart Core Audio only.
    func reload() {
        guard !busy else { return }
        Task {
            state = .reloading
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard runPrivileged(Self.restartAudio, prompt: "omi needs to restart the system's audio so it sees the virtual microphone. Sound stops for about a second.") else { return }
            await waitForDevice()
        }
    }

    func runTest() {
        guard !busy, let device else { return }
        Task {
            state = .testing
            // Reading the virtual mic's input side is microphone access like any other.
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                test = .init(heard: false, text: "", levels: [], problem: "The sound test needs microphone access for omi.")
                state = .idle
                return
            }
            test = await LoopbackTest.run(device: device, phrase: Self.testPhrase) {
                await InterpretEngine.shared.speak(Self.testPhrase, language: "en", to: device)
            }
            log("VirtualMic: test heard=\(test?.heard ?? false) text=\(test?.text ?? "")")
            state = .idle
        }
    }

    // MARK: Steps

    // `launchctl kickstart` is the supported restart; killall is the fallback (launchd relaunches it).
    private static let restartAudio =
        "/bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod"

    private func download() async -> URL? {
        state = .downloading
        do {
            let (tmp, response) = try await URLSession.shared.download(from: Self.packageURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                state = .failed("Download failed — check your connection.")
                return nil
            }
            let digest = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
            guard digest == Self.packageSHA256 else {
                log("VirtualMic: checksum mismatch \(digest)")
                state = .failed("The package didn't match its checksum, so it wasn't installed.")
                return nil
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omi-virtual-mic", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pkg = dir.appendingPathComponent("BlackHole2ch.pkg")
            try? FileManager.default.removeItem(at: pkg)
            try FileManager.default.moveItem(at: tmp, to: pkg)
            log("VirtualMic: downloaded and verified \(pkg.path)")
            return pkg
        } catch {
            log("VirtualMic: download error \(error.localizedDescription)")
            state = .failed("Download failed — check your connection.")
            return nil
        }
    }

    /// Runs a shell command through the standard administrator prompt. Cancel goes back to idle.
    private func runPrivileged(_ command: String, prompt: String) -> Bool {
        let script = "do shell script \(appleQuote(command)) with prompt \(appleQuote(prompt)) with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return true }
        let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        log("VirtualMic: privileged command error \(code)")
        state = code == -128 ? .idle : .failed("The install didn't finish — try again.")
        return false
    }

    private func waitForDevice() async {
        for _ in 0..<30 where !isLoaded {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        generation += 1
        guard isLoaded else {
            state = .failed(isOnDisk ? "The system hasn't picked it up yet — restart audio and try again." : "The install didn't finish — try again.")
            return
        }
        log("VirtualMic: loaded")
        state = .idle
        InterpretEngine.shared.resetOutput()
        InterpreterController.shared.virtualMicLoaded()
        // Core Audio just restarted; give it a moment before the test.
        try? await Task.sleep(nanoseconds: 800_000_000)
        runTest()
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func appleQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - Loopback test

/// Records the virtual mic's input side while a phrase is played into its output side, then
/// (on macOS 26) transcribes the recording. Hearing the phrase back proves the room will hear us.
enum LoopbackTest {
    @MainActor
    static func run(device: AudioDevice, phrase: String, play: @escaping () async -> Void) async
        -> VirtualMicInstaller.TestResult
    {
        let recorder = LoopbackRecorder()
        guard recorder.start(deviceID: device.id) else {
            return .init(
                heard: false, text: "", levels: [],
                problem: "The virtual microphone wouldn't open — restart audio, then test again.")
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        await play()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let buffers = recorder.stop()
        let levels = LoopbackRecorder.levels(buffers, bars: 12)
        let loud = (levels.max() ?? 0) > 0.02
        let text = loud ? await transcribe(buffers, locale: "en-US") : ""
        // Any real signal counts; the transcript is shown so people can judge it themselves.
        return .init(
            heard: loud, text: text, levels: levels,
            problem: loud ? nil : buffers.isEmpty ? "The virtual microphone didn't receive any sound — try again." : nil)
    }

    static func transcribe(_ buffers: [AVAudioPCMBuffer], locale: String) async -> String {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let t = SpeechTranscriber(
                    locale: Locale(identifier: locale), transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                guard await AssetInventory.status(forModules: [t]) == .installed,
                    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
                else { return "" }
                let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
                let conv = PCMBufferConverter()
                for b in buffers {
                    if let c = conv.convert(b, to: format) { cont.yield(AnalyzerInput(buffer: c)) }
                }
                cont.finish()
                let collector = Task { () -> String in
                    var parts: [String] = []
                    do {
                        for try await r in t.results where r.isFinal {
                            parts.append(String(r.text.characters).trimmingCharacters(in: .whitespaces))
                        }
                    } catch {}
                    return parts.joined(separator: " ")
                }
                let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [t])
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                return await collector.value
            }
        #endif
        return ""
    }
}

/// Records one device's input side with a plain Core Audio IO proc. (An AVAudioEngine input node
/// switched to another device keeps the default mic's format and can stop itself on the format
/// change, which made the test flaky.)
final class LoopbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var device = AudioObjectID(0)
    private var proc: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 48_000
    private let queue = DispatchQueue(label: "com.omi.loopback-test")

    func start(deviceID: AudioObjectID) -> Bool {
        device = deviceID
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr, rate > 0 { sampleRate = rate }
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, let data = first.mData else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / channels
            let p = data.assumingMemoryBound(to: Float.self)
            self.lock.lock()
            for i in 0..<frames { self.samples.append(p[i * channels]) }  // first channel is enough
            self.lock.unlock()
        }
        guard status == noErr, let proc else {
            log("VirtualMic: loopback io proc failed \(status)")
            return false
        }
        return AudioDeviceStart(deviceID, proc) == noErr
    }

    func stop() -> [AVAudioPCMBuffer] {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        proc = nil
        lock.lock()
        let all = samples
        lock.unlock()
        guard !all.isEmpty,
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(all.count))
        else { return [] }
        buf.frameLength = AVAudioFrameCount(all.count)
        all.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: all.count) }
        return [buf]
    }

    /// Peak level per slice of the recording, 0…1, for the little bar graph.
    static func levels(_ buffers: [AVAudioPCMBuffer], bars: Int) -> [Float] {
        var samples: [Float] = []
        for b in buffers {
            guard let ch = b.floatChannelData?[0] else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(b.frameLength)))
        }
        guard !samples.isEmpty else { return [] }
        let slice = max(1, samples.count / bars)
        return stride(from: 0, to: samples.count, by: slice).prefix(bars).map { start in
            let end = min(samples.count, start + slice)
            return min(1, samples[start..<end].reduce(0) { max($0, abs($1)) })
        }
    }
}
