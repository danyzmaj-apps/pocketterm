import AVFoundation
import PocketTermKit
import Speech
import UIKit

/// The composer's microphone ([SpeechSource]): speech to text in the language asked for (`en` or `hr`), on the
/// iPhone only, never on Apple's servers. iOS 26 and later: SpeechAnalyzer with SpeechTranscriber, made for long
/// dictation, its volatile results the live text. Before (or on hardware SpeechTranscriber doesn't run on):
/// SFSpeechRecognizer with requiresOnDeviceRecognition, a new request taking over before Apple's per-request limit.
///
/// A stream per listening: `.heard`, `.level` (0…1), then `.ended` (stopped, interrupted, error) and the stream's
/// end. Cancelling its consumer discards what was heard and stops the microphone at once.
@MainActor
final class Dictation: SpeechSource {
  private let engine = AVAudioEngine()
  private var recognizer: Recognizer?
  private var sink: AsyncStream<SpeechEvent>.Continuation?
  /// Which listening the microphone belongs to now: one cancelled or replaced meanwhile doesn't start.
  private var token: UUID?
  /// Listenings let go of before they started.
  private var dropped: Set<UUID> = []
  private var listening = false
  private var observers: [NSObjectProtocol] = []
  private var lastLevel: CFTimeInterval = 0

  /// The locale for [code] (a SpeechLanguage.code): English British when the phone's first English language is,
  /// else American; Croatian hr-HR.
  nonisolated static func locale(_ code: String) -> Locale {
    if code == "hr" { return Locale(identifier: "hr-HR") }
    let first = Locale.preferredLanguages.first { $0.hasPrefix("en") }
    let region = first.map { Locale(identifier: $0).region?.identifier } ?? Locale.current.region?.identifier
    return Locale(identifier: region == "GB" ? "en-GB" : "en-US")
  }

  @available(iOS 26.0, *)
  fileprivate static func transcriber(_ locale: Locale) -> SpeechTranscriber {
    // Volatile results: the words being said show at once and settle as the transcriber is sure of them. Fast
    // results: it guesses after each word instead of waiting for a pause, so the text keeps up with the voice.
    SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
  }

  /// SpeechTranscriber runs on this iPhone (iOS 26, and hardware it supports).
  private static var modern: Bool {
    if #available(iOS 26.0, *) { return SpeechTranscriber.isAvailable }
    return false
  }

  // MARK: - SpeechSource

  nonisolated func check(_ language: SpeechLanguage) async throws -> SpeechCheck {
    await status(Self.locale(language.code))
  }

  nonisolated func support(_ language: SpeechLanguage) async throws -> SpeechCheck {
    await Self.plan(Self.locale(language.code)).check
  }

  nonisolated func listen(_ language: SpeechLanguage) -> AsyncStream<SpeechEvent> {
    let (stream, out) = AsyncStream<SpeechEvent>.makeStream()
    let token = UUID()
    let locale = Self.locale(language.code)
    out.onTermination = { [weak self] why in
      // Closed or cancelled: what was heard goes, and the microphone stops now.
      guard case .cancelled = why else { return }
      Task { @MainActor in self?.cancel(token) }
    }
    Task { @MainActor in await self.start(token, locale: locale, out: out) }
    return stream
  }

  nonisolated func stop() async throws {
    await finish(.stopped)
  }

  nonisolated func fix(_ fix: SpeechFix, _ language: SpeechLanguage) async throws {
    switch fix {
    case .download:
      guard #available(iOS 26.0, *) else { return }
      try await Self.download(Self.locale(language.code))
    case .appSettings, .speechSettings:
      // iOS has no link to its dictation languages: PocketTerm's own page has the microphone and speech switches.
      await MainActor.run {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
      }
    }
  }

  // MARK: - Checks

