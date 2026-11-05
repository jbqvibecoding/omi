import XCTest

@testable import Omi_Computer

/// The minutes engine's pure parts: reading the model's reply into sourced minutes, keeping
/// sources across updates, the language check, and the gate that decides a session is a
/// meeting. (Cicada, where this comes from, had no tests for its notes.)
final class MeetingMinutesTests: XCTestCase {
  private func line(_ i: Int, _ t: Double, _ text: String, user: Bool = false, speaker: Int = 1,
                    deleted: Bool = false) -> MinutesLine {
    MinutesLine(id: "seg\(i)", t: t, speakerId: user ? 0 : speaker, isUser: user, text: text, deleted: deleted)
  }

  private var lines: [MinutesLine] {
    [
      line(1, 3, "我们先看下季度的预算"),
      line(2, 10, "好的，预算要砍掉20%", user: true),
      line(3, 40, "为什么要砍？"),
      line(4, 65, "因为收入下滑和成本上涨", speaker: 2),
      line(5, 90, "这句被删除了", deleted: true),
      line(6, 120, "那就下周五前给方案", user: true),
    ]
  }

  private let labels = MinutesLogic.Labels.forLanguage("zh-CN")
  private func who(_ l: MinutesLine) -> String { labels.who(l, names: [:]) }

  private let reply = """
    Here you go:
    {"title": "「季度预算」", "summary": "讨论了预算削减。",
     "topics": [{"start": "00:03", "title": "预算", "summary": "砍预算",
                 "points": [{"text": "预算砍20%", "evidence": ["L2"]}, "裸字符串要点", {"text": "", "evidence": ["L1"]}],
                 "evidence": ["L1"],
                 "fishbone": {"question": "为什么砍预算", "branches": [
                    {"label": "收入下滑", "detail": "", "t": 65, "evidence": ["L4"]},
                    {"label": "成本上涨", "detail": "原材料", "evidence": []},
                    {"label": "", "detail": "x"}]}},
                {"title": "", "points": []},
                {"title": "方案", "points": [{"text": "下周五前", "evidence": ["L6", "L5", "L99"]}]}],
     "conclusions": [{"text": "预算砍20%", "evidence": ["L2", "L4"]}, {"text": "无依据结论", "evidence": []}],
     "todos": [{"text": "下周五前给方案", "owner": "你", "evidence": ["L6"]}, {"text": "x", "owner": "null", "evidence": "L1"}],
     "terms": [{"name": "江充", "note": "人名", "heard": ["江松", "江充", ""]}]}
    Thanks!
    """

  // MARK: Evidence ids and times

  func testEvidenceIdsInEveryShapeModelsWrite() {
    XCTAssertEqual(MinutesLogic.lineNumbers(["L4", "L7"], lineCount: 10), [4, 7])
    XCTAssertEqual(MinutesLogic.lineNumbers("L4", lineCount: 10), [4])
    XCTAssertEqual(MinutesLogic.lineNumbers("L4, L6", lineCount: 10), [4, 6])
    XCTAssertEqual(MinutesLogic.lineNumbers(["L2-L4"], lineCount: 10), [2, 3, 4])
    XCTAssertEqual(MinutesLogic.lineNumbers(["L2–4"], lineCount: 10), [2, 3, 4])
    XCTAssertEqual(MinutesLogic.lineNumbers([4, 7.0] as [Any], lineCount: 10), [4, 7])
    XCTAssertEqual(MinutesLogic.lineNumbers(nil, lineCount: 10), [])
  }

  func testEvidenceIdsAreBoundedAndDeduplicated() {
    XCTAssertEqual(MinutesLogic.lineNumbers(["L0", "L11", "L5", "L5"], lineCount: 10), [5])
    // A "range" across most of the meeting is two citations, not forty.
    XCTAssertEqual(MinutesLogic.lineNumbers(["L1-L40"], lineCount: 50), [1, 40])
  }

