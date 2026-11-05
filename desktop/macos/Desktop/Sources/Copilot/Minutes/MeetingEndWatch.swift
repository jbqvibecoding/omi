import AppKit
import Foundation

// Adapted from Cicada (github.com/wquguru/cicada), Apache-2.0 — Sources/LiveSubs/MeetingEnd.swift.
// See ThirdPartyLicenses/cicada-LICENSE.txt. Changes: none to the rules; the monitor that ticks it
// is omi's — it runs only while a session is being minuted, and ending a meeting means "finish this
// conversation and keep recording the next", not stopping.

/// Decides when a meeting is over, so one nobody ended doesn't run on for hours and pull the next
/// video or meeting into its minutes.
///
/// Two signals. The main one: a meeting app (Zoom, Tencent Meeting…) that was reading a microphone
/// during this meeting lets go of it, which is what hanging up looks like from outside; a short
/// grace covers switching devices. The fallback, for meetings in a browser or in the room: nothing
/// was recognised for a while. "Nothing recognised" counts words, not sound, so background music
/// doesn't keep a meeting alive. While a meeting app is still in a call, silence doesn't count:
/// muted webinars and quiet screen shares are still meetings. Pure.
struct MeetingEndWatch: Equatable {
    enum Silence: String, CaseIterable { case prompt, end, off }

    struct Config: Equatable {
        var followApps = true
        var silence: Silence = .prompt
        var silenceAfter: TimeInterval = 600
        /// How long the "nobody's talking" prompt waits before ending.
        var countdown: TimeInterval = 60
        /// How long after a hang-up before ending: a device switch drops the mic for a moment.
        var appGrace: TimeInterval = 30
    }

    enum Reason: Equatable {
        /// The meeting app (by name) hung up.
        case appLeft(String)
        case silence
        /// Nobody spoke at all: there is nothing to keep.
        case nobodySpoke
    }

    struct Pending: Equatable {
        var reason: Reason
        var deadline: Date
    }

    var config: Config
    /// The meeting ends at `deadline` unless someone keeps it going.
    private(set) var pending: Pending?
    private(set) var lastSpeech: Date
    /// Meeting apps seen in a call during this meeting (bundle id → name).
    private(set) var inCall: [String: String] = [:]

    init(config: Config, start: Date) {
        self.config = config
        lastSpeech = start
    }

    /// Words were recognised (theirs or mine): a silence countdown stops. A hang-up doesn't: the
    /// next video would talk over it.
    mutating func heard(at now: Date) {
        lastSpeech = now
        if pending?.reason == .silence { pending = nil }
    }

    /// The silence countdown, started by hand (omi-ctl): it runs and ends like a real one.
    mutating func silenceCountdown(until deadline: Date) {
        pending = Pending(reason: .silence, deadline: deadline)
    }

    /// "Keep recording": forget the hang-up and start counting silence again.
    mutating func keepGoing(at now: Date) {
        pending = nil
        lastSpeech = now
        inCall = [:]
    }

    /// `calls`: meeting apps reading a microphone now. `said`: the meeting has lines. Returns why
    /// the meeting ends now, if it does. A call that ended before anyone spoke doesn't count.
    mutating func tick(at now: Date, calls: [String: String], said: Bool) -> Reason? {
        guard said else {
            inCall = config.followApps ? calls : [:]
            pending = nil
            let inACall = config.followApps && !calls.isEmpty
            if config.silence != .off, !inACall, now.timeIntervalSince(lastSpeech) >= config.silenceAfter {
                return .nobodySpoke
            }
            return nil
        }
        if config.followApps {
            for (id, name) in calls { inCall[id] = name }
            let hungUp = !inCall.isEmpty && inCall.keys.allSatisfy { calls[$0] == nil }
            if case .appLeft = pending?.reason, !hungUp { pending = nil }  // rejoined
            if hungUp, pending == nil || pending?.reason == .silence {
                let name = inCall.sorted { $0.key < $1.key }.first?.value ?? ""
                pending = Pending(reason: .appLeft(name), deadline: now.addingTimeInterval(config.appGrace))
            }
        } else if case .appLeft = pending?.reason {
            pending = nil
        }
        let inACall = config.followApps && !calls.isEmpty
        if pending == nil, config.silence != .off, !inACall, now.timeIntervalSince(lastSpeech) >= config.silenceAfter {
            if config.silence == .end { return .silence }
            pending = Pending(reason: .silence, deadline: now.addingTimeInterval(config.countdown))
        }
        if config.silence == .off || inACall, pending?.reason == .silence { pending = nil }
        if let p = pending, now >= p.deadline {
            pending = nil
            return p.reason
        }
        return nil
    }
}

