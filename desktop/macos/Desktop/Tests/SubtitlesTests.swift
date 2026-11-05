import XCTest

@testable import Omi_Computer

/// Recognizer routing, the shared model budget, and the subtitle line helpers.
final class TranscriberRoutingTests: XCTestCase {
  private func plan(_ language: String, apple: Bool, subtitles: Bool, local: Bool = true, force: Bool = false)
    -> TranscriberPlan
  {
    TranscriberRouting.plan(
      language: language, localAllowed: local, appleSpeechAvailable: apple, subtitlesOn: subtitles,
      forceLocal: force)
  }

  func testEnglishWithoutSubtitlesIsUnchanged() {
    XCTAssertEqual(plan("en", apple: true, subtitles: false), .local(mic: .parakeet, system: .parakeet))
    XCTAssertEqual(plan("en", apple: false, subtitles: true), .local(mic: .parakeet, system: .parakeet))
  }

  func testSubtitlesOnMacOS26MoveTheOtherSideToApple() {
    XCTAssertEqual(plan("en", apple: true, subtitles: true), .local(mic: .parakeet, system: .appleSpeech))
    XCTAssertEqual(plan("fr", apple: true, subtitles: true), .local(mic: .parakeet, system: .appleSpeech))
  }

  func testCJKNoLongerGoesToParakeet() {
    XCTAssertEqual(plan("zh", apple: true, subtitles: false), .local(mic: .appleSpeech, system: .appleSpeech))
    XCTAssertEqual(plan("zh-TW", apple: true, subtitles: true), .local(mic: .appleSpeech, system: .appleSpeech))
    XCTAssertEqual(plan("ja", apple: false, subtitles: false), .cloud, "older macOS: the cloud reads it")
    XCTAssertEqual(plan("ko", apple: false, subtitles: true), .cloud)
  }

  func testLanguagesAppleCantReadStayWithParakeet() {
    XCTAssertEqual(plan("ru", apple: true, subtitles: true), .local(mic: .parakeet, system: .parakeet))
    XCTAssertEqual(plan("th", apple: true, subtitles: false), .cloud)
  }

  func testCloudFailureForcesWhateverIsLocal() {
    XCTAssertEqual(plan("th", apple: true, subtitles: false, force: true), .local(mic: .appleSpeech, system: .appleSpeech))
    XCTAssertEqual(plan("ko", apple: false, subtitles: false, force: true), .local(mic: .parakeet, system: .parakeet))
  }

  func testNotAllowedLocallyIsCloud() {
    XCTAssertEqual(plan("en", apple: true, subtitles: true, local: false), .cloud)
  }

  func testSpeechLocales() {
    XCTAssertEqual(TranscriberRouting.speechLocale(for: "zh"), "zh-CN")
    XCTAssertEqual(TranscriberRouting.speechLocale(for: "zh-TW"), "zh-TW")
    XCTAssertEqual(TranscriberRouting.speechLocale(for: "zh-Hant"), "zh-TW")
    XCTAssertEqual(TranscriberRouting.speechLocale(for: "ja"), "ja-JP")
    XCTAssertEqual(TranscriberRouting.speechLocale(for: "en"), "en-US")
    XCTAssertEqual(TranscriberRouting.speechLocale(for: "en-GB"), "en-GB")
    XCTAssertEqual(TranscriberRouting.speechLocale(for: "pt"), "pt-BR")
  }
}

final class GeminiCallBudgetTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_000_000)
  private func at(_ s: Double) -> Date { start.addingTimeInterval(s) }

  func testTranslationsAreCappedPerMinute() {
    var budget = GeminiCallBudget()
    let allowed = (0..<10).map { budget.allow(.translate, now: at(Double($0))) }
    XCTAssertEqual(allowed, Array(repeating: true, count: 8) + [false, false])
    XCTAssertTrue(budget.allow(.minutes, now: at(10)), "minutes have their own room")
    XCTAssertTrue(budget.allow(.translate, now: at(61)), "the window slides")
  }

  func testTotalCapLeavesRoomForTheRestOfTheApp() {
    var budget = GeminiCallBudget()
    for _ in 0..<GeminiCallBudget.totalLimit { _ = budget.allow(.interpret, now: at(0)) }
    XCTAssertFalse(budget.allow(.minutes, now: at(1)))
    XCTAssertFalse(budget.allow(.translate, now: at(1)))
    XCTAssertTrue(budget.allow(.interpret, now: at(1)), "the interpreter always goes")
  }

  func testRateLimitPausesLowerPriorities() {
    var budget = GeminiCallBudget()
    budget.noteRateLimited(now: at(0))
    XCTAssertFalse(budget.allow(.translate, now: at(10)))
    XCTAssertTrue(budget.allow(.translate, now: at(21)))
    XCTAssertFalse(budget.allow(.minutes, now: at(30)))
    XCTAssertTrue(budget.allow(.minutes, now: at(61)))
    XCTAssertTrue(budget.allow(.interpret, now: at(5)))
  }
}