  func testTimesParseAsSecondsOrClock() {
    XCTAssertEqual(MinutesLogic.seconds(75), 75)
    XCTAssertEqual(MinutesLogic.seconds("75"), 75)
    XCTAssertEqual(MinutesLogic.seconds("01:15"), 75)
    XCTAssertEqual(MinutesLogic.seconds("1:01:15"), 3675)
    XCTAssertNil(MinutesLogic.seconds("abc"))
    XCTAssertNil(MinutesLogic.seconds("1:xx"))
    XCTAssertNil(MinutesLogic.seconds(""))
  }

  func testClock() {
    XCTAssertEqual(MinutesLogic.clock(0), "00:00")
    XCTAssertEqual(MinutesLogic.clock(232), "03:52")
    XCTAssertEqual(MinutesLogic.clock(3675), "1:01:15")
    XCTAssertEqual(MinutesLogic.clock(-4), "00:00")
  }

  // MARK: Parse

  func testParseKeepsQuotesSpeakersAndTimes() throws {
    let m = try XCTUnwrap(MinutesLogic.parse(reply, lines: lines, startedAt: 3, who: who))
    XCTAssertEqual(m.title, "季度预算")
    XCTAssertEqual(m.summary, "讨论了预算削减。")
    XCTAssertEqual(m.topics.map(\.title), ["预算", "方案"], "a topic without a title is dropped")

    let budget = m.topics[0]
    XCTAssertEqual(budget.start, 3, "start given as mm:ss")
    XCTAssertEqual(budget.points.map(\.text), ["预算砍20%", "裸字符串要点"])
    let ref = try XCTUnwrap(budget.points[0].evidence.first)
    XCTAssertEqual(ref.quote, "好的，预算要砍掉20%")
    XCTAssertEqual(ref.speaker, "你")
    XCTAssertEqual(ref.lineId, "seg2")
    XCTAssertEqual(ref.line, 2)
    XCTAssertEqual(budget.points[0].t, 10)
    XCTAssertTrue(budget.points[1].evidence.isEmpty)

    let fish = try XCTUnwrap(budget.fishbone)
    XCTAssertEqual(fish.branches.map(\.label), ["收入下滑", "成本上涨"])
    XCTAssertEqual(fish.branches[0].t, 65)
    XCTAssertEqual(fish.branches[0].evidence.first?.speaker, "说话人2")
    XCTAssertNil(fish.branches[1].t)
    XCTAssertEqual(fish.branches[1].support, 0)
  }

  func testParseDropsDeletedAndOutOfRangeEvidence() throws {
    let m = try XCTUnwrap(MinutesLogic.parse(reply, lines: lines, startedAt: 3, who: who))
    let plan = m.topics[1]
    XCTAssertEqual(plan.points[0].evidence.map(\.line), [6])
    XCTAssertEqual(plan.start, 120, "no start given: the earliest evidence")
  }

  func testParseItemsAndTerms() throws {
    let m = try XCTUnwrap(MinutesLogic.parse(reply, lines: lines, startedAt: 3, who: who))
    XCTAssertEqual(m.conclusions.map(\.support), [2, 0])
    XCTAssertEqual(m.conclusions[0].t, 10)
    XCTAssertEqual(m.todos[0].owner, "你")
    XCTAssertNil(m.todos[1].owner, "\"null\" written as a string is no owner")
    XCTAssertEqual(m.todos[1].evidence.map(\.line), [1], "evidence given as one string")
    XCTAssertEqual(m.terms.first?.heard, ["江松"], "the name itself and blanks are not misreadings")
  }

