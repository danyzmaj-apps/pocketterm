import Combine
import PocketTermKit
import SwiftUI
import UIKit

/// A hold on the microphone in progress: whether the finger is still down, and whether it slid away to cancel.
final class VoiceHold {
  private(set) var down = true
  private(set) var away = false

  /// Told after either changes.
  var onChange: (() -> Void)?

  func setAway(_ away: Bool) {
    guard away != self.away, down else { return }
    self.away = away
    onChange?()
  }

  func release() {
    guard down else { return }
    down = false
    onChange?()
  }
}

/// What the voice sheet does: listening at once, and once stopped what was said, editable, to Send, Insert or
/// Cancel. Leaving the app, a call or Siri stop it, keeping what was said.
final class VoiceSheetModel: ObservableObject {
  enum Phase: Equatable { case checking, problem, downloading, listening, stopping, review }

  /// [hold]: opened by a hold, which lifting stops. [existing]: the composer's text, shown dimmed above what's said.
  init(source: SpeechSource, existing: String, hold: VoiceHold? = nil, languages: VoiceLanguage = .shared) {
    self.source = source
    self.existing = existing.spokenTrimmed
    self.hold = hold
    self.languages = languages
    held = hold?.down ?? false
    language = languages.choice ?? languages.guess
    hold?.onChange = { [weak self] in self?.holdChanged() }
  }

  let source: SpeechSource
  let existing: String
  let hold: VoiceHold?
  private let languages: VoiceLanguage

  /// What the sheet was closed with: nil when cancelled, closed or slid away.
  var onClose: (VoiceResult?) -> Void = { _ in }

  @Published private(set) var phase: Phase = .checking
  @Published private(set) var problem = SpeechCheck(.unavailable)
  /// What's said, live, after what was kept before Keep talking.
  @Published private(set) var heard = ""
  @Published private(set) var level: Double = 0
  /// What's said once stopped, as the person edits it.
  @Published var edit = ""
  /// Why listening ended early, shown under the text (or under a problem, what went wrong fixing it).
  @Published private(set) var note: String?
  /// Still held to talk: lifting stops. False after a lift, or for a tap.
  @Published private(set) var held: Bool
  /// What it listens in: until Auto has asked the phone, its first guess.
  @Published private(set) var language: SpeechLanguage

  /// What was said (and edited) before Keep talking: the new words go after it.
  private var before = ""
  private var listening: Task<Void, Never>?
  private var stopWait: Task<Void, Never>?
  private var began = false
  private(set) var closed = false

  /// Slid away while held: lifting cancels.
  var away: Bool { held && (hold?.away ?? false) }

  var title: String {
    switch phase {
    case .checking, .listening, .stopping: away ? "Release to cancel" : "Listening"
    case .downloading: "Downloading"
    case .problem, .review: "Voice prompt"
    }
  }

  /// The language can be switched while listening, at a problem or in review, and not while held (the finger is
  /// on the microphone).
  var canSwitchLanguage: Bool { !held && [.listening, .problem, .review].contains(phase) }

  var canFinish: Bool { !edit.spokenTrimmed.isEmpty }

  /// Starts listening, once.
  func begin() {
    guard !began else { return }
    began = true
    Task { await start() }
  }

  private func start() async {
    phase = .checking
    let language = await languages.resolve(source)
    guard !closed else { return }
    self.language = language
    let check: SpeechCheck
    do {
      check = try await source.check(language)
    } catch {
      check = SpeechCheck(.unavailable)
    }
    guard !closed else { return }
    if !check.ready {
      problem = check
      phase = .problem
      return
    }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    let stream = source.listen(language)
    listening = Task { [weak self] in
      for await e in stream { self?.on(e) }
      if !Task.isCancelled { self?.ended(.stopped) }
    }
    phase = .listening
  }

