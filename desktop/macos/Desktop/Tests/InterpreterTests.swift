import AppKit
import XCTest

@testable import Omi_Computer

/// Ported from Cicada's SystemMicTests (Swift Testing → XCTest).
final class SystemMicPlanTests: XCTestCase {
  private let builtIn = SystemMicPlan.Device(uid: "BuiltInMicrophoneDevice", isVirtual: false)
  private let airpods = SystemMicPlan.Device(uid: "airpods", isVirtual: false)
  private let blackhole = SystemMicPlan.Device(uid: "BlackHole2ch_UID", isVirtual: true)
  private var all: [SystemMicPlan.Device] { [blackhole, builtIn, airpods] }

  func testSavedMicComesBackWhilePluggedIn() {
    XCTAssertEqual(SystemMicPlan.original(saved: "airpods", current: blackhole.uid, inputs: all), "airpods")
  }

  func testUnpluggedSavedMicFallsBackToARealOne() {
    XCTAssertEqual(
      SystemMicPlan.original(saved: "airpods", current: blackhole.uid, inputs: [blackhole, builtIn]), builtIn.uid)
  }

  func testCurrentRealMicIsTheOriginalWhenNothingIsSaved() {
    XCTAssertEqual(SystemMicPlan.original(saved: "", current: "airpods", inputs: all), "airpods")
  }

  /// BlackHole was already the system mic by hand: "back" must still be a real mic.
  func testNeverRestoresToTheVirtualMic() {
    XCTAssertEqual(SystemMicPlan.original(saved: "", current: blackhole.uid, inputs: all), builtIn.uid)
    XCTAssertEqual(SystemMicPlan.original(saved: blackhole.uid, current: blackhole.uid, inputs: all), builtIn.uid)
    XCTAssertNil(SystemMicPlan.original(saved: "", current: blackhole.uid, inputs: [blackhole]))
  }

  func testRecordingUsesTheChosenMicElseTheOriginal() {
    XCTAssertEqual(
      SystemMicPlan.recording(chosen: "airpods", saved: builtIn.uid, current: blackhole.uid, inputs: all), "airpods")
    XCTAssertEqual(
      SystemMicPlan.recording(chosen: "", saved: builtIn.uid, current: blackhole.uid, inputs: all), builtIn.uid)
    // A chosen mic that's unplugged, or the virtual mic itself, is skipped.
    XCTAssertEqual(SystemMicPlan.recording(chosen: "gone", saved: "", current: "airpods", inputs: all), "airpods")
    XCTAssertEqual(
      SystemMicPlan.recording(chosen: blackhole.uid, saved: "", current: blackhole.uid, inputs: all), builtIn.uid)
  }

  func testOnlyBlackHoleIsTheVirtualMic() {
    XCTAssertTrue(AudioDevice(id: 1, uid: "x", name: "BlackHole 2ch").isVirtualMic)
    XCTAssertFalse(AudioDevice(id: 2, uid: "y", name: "MacBook Pro Microphone").isVirtualMic)
    XCTAssertFalse(AudioDevice(id: 3, uid: "z", name: "Loopback Audio").isVirtualMic, "a user's own Loopback device is a real choice")
  }
}

/// Ported from Cicada's MicUsersTests (Swift Testing → XCTest).
final class MicUsersTests: XCTestCase {
  private let virtual: UInt32 = 87
  private let builtIn: UInt32 = 82
  private let names: [UInt32: String] = [87: "BlackHole 2ch", 82: "MacBook Pro Microphone"]

  func testHelperProcessesBelongToTheirApp() {
    let running: Set<String> = ["com.google.Chrome", "com.apple.Safari", "us.zoom.xos"]
    XCTAssertEqual(MicUsers.owner(of: "com.google.Chrome.helper", running: running), "com.google.Chrome")
    XCTAssertEqual(MicUsers.owner(of: "com.google.Chrome.helper.renderer", running: running), "com.google.Chrome")
    XCTAssertEqual(MicUsers.owner(of: "us.zoom.xos", running: running), "us.zoom.xos")
    XCTAssertEqual(MicUsers.owner(of: "com.apple.WebKit.GPU", running: running), "com.apple.Safari")
    XCTAssertNil(MicUsers.owner(of: "com.apple.WebKit.GPU", running: ["us.zoom.xos"]))
    XCTAssertNil(MicUsers.owner(of: "org.example.tool", running: running))
  }

  func testMergeSortsProblemsFirstAndListsIdleMeetingApps() {
    let users = MicUsers.merge(
      readers: [
        .init(bundleID: "us.zoom.xos", inputs: [virtual]),
        .init(bundleID: "com.tencent.meeting", inputs: [builtIn]),
        .init(bundleID: "com.google.Chrome.helper", inputs: []),
      ],
      running: [
        "us.zoom.xos": "Zoom", "com.tencent.meeting": "腾讯会议", "com.microsoft.teams2": "Microsoft Teams",
        "com.google.Chrome": "Google Chrome",
      ],
      virtualMic: virtual, deviceName: { self.names[$0] }, ownBundleID: "com.omi.desktop-dev")
    XCTAssertEqual(users.map(\.name), ["腾讯会议", "Zoom", "Microsoft Teams"])
    XCTAssertEqual(users.map(\.state), [.otherMic("MacBook Pro Microphone"), .virtualMic, .idle])
  }

