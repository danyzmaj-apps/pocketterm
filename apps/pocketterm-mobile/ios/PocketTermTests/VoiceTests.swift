import PocketTermKit
import XCTest

@testable import PocketTerm

/// The phone's recognizer, played by the test: it says what [say] is given and settles it on [stop].
@MainActor
private final class FakeSpeech: SpeechSource {
  var status = SpeechCheck(.ready)
  var fixes: [SpeechFix] = []
  /// The language of each listening, in order.
  var listened: [SpeechLanguage] = []
  /// Languages it has no model for: checking one says so, with a download.
  var missing: Set<SpeechLanguage> = []
  /// Languages this phone can't recognize at all.
  var unsupported: Set<SpeechLanguage> = []
  private var out: AsyncStream<SpeechEvent>.Continuation?
  private var said = ""
  private var ended = false
  /// The sheet let go of the stream before it ended: what was heard was discarded.
  var discarded = false

  var listening: Bool { out != nil }

  nonisolated func support(_ language: SpeechLanguage) async throws -> SpeechCheck { await supportOf(language) }

  nonisolated func check(_ language: SpeechLanguage) async throws -> SpeechCheck { await checkOf(language) }

  nonisolated func listen(_ language: SpeechLanguage) -> AsyncStream<SpeechEvent> {
    let (stream, out) = AsyncStream<SpeechEvent>.makeStream()
    out.onTermination = { [weak self] why in
      guard case .cancelled = why else { return }
      Task { @MainActor in self?.letGo() }
    }
    MainActor.assumeIsolated { begin(language, out) }
    return stream
  }

  nonisolated func stop() async throws { await stopped() }

  nonisolated func fix(_ fix: SpeechFix, _ language: SpeechLanguage) async throws { await fixed(fix, language) }

  private func supportOf(_ language: SpeechLanguage) -> SpeechCheck {
    if unsupported.contains(language) { return SpeechCheck(.noLanguage) }
    if missing.contains(language) { return SpeechCheck(.noLanguage, fix: .download) }
    return SpeechCheck(.ready)
  }

  private func checkOf(_ language: SpeechLanguage) -> SpeechCheck {
    let s = supportOf(language)
    return s.ready ? status : s
  }

  private func begin(_ language: SpeechLanguage, _ out: AsyncStream<SpeechEvent>.Continuation) {
    listened.append(language)
    said = ""
    ended = false
    discarded = false
    self.out = out
  }

  private func letGo() {
    if !ended { discarded = true }
    out = nil
  }

  func say(_ text: String) {
    said = text
    out?.yield(.heard(text))
  }

  func end(_ why: SpeechEnd, message: String? = nil, status: SpeechStatus? = nil) {
    ended = true
    out?.yield(.ended(SpeechEnded(why, message: message, status: status)))
    out?.finish()
    out = nil
  }

  private func stopped() {
    out?.yield(.heard(said))
    end(.stopped)
  }

  private func fixed(_ fix: SpeechFix, _ language: SpeechLanguage) {
    fixes.append(fix)
    if fix == .download {
      missing.remove(language)
      status = SpeechCheck(.ready)
    }
  }
}

