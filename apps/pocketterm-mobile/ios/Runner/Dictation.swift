import AVFoundation
import Flutter
import Speech

/// The composer's microphone (packages/pocketterm_core/lib/speech.dart): speech to text in the language Dart asks
/// for (`en` or `hr`), on the iPhone only,
/// never on Apple's servers. iOS 26 and later: SpeechAnalyzer with SpeechTranscriber, made for long dictation, its
/// volatile results the live text. Before (or on hardware SpeechTranscriber doesn't run on): SFSpeechRecognizer
/// with requiresOnDeviceRecognition, a new request taking over before Apple's per-request limit.
///
/// Methods (from AppDelegate's channel): speechCheck {language} → {status, fix?}, speechStop, speechFix {fix,
/// language}. Events on `pocketterm/speech`, listened to with {language}, a stream per listening: {type: heard,
/// text}, {type: level, level 0…1}, then {type: ended, why: stopped|interrupted|error, message?} and the stream's
/// end. Cancelling it discards.
final class Dictation: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private let engine = AVAudioEngine()
  private var recognizer: Recognizer?
  private var listening = false
  /// Which listening the async start belongs to: one cancelled meanwhile doesn't start.
  private var generation = 0
  private var observers: [NSObjectProtocol] = []
  private var lastLevel: CFTimeInterval = 0

  /// The locale for [code] (a SpeechLanguage.code): English British when the phone's first English language is,
  /// else American; Croatian hr-HR.
  static func locale(_ code: String?) -> Locale {
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

  // MARK: - Methods

  func check(_ args: [String: Any], result: @escaping FlutterResult) {
    let locale = Self.locale(args["language"] as? String)
    Task { @MainActor in result(await self.status(locale)) }
  }

  /// speechSupport: whether the language can be recognized on this iPhone, asking for no permission.
  func support(_ args: [String: Any], result: @escaping FlutterResult) {
    let locale = Self.locale(args["language"] as? String)
    Task { @MainActor in result(await Self.plan(locale).status) }
  }

  /// How [wanted] is recognized on this iPhone: its status (ready, downloading, or noLanguage with the fix:
  /// download for SpeechTranscriber's model, speechSettings for Dictation's language, none when the iPhone can't
  /// at all), and the SpeechTranscriber locale when SpeechAnalyzer does it. A language SpeechTranscriber hasn't
  /// got, or hasn't downloaded, that SFSpeechRecognizer has on the device goes to SFSpeechRecognizer.
  @MainActor static func plan(_ wanted: Locale) async -> (status: [String: Any], modern: Locale?) {
    let legacy = SFSpeechRecognizer(locale: wanted)
    let legacyOnDevice = legacy?.supportsOnDeviceRecognition ?? false
    if #available(iOS 26.0, *), modern, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
      switch await AssetInventory.status(forModules: [transcriber(locale)]) {
      case .installed: return (["status": "ready"], locale)
      case .downloading: return legacyOnDevice ? (["status": "ready"], nil) : (["status": "downloading"], nil)
      case .supported:
        return legacyOnDevice ? (["status": "ready"], nil) : (["status": "noLanguage", "fix": "download"], nil)
      default: break
      }
    }
    guard legacy != nil else { return (["status": "noLanguage"], nil) }
    // A language for the device comes with Dictation's languages (Settings → General → Keyboard).
    return legacyOnDevice ? (["status": "ready"], nil) : (["status": "noLanguage", "fix": "speechSettings"], nil)
  }

  func stop(result: @escaping FlutterResult) {
    result(nil)
    finish("stopped")
  }

  func fix(_ args: [String: Any], result: @escaping FlutterResult) {
    switch args["fix"] as? String {
    case "download":
      guard #available(iOS 26.0, *) else { return result(nil) }
      Task { @MainActor in
        do {
          let wanted = Self.locale(args["language"] as? String)
          let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? wanted
          if let request = try await AssetInventory.assetInstallationRequest(supporting: [Self.transcriber(locale)]) {
            try await request.downloadAndInstall()
          }
          result(nil)
        } catch {
          result(FlutterError(code: "download", message: error.localizedDescription, details: nil))
        }
      }
    default:
      // iOS has no link to its dictation languages: PocketTerm's own page has the microphone and speech switches.
      if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
      result(nil)
    }
  }

  @MainActor private func status(_ wanted: Locale) async -> [String: Any] {
    let denied: [String: Any] = ["status": "denied", "fix": "appSettings"]
    switch AVAudioApplication.shared.recordPermission {
    case .denied: return denied
    case .undetermined:
      if !(await AVAudioApplication.requestRecordPermission()) { return denied }
    default: break
    }
    let plan = await Self.plan(wanted)
    // SpeechAnalyzer needs only the microphone; SFSpeechRecognizer also speech recognition's permission.
    if plan.status["status"] as? String != "ready" || plan.modern != nil { return plan.status }
    var auth = SFSpeechRecognizer.authorizationStatus()
    if auth == .notDetermined {
      auth = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
    }
    switch auth {
    case .authorized: return ["status": "ready"]
    case .restricted: return ["status": "restricted"]
    default: return denied
    }
  }

  // MARK: - Listening

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    generation += 1
    let mine = generation
    let locale = Self.locale((arguments as? [String: Any])?["language"] as? String)
    Task { @MainActor in await self.start(mine, locale: locale) }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    // Closed or cancelled: what was heard goes, and the microphone stops now.
    generation += 1
    sink = nil
    listening = false
    recognizer?.cancel()
    recognizer = nil
    stopAudio()
    return nil
  }

  @MainActor private func start(_ mine: Int, locale: Locale) async {
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
        guard let self, self.generation == mine else { return }
        self.sink?(["type": "heard", "text": text.trimmingCharacters(in: .whitespacesAndNewlines)])
      }
      let rec: Recognizer
      if #available(iOS 26.0, *), let modern = await Self.plan(locale).modern {
        engineName = "SpeechAnalyzer"
        rec = try await ModernRecognizer.make(locale: modern, natural: format, onText: onText)
      } else {
        rec = try LegacyRecognizer(locale: locale, onText: onText) { [weak self] message in
          guard let self, self.generation == mine else { return }
          NSLog("PocketTerm: dictation (SFSpeechRecognizer): \(message)")
          self.recognizer = nil
          self.stopAudio()
          self.end("error", message: message)
        }
      }
      guard generation == mine, sink != nil else {
        rec.cancel()
        stopAudio()
        return
      }
      recognizer = rec
      input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
        rec.append(buffer)
        self?.level(buffer)
      }
      engine.prepare()
      try engine.start()
      listening = true
      observe()
    } catch {
      guard generation == mine else { return }
      NSLog("PocketTerm: dictation (\(engineName)) didn't start: \(error)")
      recognizer?.cancel()
      recognizer = nil
      stopAudio()
      end("error", message: error.localizedDescription)
    }
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
        if raw == AVAudioSession.InterruptionType.began.rawValue { self?.finish("interrupted") }
      },
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
        self?.finish("interrupted")
      },
      center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) {
        [weak self] _ in self?.finish("interrupted")
      },
    ]
  }

  /// Stops the microphone, lets the recognizer settle the last words, then ends the stream.
  private func finish(_ why: String) {
    guard listening, let rec = recognizer else { return }
    listening = false
    stopAudio()
    let mine = generation
    rec.finish { [weak self] in
      guard let self, self.generation == mine else { return }
      self.recognizer = nil
      self.end(why)
    }
  }

  private func end(_ why: String, message: String? = nil) {
    listening = false
    var event: [String: Any] = ["type": "ended", "why": why]
    if let message { event["message"] = message }
    sink?(event)
    sink?(FlutterEndOfEventStream)
    sink = nil
  }

  private func stopAudio() {
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers = []
    engine.inputNode.removeTap(onBus: 0)
    if engine.isRunning { engine.stop() }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// The buffer's loudness, -50 dB (quiet room) to -10 dB (close speech) as 0…1, at most 20 times a second.
  private func level(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
    let n = Int(buffer.frameLength)
    var sum: Float = 0
    for i in 0..<n { sum += data[i] * data[i] }
    let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
    let level = Double(min(max((db + 50) / 40, 0), 1))
    DispatchQueue.main.async { [weak self] in
      guard let self, self.listening else { return }
      let now = CACurrentMediaTime()
      guard now - self.lastLevel >= 0.05 else { return }
      self.lastLevel = now
      self.sink?(["type": "level", "level": level])
    }
  }
}