  func testParseRejectsGarbageAndEmptyMinutes() {
    XCTAssertNil(MinutesLogic.parse("not json", lines: lines, startedAt: 0, who: who))
    XCTAssertNil(MinutesLogic.parse(#"{"summary": "", "topics": []}"#, lines: lines, startedAt: 0, who: who))
    XCTAssertNotNil(MinutesLogic.parse(#"{"summary": "x"}"#, lines: [], startedAt: 0, who: who))
  }

  func testTermCapKeepsTheMisheardOnes() throws {
    let terms = (0..<30).map { i in
      #"{"name": "T\#(i)", "note": "", "heard": \#(i % 5 == 0 ? #"["h"]"# : "[]")}"#
    }.joined(separator: ",")
    let m = try XCTUnwrap(
      MinutesLogic.parse(#"{"summary": "s", "terms": [\#(terms)]}"#, lines: lines, startedAt: 0, who: who))
    XCTAssertEqual(m.terms.count, 20)
    for i in stride(from: 0, to: 30, by: 5) {
      XCTAssertTrue(m.terms.contains { $0.name == "T\(i)" }, "misheard T\(i) kept")
    }
  }

  // MARK: Carrying sources across updates

  func testCarryEvidenceKeepsSourcesOfRestatedItems() throws {
    let old = try XCTUnwrap(MinutesLogic.parse(reply, lines: lines, startedAt: 3, who: who))
    let next = #"""
      {"summary": "s", "topics": [{"title": "预算", "start": 3,
        "points": [{"text": "预算砍20%。", "evidence": []}, {"text": "新要点", "evidence": ["L6"]}],
        "fishbone": {"question": "q", "branches": [
          {"label": "收入下滑", "detail": "", "evidence": []},
          {"label": "成本上涨", "detail": "", "t": 200, "evidence": ["L6"]}]}}],
       "conclusions": [{"text": "预算砍20%", "evidence": ["L6"]}]}
      """#
    var new = try XCTUnwrap(MinutesLogic.parse(next, lines: lines, startedAt: 0, who: who))
    MinutesLogic.carryEvidence(from: old, into: &new)

    let points = new.topics[0].points
    XCTAssertEqual(points[0].evidence.map(\.line), [2], "matched despite trailing punctuation")
    XCTAssertEqual(points[1].evidence.map(\.line), [6])
    let branches = try XCTUnwrap(new.topics[0].fishbone).branches
    XCTAssertEqual(branches[0].evidence.map(\.line), [4])
    XCTAssertEqual(branches[0].t, 65)
    XCTAssertEqual(branches[1].t, 120, "a branch's time is never later than its first evidence")
    XCTAssertEqual(new.conclusions[0].evidence.map(\.line), [2, 4, 6], "merged, oldest first")
    XCTAssertEqual(new.conclusions[0].t, 10, "a later mention never moves an item later")
  }

  func testFreshKeysOnlyAfterFirstVersion() throws {
    let old = try XCTUnwrap(MinutesLogic.parse(reply, lines: lines, startedAt: 3, who: who))
    var new = old
    new.topics[0].points.append(MinutesPoint(text: "新要点", evidence: []))
    XCTAssertEqual(MinutesLogic.freshKeys(old: old, new: new), ["新要点"])
    XCTAssertEqual(MinutesLogic.freshKeys(old: MeetingMinutes(), new: new), [])
  }

  // MARK: Prompt

  func testPromptNumbersLinesGloballyAndSkipsDeleted() {
    let prompt = MinutesLogic.prompt(
      minutes: MeetingMinutes(), lines: lines, from: 3, language: "Simplified Chinese", final: false,
      labels: labels)
    XCTAssertTrue(prompt.contains("[L4 01:05 说话人2] 因为收入下滑和成本上涨"))
    XCTAssertTrue(prompt.contains("[L6 02:00 你] 那就下周五前给方案"))
    XCTAssertFalse(prompt.contains("这句被删除了"))
    XCTAssertTrue(prompt.contains("[L2 00:10 你]"), "two lines of context before the new ones")
    XCTAssertTrue(prompt.contains("These are the first lines: make one topic."))
  }

  func testPromptHoldsBackANewTopicUnderTwoMinutes() throws {
    var current = try XCTUnwrap(MinutesLogic.parse(reply, lines: lines, startedAt: 3, who: who))
    current.topics = [MinutesTopic(start: 60, title: "预算", summary: "", points: [], fishbone: nil)]
    let prompt = MinutesLogic.prompt(
      minutes: current, lines: lines, from: 4, language: "Simplified Chinese", final: false, labels: labels)
    XCTAssertTrue(prompt.contains("under 2 minutes ago: do not start a new topic"))
    XCTAssertTrue(prompt.contains(#""evidence":["L2","L4"]"#), "current minutes go back with their evidence ids")
  }

  func testFinalPromptCapsTopicsByLength() {
    let long = (0..<20).map { line($0 + 1, Double($0) * 60, "第\($0)句") }
    let prompt = MinutesLogic.prompt(
      minutes: MeetingMinutes(), lines: long, from: 0, language: "English", final: true,
      labels: .forLanguage("en"))
    XCTAssertTrue(prompt.contains("This meeting ran 19:00: use at most 7 topics."))
    XCTAssertFalse(prompt.contains("Current notes (JSON)"))
  }

  // MARK: Language

  func testWrittenInTheRequestedLanguage() {
    var zh = MeetingMinutes()
    zh.summary = "我们讨论了 Q3 预算 and OKR"
    zh.topics = [MinutesTopic(start: 0, title: "预算", summary: "", points: [], fishbone: nil)]
    var en = MeetingMinutes()
    en.summary = "We discussed the Q3 budget"
    en.topics = [MinutesTopic(start: 0, title: "Budget", summary: "", points: [], fishbone: nil)]
    XCTAssertTrue(MinutesLogic.written(zh, in: "Simplified Chinese"))
    XCTAssertFalse(MinutesLogic.written(en, in: "Simplified Chinese"))
    XCTAssertTrue(MinutesLogic.written(en, in: "English"))
    XCTAssertFalse(MinutesLogic.written(zh, in: "English"))
    XCTAssertTrue(MinutesLogic.written(MeetingMinutes(), in: "English"))
  }

  func testLabelsFollowTheMinutesLanguage() {
    let zh = MinutesLogic.Labels.forLanguage("zh-TW")
    let en = MinutesLogic.Labels.forLanguage("ja")
    let other = line(1, 0, "x", speaker: 3)
    XCTAssertEqual(zh.who(other, names: [:]), "说话人3")
    XCTAssertEqual(en.who(other, names: [:]), "Speaker 3")
    XCTAssertEqual(en.who(other, names: [3: "George"]), "George")
    XCTAssertEqual(zh.who(line(2, 0, "y", user: true), names: [:]), "你")
  }

  // MARK: Gate

  func testGate() {
    XCTAssertNil(MinutesGate.trigger(enabled: false, manual: true, callSeen: true, soundSamples: [], othersLines: 9))
    XCTAssertEqual(MinutesGate.trigger(enabled: true, manual: true, callSeen: false, soundSamples: [], othersLines: 0), .manual)
    XCTAssertEqual(MinutesGate.trigger(enabled: true, manual: false, callSeen: true, soundSamples: [], othersLines: 0), .call)
    XCTAssertNil(
      MinutesGate.trigger(enabled: true, manual: false, callSeen: false, soundSamples: Array(repeating: true, count: 5), othersLines: 9),
      "too few samples: one loud moment is not a meeting")
    XCTAssertEqual(
      MinutesGate.trigger(
        enabled: true, manual: false, callSeen: false,
        soundSamples: Array(repeating: true, count: 3) + Array(repeating: false, count: 7), othersLines: 3),
      .systemAudio)
    XCTAssertNil(
      MinutesGate.trigger(
        enabled: true, manual: false, callSeen: false,
        soundSamples: Array(repeating: true, count: 2) + Array(repeating: false, count: 8), othersLines: 3))
    XCTAssertNil(
      MinutesGate.trigger(enabled: true, manual: false, callSeen: false, soundSamples: Array(repeating: true, count: 10), othersLines: 2),
      "the speakers playing with nobody else talking is music, not a meeting")
  }

  func testChineseMeetingAppsCountAsCalls() {
    XCTAssertTrue(ConferencingApps.isNativeCallApp(bundleID: "com.tencent.meeting"))
    XCTAssertTrue(ConferencingApps.isNativeCallApp(bundleID: "com.electron.lark"))
    XCTAssertTrue(ConferencingApps.isNativeCallApp(bundleID: "com.alibaba.DingTalkMac"))
  }
}

/// Ported from Cicada's LanguageTests / FollowSystemTests (Swift Testing → XCTest).
final class MeetingLanguagesTests: XCTestCase {
  func testSystemLanguageMapsToTranslationCode() {
    let cases: [(String, String)] = [
      ("zh-Hans-CN", "zh-CN"), ("zh-Hans-CA", "zh-CN"), ("zh-Hant-TW", "zh-TW"),
      ("zh-TW", "zh-TW"), ("zh-HK", "zh-TW"), ("zh-CN", "zh-CN"),
      ("en-CA", "en"), ("ja-JP", "ja"), ("pt-BR", "pt"),
    ]
    for (id, code) in cases {
      XCTAssertEqual(MeetingLanguages.translationCode(forSystemLanguage: id), code, id)
    }
  }

  func testMyLanguageIsChineseWhenListed() {
    let cases: [([String], String)] = [
      (["zh-Hans-CN"], "zh-CN"), (["en-US"], "en"), (["en-CA", "zh-Hans-CA"], "zh-CN"),
      (["ja-JP", "zh-Hant-TW"], "zh-TW"), (["ja-JP", "en-US"], "ja"),
      // omi: an empty list means English (Cicada, a Chinese app, chose Chinese).
      ([], "en"),
    ]
    for (prefs, mine) in cases {
      XCTAssertEqual(MeetingLanguages.myLanguage(systemLanguages: prefs), mine, "\(prefs)")
    }
  }

  func testSubtitlesFollowMyLanguage() {
    for prefs in [["en-CA", "zh-Hans-CA"], ["zh-Hans-CN", "en-US"], ["ja-JP", "en-US"], ["en-US"]] {
      let mine = MeetingLanguages.myLanguage(systemLanguages: prefs)
      for source in ["en", "ja", "ko", "zh-CN", nil] as [String?]
      where source.map({ !MeetingLanguages.sameLanguage($0, mine) }) ?? true {
        XCTAssertEqual(MeetingLanguages.followSystemTarget(source: source, systemLanguages: prefs), mine)
      }
    }
  }

  func testSpeakingMyLanguageTranslatesIntoTheNextOne() {
    XCTAssertEqual(MeetingLanguages.followSystemTarget(source: "zh-CN", systemLanguages: ["en-CA", "zh-Hans-CA"]), "en")
    XCTAssertEqual(MeetingLanguages.followSystemTarget(source: "ja", systemLanguages: ["ja-JP", "en-US"]), "en")
    XCTAssertEqual(MeetingLanguages.followSystemTarget(source: "zh-CN", systemLanguages: ["zh-Hans-CN"]), "en")
    XCTAssertEqual(MeetingLanguages.followSystemTarget(source: "en", systemLanguages: ["en-US"]), "zh-CN")
    // omi: a regional code is the same language ("en-US" is "en").
    XCTAssertEqual(MeetingLanguages.followSystemTarget(source: "en-US", systemLanguages: ["en-US"]), "zh-CN")
  }

  func testDominantScript() {
    XCTAssertEqual(MeetingLanguages.dominantScript(of: "我们先看下季度的预算，然后讨论招聘计划"), "zh-CN")
    XCTAssertEqual(MeetingLanguages.dominantScript(of: "今日はいい天気ですね、会議を始めましょう"), "ja")
    XCTAssertEqual(MeetingLanguages.dominantScript(of: "오늘 회의를 시작하겠습니다 감사합니다"), "ko")
    XCTAssertEqual(MeetingLanguages.dominantScript(of: "Let's start with the quarterly budget review"), "en")
    XCTAssertNil(MeetingLanguages.dominantScript(of: "ok"), "too little to tell")
  }
}
