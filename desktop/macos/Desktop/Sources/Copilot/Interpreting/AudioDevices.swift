import AVFoundation
import CoreAudio
import Foundation

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — OutputDevice and AudioDevices in
// Sources/LiveSubs/SpeakEngine.swift, and SystemMic.swift (the input helpers, SystemMicPlan and
// SystemMic). See ThirdPartyLicenses/cicada-LICENSE.txt.
// Changes: `OutputDevice` is `AudioDevice`; only BlackHole counts as the virtual mic (omi has no
// device of its own, and a user's own Loopback device is a real choice); the saved microphone
// lives under an omi key; a helper keeps omi's own capture off the virtual mic.

/// A Core Audio device with streams on the side it was listed for.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String

    /// The virtual microphone the interpreter speaks into.
    var isVirtualMic: Bool { name.lowercased().contains("blackhole") }
}

enum AudioDevices {
    static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value as String : nil
    }

    /// Devices with streams on one side (output or input), minus private aggregate devices
    /// (omi's own system-audio tap among them).
    static func devices(scope: AudioObjectPropertyScope) -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0,
                let uid = string(id, kAudioDevicePropertyDeviceUID),
                let name = string(id, kAudioObjectPropertyName),
                !name.hasPrefix("OMI System Audio")
            else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func outputs() -> [AudioDevice] { devices(scope: kAudioObjectPropertyScopeOutput) }
    static func inputs() -> [AudioDevice] { devices(scope: kAudioObjectPropertyScopeInput) }

    /// BlackHole's output side: where the interpreter speaks.
    static var virtualMic: AudioDevice? { outputs().first(where: \.isVirtualMic) }

    static func name(_ device: AudioObjectID) -> String? { string(device, kAudioObjectPropertyName) }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
        else { return nil }
        return id
    }

    /// The system output (speakers or headphones): voice previews play here, not into the room.
    static var defaultOutput: AudioDevice? {
        guard let id = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return outputs().first { $0.id == id }
    }

    static var defaultInput: AudioDevice? {
        guard let id = defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return inputs().first { $0.id == id }
    }

    @discardableResult
    static func setDefaultInput(_ device: AudioDevice) -> Bool {
        var id = device.id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
        if status != noErr { log("SystemMic: set default input \(device.name) failed \(status)") }
        return status == noErr
    }

    /// Points an engine's input at a device. Call while the engine is stopped and before reading
    /// the input format, which then follows the device. nil leaves it where it is.
    static func pinInput(_ engine: AVAudioEngine, to device: AudioDevice?) {
        guard let device, let unit = engine.inputNode.audioUnit else { return }
        var current = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
        guard current != device.id else { return }
        var id = device.id
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
            UInt32(MemoryLayout<AudioObjectID>.size))
    }

    /// The device omi's own microphone capture should use instead of `deviceID`.
    ///
    /// The interpreter makes BlackHole the system's default input so the meeting app hears the
    /// translation. omi's capture follows the default input — so without this it would start
    /// recording BlackHole: transcribing its own translated voice as "you", and dropping yours.
    /// Whoever moved the default there, omi keeps recording the real microphone.
    static func realInput(replacing deviceID: AudioObjectID) -> AudioObjectID {
        let all = inputs()
        guard let device = all.first(where: { $0.id == deviceID }), device.isVirtualMic else { return deviceID }
        let plan = all.map { SystemMicPlan.Device(uid: $0.uid, isVirtual: $0.isVirtualMic) }
        guard let uid = SystemMicPlan.original(saved: SystemMic.savedInputUID, current: nil, inputs: plan),
            let real = all.first(where: { $0.uid == uid })
        else { return deviceID }
        return real.id
    }
}

/// Which real microphone to come back to and which one the interpreter records from. Pure, so
/// it's tested. Devices are compared by UID: IDs change when Core Audio restarts (the BlackHole
/// install does).
enum SystemMicPlan {
    struct Device: Equatable {
        var uid: String
        var isVirtual: Bool
    }

    /// The microphone to put back when we let go of the system default. The one saved when we
    /// switched, while it's still plugged in; else the current default if it's real (the user
    /// already chose it); else the first real one. Never a virtual mic: putting BlackHole "back"
    /// would leave every other app deaf.
    static func original(saved: String, current: String?, inputs: [Device]) -> String? {
        let real = inputs.filter { !$0.isVirtual }
        if real.contains(where: { $0.uid == saved }) { return saved }
        if let current, real.contains(where: { $0.uid == current }) { return current }
        return real.first?.uid
    }

