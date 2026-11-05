import Foundation
import PocketTermKit

/// Where the voice sheet hears from: the phone's on-device recognizer, or in an E2E build (no microphone in the
/// Simulator) a made-up speaker that says [ScriptedSpeech]'s sentence.
let voiceSource: SpeechSource = E2E.enabled ? ScriptedSpeech() : Dictation()

/// What the person did with what they said: [send] it as the composer would, or insert it into the composer.
struct VoiceResult: Equatable {
  let text: String
  let send: Bool
}

/// [existing] and then [spoken], a space between them when [existing] has words.
nonisolated func appendSpoken(_ existing: String, _ spoken: String) -> String {
  let before = existing.voiceTrimmingTrailingWhitespace()
  return before.isEmpty ? spoken : "\(before) \(spoken)"
}

/// Why the phone can't listen in [language], as [c] says, for the person.
nonisolated func speechProblemText(_ c: SpeechCheck, _ language: SpeechLanguage) -> String {
  let lang = language.title
  switch (c.status, c.fix) {
  case (.denied, _):
    return "PocketTerm isn\u{2019}t allowed to use the microphone or speech recognition. Allow them in Settings."
  case (.restricted, _):
    return "Speech recognition is turned off on this phone."
  case (.noLanguage, .download):
    return "\(lang) for speech recognition isn\u{2019}t on this phone yet. Download it once; what you say stays on the phone."
  case (.noLanguage, .speechSettings):
    return "This iPhone can\u{2019}t recognize \(lang) on the device yet. Turn on Dictation in \(lang) in Settings → General "
      + "→ Keyboard, and it downloads."
  case (.noLanguage, _):
    return "\(lang) isn\u{2019}t supported for speech recognition on this phone. Tap the language above to pick another."
  case (.downloading, _):
    return "\(lang) for speech recognition is downloading. Try again when it\u{2019}s done."
  case (.unavailable, _), (.ready, _):
    return "This phone can\u{2019}t recognize speech on the device, so voice prompts are off here."
  }
}

/// What a recognizer's failure says, for the person.
nonisolated func speechErrorText(_ error: Error) -> String {
  if let e = error as? LocalizedError, let text = e.errorDescription { return text }
  let ns = error as NSError
  return ns.domain.hasPrefix("NS") || ns.domain.hasPrefix("com.apple") ? ns.localizedDescription : "\(error)"
}

extension String {
  nonisolated fileprivate func voiceTrimmingTrailingWhitespace() -> String {
    var s = Substring(self)
    while let last = s.last, last.isWhitespace { s.removeLast() }
    return String(s)
  }

  /// Without the whitespace around it, as what's said is kept.
  nonisolated var spokenTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// An E2E build's speaker (no microphone in the Simulator): says [words] (else a sentence in the language it
/// listens in) one by one, a loudness swinging with each, then goes quiet until stopped.
@MainActor
final class ScriptedSpeech: SpeechSource {
  init(words: [String]? = nil, every: Duration = .milliseconds(120)) {
    self.words = words
    self.every = every
  }

  static let sentence = [
    "Add", "a", "dark", "mode", "toggle", "to", "the", "settings", "page", "and", "write", "a", "test", "for", "it.",
  ]

  static let croatian = ["Dodaj", "tamni", "na\u{10D}in", "rada", "u", "postavke", "i", "napi\u{161}i", "test", "za", "to."]

  private let words: [String]?
  private let every: Duration
  private var out: AsyncStream<SpeechEvent>.Continuation?
  private var timer: Task<Void, Never>?
  private var said = ""

  nonisolated func check(_ language: SpeechLanguage) async throws -> SpeechCheck { SpeechCheck(.ready) }

  nonisolated func support(_ language: SpeechLanguage) async throws -> SpeechCheck { SpeechCheck(.ready) }

  nonisolated func listen(_ language: SpeechLanguage) -> AsyncStream<SpeechEvent> {
    let (stream, out) = AsyncStream<SpeechEvent>.makeStream()
    let id = UUID()
    out.onTermination = { [weak self] why in
      guard case .cancelled = why else { return }
      Task { @MainActor in self?.cancelled(id) }
    }
    Task { @MainActor in self.begin(language, out, id) }
    return stream
  }

  nonisolated func stop() async throws { await end() }

  nonisolated func fix(_ fix: SpeechFix, _ language: SpeechLanguage) async throws {}

  private var current: UUID?

  private func begin(_ language: SpeechLanguage, _ out: AsyncStream<SpeechEvent>.Continuation, _ id: UUID) {
    timer?.cancel()
    self.out?.finish()
    said = ""
    self.out = out
    current = id
    let words = self.words ?? (language == .croatian ? Self.croatian : Self.sentence)
    let every = self.every
    timer = Task { [weak self] in
      var tick = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: every)
        guard !Task.isCancelled, let self else { return }
        tick += 1
        for e in Self.events(tick: tick, words: words) {
          if case .heard(let text) = e { self.said = text }
          out.yield(e)
        }
      }
    }
  }

  /// What the speaker says at [tick] (from 1): a loudness each tick, swinging while it talks; every third tick
  /// one more word, until all of [words] are said.
  nonisolated static func events(tick: Int, words: [String]) -> [SpeechEvent] {
    let word = tick / 3
    var out: [SpeechEvent] = [.level(word < words.count ? 0.45 + 0.4 * abs(sin(Double(tick) * 1.3)) : 0.04)]
    if tick % 3 == 0 && word <= words.count { out.append(.heard(words.prefix(word).joined(separator: " "))) }
    return out
  }

  private func cancelled(_ id: UUID) {
    guard current == id else { return }
    timer?.cancel()
    timer = nil
    out = nil
    current = nil
  }

  private func end() {
    timer?.cancel()
    timer = nil
    guard let out else { return }
    self.out = nil
    current = nil
    out.yield(.heard(said))
    out.yield(.ended(SpeechEnded(.stopped)))
    out.finish()
  }
}