  private func on(_ e: SpeechEvent) {
    switch e {
    case .heard(let text):
      if phase == .listening || phase == .stopping { heard = appendSpoken(before, text) }
    case .level(let level):
      self.level = level
    case .ended(let end):
      if let status = end.status, status != .ready, heard.spokenTrimmed.isEmpty {
        listening?.cancel()
        listening = nil
        // Auto's pick turned out missing only now: it listens in the next language Auto has, without asking.
        if status == .noLanguage, languages.choice == nil, language != .english {
          languages.missed(language)
          Task { await start() }
          return
        }
        problem = SpeechCheck(status, fix: status == .noLanguage ? .speechSettings : nil)
        phase = .problem
        return
      }
      ended(end.why, message: end.message)
    }
  }

  func stop() async {
    guard phase == .listening else { return }
    phase = .stopping
    // The recognizer settles the last words and says so; one that doesn't answer still leaves what it heard.
    stopWait = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      if !Task.isCancelled { self?.ended(.stopped) }
    }
    do {
      try await source.stop()
    } catch {
      ended(.error, message: speechErrorText(error))
    }
  }

  private func ended(_ why: SpeechEnd, message: String? = nil) {
    guard !closed, phase == .listening || phase == .stopping else { return }
    stopWait?.cancel()
    listening?.cancel()
    listening = nil
    level = 0
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    held = false
    note =
      switch why {
      case .stopped: nil
      case .interrupted: "Stopped: something else took the microphone."
      case .error: (message ?? "").isEmpty ? "Listening stopped." : "Listening stopped: \(message!)"
      }
    edit = heard.spokenTrimmed
    phase = .review
  }

  private func holdChanged() {
    guard !closed, let hold else { return }
    if !hold.down && held {
      held = false
      if hold.away {
        listening?.cancel()
        listening = nil
        return close(nil)
      }
      // Lifted before listening began (a permission prompt took the finger): it goes on until Stop, as for a tap.
      if phase == .listening { Task { await stop() } }
    }
    objectWillChange.send()
  }

  /// Listens again, the new words after what's in the editor now.
  func keepTalking() {
    before = edit.spokenTrimmed
    heard = before
    note = nil
    Task { await start() }
  }

  /// Listens in the other language from now on, and keeps it for this phone. Mid-listening, the words so far stay
  /// and listening goes on in the new one; a problem is checked again for it.
  func switchLanguage() {
    let all = SpeechLanguage.allCases
    let next = all[((all.firstIndex(of: language) ?? 0) + 1) % all.count]
    language = next
    languages.choose(next)
    switch phase {
    case .listening:
      listening?.cancel()
      listening = nil
      before = heard.spokenTrimmed
      heard = before
      Task { await start() }
    case .problem:
      note = nil
      Task { await start() }
    case .review, .checking, .stopping, .downloading:
      break
    }
  }

  /// The problem's button: what it says and does.
  var problemAction: (label: String, fix: SpeechFix?)? {
    switch (problem.status, problem.fix) {
    case (.downloading, _): ("Try again", nil)
    case (_, .download): ("Download", .download)
    case (_, let fix?): ("Open Settings", fix)
    default: nil
    }
  }

  func runProblemAction() async {
    guard let action = problemAction else { return }
    guard let fix = action.fix else { return await start() }
    await self.fix(fix)
  }

  private func fix(_ fix: SpeechFix) async {
    if fix != .download {
      try? await source.fix(fix, language)
      return
    }
    phase = .downloading
    do {
      try await source.fix(fix, language)
    } catch {
      guard !closed else { return }
      problem = SpeechCheck(.noLanguage, fix: .download)
      note = speechErrorText(error)
      phase = .problem
      return
    }
    note = nil
    await start()
  }

  func finish(send: Bool) {
    let text = edit.spokenTrimmed
    guard !text.isEmpty else { return }
    close(VoiceResult(text: text, send: send))
  }

  /// Out of sight: the microphone stops, what was said stays to check when the person is back.
  func wentAway() { Task { await stop() } }

  /// Closed with [result]; closed or slid away while listening, what was heard goes and the microphone stops at
  /// once.
  func close(_ result: VoiceResult?) {
    guard !closed else { return }
    closed = true
    hold?.onChange = nil
    stopWait?.cancel()
    listening?.cancel()
    listening = nil
    onClose(result)
  }
}