    /// What the interpreter records from: the one picked in settings, else the original. It must
    /// never follow the system default onto the virtual mic, or it would hear its own voice.
    static func recording(chosen: String, saved: String, current: String?, inputs: [Device]) -> String? {
        if inputs.contains(where: { $0.uid == chosen && !$0.isVirtual }) { return chosen }
        return original(saved: saved, current: current, inputs: inputs)
    }
}

/// Points the system default input at the virtual mic while interpretation is on, so a meeting in
/// a browser (and any app left on "default") hears the translation without being set up, and puts
/// it back when interpretation stops or omi quits. The device switched from is saved, so a crash
/// can be undone on the next launch.
@MainActor
final class SystemMic {
    static let shared = SystemMic()

    enum State: Equatable {
        /// Not switched, nothing to undo.
        case off
        /// The system mic is the virtual mic; `original` comes back when interpretation stops.
        case switched(original: String)
        /// Interpretation is off but the system mic is still the virtual mic (omi quit uncleanly).
        case notRestored(original: String)
        /// Interpretation is on but something else (AirPods, the user) moved the system mic away.
        case moved(to: String)
    }

    private static let savedKey = "omi.interpreter.savedSystemInput"

    /// The real microphone the system default was switched away from ("" when not switched).
    nonisolated static var savedInputUID: String {
        UserDefaults.standard.string(forKey: savedKey) ?? ""
    }

    private var saved: String {
        get { Self.savedInputUID }
        set { UserDefaults.standard.set(newValue, forKey: Self.savedKey) }
    }

    private(set) var state: State = .off

    private init() {}

    private var plan: [SystemMicPlan.Device] {
        AudioDevices.inputs().map { .init(uid: $0.uid, isVirtual: $0.isVirtualMic) }
    }

    private func device(_ uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return AudioDevices.inputs().first { $0.uid == uid }
    }

    /// The real microphone the interpreter records your voice from.
    func recordingDevice(chosen: String) -> AudioDevice? {
        device(
            SystemMicPlan.recording(
                chosen: chosen, saved: saved, current: AudioDevices.defaultInput?.uid, inputs: plan))
    }

    /// Real microphones for the settings menu.
    var realInputs: [AudioDevice] { AudioDevices.inputs().filter { !$0.isVirtualMic } }

    /// Makes the virtual mic the system default, remembering the real one it replaces.
    func engage() {
        guard let virtual = AudioDevices.inputs().first(where: \.isVirtualMic) else {
            refresh(wanted: true)
            return
        }
        let current = AudioDevices.defaultInput
        // Keep a save left over from a crash: by now the default is the virtual mic.
        if saved.isEmpty || device(saved) == nil,
            let original = SystemMicPlan.original(saved: saved, current: current?.uid, inputs: plan)
        {
            saved = original
        }
        if current?.uid != virtual.uid {
            AudioDevices.setDefaultInput(virtual)
            log("SystemMic: \(current?.name ?? "-") → \(virtual.name), will restore \(device(saved)?.name ?? "-")")
        }
        refresh(wanted: true)
    }

    /// Puts the saved real microphone back, if the system default is still the virtual mic.
    func release() {
        let current = AudioDevices.defaultInput
        if current?.isVirtualMic ?? false,
            let back = device(SystemMicPlan.original(saved: saved, current: nil, inputs: plan))
        {
            AudioDevices.setDefaultInput(back)
            log("SystemMic: restored \(back.name)")
        }
        if !saved.isEmpty { saved = "" }
        state = .off
    }

    /// Re-reads the system default: spots a crash left over or a device that took over.
    @discardableResult
    func refresh(wanted: Bool) -> State {
        let current = AudioDevices.defaultInput
        let originalName = device(SystemMicPlan.original(saved: saved, current: nil, inputs: plan))?.name ?? ""
        let next: State
        if saved.isEmpty {
            next = .off
        } else if current?.isVirtualMic ?? false {
            next = wanted ? .switched(original: originalName) : .notRestored(original: originalName)
        } else if wanted {
            next = .moved(to: current?.name ?? "")
        } else {
            // Someone already put a real mic back: nothing left to undo.
            saved = ""
            next = .off
        }
        state = next
        return next
    }

    /// At launch: interpretation is off, so a switch left over from a crash is undone.
    func restoreAfterCrashIfNeeded() {
        guard !saved.isEmpty else { return }
        if case .notRestored = refresh(wanted: false) {
            log("SystemMic: undoing a switch left over from the last run")
            release()
        }
    }
}
