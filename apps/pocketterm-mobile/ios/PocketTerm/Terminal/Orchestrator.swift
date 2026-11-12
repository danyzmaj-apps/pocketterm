import PocketTermKit
import SwiftUI

// The computer's orchestrator (LiveSummary.orchestrator): an omp session the computer starts in PocketTerm's own
// folder, with tools to see and steer its other sessions. The list shows it as a bar, not as a project; the bar
// opens it as a chat.

private let askText = "Ask about your sessions…"

/// The bar at the bottom of the list: what the orchestrator is up to; a tap opens its chat over everything.
/// Shown once the computer's omp can run one (PocketTerm installed in it), or one runs.
struct OrchestratorBar: View {
  @ObservedObject var home: HomeModel
  @ObservedObject var remote: TerminalRemote

  init(home: HomeModel, remote: TerminalRemote) {
    self.home = home
    self.remote = remote
  }

  @EnvironmentObject private var look: Appearance
  @State private var open = false

  /// A session the chat asked to open, once it has slid away.
  @State private var opening: String?

  var body: some View {
    let o = remote.orchestrator
    if o != nil || remote.agents[.omp] == .installed {
      let (text, color): (String, Color) =
        if let ask = o?.ask {
          ("Needs you: \(ask.text)", .orange)
        } else if o?.busy == true {
          ("Working…", look.theme.tint)
        } else if let p = o?.preview, !p.isEmpty {
          (p, .primary)
        } else {
          (askText, .secondary)
        }
      let working = o != nil && o?.ask == nil && o?.busy == true
      Button {
        open = true
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "sparkles")
            .foregroundStyle(look.theme.tint)
            .symbolEffect(.pulse, isActive: working)
          if working { ProgressView().controlSize(.small) }
          Text(text)
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .modifier(BarBackground())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Orchestrator")
      .accessibilityValue(text)
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("orchestrator-bar")
      .fullScreenCover(
        isPresented: $open,
        onDismiss: {
          // The session page answers what it asks, and shows its whole transcript.
          if let key = opening {
            opening = nil
            home.openSession(key)
          }
        }
      ) {
        OrchestratorScreen(remote: remote, drafts: home.app.drafts) { key in
          opening = key
          open = false
        }
        .environmentObject(look)
        .tint(look.theme.tint)
        .toasts()
        .analyticsScreen("orchestrator")
      }
    }
  }
}

/// The bar's capsule: Liquid Glass on iOS 26, a material before.
private struct BarBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26, *) {
      content.glassEffect(.regular.interactive(), in: Capsule())
    } else {
      content
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
  }
}

/// The orchestrator's chat over everything: what was asked and answered, Stop while it works, and its
/// conversation's own page.
struct OrchestratorScreen: View {
  @ObservedObject var remote: TerminalRemote
  let drafts: Drafts

  /// Opens session [key]'s own page.
  let onOpen: (String) -> Void

  @Environment(\.dismiss) private var dismiss

  /// What went wrong last, shown above the composer; Stop sets it too.
  @State private var error: String?

  var body: some View {
    let o = remote.orchestrator
    NavigationStack {
      OrchestratorChat(remote: remote, drafts: drafts, error: $error, onOpen: onOpen)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }
              .accessibilityIdentifier("orchestrator-close")
          }
          ToolbarItem(placement: .principal) {
            let state = o?.ask != nil ? " · Needs you" : o?.busy == true ? " · Working…" : ""
            HStack(spacing: 0) {
              Text("Orchestrator").font(.headline)
              if !state.isEmpty { Text(state).font(.headline).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
          }
          ToolbarItemGroup(placement: .primaryAction) {
            if let o, o.busy, remote.online {
              Button {
                Task {
                  do {
                    try await remote.abort(o.key)
                  } catch {
                    self.error = errorText(error)
                  }
                }
              } label: {
                Image(systemName: "stop.circle")
              }
              .accessibilityLabel("Stop")
              .accessibilityIdentifier("orchestrator-stop")
            }
            if let o {
              Button {
                onOpen(o.key)
              } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
              }
              .accessibilityLabel("Open conversation")
              .accessibilityIdentifier("orchestrator-open")
            }
          }
        }
    }
  }
}

/// The orchestrator's chat: the person's prompts and its answers (no tools), and a composer whose microphone
/// listens only while held and puts what it heard into the field. The first prompt starts the orchestrator on the
/// computer when none runs.
private struct OrchestratorChat: View {
  @ObservedObject var remote: TerminalRemote
  let drafts: Drafts
  @Binding var error: String?
  let onOpen: (String) -> Void

