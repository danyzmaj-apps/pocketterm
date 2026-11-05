import PocketTermKit
import SwiftUI

/// A scroll view as tall as what's in it, up to [maxHeight]: a card above the composer that keeps the composer on
/// screen.
struct CappedScroll<Content: View>: View {
  let maxHeight: CGFloat
  @ViewBuilder let content: Content
  @State private var height: CGFloat = 0

  var body: some View {
    ScrollView {
      content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollDismissesKeyboard(.interactively)
    .frame(height: min(max(height, 1), maxHeight))
  }
}

/// What the agent asks, answered from the phone: the `ask` tool's questions, an approval, or the plan review at the
/// end of plan mode (its options as the computer read them off the agent's screen; the plan itself is read there).
struct AskCard: View {
  let remote: TerminalRemote
  let session: String
  let ask: LiveAsk

  /// Opens the session's screen; nil when it has none.
  let onScreen: (() -> Void)?
  let maxHeight: CGFloat

  init(remote: TerminalRemote, session: String, ask: LiveAsk, onScreen: (() -> Void)?, maxHeight: CGFloat) {
    self.remote = remote
    self.session = session
    self.ask = ask
    self.onScreen = onScreen
    self.maxHeight = maxHeight
    let n = ask.questions?.count ?? 0
    _picks = State(initialValue: Array(repeating: [], count: n))
    _other = State(initialValue: Array(repeating: "", count: n))
  }

  @State private var picks: [Set<Int>]
  @State private var other: [String]
  @State private var sending = false

  /// The plan review option being sent.
  @State private var planPick: Int?

  /// Sent; the card stays until the agent moves on.
  @State private var sent = false

  private var busy: Bool { sending || sent }
  private var agentLabel: String { (remote.session(session)?.agent ?? remote.agent).label }

  private var complete: Bool {
    guard let qs = ask.questions else { return false }
    for (i, q) in qs.enumerated() {
      let custom = other[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
      if q.multi ? picks[i].count + custom == 0 : picks[i].count + custom != 1 { return false }
    }
    return true
  }

  private func answer(approve: Bool = false, plan: Int? = nil) async {
    sending = true
    planPick = plan
    var answers: [LiveAnswer] = []
    if let plan {
      answers = [LiveAnswer(picks: [plan])]
    } else if !ask.isApproval {
      answers = picks.enumerated().map { i, p in
        let custom = other[i].trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveAnswer(picks: p.sorted(), custom: custom.isEmpty ? nil : custom)
      }
    }
    do {
      try await remote.answer(session, ask, answers: answers, approve: approve)
      sent = true
      Haptics.done()
    } catch {
      Toaster.shared.show(errorText(error))
    }
    sending = false
  }

  var body: some View {
    let online = remote.online
    CappedScroll(maxHeight: maxHeight) {
      VStack(alignment: .leading, spacing: 10) {
        Label("\(agentLabel) needs you", systemImage: "exclamationmark.bubble.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.orange)
        if ask.isPlan {
          plan(online: online)
        } else if ask.isApproval {
          approval(online: online)
        } else {
          questions(online: online)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .background(Color.orange.opacity(0.1))
    .overlay(alignment: .top) { Divider().overlay(Color.orange.opacity(0.35)) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ask-\(ask.id)")
  }

  @ViewBuilder private func plan(online: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Plan ready").font(.headline)
      if !ask.title.isEmpty { Text(ask.title).font(.mono(.caption)).foregroundStyle(.secondary) }
      if ask.options.isEmpty {
        Text(
          onScreen == nil
            ? "Answer it on the computer: PocketTerm can\u{2019}t read this terminal." : "\(agentLabel) is waiting on its screen"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("plan-waiting")
      }
      ForEach(Array(ask.options.enumerated()), id: \.offset) { i, label in
        Button {
          Task { await answer(plan: i) }
        } label: {
          HStack {
            Text(label).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if sending && planPick == i { ProgressView().controlSize(.small) }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(busy || !online)
        .accessibilityIdentifier("plan-\(i)")
      }
      if let onScreen {
        HStack {
          Spacer()
          Button(action: onScreen) {
            Label(ask.options.isEmpty ? "Screen" : "View plan", systemImage: "terminal")
          }
          .accessibilityIdentifier(ask.options.isEmpty ? "plan-screen" : "view-plan")
        }
      }
    }
  }

  @ViewBuilder private func approval(online: Bool) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Approve \(ask.tool)?").font(.headline)
      if !ask.summary.isEmpty {
        Text(ask.summary).font(.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
      }
    }
    HStack(spacing: 8) {
      Spacer()
      Button("Deny") { Task { await answer() } }
        .buttonStyle(.bordered)
        .disabled(busy || !online)
        .accessibilityIdentifier("deny")
      Button {
        Task { await answer(approve: true) }
      } label: {
        if sending { ProgressView().controlSize(.small) } else { Text("Approve") }
      }
      .buttonStyle(.borderedProminent)
      .disabled(busy || !online)
      .accessibilityIdentifier("approve")
    }
    .controlSize(.large)
  }

  @ViewBuilder private func questions(online: Bool) -> some View {
    ForEach(Array((ask.questions ?? []).enumerated()), id: \.offset) { i, q in
      question(i, q)
        .padding(.top, i > 0 ? 6 : 0)
    }
    HStack {
      Spacer()
      Button {
        Task { await answer() }
      } label: {
        if sending { ProgressView().controlSize(.small) } else { Text(sent ? "Answered" : "Answer") }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(busy || !online || !complete)
      .accessibilityIdentifier("answer")
    }
  }

  @ViewBuilder private func question(_ i: Int, _ q: LiveQuestion) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if !q.header.isEmpty {
        Text(q.header)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tint)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Color.accentColor.opacity(0.14), in: Capsule())
      }
      Text(q.question).font(.body)
      if q.multi { Text("Pick any").font(.caption).foregroundStyle(.secondary) }
      SessionFlowLayout(spacing: 6) {
        ForEach(Array(q.options.enumerated()), id: \.offset) { o, label in
          AnswerChip(
            label: q.recommended == o ? "\(label) \u{2605}" : label,
            check: q.multi,
            selected: picks[i].contains(o),
            enabled: !busy
          ) {
            Haptics.picked()
            let on = !picks[i].contains(o)
            if !q.multi {
              picks[i].removeAll()
              other[i] = ""
            }
            if on { picks[i].insert(o) } else { picks[i].remove(o) }
          }
          .accessibilityIdentifier("ask-\(i)-\(o)")
        }
      }
      TextField("Other…", text: $other[i], axis: .vertical)
        .lineLimit(1...4)
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .disabled(busy)
        .onChange(of: other[i]) { _, t in
          if !q.multi && !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { picks[i].removeAll() }
        }
        .accessibilityIdentifier("ask-\(i)-other")
    }
  }
}

/// An answer to pick: all of its label shows, wrapping within the row; picked, it fills with the tint (and, for a
/// question taking several, shows a check).
private struct AnswerChip: View {
  let label: String
  let check: Bool
  let selected: Bool
  let enabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if check { Image(systemName: selected ? "checkmark.circle.fill" : "circle").imageScale(.small) }
        Text(label).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
      }
      .font(.subheadline)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .foregroundStyle(selected ? Color.white : Color.primary)
      .background(
        selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.tertiarySystemFill)),
        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.6)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .animation(.snappy(duration: 0.2), value: selected)
  }
}

/// A picker a slash command opened in the agent's terminal UI (/resume, /model, /tree …), as the computer read it
/// off the screen: its items to pick from, a search when it has one, Cancel (Esc) and the screen itself.
struct MenuCard: View {
  let remote: TerminalRemote
  let session: String

