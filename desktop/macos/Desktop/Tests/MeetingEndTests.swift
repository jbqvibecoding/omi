import XCTest

@testable import Omi_Computer

/// Ported from Cicada's MeetingEndTests (Swift Testing → XCTest). `callsCountOnlyMeetingAppsReadingAMic`
/// is MicUsersTests.testCallsAreMeetingAppsReadingAMicrophone in InterpreterTests.
final class MeetingEndWatchTests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_000_000)
  private let zoom = ["us.zoom.xos": "Zoom"]

  private func watch(_ silence: MeetingEndWatch.Silence = .prompt, followApps: Bool = true) -> MeetingEndWatch {
    var c = MeetingEndWatch.Config()
    c.followApps = followApps
    c.silence = silence
    return MeetingEndWatch(config: c, start: t0)
  }

  private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

  func testHangUpEndsAfterTheGrace() {
    var w = watch()
    XCTAssertNil(w.tick(at: at(10), calls: zoom, said: true))
    XCTAssertNil(w.tick(at: at(20), calls: [:], said: true))
    XCTAssertEqual(w.pending, MeetingEndWatch.Pending(reason: .appLeft("Zoom"), deadline: at(50)))
    XCTAssertNil(w.tick(at: at(49), calls: [:], said: true))
    XCTAssertEqual(w.tick(at: at(50), calls: [:], said: true), .appLeft("Zoom"))
  }

  func testRejoiningWithinTheGraceKeepsGoing() {
    var w = watch()
    _ = w.tick(at: at(10), calls: zoom, said: true)
    _ = w.tick(at: at(20), calls: [:], said: true)
    XCTAssertNil(w.tick(at: at(30), calls: zoom, said: true))
    XCTAssertNil(w.pending)
  }

  func testSpeechDoesNotCancelAHangUp() {
    var w = watch()
    _ = w.tick(at: at(10), calls: zoom, said: true)
    _ = w.tick(at: at(20), calls: [:], said: true)
    w.heard(at: at(25))
    XCTAssertEqual(w.tick(at: at(50), calls: [:], said: true), .appLeft("Zoom"))
  }

  func testKeepGoingForgetsTheHangUp() {
    var w = watch()
    _ = w.tick(at: at(10), calls: zoom, said: true)
    _ = w.tick(at: at(20), calls: [:], said: true)
    w.keepGoing(at: at(30))
    XCTAssertNil(w.tick(at: at(100), calls: [:], said: true))
    XCTAssertNil(w.pending)
  }

  func testSilencePromptsThenEnds() {
    var w = watch()
    w.heard(at: at(5))
    XCTAssertNil(w.tick(at: at(604), calls: [:], said: true))
    XCTAssertNil(w.pending)
    XCTAssertNil(w.tick(at: at(605), calls: [:], said: true))
    XCTAssertEqual(w.pending, MeetingEndWatch.Pending(reason: .silence, deadline: at(665)))
    XCTAssertEqual(w.tick(at: at(665), calls: [:], said: true), .silence)
  }

  func testWordsCancelTheSilencePrompt() {
    var w = watch()
    _ = w.tick(at: at(600), calls: [:], said: true)
    XCTAssertEqual(w.pending?.reason, .silence)
    w.heard(at: at(620))
    XCTAssertNil(w.pending)
    XCTAssertNil(w.tick(at: at(700), calls: [:], said: true))
  }

  func testSilenceEndModeEndsAtOnceAndOffNever() {
    var end = watch(.end)
    XCTAssertEqual(end.tick(at: at(600), calls: [:], said: true), .silence)
    var off = watch(.off)
    XCTAssertNil(off.tick(at: at(99_999), calls: [:], said: true))
    XCTAssertNil(off.pending)
  }

  func testSilenceDoesNotCountDuringACall() {
    var w = watch()
    XCTAssertNil(w.tick(at: at(5_000), calls: zoom, said: true))
    XCTAssertNil(w.pending)
    // Without following apps, a call says nothing.
    var plain = watch(followApps: false)
    XCTAssertNil(plain.tick(at: at(600), calls: zoom, said: true))
    XCTAssertEqual(plain.pending?.reason, .silence)
  }

  func testNothingSaidStopsQuietlyAfterTheSilence() {
    var w = watch()
    XCTAssertNil(w.tick(at: at(599), calls: [:], said: false))
    XCTAssertEqual(w.tick(at: at(600), calls: [:], said: false), .nobodySpoke)
    XCTAssertNil(w.pending)
    // Even when silence only prompts: there is nothing to keep, so no countdown.
    var e = watch(.end)
    XCTAssertEqual(e.tick(at: at(600), calls: [:], said: false), .nobodySpoke)
    // Off, or a meeting app in a call (a muted webinar), keeps listening.
    var off = watch(.off)
    XCTAssertNil(off.tick(at: at(5_000), calls: [:], said: false))
    var call = watch()
    XCTAssertNil(call.tick(at: at(5_000), calls: zoom, said: false))
  }

  func testNothingSaidKeepsListening() {
    var w = watch()
    _ = w.tick(at: at(10), calls: zoom, said: false)
    XCTAssertNil(w.tick(at: at(500), calls: [:], said: false))
    XCTAssertNil(w.pending)
    // A call that ended before anyone spoke is forgotten once someone does.
    w.heard(at: at(5_001))
    XCTAssertNil(w.tick(at: at(5_002), calls: [:], said: true))
    XCTAssertNil(w.pending)
  }

  /// omi's `meeting_end_soon`: a countdown started by hand runs and ends like a real one, and
  /// words or a call cancel it the same way.
  func testHandStartedCountdownBehavesLikeSilence() {
    var w = watch()
    w.heard(at: at(100))
    w.silenceCountdown(until: at(120))
    XCTAssertNil(w.tick(at: at(105), calls: [:], said: true))
    XCTAssertEqual(w.pending, MeetingEndWatch.Pending(reason: .silence, deadline: at(120)))
    XCTAssertEqual(w.tick(at: at(120), calls: [:], said: true), .silence)

    var talked = watch()
    talked.silenceCountdown(until: at(120))
    talked.heard(at: at(110))
    XCTAssertNil(talked.pending)
    XCTAssertNil(talked.tick(at: at(121), calls: [:], said: true))

    var inCall = watch()
    inCall.silenceCountdown(until: at(120))
    XCTAssertNil(inCall.tick(at: at(110), calls: zoom, said: true))
    XCTAssertNil(inCall.pending)
  }
}

