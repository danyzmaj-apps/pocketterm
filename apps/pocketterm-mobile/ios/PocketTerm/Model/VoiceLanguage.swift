import Combine
import Foundation
import PocketTermKit

/// The language the voice sheet listens in, per phone: chosen in Settings or on the sheet, else Auto. Kept as
/// the preference `voiceLanguage`, a [SpeechLanguage]'s raw value; none is Auto.
final class VoiceLanguage: ObservableObject {
  static let shared = VoiceLanguage()

  static let prefsKey = "voiceLanguage"

  private var prefs: Preferences?

  /// What was chosen; nil for Auto.
  @Published private(set) var choice: SpeechLanguage?

  /// Languages Auto listened in and the phone then said it has none of: Auto passes over them until a
  /// language is chosen again.
  private var missing: Set<SpeechLanguage> = []

  /// The phone's languages, in its order.
  var locales: [String] { Locale.preferredLanguages }

  /// Auto's first guess, before asking the phone: its first language PocketTerm can listen for.
  var guess: SpeechLanguage { SpeechLanguage.byLocales(locales).first ?? .english }

  /// What it listens in: the choice, else [auto].
  func resolve(_ source: SpeechSource) async -> SpeechLanguage {
    if let choice { return choice }
    return await auto(source)
  }

  /// Auto: of the phone's languages PocketTerm can listen for (in the phone's order, then English), the first
  /// the phone has for on-device recognition; when none is there yet, the first it can get (a download, a
  /// setting); English when it can get none.
  func auto(_ source: SpeechSource) async -> SpeechLanguage {
    let candidates = SpeechLanguage.byLocales(locales).filter { !missing.contains($0) }
    var found: [SpeechLanguage: SpeechCheck] = [:]
    for l in candidates {
      let s = await Self.supportOf(source, l)
      found[l] = s
      if s.ready { return l }
    }
    return candidates.first { !(found[$0]?.unsupported ?? true) } ?? .english
  }

  /// [SpeechSource.support], ready when the phone can't say (listening finds out).
  static func supportOf(_ source: SpeechSource, _ language: SpeechLanguage) async -> SpeechCheck {
    (try? await source.support(language)) ?? SpeechCheck(.ready)
  }

  /// Auto's [language] turned out missing once listening began.
  func missed(_ language: SpeechLanguage) { missing.insert(language) }

  func load(_ prefs: Preferences) {
    self.prefs = prefs
    choice = prefs.string(Self.prefsKey).flatMap(SpeechLanguage.init(rawValue:))
  }

  /// Keeps [choice] for this phone; nil goes back to Auto.
  func choose(_ choice: SpeechLanguage?) {
    missing.removeAll()
    if choice == self.choice { return }
    self.choice = choice
    if let choice { prefs?.setString(Self.prefsKey, choice.rawValue) } else { prefs?.remove(Self.prefsKey) }
  }
}