struct DictationError: LocalizedError {
  init(_ message: String) { errorDescription = message }
  var errorDescription: String?
}

/// One listening's recognizer, fed the microphone's buffers.
private protocol Recognizer: AnyObject {
  /// From the audio thread.
  func append(_ buffer: AVAudioPCMBuffer)
  /// No more audio: settles the last words (its last onText), then [done], on the main thread.
  func finish(_ done: @escaping () -> Void)
  func cancel()
}

/// [a] then [b], a space between them unless one is there.
private func joined(_ a: String, _ b: String) -> String {
  if a.isEmpty || b.isEmpty || a.last!.isWhitespace || b.first!.isWhitespace { return a + b }
  return a + " " + b
}

@available(iOS 26.0, *)
private final class ModernRecognizer: Recognizer {
  private let analyzer: SpeechAnalyzer
  private let format: AVAudioFormat
  private let converter: AVAudioConverter
  private let input: AsyncStream<AnalyzerInput>.Continuation
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

  @MainActor static func make(locale: Locale, natural: AVAudioFormat, onText: @escaping (String) -> Void) async throws
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

  func append(_ buffer: AVAudioPCMBuffer) {
    // Converted into a buffer of its own: the tap reuses its buffers once this returns.
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
    var given = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if given {
        status.pointee = .noDataNow
        return nil
      }
      given = true
      status.pointee = .haveData
      return buffer
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
    Task { await self.analyzer.cancelAndFinishNow() }
  }
}