  /// The terminal window the agent runs in, for Esc; nil when it can't press keys.
  let window: String?
  let ask: LiveAsk
  let onScreen: (() -> Void)?
  let maxHeight: CGFloat

  @State private var search = ""
  @State private var searchSoon: Task<Void, Never>?

  /// The item being picked, or -1 for Cancel.
  @State private var busy: Int?

  /// Put away here (no keys to press Esc with); a new picker shows again.
  @State private var hidden = false

  private func run(_ what: Int, _ action: @escaping () async throws -> Void) {
    busy = what
    Task {
      do { try await action() } catch { Toaster.shared.show(errorText(error)) }
      busy = nil
    }
  }

  private func pick(_ i: Int) {
    run(i) { try await remote.answer(session, ask, answers: [LiveAnswer(picks: [i])]) }
  }

  /// What's typed goes to the picker's search once typing pauses.
  private func searchChanged(_ text: String) {
    searchSoon?.cancel()
    searchSoon = Task {
      try? await Task.sleep(for: .milliseconds(300))
      if Task.isCancelled { return }
      do {
        try await remote.answer(session, ask, answers: [LiveAnswer(custom: text)])
      } catch {
        Toaster.shared.show(errorText(error))
      }
    }
  }

  var body: some View {
    if !hidden {
      let enabled = busy == nil && remote.online
      // Picking presses keys in the agent's window: with none, only the screen and Hide.
      let picks = enabled && window != nil
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(ask.title.isEmpty ? (remote.session(session)?.agent ?? remote.agent).label : ask.title)
            .font(.headline)
          Spacer()
          if let onScreen {
            Button("Screen", action: onScreen).accessibilityIdentifier("menu-screen")
          }
          if let window {
            Button {
              run(-1) { try await remote.press(window, "esc") }
            } label: {
              if busy == -1 { ProgressView().controlSize(.small) } else { Text("Cancel") }
            }
            .disabled(!enabled)
            .accessibilityIdentifier("menu-cancel")
          } else {
            Button("Hide") { hidden = true }.accessibilityIdentifier("menu-hide")
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        if window == nil {
          Text("PocketTerm can\u{2019}t press keys in this terminal. Pick on the computer.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
        }
        if ask.filter && window != nil {
          HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search…", text: $search)
              .autocorrectionDisabled()
              .textInputAutocapitalization(.never)
              .onChange(of: search) { _, t in searchChanged(t) }
              .accessibilityIdentifier("menu-search")
          }
          .font(.subheadline)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .disabled(!remote.online)
          .padding(.horizontal, 16)
        }
        if ask.items.isEmpty {
          Text("Nothing matches.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else {
          CappedScroll(maxHeight: maxHeight) {
            VStack(spacing: 2) {
              ForEach(Array(ask.items.enumerated()), id: \.offset) { i, item in
                menuItem(i, item, enabled: picks)
              }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
          }
        }
      }
      .background(.bar)
      .overlay(alignment: .top) { Divider() }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("ask-\(ask.id)")
    }
  }

  private func menuItem(_ i: Int, _ item: MenuItem, enabled: Bool) -> some View {
    // The row the picker's cursor is on: tinted and outlined in the accent, so it reads in every theme.
    let current = i == ask.selected
    return Button {
      pick(i)
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(item.label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
          if !item.detail.isEmpty {
            Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          }
        }
        .multilineTextAlignment(.leading)
        Spacer(minLength: 8)
        if busy == i { ProgressView().controlSize(.small) }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        current ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        if current { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityAddTraits(current ? .isSelected : [])
    .accessibilityIdentifier("menu-\(i)")
  }
}