  /// How [wanted] is recognized on this iPhone: its check (ready, downloading, or noLanguage with the fix:
  /// download for SpeechTranscriber's model, speechSettings for Dictation's language, none when the iPhone can't
  /// at all), and the SpeechTranscriber locale when SpeechAnalyzer does it. A language SpeechTranscriber hasn't
  /// got, or hasn't downloaded, that SFSpeechRecognizer has on the device goes to SFSpeechRecognizer.
  static func plan(_ wanted: Locale) async -> (check: SpeechCheck, modern: Locale?) {
    let legacy = SFSpeechRecognizer(locale: wanted)
    let legacyOnDevice = legacy?.supportsOnDeviceRecognition ?? false
    if #available(iOS 26.0, *), modern, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
      switch await AssetInventory.status(forModules: [transcriber(locale)]) {
      case .installed: return (SpeechCheck(.ready), locale)
      case .downloading: return (SpeechCheck(legacyOnDevice ? .ready : .downloading), nil)
      case .supported: return (legacyOnDevice ? SpeechCheck(.ready) : SpeechCheck(.noLanguage, fix: .download), nil)
      default: break
      }
    }
    guard legacy != nil else { return (SpeechCheck(.noLanguage), nil) }
    // A language for the device comes with Dictation's languages (Settings → General → Keyboard).
    return (legacyOnDevice ? SpeechCheck(.ready) : SpeechCheck(.noLanguage, fix: .speechSettings), nil)
  }

  @available(iOS 26.0, *)
  private static func download(_ wanted: Locale) async throws {
    do {
      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? wanted
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(locale)]) {
        try await request.downloadAndInstall()
      }
    } catch {
      throw DictationError(error.localizedDescription)
    }
  }

  private func status(_ wanted: Locale) async -> SpeechCheck {
    let denied = SpeechCheck(.denied, fix: .appSettings)
    switch AVAudioApplication.shared.recordPermission {
    case .denied: return denied
    case .undetermined:
      if !(await AVAudioApplication.requestRecordPermission()) { return denied }
    default: break
    }
    let plan = await Self.plan(wanted)
    // SpeechAnalyzer needs only the microphone; SFSpeechRecognizer also speech recognition's permission.
    if !plan.check.ready || plan.modern != nil { return plan.check }
    var auth = SFSpeechRecognizer.authorizationStatus()
    if auth == .notDetermined { auth = await Self.requestSpeechAuthorization() }
    switch auth {
    case .authorized: return SpeechCheck(.ready)
    case .restricted: return SpeechCheck(.restricted)
    default: return denied
    }
  }

  /// Speech recognition's permission; its answer comes on a queue of its own, so not on the main actor.
  nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
  }

  // MARK: - Listening

  private func start(_ token: UUID, locale: Locale, out: AsyncStream<SpeechEvent>.Continuation) async {
    if dropped.remove(token) != nil { return out.finish() }
    // A new listening takes over the microphone from one still going.
    if self.token != nil { cancel(self.token!) }
    self.token = token
    sink = out
    var engineName = "SFSpeechRecognizer"
    do {
      let session = AVAudioSession.sharedInstance()
      // Recording ducks or pauses what else plays; deactivating with notifyOthersOnDeactivation lets it resume.
      try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
      // Else iOS mutes the start and stop haptics while recording.
      try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError("No microphone") }
      let onText: (String) -> Void = { [weak self] text in
        guard let self, self.token == token else { return }
        self.sink?.yield(.heard(text.trimmingCharacters(in: .whitespacesAndNewlines)))
      }
      let rec: Recognizer
      if #available(iOS 26.0, *), let modern = await Self.plan(locale).modern {
        engineName = "SpeechAnalyzer"
        rec = try await ModernRecognizer.make(locale: modern, natural: format, onText: onText)
      } else {
        rec = try LegacyRecognizer(locale: locale, onText: onText) { [weak self] message in
          guard let self, self.token == token else { return }
          NSLog("PocketTerm: dictation (SFSpeechRecognizer): \(message)")
          self.recognizer = nil
          self.stopAudio()
          self.end(.error, message: message)
        }
      }
      guard self.token == token, sink != nil else {
        rec.cancel()
        stopAudio()
        return
      }
      recognizer = rec
      let level: @Sendable (Double) -> Void = { [weak self] level in
        Task { @MainActor in self?.level(level, token) }
      }
      input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(rec, level: level))
      engine.prepare()
      try engine.start()
      listening = true
      observe()
    } catch {
      guard self.token == token else { return }
      NSLog("PocketTerm: dictation (\(engineName)) didn't start: \(error)")
      recognizer?.cancel()
      recognizer = nil
      stopAudio()
      end(.error, message: error.localizedDescription)
    }
  }

  /// The microphone's tap: runs on the audio thread, so built away from the main actor.
  nonisolated private static func tap(_ rec: Recognizer, level: @escaping @Sendable (Double) -> Void)
    -> AVAudioNodeTapBlock
  {
    { buffer, _ in
      rec.append(buffer)
      if let l = loudness(buffer) { level(l) }
    }
  }

  /// The buffer's loudness, -50 dB (quiet room) to -10 dB (close speech) as 0…1.
  nonisolated private static func loudness(_ buffer: AVAudioPCMBuffer) -> Double? {
    guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
    let n = Int(buffer.frameLength)
    var sum: Float = 0
    for i in 0..<n { sum += data[i] * data[i] }
    let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
    return Double(min(max((db + 50) / 40, 0), 1))
  }

  /// [level] for the listening [token], at most 20 times a second.
  private func level(_ level: Double, _ token: UUID) {
    guard listening, self.token == token else { return }
    let now = CACurrentMediaTime()
    guard now - lastLevel >= 0.05 else { return }
    lastLevel = now
    sink?.yield(.level(level))
  }

  /// A call, Siri, an alarm or a route change (headphones out) takes the microphone: it stops, keeping what was
  /// said.
  private func observe() {
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    observers = [
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) {
        [weak self] note in
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
        MainActor.assumeIsolated { self?.finish(.interrupted) }
      },
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.finish(.interrupted) }
      },
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.finish(.interrupted) }
      },
    ]
  }

  /// Stops the microphone, lets the recognizer settle the last words, then ends the stream.
  private func finish(_ why: SpeechEnd) {
    guard listening, let rec = recognizer, let mine = token else { return }
    listening = false
    stopAudio()
    rec.finish { [weak self] in
      guard let self, self.token == mine else { return }
      self.recognizer = nil
      self.end(why)
    }
  }

  private func end(_ why: SpeechEnd, message: String? = nil) {
    listening = false
    token = nil
    sink?.yield(.ended(SpeechEnded(why, message: message)))
    sink?.finish()
    sink = nil
  }

  /// The listening [token]'s stream was let go of: what was heard goes, and the microphone stops now.
  private func cancel(_ token: UUID) {
    guard self.token == token else {
      // Not started yet (a listening that ended or was taken over has finished its stream): it won't start.
      dropped.insert(token)
      return
    }
    self.token = nil
    let out = sink
    sink = nil
    listening = false
    recognizer?.cancel()
    recognizer = nil
    stopAudio()
    out?.finish()
  }

  private func stopAudio() {
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers = []
    engine.inputNode.removeTap(onBus: 0)
    if engine.isRunning { engine.stop() }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

struct DictationError: LocalizedError {
  init(_ message: String) { errorDescription = message }
  var errorDescription: String?
}

/// One listening's recognizer, fed the microphone's buffers.
@MainActor
private protocol Recognizer: AnyObject, Sendable {
  /// From the audio thread.
  nonisolated func append(_ buffer: AVAudioPCMBuffer)
  /// No more audio: settles the last words (its last onText), then [done].
  func finish(_ done: @escaping () -> Void)
  func cancel()
}

/// [a] then [b], a space between them unless one is there.
nonisolated private func joined(_ a: String, _ b: String) -> String {
  if a.isEmpty || b.isEmpty || a.last!.isWhitespace || b.first!.isWhitespace { return a + b }
  return a + " " + b
}

@available(iOS 26.0, *)
@MainActor
private final class ModernRecognizer: Recognizer {
  private let analyzer: SpeechAnalyzer
  /// Read on the audio thread; never changed after it's made.
  nonisolated private let format: AVAudioFormat
  nonisolated private let converter: AVAudioConverter
  nonisolated private let input: AsyncStream<AnalyzerInput>.Continuation
  private let onText: (String) -> Void
  private var results: Task<Void, Never>?
  /// Settled words, and the ones still changing after them.
  private var settled = ""
  private var volatile = ""

  private init(
    analyzer: SpeechAnalyzer, format: AVAudioFormat, converter: AVAudioConverter,
    input: AsyncStream<AnalyzerInput>.Continuation, onText: @escaping (String) -> Void
  ) {
    self.analyzer = analyzer
    self.format = format
    self.converter = converter
    self.input = input
    self.onText = onText
  }

  static func make(locale: Locale, natural: AVAudioFormat, onText: @escaping (String) -> Void) async throws
    -> ModernRecognizer
  {
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
    let transcriber = Dictation.transcriber(locale)
    // The analyzer takes one format and converts nothing itself: the microphone's buffers are converted to it.
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: natural),
      let converter = AVAudioConverter(from: natural, to: format)
    else { throw DictationError("This iPhone's microphone format can't be recognized") }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: format)
    let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
    let r = ModernRecognizer(analyzer: analyzer, format: format, converter: converter, input: input, onText: onText)
    r.results = Task { @MainActor in
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          if result.isFinal {
            r.settled = joined(r.settled, text)
            r.volatile = ""
          } else {
            r.volatile = text
          }
          r.onText(joined(r.settled, r.volatile))
        }
      } catch {}
    }
    try await analyzer.start(inputSequence: stream)
    return r
  }

  nonisolated func append(_ buffer: AVAudioPCMBuffer) {
    // Converted into a buffer of its own: the tap reuses its buffers once this returns.
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
    let feed = Feed(buffer)
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      guard let next = feed.take() else {
        status.pointee = .noDataNow
        return nil
      }
      status.pointee = .haveData
      return next
    }
    if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
  }

  func finish(_ done: @escaping () -> Void) {
    input.finish()
    Task { @MainActor in
      try? await self.analyzer.finalizeAndFinishThroughEndOfInput()
      await self.results?.value
      self.onText(joined(self.settled, self.volatile))
      done()
    }
  }

  func cancel() {
    input.finish()
    results?.cancel()
    let analyzer = self.analyzer
    Task { await analyzer.cancelAndFinishNow() }
  }
}

