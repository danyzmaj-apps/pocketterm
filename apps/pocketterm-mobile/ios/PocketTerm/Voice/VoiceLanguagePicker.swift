import PocketTermKit
import SwiftUI
import UIKit

/// Auto and each language, with what this phone has of it, asked on opening and on coming back to the app: on the
/// phone; to download (Download); to add in the phone's settings (Open Settings); or not supported, which can't be
/// picked. A tap keeps the choice for this phone. A page of its own (pushed from Settings).
struct VoiceLanguagePicker: View {
  init() { source = voiceSource }

  init(source: SpeechSource) { self.source = source }

  private let source: SpeechSource
  @ObservedObject private var languages = VoiceLanguage.shared
  @State private var support: [SpeechLanguage: SpeechCheck] = [:]
  @State private var fixing: Set<SpeechLanguage> = []
  @State private var auto: SpeechLanguage?
  @State private var error: String?

  var body: some View {
    Form {
      Section {
        choiceRow(
          title: "Auto",
          note: "The phone\u{2019}s language when it has it, else English" + (auto.map { ": now \($0.label)" } ?? ""),
          on: languages.choice == nil,
          enabled: true
        ) { languages.choose(nil) }
        .accessibilityIdentifier("voice-language-auto")
        ForEach(SpeechLanguage.allCases, id: \.self) { l in
          let unsupported = support[l]?.unsupported ?? false
          HStack(spacing: 8) {
            choiceRow(title: l.label, note: note(l), on: languages.choice == l, enabled: !unsupported) {
              languages.choose(l)
            }
            .accessibilityIdentifier("voice-language-\(l.rawValue)")
            action(l)
          }
        }
      } footer: {
        if let error {
          Text(error).foregroundStyle(.orange)
        }
      }
    }
    .navigationTitle("Voice prompt language")
    .navigationBarTitleDisplayMode(.inline)
    .task { await refresh() }
    // Back from the phone's settings or its download: what it has may have changed.
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
      Task { await refresh() }
    }
  }

  private func choiceRow(title: String, note: String?, on: Bool, enabled: Bool, pick: @escaping () -> Void)
    -> some View
  {
    Button(action: pick) {
      HStack(spacing: 12) {
        Image(systemName: "checkmark")
          .font(.body.weight(.semibold))
          .foregroundStyle(.tint)
          .opacity(on ? 1 : 0)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).foregroundStyle(enabled ? .primary : .secondary)
          if let note {
            Text(note).font(.footnote).foregroundStyle(enabled ? .secondary : .tertiary)
          }
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityAddTraits(on ? .isSelected : [])
  }

  /// What the phone has of [l].
  private func note(_ l: SpeechLanguage) -> String? {
    guard let s = support[l] else { return nil }
    if fixing.contains(l) { return "Downloading\u{2026}" }
    switch (s.status, s.fix) {
    case (.ready, _): return "On this phone"
    case (.downloading, _): return "Downloading\u{2026}"
    case (.noLanguage, .download): return "Not downloaded yet"
    case (.noLanguage, _?): return "Turn on Dictation in \(l.title): Settings → General → Keyboard"
    default: return "Not supported on this phone"
    }
  }

  /// The button that gets [l] onto the phone, or a spinner while it's coming.
  @ViewBuilder private func action(_ l: SpeechLanguage) -> some View {
    if fixing.contains(l) {
      ProgressView()
    } else if let s = support[l], s.status == .noLanguage, let fix = s.fix {
      Button(fix == .download ? "Download" : "Open Settings") { Task { await self.fix(l, fix) } }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("voice-language-\(l.rawValue)-\(fix.rawValue)")
    }
  }

  private func refresh() async {
    var found: [SpeechLanguage: SpeechCheck] = [:]
    for l in SpeechLanguage.allCases { found[l] = await VoiceLanguage.supportOf(source, l) }
    let auto = await languages.auto(source)
    support = found
    self.auto = auto
  }

  private func fix(_ l: SpeechLanguage, _ fix: SpeechFix) async {
    fixing.insert(l)
    error = nil
    do {
      try await source.fix(fix, l)
    } catch {
      self.error = speechErrorText(error)
    }
    fixing.remove(l)
    await refresh()
  }
}
