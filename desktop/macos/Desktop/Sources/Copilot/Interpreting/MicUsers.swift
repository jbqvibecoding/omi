import AppKit
import CoreAudio
import Foundation

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — Sources/LiveSubs/MicUsers.swift.
// See ThirdPartyLicenses/cicada-LICENSE.txt. Changes: the meeting-app list also covers FaceTime and
// the newer Webex / GoTo ids omi already knew; `AudioDevice` names; macOS 14.4 like the rest of
// omi's process-object code.

/// An app reading a microphone, and whether that microphone is the interpreter's.
struct MicUser: Identifiable, Equatable {
    enum State: Equatable {
        /// It hears the translation.
        case virtualMic
        /// It reads another microphone (named): it hears your real voice, not the translation.
        case otherMic(String)
        /// A meeting app that is open but not reading any microphone right now.
        case idle
    }

    let bundleID: String
    let name: String
    let state: State
    var id: String { bundleID }
}

/// Which microphone each meeting app is reading, so the interpreter can say who hears it.
///
/// This is where interpretation most often looks broken: an app set to a *specific* microphone in
/// its own audio settings ignores the system default, so switching the default to the virtual mic
/// does nothing for it and the other side never hears a word. macOS doesn't let one app pick
/// another app's microphone, so all we can do is look, and say so.
enum MicUsers {
    /// Dedicated meeting apps: listed while running, even when idle. Browsers and chat apps are
    /// listed only while they read a microphone, or the list would always show them.
    static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.tencent.meeting", "com.microsoft.teams2", "com.microsoft.teams",
        "com.electron.lark", "com.bytedance.lark", "com.alibaba.DingTalkMac", "Cisco-Systems.Spark",
        "com.apple.FaceTime", "com.webex.meetingmanager", "com.logmein.goto",
    ]

    /// One audio-reading process: its bundle id and the input devices it has open.
    struct Reader: Equatable {
        var bundleID: String
        var inputs: [AudioObjectID]
    }

    /// The app a process belongs to. Browsers and Electron apps capture audio in helper processes
    /// (`com.google.Chrome.helper`), so walk up the bundle id until it names a running app.
    /// Safari and other WebKit apps capture in the shared GPU process; it's Safari in practice.
    static func owner(of bundleID: String, running: Set<String>) -> String? {
        if bundleID.hasPrefix("com.apple.WebKit") {
            return running.contains("com.apple.Safari") ? "com.apple.Safari" : nil
        }
        var parts = bundleID.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            let id = parts.joined(separator: ".")
            if running.contains(id) { return id }
            parts.removeLast()
        }
        return nil
    }

    /// Apple's own processes that read the mic for themselves (Sound settings' level meter, Siri,
    /// Voice Memos) never carry a meeting: listing them only raises false alarms.
    static func isSystemUI(_ app: String) -> Bool {
        app.hasPrefix("com.apple.") && app != "com.apple.Safari" && app != "com.apple.FaceTime"
    }

    /// Pure merge of what Core Audio reports with the running apps: readers first (the ones that
    /// can't hear the translation before the ones that can), then idle meeting apps, each by name.
    static func merge(
        readers: [Reader], running: [String: String], virtualMic: AudioObjectID,
        deviceName: (AudioObjectID) -> String?, ownBundleID: String
    ) -> [MicUser] {
        let ids = Set(running.keys)
        var inputs: [String: Set<AudioObjectID>] = [:]
        for r in readers where !r.inputs.isEmpty {
            guard let app = owner(of: r.bundleID, running: ids), app != ownBundleID, !isSystemUI(app) else { continue }
            inputs[app, default: []].formUnion(r.inputs)
        }
        var users = inputs.map { app, devices -> MicUser in
            // An app may hold several inputs open; any one being the virtual mic means it hears us.
            let state: MicUser.State =
                devices.contains(virtualMic)
                ? .virtualMic
                : .otherMic(devices.sorted().compactMap(deviceName).first ?? "")
            return MicUser(bundleID: app, name: running[app] ?? app, state: state)
        }
        for app in ids.intersection(meetingApps) where inputs[app] == nil {
            users.append(MicUser(bundleID: app, name: running[app] ?? app, state: .idle))
        }
        func rank(_ s: MicUser.State) -> Int {
            switch s {
            case .otherMic: return 0
            case .virtualMic: return 1
            case .idle: return 2
            }
        }
        return users.sorted { (rank($0.state), $0.name) < (rank($1.state), $1.name) }
    }

    /// Meeting apps in a call: reading a microphone, any microphone (bundle id → name). Browsers
    /// aren't counted: their mic use doesn't say a meeting started or ended.
    static func calls(readers: [Reader], running: [String: String]) -> [String: String] {
        let ids = Set(running.keys)
        var out: [String: String] = [:]
        for r in readers where !r.inputs.isEmpty {
            if let app = owner(of: r.bundleID, running: ids), meetingApps.contains(app) {
                out[app] = running[app] ?? app
            }
        }
        return out
    }

    /// The apps using a microphone now, plus idle meeting apps.
    @available(macOS 14.4, *)
    @MainActor
    static func current() -> [MicUser] {
        var running: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            running[id] = app.localizedName ?? id
        }
        return merge(
            readers: readers(), running: running, virtualMic: AudioDevices.virtualMic?.id ?? 0,
            deviceName: AudioDevices.name, ownBundleID: Bundle.main.bundleIdentifier ?? "")
    }

    /// Meeting apps in a call right now.
    @available(macOS 14.4, *)
    @MainActor
    static func currentCalls() -> [String: String] {
        var running: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, meetingApps.contains(id) else { continue }
            running[id] = app.localizedName ?? id
        }
        return running.isEmpty ? [:] : calls(readers: readers(), running: running)
    }

    /// Core Audio's process objects that have input running.
    @available(macOS 14.4, *)
    static func readers() -> [Reader] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return objects(system, kAudioHardwarePropertyProcessObjectList).compactMap { process in
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &running) == noErr, running != 0,
                let bundleID = AudioDevices.string(process, kAudioProcessPropertyBundleID), !bundleID.isEmpty
            else { return nil }
            return Reader(
                bundleID: bundleID,
                inputs: objects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput))
        }
    }

    private static func objects(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
}