nonisolated final class VoiceTests: XCTestCase {
  /// Waits (up to 2 s) for [condition], letting the sheet's tasks run.
  @MainActor
  private func until(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<200 {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out", file: file, line: line)
  }

  /// Auto's candidates on the machine running the tests.
  @MainActor
  private var candidates: [SpeechLanguage] { SpeechLanguage.byLocales(VoiceLanguage().locales) }

  // MARK: - Pure helpers

  func testAppendSpokenPutsASpaceAfterWordsOnly() {
    XCTAssertEqual(appendSpoken("", "Add a test"), "Add a test")
    XCTAssertEqual(appendSpoken("   \n", "Add a test"), "Add a test")
    XCTAssertEqual(appendSpoken("Fix the build", "and add a test"), "Fix the build and add a test")
    XCTAssertEqual(appendSpoken("Fix the build  \n", "now"), "Fix the build now")
    XCTAssertEqual(appendSpoken("  indented", "x"), "  indented x")
  }

  func testSpeechProblemTextSaysWhatToDo() {
    XCTAssertEqual(
      speechProblemText(SpeechCheck(.denied, fix: .appSettings), .english),
      "PocketTerm isn\u{2019}t allowed to use the microphone or speech recognition. Allow them in Settings.")
    XCTAssertEqual(
      speechProblemText(SpeechCheck(.restricted), .english), "Speech recognition is turned off on this phone.")
    XCTAssertEqual(
      speechProblemText(SpeechCheck(.noLanguage, fix: .download), .croatian),
      "Croatian for speech recognition isn\u{2019}t on this phone yet. Download it once; what you say stays on the phone.")
    XCTAssertEqual(
      speechProblemText(SpeechCheck(.noLanguage, fix: .speechSettings), .english),
      "This iPhone can\u{2019}t recognize English on the device yet. Turn on Dictation in English in Settings → General "
        + "→ Keyboard, and it downloads.")
    let unsupported = "Croatian isn\u{2019}t supported for speech recognition on this phone. Tap the language above to pick another."
    XCTAssertEqual(speechProblemText(SpeechCheck(.noLanguage), .croatian), unsupported)
    XCTAssertEqual(speechProblemText(SpeechCheck(.noLanguage, fix: .appSettings), .croatian), unsupported)
    XCTAssertEqual(
      speechProblemText(SpeechCheck(.downloading), .english),
      "English for speech recognition is downloading. Try again when it\u{2019}s done.")
    let off = "This phone can\u{2019}t recognize speech on the device, so voice prompts are off here."
    XCTAssertEqual(speechProblemText(SpeechCheck(.unavailable), .english), off)
    XCTAssertEqual(speechProblemText(SpeechCheck(.ready), .english), off)
  }

  // MARK: - Auto

  @MainActor
  func testAutoTakesTheFirstLanguageThePhoneHas() async {
    let speech = FakeSpeech()
    let languages = VoiceLanguage()
    let auto = await languages.auto(speech)
    XCTAssertEqual(auto, candidates.first)
  }

  @MainActor
  func testAutoPassesOverALanguageThePhoneCannotRecognize() async {
    let speech = FakeSpeech()
    let first = candidates.first!
    speech.unsupported = [first]
    let auto = await VoiceLanguage().auto(speech)
    XCTAssertEqual(auto, candidates.count > 1 ? candidates[1] : .english)
  }

  @MainActor
  func testAutoTakesALanguageToDownloadWhenNoneIsThereAndEnglishWhenNoneCanBeHad() async {
    let speech = FakeSpeech()
    speech.missing = Set(SpeechLanguage.allCases)
    let languages = VoiceLanguage()
    let downloadable = await languages.auto(speech)
    XCTAssertEqual(downloadable, candidates.first)
    speech.missing = []
    speech.unsupported = Set(SpeechLanguage.allCases)
    let none = await languages.auto(speech)
    XCTAssertEqual(none, .english)
  }

  @MainActor
  func testAutoPassesOverALanguageFoundMissingWhenListening() async {
    let speech = FakeSpeech()
    let languages = VoiceLanguage()
    let first = candidates.first!
    languages.missed(first)
    let auto = await languages.auto(speech)
    XCTAssertEqual(auto, candidates.count > 1 ? candidates[1] : .english)
    // Choosing again forgets it.
    languages.choose(nil)
    let again = await languages.auto(speech)
    XCTAssertEqual(again, first)
  }

  // MARK: - The sheet

  @MainActor
  func testTapListensUntilStopThenTheEditedTextIsSent() async {
    let speech = FakeSpeech()
    let model = VoiceSheetModel(source: speech, existing: "", languages: VoiceLanguage())
    var result: VoiceResult?
    model.onClose = { result = $0 }
    model.begin()
    await until { model.phase == .listening && speech.listening }
    speech.say("Add a dark mode")
    await until { model.heard == "Add a dark mode" }
    XCTAssertEqual(model.title, "Listening")
    await model.stop()
    await until { model.phase == .review }
    XCTAssertEqual(model.edit, "Add a dark mode")
    XCTAssertNil(model.note)
    model.edit = "Add a dark mode toggle "
    model.finish(send: true)
    XCTAssertEqual(result, VoiceResult(text: "Add a dark mode toggle", send: true))
    XCTAssertFalse(speech.discarded)
  }

  @MainActor
  func testKeepTalkingAddsTheNewWordsAfterTheEditedOnes() async {
    let speech = FakeSpeech()
    let model = VoiceSheetModel(source: speech, existing: "typed", languages: VoiceLanguage())
    model.begin()
    await until { speech.listening }
    speech.say("one")
    await model.stop()
    await until { model.phase == .review }
    model.edit = "one, edited"
    model.keepTalking()
    await until { model.phase == .listening && speech.listening }
    speech.say("two")
    await until { model.heard == "one, edited two" }
    XCTAssertEqual(model.existing, "typed")
  }

  @MainActor
  func testHoldLiftStopsAndSlidingAwayCancels() async {
    let speech = FakeSpeech()
    let hold = VoiceHold()
    let model = VoiceSheetModel(source: speech, existing: "", hold: hold, languages: VoiceLanguage())
    model.begin()
    await until { speech.listening }
    XCTAssertTrue(model.held)
    speech.say("held words")
    hold.release()
    await until { model.phase == .review }
    XCTAssertEqual(model.edit, "held words")

    let speech2 = FakeSpeech()
    let hold2 = VoiceHold()
    let cancelled = VoiceSheetModel(source: speech2, existing: "", hold: hold2, languages: VoiceLanguage())
    var closedWith: VoiceResult?? = .none
    cancelled.onClose = { closedWith = .some($0) }
    cancelled.begin()
    await until { speech2.listening }
    speech2.say("never mind")
    hold2.setAway(true)
    XCTAssertEqual(cancelled.title, "Release to cancel")
    hold2.release()
    XCTAssertEqual(closedWith, .some(nil))
    await until { speech2.discarded }
  }

  @MainActor
  func testARefusedMicrophoneSaysSoAndOpensSettings() async {
    let speech = FakeSpeech()
    speech.status = SpeechCheck(.denied, fix: .appSettings)
    let model = VoiceSheetModel(source: speech, existing: "", languages: VoiceLanguage())
    model.begin()
    await until { model.phase == .problem }
    XCTAssertEqual(model.problemAction?.label, "Open Settings")
    await model.runProblemAction()
    XCTAssertEqual(speech.fixes, [.appSettings])
    XCTAssertTrue(speech.listened.isEmpty)
  }

  @MainActor
  func testAMissingLanguageDownloadsThenListens() async {
    let speech = FakeSpeech()
    let languages = VoiceLanguage()
    languages.choose(.english)
    defer { languages.choose(nil) }
    speech.missing = [.english]
    let model = VoiceSheetModel(source: speech, existing: "", languages: languages)
    model.begin()
    await until { model.phase == .problem }
    XCTAssertEqual(model.problemAction?.label, "Download")
    await model.runProblemAction()
    await until { model.phase == .listening }
    XCTAssertEqual(speech.fixes, [.download])
    XCTAssertEqual(speech.listened, [.english])
  }

  @MainActor
  func testSwitchingLanguageWhileListeningKeepsTheWords() async {
    let speech = FakeSpeech()
    let languages = VoiceLanguage()
    languages.choose(.english)
    defer { languages.choose(nil) }
    let model = VoiceSheetModel(source: speech, existing: "", languages: languages)
    model.begin()
    await until { speech.listening }
    speech.say("Hello")
    await until { model.heard == "Hello" }
    model.switchLanguage()
    await until { speech.listened.count == 2 && model.phase == .listening }
    XCTAssertEqual(speech.listened, [.english, .croatian])
    XCTAssertEqual(languages.choice, .croatian)
    speech.say("svijete")
    await until { model.heard == "Hello svijete" }
  }

  @MainActor
  func testACallTakingTheMicrophoneKeepsWhatWasSaid() async {
    let speech = FakeSpeech()
    let model = VoiceSheetModel(source: speech, existing: "", languages: VoiceLanguage())
    model.begin()
    await until { speech.listening }
    speech.say("half a thought")
    speech.end(.interrupted)
    await until { model.phase == .review }
    XCTAssertEqual(model.edit, "half a thought")
    XCTAssertEqual(model.note, "Stopped: something else took the microphone.")
  }

  @MainActor
  func testEnglishFoundMissingOnlyWhenListeningSaysSo() async {
    let speech = FakeSpeech()
    let languages = VoiceLanguage()
    languages.choose(.english)
    defer { languages.choose(nil) }
    let model = VoiceSheetModel(source: speech, existing: "", languages: languages)
    model.begin()
    await until { speech.listening }
    speech.end(.error, message: "no model", status: .noLanguage)
    await until { model.phase == .problem }
    XCTAssertEqual(model.problem, SpeechCheck(.noLanguage, fix: .speechSettings))
  }

  // MARK: - ScriptedSpeech

  func testScriptedSpeechSaysAWordEveryThirdTick() {
    let words = ["Hi", "there"]
    XCTAssertEqual(ScriptedSpeech.events(tick: 1, words: words).count, 1)
    XCTAssertEqual(ScriptedSpeech.events(tick: 3, words: words).last, .heard("Hi"))
    XCTAssertEqual(ScriptedSpeech.events(tick: 6, words: words).last, .heard("Hi there"))
    // Said it all: quiet, and nothing new.
    XCTAssertEqual(ScriptedSpeech.events(tick: 7, words: words), [.level(0.04)])
    XCTAssertEqual(ScriptedSpeech.events(tick: 9, words: words), [.level(0.04)])
    if case .level(let l) = ScriptedSpeech.events(tick: 2, words: words)[0] {
      XCTAssertGreaterThanOrEqual(l, 0.45)
    } else {
      XCTFail("a loudness first")
    }
  }

  @MainActor
  func testScriptedSpeechSpeaksTheLanguageAndSettlesOnStop() async throws {
    XCTAssertEqual(ScriptedSpeech.sentence.joined(separator: " "), "Add a dark mode toggle to the settings page and write a test for it.")
    XCTAssertEqual(ScriptedSpeech.croatian.joined(separator: " "), "Dodaj tamni na\u{10D}in rada u postavke i napi\u{161}i test za to.")
    let speech = ScriptedSpeech(words: ["Hi", "there"], every: .milliseconds(5))
    var events: [SpeechEvent] = []
    let stream = speech.listen(.english)
    for await e in stream {
      events.append(e)
      if e == .heard("Hi there") { try await speech.stop() }
    }
    XCTAssertEqual(events.suffix(2), [.heard("Hi there"), .ended(SpeechEnded(.stopped))])
  }

  // MARK: - Tips

  func testTipsShowInTourOrderOnlyOnceAnswered() async {
    let tip = await MainActor.run { () -> (AppTip?, AppTip?, AppTip?, AppTip?) in
      let none: (AppTip) -> Bool = { _ in false }
      return (
        TipStage.next(present: [.slash, .projectHeading, .follow], seen: none, answered: true),
        TipStage.next(present: [.slash, .projectHeading], seen: { $0 == .projectHeading }, answered: true),
        TipStage.next(present: [.newSession, .switchOpen], seen: none, answered: true),
        TipStage.next(present: [.slash], seen: none, answered: false)
      )
    }
    XCTAssertEqual(tip.0, .projectHeading)
    XCTAssertEqual(tip.1, .slash)
    XCTAssertEqual(tip.2, .switchOpen)
    XCTAssertNil(tip.3)
  }

  @MainActor
  func testTipStageShowsOneTipAtATimeAndTheNextOnceSeen() async {
    let defaults = UserDefaults(suiteName: "VoiceTests-\(UUID().uuidString)")!
    let tips = TipsController(prefs: Preferences(defaults), startSeen: false)
    tips.answer(tour: true)
    let stage = TipStage.shared
    stage.attach(tips)
    stage.register(.slash)
    stage.register(.projectHeading)
    defer {
      stage.unregister(.slash)
      stage.unregister(.projectHeading)
    }
    await until { stage.showing == .projectHeading }
    stage.gotIt(.projectHeading)
    await until { stage.showing == .slash }
    XCTAssertTrue(tips.seen(.projectHeading))
    // Show tips again: the first one shows again.
    tips.reset()
    await until { stage.showing == .projectHeading }
  }
}
