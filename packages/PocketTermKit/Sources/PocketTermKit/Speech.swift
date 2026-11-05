import Foundation

/// What the phone listens for. [code] is the BCP 47 language the native recognizers take (`en`: British or
/// American by the phone's region; `hr`: hr-HR). The raw value is the name kept in the preferences.
public enum SpeechLanguage: String, CaseIterable, Hashable, Sendable {
  case english
  case croatian

  public var code: String {
    switch self {
    case .english: "en"
    case .croatian: "hr"
    }
  }

  /// Its name in the app's own English, for sentences ("Croatian for speech recognition…").
  public var title: String {
    switch self {
    case .english: "English"
    case .croatian: "Croatian"
    }
  }

  /// Its own name, as the voice sheet and Settings offer it.
  public var label: String {
    switch self {
    case .english: "English"
    case .croatian: "Hrvatski"
    }
  }

  /// The languages PocketTerm can listen for in the order the phone's [languages] list them, then English if
  /// they don't: Auto's candidates, the first the phone can recognize winning. [languages] are language codes
  /// (`hr`) or BCP 47 identifiers (`hr-HR`, as `Locale.preferredLanguages` gives them); only the language
  /// part counts.
  public static func byLocales(_ languages: [String]) -> [SpeechLanguage] {
    var out: [SpeechLanguage] = []
    for l in languages {
      let code = l.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? l
      if let s = allCases.first(where: { $0.code == code }), !out.contains(s) { out.append(s) }
    }
    if !out.contains(.english) { out.append(.english) }
    return out
  }
}

/// Whether the phone can listen now, in the chosen [SpeechLanguage], on the device. Raw values are the
/// names the native recognizers report.
public enum SpeechStatus: String, CaseIterable, Hashable, Sendable {
  case ready

  /// The microphone (or, on an iPhone before iOS 26, speech recognition) was refused.
  case denied

  /// Turned off for this phone (Screen Time, a device profile).
  case restricted

  /// The language isn't on the device for recognition; [SpeechCheck.fix] says whether it can be fetched or
  /// added, and none means this phone can't recognize it at all.
  case noLanguage

  /// The language for the device is on its way.
  case downloading

  /// This phone can't recognize speech on the device at all.
  case unavailable
}

/// What the person can do about a [SpeechStatus] that isn't ready.
public enum SpeechFix: String, CaseIterable, Hashable, Sendable {
  /// PocketTerm's page in the phone's Settings (its permissions).
  case appSettings

  /// Fetch the language's model for on-device recognition (iOS 26's speech assets, Android 13's on-device
  /// recognizer). Recognition itself still never leaves the phone.
  case download

  /// The phone's own speech settings, where a language for on-device recognition is turned on.
  case speechSettings
}

public struct SpeechCheck: Hashable, Sendable {
  public let status: SpeechStatus
  public let fix: SpeechFix?

  public init(_ status: SpeechStatus, fix: SpeechFix? = nil) {
    self.status = status
    self.fix = fix
  }

  /// A check as the native recognizers report one, `{status, fix?}`: unavailable when the status is
  /// missing or unknown.
  public init(json m: JSONObject) {
    self.init(
      m["status"]?.string.flatMap(SpeechStatus.init(rawValue:)) ?? .unavailable,
      fix: m["fix"]?.string.flatMap(SpeechFix.init(rawValue:))
    )
  }

  public var ready: Bool { status == .ready }

  /// This phone can't listen in the language, whatever the person does.
  public var unsupported: Bool { status == .unavailable || (status == .noLanguage && fix == nil) }
}

public enum SpeechEnd: String, CaseIterable, Hashable, Sendable {
  /// Stopped as asked ([SpeechSource.stop]).
  case stopped

  /// Something else took the microphone (a call, Siri, the app left the screen).
  case interrupted

  /// Recognition failed; [SpeechEnded.message] says why.
  case error
}

public struct SpeechEnded: Hashable, Sendable {
  public let why: SpeechEnd
  public let message: String?

  /// When the failure is one [SpeechSource.check] would have found (Android 12 learns the language is
  /// missing only when it starts).
  public let status: SpeechStatus?

  public init(_ why: SpeechEnd, message: String? = nil, status: SpeechStatus? = nil) {
    self.why = why
    self.message = message
    self.status = status
  }
}

/// What a listening session reports, in order, the last one [ended].
public enum SpeechEvent: Hashable, Sendable {
  /// Everything heard since listening started, the newest words possibly still changing.
  case heard(String)

  /// How loud the microphone is, 0 (silence) to 1.
  case level(Double)

  case ended(SpeechEnded)

  /// An event as the native recognizers report one: `{type: heard, text}`, `{type: level, level}`,
  /// `{type: ended, why: stopped|interrupted|error, message?, status?}`; anything else ends with an error.
  public init(json m: JSONObject) {
    switch m["type"]?.string {
    case "heard": self = .heard(m["text"]?.string ?? "")
    case "level": self = .level(min(max(m["level"]?.number ?? 0, 0), 1))
    default:
      self = .ended(
        SpeechEnded(
          m["why"]?.string.flatMap(SpeechEnd.init(rawValue:)) ?? .error,
          message: m["message"]?.string,
          status: m["status"]?.string.flatMap(SpeechStatus.init(rawValue:))
        ))
    }
  }
}

/// Speech to text on the phone, in one [SpeechLanguage] and on the device only.
public protocol SpeechSource: Sendable {
  /// Whether it can listen in [language]; asks for the permissions it needs the first time.
  func check(_ language: SpeechLanguage) async throws -> SpeechCheck

  /// Whether the phone has [language] for on-device recognition, asking for no permission: ready,
  /// downloading, or `.noLanguage` with its fix (none: not supported), or `.unavailable`. Ready when it
  /// can't tell (Android 12 and older); listening finds out.
  func support(_ language: SpeechLanguage) async throws -> SpeechCheck

  /// Starts listening in [language]. Cancelling the stream's consumer discards what was heard and stops at
  /// once; [stop] ends it with the last words settled instead. The stream finishes after `.ended`.
  func listen(_ language: SpeechLanguage) -> AsyncStream<SpeechEvent>

  /// Stops listening: the last `.heard`, then `.ended` with `.stopped`.
  func stop() async throws

  /// Does [fix] for [language]; for `.download`, returns once the download is done or handed to the system.
  func fix(_ fix: SpeechFix, _ language: SpeechLanguage) async throws
}
