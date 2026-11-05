import AppKit
import Foundation

#if compiler(>=6.2)
  import Speech
#endif

/// The interpreter's talk key: hold **right** ⌥ alone, speak, let go.
///
/// Push-to-talk's default is "hold ⌥", either side. While interpretation is on, the two sides
/// split: right ⌥ talks to the meeting (through the interpreter), left ⌥ still asks omi. macOS
/// reports which physical key it was in the event's device-dependent flag bits, so this needs no
/// Input Monitoring permission — only the Accessibility access push-to-talk already has.
///
/// Holding right ⌥ and pressing another key (typing ⌥-characters, a ⌥-shortcut) is a chord, not a
/// sentence: the press is dropped and nothing is sent (Cicada's `pressCancelled`).
@MainActor
final class InterpretKeyMonitor {
    static let shared = InterpretKeyMonitor()

    /// NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK.
    nonisolated static let leftOptionBit: UInt = 0x20
    nonisolated static let rightOptionBit: UInt = 0x40

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var holding = false

    private init() {}

    var isRunning: Bool { globalMonitor != nil }

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { event in
            Task { @MainActor in InterpretKeyMonitor.shared.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            Task { @MainActor in InterpretKeyMonitor.shared.handle(event) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if holding {
            holding = false
            InterpretEngine.shared.pressCancelled()
        }
    }

    /// Exactly the right ⌥ held, nothing else.
    nonisolated static func isRightOptionAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        return flags.intersection(.deviceIndependentFlagsMask) == [.option]
            && raw & rightOptionBit != 0 && raw & leftOptionBit == 0
    }

    /// Whether a ⌥-only push-to-talk press belongs to the interpreter instead (right ⌥ while
    /// interpretation is on), so push-to-talk leaves it alone.
    nonisolated static func claims(_ flags: NSEvent.ModifierFlags, interpreterOn: Bool) -> Bool {
        interpreterOn && isRightOptionAlone(flags)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let alone = Self.isRightOptionAlone(event.modifierFlags)
            if !holding, alone {
                holding = true
                InterpretEngine.shared.pressBegan()
            } else if holding, !alone {
                holding = false
                // Let go cleanly → send; another modifier joined → a chord, drop it.
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    InterpretEngine.shared.pressEnded()
                } else {
                    InterpretEngine.shared.pressCancelled()
                }
            }
        case .keyDown:
            if holding {
                holding = false
                InterpretEngine.shared.pressCancelled()
            }
        default:
            break
        }
    }
}

/// Turns interpretation on and off as a whole: the talk key, the system microphone switch, and
/// undoing a switch an earlier run left behind.
@MainActor
final class InterpreterController: ObservableObject {
    static let shared = InterpreterController()

    @Published private(set) var systemMicState: SystemMic.State = .off

    private var refreshTimer: Timer?

    private init() {}

    var enabled: Bool { CopilotSettings.shared.interpreterEnabled }

    /// At launch: pick up where the setting left off, or undo a switch from a crash.
    func appDidLaunch() {
        if enabled {
            activate()
        } else {
            SystemMic.shared.restoreAfterCrashIfNeeded()
        }
    }

    /// Quitting: give the system its microphone back.
    func appWillTerminate() {
        if enabled { SystemMic.shared.release() }
    }

    func setEnabled(_ on: Bool) {
        CopilotSettings.shared.interpreterEnabled = on
        if on { activate() } else { deactivate() }
    }

    private func activate() {
        InterpretKeyMonitor.shared.start()
        // Only once the virtual mic exists: switching the default to nothing would do nothing.
        if VirtualMicInstaller.shared.isLoaded { SystemMic.shared.engage() }
        systemMicState = SystemMic.shared.refresh(wanted: true)
        prepareRecognizer()
        refreshTimer?.invalidate()
        // AirPods connecting, or the user, can move the system microphone; say so.
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                let controller = InterpreterController.shared
                controller.systemMicState = SystemMic.shared.refresh(wanted: controller.enabled)
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        log("Interpreter: on")
    }

    private func deactivate() {
        InterpretKeyMonitor.shared.stop()
        SystemMic.shared.release()
        systemMicState = .off
        refreshTimer?.invalidate()
        refreshTimer = nil
        log("Interpreter: off")
    }

    /// The virtual mic just appeared (installed, or Core Audio restarted).
    func virtualMicLoaded() {
        guard enabled else { return }
        SystemMic.shared.engage()
        systemMicState = SystemMic.shared.refresh(wanted: true)
    }

    /// macOS 26: make sure the recognizer for the user's language is on this Mac, so the press
    /// shows words as they are said and doesn't need the cloud to be understood.
    private func prepareRecognizer() {
        #if compiler(>=6.2)
            if #available(macOS 26.0, *), TranscriberRouting.appleSpeechAvailable {
                let locale = TranscriberRouting.speechLocale(for: InterpretEngine.shared.sourceCode)
                Task.detached(priority: .utility) {
                    let transcriber = SpeechTranscriber(
                        locale: Locale(identifier: locale), transcriptionOptions: [], reportingOptions: [],
                        attributeOptions: [])
                    guard await AssetInventory.status(forModules: [transcriber]) != .installed,
                        let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
                    else { return }
                    try? await request.downloadAndInstall()
                }
            }
        #endif
    }

    // MARK: Debug (omi-ctl)

    func debugDump() -> [String: String] {
        let engine = InterpretEngine.shared
        return [
            "enabled": enabled ? "true" : "false",
            "key_monitor": InterpretKeyMonitor.shared.isRunning ? "on" : "off",
            "virtual_mic": VirtualMicInstaller.shared.isLoaded ? "loaded" : (VirtualMicInstaller.shared.isOnDisk ? "on disk, not loaded" : "not installed"),
            "system_mic": "\(SystemMic.shared.refresh(wanted: enabled))",
            "default_input": AudioDevices.defaultInput?.name ?? "-",
            "records_from": SystemMic.shared.recordingDevice(chosen: CopilotSettings.shared.interpreterMicUID)?.name ?? "-",
            "speaks_into": engine.outputDevice()?.name ?? "-",
            "from": engine.sourceCode,
            "to": engine.targetCode,
            "ling_key": LingClient.shared.hasKey ? "\(LingClient.shared.keyState)" : "none",
            "voice_sample": VoiceSample.exists ? String(format: "%.0fs", VoiceSample.duration) : "none",
            "phase": "\(engine.phase)",
            "last_heard": engine.lastHeard,
            "last_spoken": engine.lastSpoken,
            "last_voice": engine.lastVoice,
            "last_failure": engine.lastFailure ?? "-",
        ]
    }
}