  @EnvironmentObject private var look: Appearance

  @State private var text = ""
  @State private var sending = false
  @State private var starting = false
  @FocusState private var focused: Bool

  /// The orchestrator the computer streams to this phone: without a watch it sends no transcript.
  @State private var watching = Watching()

  private enum Voice { case off, checking, listening, stopping }
  @State private var voice = Voice.off

  /// What was heard so far while held, and how loud.
  @State private var live = ""
  @State private var level = 0.0

  /// The finger came up (perhaps before listening started).
  @State private var released = false
  @State private var held = false
  @State private var listening: Task<Void, Never>?
  @State private var stopWait: Task<Void, Never>?

  private var draftKey: String { "\(remote.desktopId)/orchestrator" }

  var body: some View {
    let o = remote.orchestrator
    let on = voice != .off
    chat(o)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .safeAreaInset(edge: .bottom, spacing: 0) { composer }
      // Held, the microphone lights the whole sheet: it's listening.
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(on ? look.theme.tint : .clear, lineWidth: 2)
          .background(on ? look.theme.tint.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 16))
          .padding(4)
          .allowsHitTesting(false)
          .animation(.easeOut(duration: 0.15), value: on)
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("orchestrator-sheet")
      .onAppear {
        follow()
        // Typed before it came: what's in the field wins.
        if text.isEmpty { text = drafts.load(draftKey) }
      }
      .onChange(of: o?.key) { _, _ in follow() }
      .onDisappear {
        drafts.save(draftKey, text)
        watching.stop()
        // Discards what was heard.
        listening?.cancel()
        stopWait?.cancel()
      }
  }

  /// Watches the orchestrator there is now, if it changed.
  private func follow() {
    let key = remote.orchestrator?.key
    if key == watching.key { return }
    watching.stop()
    watching.key = key
    watching.unwatch = key.map { remote.watchSession($0) }
  }

  // MARK: The chat

  @ViewBuilder
  private func chat(_ o: LiveSummary?) -> some View {
    let items = (o.flatMap { remote.view($0.key) }?.items ?? []).filter {
      ($0.kind == .user || $0.kind == .assistant) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if items.isEmpty {
      Text(
        "Ask about the sessions on \(remote.desktopName ?? "this computer"): what\u{2019}s running, what\u{2019}s "
          + "stuck, what each one did. It can also prompt or stop them."
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      .padding(32)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(items, id: \.id) { i in
              if i.kind == .user { userBubble(i.text) } else { answer(i.text) }
            }
            if let o, let ask = o.ask {
              HStack(spacing: 8) {
                Text("Needs you: \(ask.text)")
                  .foregroundStyle(.orange)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Button("Answer") { onOpen(o.key) }
                  .buttonStyle(.bordered)
              }
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("orchestrator-answer")
            } else if o?.busy == true {
              HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Working…").foregroundStyle(.secondary)
              }
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("orchestrator-working")
            }
            Color.clear.frame(height: 1).id("end")
          }
          .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: items.last) { _, _ in
          withAnimation { proxy.scrollTo("end", anchor: .bottom) }
        }
        .onChange(of: o?.busy) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
      }
    }
  }

  private func userBubble(_ text: String) -> some View {
    Text(text)
      .textSelection(.enabled)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(look.theme.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(.leading, 48)
  }

  private func answer(_ text: String) -> some View {
    let md =
      (try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
    return Text(md)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: The composer

  private var composer: some View {
    VStack(alignment: .leading, spacing: 6) {
      if voice != .off {
        VStack(alignment: .leading, spacing: 8) {
          Text(live.isEmpty ? "Listening…" : live)
            .foregroundStyle(live.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
          ProgressView(value: level)
            .tint(look.theme.tint)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("orchestrator-live")
        .transition(.opacity)
      }
      if let error {
        Text(error)
          .font(.footnote)
          .foregroundStyle(.orange)
          .accessibilityIdentifier("orchestrator-error")
      }
      if starting {
        Text("Starting the orchestrator on \(remote.desktopName ?? "the computer")…")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("orchestrator-starting")
      }
      HStack(alignment: .bottom, spacing: 4) {
        TextField("Ask the orchestrator…", text: $text, axis: .vertical)
          .lineLimit(1...5)
          .textInputAutocapitalization(.sentences)
          .focused($focused)
          .padding(.leading, 14)
          .padding(.trailing, text.isEmpty ? 14 : 36)
          .padding(.vertical, 10)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
          .accessibilityIdentifier("orchestrator-input")
          // Dictation fills the field with a whole sentence; one tap empties it.
          .overlay(alignment: .trailing) {
            if !text.isEmpty {
              Button {
                text = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
                  .frame(width: 36, height: 36)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Clear")
              .accessibilityIdentifier("orchestrator-clear")
            }
          }
        mic
        let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
        Button {
          Task { await send() }
        } label: {
          if sending {
            ProgressView().frame(width: 34, height: 34)
          } else {
            Image(systemName: "arrow.up.circle.fill")
              .font(.system(size: 32))
              .foregroundStyle(canSend ? look.theme.tint : Color.secondary)
          }
        }
        .frame(minWidth: 44, minHeight: 44)
        .disabled(!canSend)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("orchestrator-send")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
    .animation(.snappy, value: voice)
  }

  /// Listens only while held; VoiceOver's double-tap starts it and the next one stops it.
  private var mic: some View {
    let on = voice == .listening || voice == .stopping
    return Image(systemName: on ? "mic.fill" : "mic")
      .font(.system(size: 22))
      .foregroundStyle(on ? look.theme.tint : Color.secondary)
      .symbolEffect(.variableColor.iterative, isActive: voice == .listening)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in
            if held { return }
            held = true
            Task { await down() }
          }
          .onEnded { _ in
            held = false
            Task { await up() }
          }
      )
      .accessibilityElement()
      .accessibilityLabel("Microphone")
      .accessibilityHint("Hold to talk")
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        if voice == .off { Task { await down() } } else { Task { await up() } }
      }
      .accessibilityIdentifier("orchestrator-mic")
  }

  // MARK: Sending

  private func send() async {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if prompt.isEmpty || sending { return }
    sending = true
    error = nil
    AppAnalytics.shared.event("prompt_sent", ["mode": .string("orchestrator"), "attachments": .bool(false)])
    defer {
      sending = false
      starting = false
    }
    do {
      var o = remote.orchestrator
      if o == nil {
        starting = true
        _ = try await remote.startOrchestrator()
        o = try await arrival(within: .seconds(30))
      }
      try await remote.prompt(o!.key, prompt)
      // Closed while it went: the prompt is sent all the same, and its draft goes.
      text = ""
      drafts.save(draftKey, "")
    } catch {
      self.error = errorText(error)
    }
  }

  /// The orchestrator, once the computer reports it (it says hello once omp is up).
  private func arrival(within timeout: Duration) async throws -> LiveSummary {
    let end = ContinuousClock.now + timeout
    while true {
      if let o = remote.orchestrator { return o }
      if ContinuousClock.now >= end {
        throw TerminalException("The orchestrator didn't start on the computer. Look at its terminal window.")
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  // MARK: Voice

  private func down() async {
    if voice != .off { return }
    released = false
    error = nil
    voice = .checking
    // The language the voice sheet listens in: the phone's choice, else Auto's.
    let language = await VoiceLanguage.shared.resolve(voiceSource)
    let check = (try? await voiceSource.check(language)) ?? SpeechCheck(.unavailable)
    if !check.ready {
      error = speechProblemText(check, language)
      voice = .off
      return
    }
    // Lifted while it checked: nothing heard.
    if released {
      voice = .off
      return
    }
    Haptics.held()
    voice = .listening
    let events = voiceSource.listen(language)
    listening = Task {
      for await e in events {
        if Task.isCancelled { return }
        switch e {
        case .heard(let t): live = t
        case .level(let l): level = l
        case .ended:
          finish()
          return
        }
      }
      finish()
    }
  }

  private func up() async {
    released = true
    if voice != .listening { return }
    voice = .stopping
    stopWait = Task {
      try? await Task.sleep(for: .seconds(3))
      if !Task.isCancelled { finish() }
    }
    do {
      try await voiceSource.stop()
    } catch {
      finish()
    }
  }

  /// Done listening: what was heard goes into the field, after what's there. Never sends.
  private func finish() {
    if voice == .off { return }
    stopWait?.cancel()
    stopWait = nil
    listening?.cancel()
    listening = nil
    let heard = live.trimmingCharacters(in: .whitespacesAndNewlines)
    if !heard.isEmpty {
      text = appendSpoken(text, heard)
      focused = true
      Haptics.picked()
    }
    live = ""
    level = 0
    voice = .off
  }
}

/// The session a chat watches, and how to stop.
private final class Watching {
  var key: String?
  var unwatch: (@MainActor () -> Void)?

  @MainActor func stop() {
    unwatch?()
    unwatch = nil
    key = nil
  }
}