  func testAnyVirtualInputCountsAndOwnAppIsHidden() {
    let users = MicUsers.merge(
      readers: [
        .init(bundleID: "com.google.Chrome.helper", inputs: [builtIn]),
        .init(bundleID: "com.google.Chrome.helper", inputs: [virtual]),
        .init(bundleID: "com.omi.desktop-dev", inputs: [virtual]),
      ],
      running: ["com.google.Chrome": "Google Chrome", "com.omi.desktop-dev": "Omi Dev"],
      virtualMic: virtual, deviceName: { self.names[$0] }, ownBundleID: "com.omi.desktop-dev")
    XCTAssertEqual(users, [MicUser(bundleID: "com.google.Chrome", name: "Google Chrome", state: .virtualMic)])
  }

  func testApplesOwnMicReadersAreNotMeetings() {
    let users = MicUsers.merge(
      readers: [
        .init(bundleID: "com.apple.Sound-Settings.extension", inputs: [builtIn]),
        .init(bundleID: "com.apple.FaceTime", inputs: [builtIn]),
      ],
      running: ["com.apple.Sound-Settings.extension": "Sound (System Settings)", "com.apple.FaceTime": "FaceTime"],
      virtualMic: virtual, deviceName: { self.names[$0] }, ownBundleID: "com.omi.desktop-dev")
    XCTAssertEqual(users.map(\.name), ["FaceTime"])
  }

  func testCallsAreMeetingAppsReadingAMicrophone() {
    let calls = MicUsers.calls(
      readers: [
        .init(bundleID: "us.zoom.xos", inputs: [builtIn]),
        .init(bundleID: "com.google.Chrome.helper", inputs: [builtIn]),
        .init(bundleID: "com.tencent.meeting", inputs: []),
      ],
      running: ["us.zoom.xos": "Zoom", "com.google.Chrome": "Chrome", "com.tencent.meeting": "腾讯会议"])
    XCTAssertEqual(calls, ["us.zoom.xos": "Zoom"], "a browser's mic use and an idle meeting app are not calls")
  }
}

final class InterpretationGuardTests: XCTestCase {
  /// The interpreter only ever speaks a reply in exactly the two-line form, translated into the
  /// target's script — the model sometimes answers a question instead, and that must not reach
  /// the room.
  func testOnlyATranslationInTheTargetScriptIsSpoken() {
    let good = LingClient.parseInterpretation("ORIGINAL: 我们下周五上线\nTRANSLATION: We launch next Friday", target: "en")
    XCTAssertEqual(good?.original, "我们下周五上线")
    XCTAssertEqual(good?.translation, "We launch next Friday")
    XCTAssertNotNil(LingClient.parseInterpretation("original: hello there\ntranslation: 你好", target: "zh-CN"))
    // An answer instead of a translation.
    XCTAssertNil(LingClient.parseInterpretation("Sure! The launch is planned for Friday.", target: "en"))
    // The "translation" left in the source language.
    XCTAssertNil(LingClient.parseInterpretation("ORIGINAL: 你好\nTRANSLATION: 你好", target: "en"))
    XCTAssertNil(LingClient.parseInterpretation("ORIGINAL: hello\nTRANSLATION: hello again", target: "ja"))
    XCTAssertNil(LingClient.parseInterpretation("ORIGINAL: 我们\nTRANSLATION: 我们的计划", target: "en"))
    XCTAssertNil(LingClient.parseInterpretation("ORIGINAL: \nTRANSLATION: hi", target: "en"))
  }

  func testRightOptionAloneIsTheTalkKey() {
    let option = NSEvent.ModifierFlags.option.rawValue
    let right = NSEvent.ModifierFlags(rawValue: option | InterpretKeyMonitor.rightOptionBit)
    let left = NSEvent.ModifierFlags(rawValue: option | InterpretKeyMonitor.leftOptionBit)
    let both = NSEvent.ModifierFlags(rawValue: option | InterpretKeyMonitor.leftOptionBit | InterpretKeyMonitor.rightOptionBit)
    let rightShift = NSEvent.ModifierFlags(
      rawValue: option | NSEvent.ModifierFlags.shift.rawValue | InterpretKeyMonitor.rightOptionBit)
    XCTAssertTrue(InterpretKeyMonitor.isRightOptionAlone(right))
    XCTAssertFalse(InterpretKeyMonitor.isRightOptionAlone(left))
    XCTAssertFalse(InterpretKeyMonitor.isRightOptionAlone(both))
    XCTAssertFalse(InterpretKeyMonitor.isRightOptionAlone(rightShift))
    // Push-to-talk gives up right ⌥ only while interpretation is on.
    XCTAssertTrue(InterpretKeyMonitor.claims(right, interpreterOn: true))
    XCTAssertFalse(InterpretKeyMonitor.claims(right, interpreterOn: false))
    XCTAssertFalse(InterpretKeyMonitor.claims(left, interpreterOn: true))
  }

  func testPressAudioIsAValidWav() {
    let wav = InterpretEngine.wav([0, 1, -1, 32767])
    XCTAssertEqual(wav.count, 44 + 8)
    XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
    XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
    XCTAssertEqual(InterpretEngine.raw([1, -1]), Data([0x01, 0x00, 0xFF, 0xFF]))
  }
}