/// The voice sheet: the composer's text dimmed, then what's said, live and large; once stopped, editable in place
/// with Keep talking, Insert and Send.
struct VoiceSheetView: View {
  @ObservedObject var model: VoiceSheetModel
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollViewReader { scroll in
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              if !model.existing.isEmpty && model.phase != .problem {
                Text(model.existing)
                  .font(.title3)
                  .foregroundStyle(.tertiary)
                  .accessibilityIdentifier("voice-existing")
              }
              words
              Color.clear.frame(height: 1).id("end")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
          }
          .scrollDismissesKeyboard(.interactively)
          // The newest words stay in view as they come.
          .onChange(of: model.heard) { scroll.scrollTo("end", anchor: .bottom) }
        }
        controls
          .padding(.horizontal, 20)
          .padding(.top, 8)
          .padding(.bottom, 12)
          .animation(.snappy, value: model.phase)
      }
      .background(Color(.systemBackground))
      .navigationTitle(model.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            model.close(nil)
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
          .accessibilityIdentifier("voice-close")
        }
        ToolbarItem(placement: .primaryAction) { languageButton }
      }
    }
    .accessibilityAction(.escape) { model.close(nil) }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
      model.wentAway()
    }
  }

  /// The language it listens in; a tap switches to the other one.
  private var languageButton: some View {
    Button {
      model.switchLanguage()
    } label: {
      // Not a Label: a toolbar shows only a Label's icon and reads only its title, and the name must show.
      HStack(spacing: 4) {
        Image(systemName: "character.bubble")
        Text(model.language.label)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Language: \(model.language.title). Switch")
    }
    .disabled(!model.canSwitchLanguage)
    .accessibilityLabel("Language: \(model.language.title). Switch")
    .accessibilityIdentifier("voice-language")
  }

  @ViewBuilder private var words: some View {
    switch model.phase {
    case .problem:
      Text(speechProblemText(model.problem, model.language))
        .font(.title3)
        .accessibilityIdentifier("voice-problem")
      if let note = model.note {
        Text(note).font(.subheadline).foregroundStyle(.secondary)
      }
    case .downloading:
      Text("Downloading \(model.language.title) for speech recognition\u{2026}")
        .font(.title3)
        .foregroundStyle(.secondary)
    case .checking, .listening, .stopping:
      LiveWords(text: model.heard)
    case .review:
      TextField("Nothing heard", text: $model.edit, axis: .vertical)
        .font(.title.weight(.medium))
        .accessibilityIdentifier("voice-edit")
      if let note = model.note {
        Text(note)
          .font(.subheadline)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("voice-note")
      }
    }
  }

  @ViewBuilder private var controls: some View {
    switch model.phase {
    case .problem:
      HStack(spacing: 12) {
        Spacer()
        Button("Cancel") { model.close(nil) }
          .accessibilityIdentifier("voice-cancel")
        if let action = model.problemAction {
          Button(action.label) { Task { await model.runProblemAction() } }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("voice-fix")
        }
      }
      .transition(.opacity)
    case .downloading:
      ProgressView().frame(height: 44).transition(.opacity)
    case .checking, .listening, .stopping:
      listeningControls.transition(.opacity.combined(with: .scale(scale: 0.95)))
    case .review:
      reviewControls.transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
  }

  private var listeningControls: some View {
    let listening = model.phase == .listening
    let orb = VoiceOrb(level: model.level, away: model.away, busy: !listening)
    return VStack(spacing: 8) {
      if model.held {
        orb
      } else {
        // A tap needs no hint: the orb is the stop button.
        Button {
          Task { await model.stop() }
        } label: {
          orb
        }
        .buttonStyle(.plain)
        .disabled(!listening)
        .accessibilityLabel("Stop")
        .accessibilityIdentifier("voice-stop")
      }
      // A hold says how to stop or cancel.
      if model.held {
        Text(model.away ? "Release to cancel" : "Release to stop \u{00B7} Slide away to cancel")
          .font(.subheadline)
          .multilineTextAlignment(.center)
          .foregroundStyle(model.away ? Color.red : Color.secondary)
          .accessibilityIdentifier("voice-hold-hint")
      }
    }
    .frame(maxWidth: .infinity)
  }

  /// No Cancel: the close button already does that.
  private var reviewControls: some View {
    let insert = Button {
      model.finish(send: false)
    } label: {
      Text("Insert").frame(maxWidth: .infinity, minHeight: 34)
    }
    .buttonStyle(.bordered)
    .disabled(!model.canFinish)
    .accessibilityIdentifier("voice-insert")
    let send = Button {
      model.finish(send: true)
    } label: {
      Text("Send").frame(maxWidth: .infinity, minHeight: 34)
    }
    .buttonStyle(.borderedProminent)
    .disabled(!model.canFinish)
    .accessibilityIdentifier("voice-send")
    return VStack(spacing: 8) {
      Button {
        model.keepTalking()
      } label: {
        Label("Keep talking", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 34)
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("voice-more")
      // Side by side; very large text stacks them.
      if typeSize.isAccessibilitySize {
        insert
        send
      } else {
        HStack(spacing: 8) {
          insert
          send
        }
      }
    }
    .controlSize(.large)
  }
}

/// What's being said, large: new words fade in as the recognizer adds them. Until something's heard, "Speak now…".
private struct LiveWords: View {
  let text: String

  var body: some View {
    Text(text.isEmpty ? "Speak now\u{2026}" : text)
      .font(.title.weight(.medium))
      .foregroundStyle(text.isEmpty ? .secondary : .primary)
      .contentTransition(.opacity)
      .animation(.easeOut(duration: 0.2), value: text)
      .accessibilityAddTraits(.updatesFrequently)
      .accessibilityIdentifier("voice-live")
  }
}

/// The microphone's loudness while listening: a waveform on a disc that swells with the voice, red while a hold
/// is slid away to cancel, dim while starting or stopping.
struct VoiceOrb: View {
  let level: Double
  let away: Bool
  let busy: Bool
  @EnvironmentObject private var look: Appearance
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let color: Color = away ? .red : busy ? .secondary : look.theme.tint
    let swell = reduceMotion ? 0 : level
    ZStack {
      Circle()
        .fill(color.opacity(0.12))
        .frame(width: 124, height: 124)
        .scaleEffect(0.7 + 0.3 * swell)
      Circle()
        .fill(color.opacity(0.2))
        .frame(width: 84, height: 84)
        .scaleEffect(0.92 + 0.12 * swell)
      Image(systemName: "waveform")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(color)
        .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !busy && !away)
    }
    .frame(width: 128, height: 128)
    .contentShape(Circle())
    .animation(.easeOut(duration: 0.12), value: level)
    .animation(.easeInOut(duration: 0.2), value: away)
    .animation(.easeInOut(duration: 0.2), value: busy)
  }
}

/// Opens the voice sheet over the whole screen, over whatever shows (a page, a sheet). Presented over the
/// screen rather than replacing it: a hold's finger stays on the microphone underneath, which follows it until
/// it lifts.
enum VoiceSheetPresenter {
  static func present(existing: String, hold: VoiceHold?, done: @escaping (VoiceResult?) -> Void) {
    guard let top = topController() else { return done(nil) }
    let model = VoiceSheetModel(source: voiceSource, existing: existing, hold: hold)
    let host = UIHostingController(rootView: VoiceSheetView(model: model).themed(appearance).toasts())
    host.modalPresentationStyle = .overFullScreen
    model.onClose = { [weak host] result in
      guard let host, host.presentingViewController != nil else { return done(result) }
      host.dismiss(animated: true) { done(result) }
    }
    top.present(host, animated: true)
    model.begin()
  }

  private static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    var top = window?.rootViewController
    while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
    return top
  }
}