/// SFSpeechRecognizer on the device. Apple ends a recognition request after about a minute (and on-device ones
/// at a long pause), so a new request takes over every 50 s, or as soon as one ends by itself: each request's
/// words go in a segment of their own, and the text is all of them.
private final class LegacyRecognizer: Recognizer {
  private let recognizer: SFSpeechRecognizer
  private let onText: (String) -> Void
  private let onFail: (String) -> Void
  private var segments: [String] = []
  /// The request the microphone feeds; the audio thread reads it.
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private let lock = NSLock()
  private var tasks: [SFSpeechRecognitionTask] = []
  private var rotation: Timer?
  private var startedAt = Date()
  /// Requests in a row that ended within a second: the recognizer is failing, not resting.
  private var quickEnds = 0
  private var finishing: (() -> Void)?

  init(locale: Locale, onText: @escaping (String) -> Void, onFail: @escaping (String) -> Void) throws {
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
      throw DictationError("This iPhone can't recognize \(Locale(identifier: "en").localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? "this language") on the device")
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
    segments.append("")
    startedAt = Date()
    // Results come on the main queue (SFSpeechRecognizer's default).
    tasks.append(
      recognizer.recognitionTask(with: req) { [weak self] result, error in
        self?.update(index, req, result, error)
      })
    lock.withLock { request = req }
    rotation?.invalidate()
    rotation = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in self?.rotate() }
  }

  /// The request in use stops taking audio (its last words still land in its segment) and a new one starts.
  private func rotate() {
    guard finishing == nil else { return }
    let old = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
      defer { request = nil }
      return request
    }
    old?.endAudio()
    begin()
  }

  private func update(
    _ index: Int, _ req: SFSpeechAudioBufferRecognitionRequest, _ result: SFSpeechRecognitionResult?, _ error: Error?
  ) {
    if let result {
      segments[index] = result.bestTranscription.formattedString
      onText(text)
    }
    guard error != nil || result?.isFinal == true else { return }
    let last = index == segments.count - 1
    if let done = finishing {
      if last {
        finishing = nil
        onText(text)
        done()
      }
      return
    }
    guard last, lock.withLock({ request === req }) else { return }
    // Ended by itself while the person still talks to it (a pause, its limit, a hiccup): a new request goes on.
    quickEnds = Date().timeIntervalSince(startedAt) < 1 ? quickEnds + 1 : 0
    if quickEnds >= 3 {
      rotation?.invalidate()
      lock.withLock { request = nil }
      return onFail(error?.localizedDescription ?? "Speech recognition stopped")
    }
    lock.withLock { request = nil }
    begin()
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.withLock { request?.append(buffer) }
  }

  func finish(_ done: @escaping () -> Void) {
    rotation?.invalidate()
    finishing = done
    let req = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
      defer { request = nil }
      return request
    }
    req?.endAudio()
    // A recognizer that never answers still ends the listening with what it heard.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self, let done = self.finishing else { return }
      self.finishing = nil
      for t in self.tasks { t.cancel() }
      done()
    }
  }

  func cancel() {
    rotation?.invalidate()
    finishing = nil
    lock.withLock { request = nil }
    for t in tasks { t.cancel() }
    tasks = []
  }
}