/// Ticks `MeetingEndWatch` for the session being minuted and ends the conversation when the
/// meeting is over — the minutes' final pass, the archive and the export then run as they do for
/// any finished conversation, and recording carries on into the next one.
@MainActor
final class MeetingEndMonitor: ObservableObject {
    static let shared = MeetingEndMonitor()

    @Published private(set) var pending: MeetingEndWatch.Pending?

    /// Finishes the current conversation (set by AppState for the recording).
    var onEnd: (() async -> Void)?

    private var watch: MeetingEndWatch?
    private var timer: Timer?
    private var probing = false
    private var ending = false

    private init() {}

    var isWatching: Bool { watch != nil }

    /// A session became a meeting: watch for its end.
    func begin() {
        guard watch == nil else { return }
        watch = MeetingEndWatch(config: Self.config(), start: Date())
        pending = nil
        ending = false
        timer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in MeetingEndMonitor.shared.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// The session ended (however it ended).
    func end() {
        timer?.invalidate()
        timer = nil
        watch = nil
        pending = nil
    }

    /// Words were recognised.
    func heard() {
        guard watch != nil else { return }
        watch?.heard(at: Date())
        pending = watch?.pending
    }

    /// "Keep recording".
    func keepGoing() {
        watch?.keepGoing(at: Date())
        pending = nil
    }

    /// "End now".
    func endNow() {
        finish(reason: pending?.reason ?? .silence)
    }

    // MARK: - Debug (omi-ctl)

    func debugDump() -> [String: String] {
        let config = watch?.config ?? Self.config()
        var out: [String: String] = [
            "watching": watch == nil ? "false" : "true",
            "ending": ending ? "true" : "false",
            "end_on_hang_up": config.followApps ? "true" : "false",
            "when_silent": config.silence.rawValue,
            "in_call": watch.map { $0.inCall.values.sorted().joined(separator: ", ") } ?? "-",
            "pending": "-",
        ]
        if let watch {
            out["silent_for_s"] = "\(Int(Date().timeIntervalSince(watch.lastSpeech)))"
        }
        if let pending {
            out["pending"] = "\(pending.reason)"
            out["ends_in_s"] = "\(max(0, Int(pending.deadline.timeIntervalSinceNow.rounded())))"
        }
        return out
    }

    func debugEndSoon(in seconds: TimeInterval) -> [String: String] {
        guard watch != nil else { return ["error": "this session isn't being minuted"] }
        watch?.silenceCountdown(until: Date().addingTimeInterval(max(5, seconds)))
        pending = watch?.pending
        return debugDump()
    }

    private static func config() -> MeetingEndWatch.Config {
        var c = MeetingEndWatch.Config()
        c.followApps = CopilotSettings.shared.endMeetingOnHangUp
        c.silence = MeetingEndWatch.Silence(rawValue: CopilotSettings.shared.endMeetingOnSilence) ?? .prompt
        return c
    }

    private func tick() {
        guard watch != nil, !probing, !ending else { return }
        watch?.config = Self.config()
        probing = true
        // The Core Audio process scan can block: off the main actor.
        Task.detached(priority: .utility) {
            var readers: [MicUsers.Reader] = []
            if #available(macOS 14.4, *) { readers = MicUsers.readers() }
            let found = readers
            await MainActor.run { MeetingEndMonitor.shared.apply(found) }
        }
    }

    private func apply(_ readers: [MicUsers.Reader]) {
        probing = false
        guard watch != nil else { return }
        var running: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, MicUsers.meetingApps.contains(id) else { continue }
            running[id] = app.localizedName ?? id
        }
        let calls = running.isEmpty ? [:] : MicUsers.calls(readers: readers, running: running)
        let said = MeetingMinutesEngine.shared.lines.contains { !$0.deleted }
        let reason = watch?.tick(at: Date(), calls: calls, said: said)
        pending = watch?.pending
        guard let reason else { return }
        switch reason {
        case .nobodySpoke:
            // Nothing to keep: nothing to finish either. Count again from now.
            watch?.keepGoing(at: Date())
        case .appLeft, .silence:
            finish(reason: reason)
        }
    }

    private func finish(reason: MeetingEndWatch.Reason) {
        guard !ending, let onEnd else { return }
        ending = true
        log("MeetingEnd: meeting over (\(reason)) — finishing the conversation")
        Task { @MainActor in
            await onEnd()
            self.ending = false
        }
    }
}