/// The one buffer a conversion is given, once; used on the audio thread only.
nonisolated private final class Feed: @unchecked Sendable {
  private var buffer: AVAudioPCMBuffer?
  init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

  func take() -> AVAudioPCMBuffer? {
    defer { buffer = nil }
    return buffer
  }
}

/// SFSpeechRecognizer on the device. Apple ends a recognition request after about a minute (and on-device ones
/// at a long pause), so a new request takes over every 50 s, or as soon as one ends by itself: each request's
/// words go in a segment of their own, and the text is all of them.
@MainActor
private final class LegacyRecognizer: Recognizer {
  private let recognizer: SFSpeechRecognizer
  private let onText: (String) -> Void
  private let onFail: (String) -> Void
  private var segments: [String] = []
  /// The request the microphone feeds; the audio thread reads it, under [lock].
  nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
  nonisolated private let lock = NSLock()
  private var tasks: [SFSpeechRecognitionTask] = []
  private var rotation: Task<Void, Never>?
  private var startedAt = Date()
  /// Requests in a row that ended within a second: the recognizer is failing, not resting.
  private var quickEnds = 0
  private var finishing: (() -> Void)?

  init(locale: Locale, onText: @escaping (String) -> Void, onFail: @escaping (String) -> Void) throws {
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
      let code = locale.language.languageCode?.identifier ?? ""
      let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "this language"
      throw DictationError("This iPhone can't recognize \(name) on the device")
    }
    self.recognizer = recognizer
    self.onText = onText
    self.onFail = onFail
    begin()
  }

  private var text: String { segments.reduce("") { joined($0, $1) } }

  private func begin() {
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.requiresOnDeviceRecognition = true
    req.shouldReportPartialResults = true
    req.taskHint = .dictation
    req.addsPunctuation = true
    let index = segments.count
    let id = ObjectIdentifier(req)
    segments.append("")
    startedAt = Date()
    // Results come on the main queue (SFSpeechRecognizer's default).
    tasks.append(
      recognizer.recognitionTask(with: req) { [weak self] result, error in
        let text = result?.bestTranscription.formattedString
        let final = result?.isFinal ?? false
        let failure = error?.localizedDescription
        MainActor.assumeIsolated { self?.update(index, id, text, final: final, failure: failure) }
      })
    lock.withLock { request = req }
    rotation?.cancel()
    rotation = Task { [weak self] in
      try? await Task.sleep(for: .seconds(50))
      if !Task.isCancelled { self?.rotate() }
    }
  }

  /// The request in use stops taking audio (its last words still land in its segment) and a new one starts.
  private func rotate() {
    guard finishing == nil else { return }
    takeRequest()?.endAudio()
    begin()
  }

  private func takeRequest() -> SFSpeechAudioBufferRecognitionRequest? {
    lock.withLock {
      defer { request = nil }
      return request
    }
  }

  private func isCurrent(_ id: ObjectIdentifier) -> Bool {
    lock.withLock { request.map(ObjectIdentifier.init) == id }
  }

  private func update(_ index: Int, _ id: ObjectIdentifier, _ heard: String?, final: Bool, failure: String?) {
    if let heard {
      segments[index] = heard
      onText(text)
    }
    guard failure != nil || final else { return }
    let last = index == segments.count - 1
    if let done = finishing {
      if last {
        finishing = nil
        onText(text)
        done()
      }
      return
    }
    guard last, isCurrent(id) else { return }
    // Ended by itself while the person still talks to it (a pause, its limit, a hiccup): a new request goes on.
    quickEnds = Date().timeIntervalSince(startedAt) < 1 ? quickEnds + 1 : 0
    if quickEnds >= 3 {
      rotation?.cancel()
      _ = takeRequest()
      return onFail(failure ?? "Speech recognition stopped")
    }
    _ = takeRequest()
    begin()
  }

  nonisolated func append(_ buffer: AVAudioPCMBuffer) {
    lock.withLock { request?.append(buffer) }
  }

  func finish(_ done: @escaping () -> Void) {
    rotation?.cancel()
    finishing = done
    takeRequest()?.endAudio()
    // A recognizer that never answers still ends the listening with what it heard.
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, let done = self.finishing else { return }
      self.finishing = nil
      for t in self.tasks { t.cancel() }
      done()
    }
  }

  func cancel() {
    rotation?.cancel()
    finishing = nil
    _ = takeRequest()
    for t in tasks { t.cancel() }
    tasks = []
  }
}
