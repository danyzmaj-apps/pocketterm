import Combine
import SwiftUI
import UIKit

/// The first-use tips, as popovers on the controls they're about (iOS's tip popover look: a bubble with an arrow,
/// its caption and Got it). Which have been seen is [TipsController]'s (the preference `pocketterm_tips_seen`);
/// [TipStage] shows them one at a time, in tour order, each once. TipKit's own popoverTip wasn't used: it didn't
/// present on List rows and section headers, and its datastore keeps a second, conflicting record of what was seen.
enum AppTips {
  static func configure(_ tips: TipsController) {
    TipStage.shared.attach(tips)
  }
}

/// Which tip shows now: of the tips whose controls are on screen, the first unseen in tour order, once the tour
/// question is answered and no keyboard is up; after its control has been there a moment, so a page settles first.
final class TipStage: ObservableObject {
  static let shared = TipStage()

  private init() {
    keyboard = [
      NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification).map { _ in true },
      NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification).map { _ in false },
    ]
    .publisher
    .flatMap { $0 }
    .sink { [weak self] up in
      self?.keyboardUp = up
      self?.update()
    }
  }

  private(set) var tips: TipsController?
  private var watching: AnyCancellable?
  private var keyboard: AnyCancellable?
  private var keyboardUp = false
  /// The controls on screen with a tip, by how many show it.
  private var present: [AppTip: Int] = [:]
  private var pending: Task<Void, Never>?

  @Published private(set) var showing: AppTip?

  func attach(_ tips: TipsController) {
    guard tips !== self.tips else { return }
    self.tips = tips
    watching = tips.objectWillChange.sink { [weak self] _ in
      // Told before the change: looked at once it's made.
      Task { @MainActor in self?.update() }
    }
    update()
  }

  /// The tip that shows among [present]: the first in tour order not [seen], once the tour question is [answered].
  static func next(present: Set<AppTip>, seen: (AppTip) -> Bool, answered: Bool) -> AppTip? {
    guard answered else { return nil }
    return AppTip.allCases.first { present.contains($0) && !seen($0) }
  }

  func isShowing(_ tip: AppTip) -> Bool { showing == tip }

  func register(_ tip: AppTip) {
    present[tip, default: 0] += 1
    update()
  }

  func unregister(_ tip: AppTip) {
    guard let n = present[tip] else { return }
    present[tip] = n > 1 ? n - 1 : nil
    update()
  }

  /// Got it: seen, and the next one may show.
  func gotIt(_ tip: AppTip) {
    tips?.markSeen(tip)
  }

  /// [tip]'s popover went. Closed by the person (its close button, a tap beside it): seen. Taken away because its
  /// control went or the keyboard came up: not, it shows again when it's back.
  func closed(_ tip: AppTip) {
    Task { @MainActor [weak self] in
      // After the control's own going, which may come just after its popover's.
      try? await Task.sleep(for: .milliseconds(150))
      guard let self, self.showing == tip, self.present[tip] != nil else { return }
      self.tips?.markSeen(tip)
    }
  }

  private var candidate: AppTip? {
    guard let tips, !keyboardUp else { return nil }
    return Self.next(present: Set(present.keys), seen: tips.seen, answered: tips.answered)
  }

  private func update() {
    if tips == nil { return }
    let next = candidate
    if next == showing {
      pending?.cancel()
      return
    }
    if showing != nil { showing = nil }
    pending?.cancel()
    guard let next else { return }
    pending = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled, let self, self.candidate == next else { return }
      self.showing = next
    }
  }
}

extension View {
  /// [tip] on this control, as a popover when it's this tip's turn: one at a time, in tour order, each once.
  /// [enabled]: whether this control has the tip now (the switch tour moves it from row to row).
  func appTip(_ tip: AppTip, enabled: Bool = true) -> some View {
    modifier(AppTipModifier(tip: tip, enabled: enabled))
  }
}

private struct AppTipModifier: ViewModifier {
  let tip: AppTip
  let enabled: Bool
  @ObservedObject private var stage = TipStage.shared
  /// Whether this control counts toward the tips on screen, and whether it's on screen at all.
  @State private var registered = false
  @State private var appeared = false

  func body(content: Content) -> some View {
    let shown = enabled && stage.isShowing(tip)
    content
      .popover(
        isPresented: Binding(
          get: { shown },
          // Closed by a tap beside it: seen (unless its control went meanwhile).
          set: { open in if !open && shown { stage.closed(tip) } })
      ) {
        TipBubble(tip: tip)
          .presentationCompactAdaptation(.popover)
      }
      .onAppear {
        appeared = true
        setRegistered(enabled)
      }
      .onDisappear {
        appeared = false
        setRegistered(false)
      }
      .onChange(of: enabled) { _, on in if appeared { setRegistered(on) } }
  }

  private func setRegistered(_ on: Bool) {
    if !on && registered { stage.unregister(tip) }
    if on && !registered { stage.register(tip) }
    registered = on
  }
}

/// A tip's bubble: its caption and Got it, findable by UI tests as `tip-<id>` and `tip-got-it`.
private struct TipBubble: View {
  let tip: AppTip

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(tip.caption)
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("tip-\(tip.id)")
      HStack {
        Spacer()
        Button("Got it") { TipStage.shared.gotIt(tip) }
          .fontWeight(.semibold)
          .accessibilityIdentifier("tip-got-it")
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 10)
    .frame(maxWidth: 300, alignment: .leading)
  }
}

/// Asks whether to have the first-use tips, the first time the list shows. Only its two buttons answer it (true:
/// Show me); it can't be swiped away.
struct TourAskSheet: View {
  init(onAnswer: @escaping (Bool) -> Void) { self.onAnswer = onAnswer }

  private let onAnswer: (Bool) -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "lightbulb")
        .font(.system(size: 40))
        .foregroundStyle(.tint)
        .padding(.bottom, 4)
        .accessibilityHidden(true)
      Text("New here?")
        .font(.title2.weight(.bold))
      Text("Want a quick tour? A few tips point out what you can tap, one at a time.")
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      Button {
        onAnswer(true)
      } label: {
        Text("Show me").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .accessibilityIdentifier("tour-yes")
      Button("No thanks") { onAnswer(false) }
        .controlSize(.large)
        .accessibilityIdentifier("tour-no")
    }
    .padding(.horizontal, 24)
    .padding(.top, 32)
    .padding(.bottom, 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tour-ask")
    .presentationDetents([.medium])
    .presentationDragIndicator(.hidden)
    .interactiveDismissDisabled()
  }
}