/// Ported from Cicada's ExportTests (`srtTimesAndTranslations`, and the bilingual lines of
/// `markdownHasTitleLinesAndQuotes` against omi's own Markdown layout).
final class MeetingExportTests: XCTestCase {
  private func segment(
    _ id: String, _ t: Double, speaker: Int = 1, user: Bool = false, _ text: String, _ translation: String? = nil
  ) -> SpeakerSegment {
    SpeakerSegment(
      segmentId: id, speaker: speaker, text: text, start: t, end: t + 1, isUser: user,
      translations: translation.map { [SegmentTranslation(lang: "zh-CN", text: $0)] } ?? [])
  }

  private var meeting: [SpeakerSegment] {
    [
      segment("1", 1.5, "Hello.", "你好。"),
      segment("2", 3.25, user: true, "Same", "Same"),
      segment("3", 20, "Bye."),
    ]
  }

  func testSrtTimesAndTranslations() {
    let srt = MeetingExport.srt(MeetingExport.lines(from: meeting))
    let cues = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    XCTAssertEqual(cues.count, 3)
    // Ends at the next line, at least 1 s and at most 8 s after it starts.
    XCTAssertEqual(cues[0], "1\n00:00:01,500 --> 00:00:03,250\nHello.\n你好。")
    // A translation identical to the source isn't repeated.
    XCTAssertEqual(cues[1], "2\n00:00:03,250 --> 00:00:11,250\nSame")
    // The last line gets 4 s.
    XCTAssertEqual(cues[2], "3\n00:00:20,000 --> 00:00:24,000\nBye.")
  }

  func testSrtKeepsEveryCueAtLeastASecondAndPastAnHour() {
    let lines = [
      MeetingExport.Line(t: 3600.2, speaker: "", text: "a", translation: nil),
      MeetingExport.Line(t: 3600.4, speaker: "", text: "b", translation: nil),
      MeetingExport.Line(t: 3700, speaker: "", text: "c", translation: nil),
    ]
    let cues = MeetingExport.srt(lines).components(separatedBy: "\n\n").filter { !$0.isEmpty }
    XCTAssertEqual(cues[0], "1\n01:00:00,200 --> 01:00:01,200\na")
    XCTAssertEqual(cues[1], "2\n01:00:00,400 --> 01:00:08,400\nb")
  }

  func testLinesAreInOrderNamedAndSkipEmptyText() {
    let segments = [
      segment("b", 9, speaker: 2, "Later"),
      segment("a", 2, user: true, "First"),
      segment("c", 12, speaker: 3, "   "),
    ]
    let lines = MeetingExport.lines(from: segments, names: [2: "Ana"])
    XCTAssertEqual(lines.map(\.text), ["First", "Later"])
    XCTAssertEqual(lines.map(\.speaker), ["You", "Ana"])
    XCTAssertEqual(MeetingExport.lines(from: [segment("d", 1, speaker: 4, "Hi")]).first?.speaker, "Speaker 4")
  }

  /// The full transcript comes from the database, with the translations subtitles wrote back.
  func testStoredRecordsKeepTheirTranslations() {
    let records = [
      TranscriptionSegmentRecord(
        sessionId: 7, speaker: 1, text: "Hello.", startTime: 1.5, endTime: 3, segmentOrder: 0, segmentId: "s1",
        translationsJson: #"[{"lang":"zh-CN","text":"你好。"}]"#),
      TranscriptionSegmentRecord(
        sessionId: 7, speaker: 0, text: "Bye.", startTime: 20, endTime: 21, segmentOrder: 1, segmentId: "s2",
        isUser: true, translationsJson: "not json"),
    ]
    let segments = MeetingExport.segments(from: records)
    XCTAssertEqual(segments.map(\.id), ["s1", "s2"])
    XCTAssertEqual(segments.first.flatMap { MeetingExport.translation(of: $0) }, "你好。")
    XCTAssertEqual(segments.last?.isUser, true)
    XCTAssertTrue(segments.last?.translations.isEmpty ?? false, "a broken translations column is no translation")
  }

  func testMarkdownTranscriptIsBilingual() throws {
    let md = try XCTUnwrap(
      MeetingMarkdownExporter.render(
        title: "Weekly", startedAt: Date(timeIntervalSince1970: 0), scenarioName: nil, sessionId: 7,
        segments: meeting, notesMarkdown: "## Summary"))
    XCTAssertTrue(md.contains("[00:00:02] Speaker 1: Hello.\n> 你好。\n"))
    XCTAssertTrue(md.contains("[00:00:03] You: Same\n"))
    XCTAssertFalse(md.contains("> Same"))
    XCTAssertTrue(md.contains("[00:00:20] Speaker 1: Bye."))
    XCTAssertNil(
      MeetingMarkdownExporter.render(
        title: "Empty", startedAt: Date(), scenarioName: nil, sessionId: nil, segments: [], notesMarkdown: nil))
  }
}