final class SubtitleLineTests: XCTestCase {
  func testMisheardSpellingsAreCorrectedBeforeTranslation() {
    let terms = [
      MinutesTerm(name: "江充", note: "人名", heard: ["江松", "江冲"]),
      MinutesTerm(name: "Kubernetes", note: "", heard: ["cooper netties"]),
      MinutesTerm(name: "Ana", note: "", heard: ["Anna"]),
    ]
    XCTAssertEqual(MinutesLogic.correct("江松说下周上线", terms: terms), "江充说下周上线")
    XCTAssertEqual(MinutesLogic.correct("We run Cooper Netties in prod", terms: terms), "We run Kubernetes in prod")
    XCTAssertEqual(MinutesLogic.correct("Annabel and Anna", terms: terms), "Annabel and Ana", "whole words only")
  }

  func testNumberingTheModelKeptIsStripped() {
    XCTAssertEqual(SubtitleTranslator.stripNumber("2. 我们下周见"), "我们下周见")
    XCTAssertEqual(SubtitleTranslator.stripNumber("10) see you"), "see you")
    XCTAssertEqual(SubtitleTranslator.stripNumber("2025 was a good year"), "2025 was a good year")
  }

  func testLineLanguage() {
    XCTAssertEqual(SubtitleTranslator.language(of: "anything", hint: "ja"), "ja")
    XCTAssertEqual(SubtitleTranslator.language(of: "我们先看一下这个季度的预算情况"), "zh-CN")
    XCTAssertEqual(SubtitleTranslator.language(of: "Let's look at this quarter's budget first"), "en")
  }
}

/// Ported from Cicada's HeardTextTests (Swift Testing → XCTest). Lines from a recorded interview.
final class HeardTextTests: XCTestCase {
  func testCleanStrayMarks() {
    XCTAssertEqual(HeardText.clean("in.........."), "in…")
    XCTAssertEqual(HeardText.clean(", , that"), "that")
    XCTAssertEqual(
      HeardText.clean(",...... has translated at its end into infrastructure..."),
      "has translated at its end into infrastructure…")
    XCTAssertEqual(HeardText.clean(". , that is causing a product twice."), "that is causing a product twice.")
    XCTAssertEqual(HeardText.clean("that.......... in increased production"), "that… in increased production")
    XCTAssertEqual(HeardText.clean("would.. would be oversupplied."), "would… would be oversupplied.")
    XCTAssertEqual(
      HeardText.clean(", and......... in alternative infrastructure routes that let's................."),
      "and… in alternative infrastructure routes that let's…")
    XCTAssertEqual(
      HeardText.clean("whether it's in the UALE, , Saudi Arab, or the wider."),
      "whether it's in the UALE, Saudi Arab, or the wider.")
    XCTAssertEqual(HeardText.clean(",, and there should be more diversified."), "and there should be more diversified.")
    XCTAssertEqual(HeardText.clean(", you... lucrative"), "you… lucrative")
    XCTAssertEqual(HeardText.clean("of people.."), "of people…")
    // What is fine stays as it is.
    XCTAssertEqual(HeardText.clean("to over 1.4 million a day."), "to over 1.4 million a day.")
    XCTAssertEqual(HeardText.clean("The U.S. said no."), "The U.S. said no.")
    XCTAssertEqual(HeardText.clean("，，我们周四上线。。。"), "我们周四上线…")
    XCTAssertEqual(HeardText.clean("........"), "")
  }

  func testJoinOnlyWhatCarriesOn() {
    XCTAssertTrue(
      HeardText.continues(
        "that… in increased production that you would have expected at this",
        "because I think as soon as this crisis is over,", gap: 0.2, cut: true))
    XCTAssertTrue(
      HeardText.continues(
        "in, diesel and gasoline crisis in Russia that is combined with the Middle",
        "that is causing a product twice.", gap: 0.1, cut: false))
    XCTAssertTrue(
      HeardText.continues(
        "So, I think the long term headwinds for global energy markets are going to be.",
        "in the, and in the getting the tanker market back", gap: 0.3, cut: true))
    XCTAssertFalse(HeardText.continues("It's not just rhetoric.", "it costs a lot more to transport.", gap: 0.2, cut: false))
    XCTAssertFalse(HeardText.continues("are going to be.", "So the tanker market", gap: 0.2, cut: true))
    XCTAssertFalse(HeardText.continues("Is it the headlines that are moving markets?", "or is it more", gap: 0.1, cut: true))
    XCTAssertFalse(HeardText.continues("at this", "because I think", gap: 2.4, cut: true))
    XCTAssertFalse(HeardText.continues(String(repeating: "word ", count: 40), "and more", gap: 0.1, cut: true))
    XCTAssertTrue(
      HeardText.continues(String(repeating: "word ", count: 39), "and five or six more words", gap: 0.1, cut: true))
    XCTAssertTrue(HeardText.continues("我们下周", "再看这个方案", gap: 0.3, cut: true))
    XCTAssertFalse(HeardText.continues("我们下周再看。", "这个方案", gap: 0.3, cut: true))
  }

  func testJoinedText() {
    XCTAssertEqual(HeardText.join("are going to be.", "in the tanker market"), "are going to be in the tanker market")
    XCTAssertEqual(HeardText.join("at this", "because I think"), "at this because I think")
    XCTAssertEqual(HeardText.join("between…", "loading a ship."), "between… loading a ship.")
    XCTAssertEqual(HeardText.join("我们下周", "再看"), "我们下周再看")
  }
}
