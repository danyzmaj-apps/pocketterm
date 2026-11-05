import PocketTermKit
import SwiftUI

/// One coding session, live: its transcript laid out for the phone, what its agent asks, and a composer that
/// prompts it. [starting]: just launched, its agent may not have reported yet; [after]: what to do once a switch
/// from a screen-only window brought it here.
struct SessionPage: View {
  init(home: HomeModel, remote: TerminalRemote, sessionKey: String, starting: Bool, after: AfterSwitch) {
    self.home = home
    self.remote = remote
    _model = StateObject(
      wrappedValue: SessionModel(home: home, remote: remote, key: sessionKey, starting: starting, after: after))
  }

  let home: HomeModel
  @ObservedObject var remote: TerminalRemote
  @StateObject private var model: SessionModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State private var closing: TermWindow?
  @State private var showQueue = false

  private var key: String { model.key }

  var body: some View {
    let s = remote.session(key)
    let v = remote.view(key)
    let online = remote.online
    let ended = online && !remote.fromCache && s == nil && (model.seen || !model.starting)
    let windowKey = model.windowKey(s)
    let window = windowKey.flatMap { remote.window($0) }
    let windowTitle = window.flatMap { $0.title.isEmpty ? nil : $0.title }
    let title = s.map(sessionTitle) ?? windowTitle ?? model.agent(s).label
    let readable = model.can(windowKey, .read)
    let screen: (() -> Void)? = readable ? { home.openWindow(windowKey!) } : nil

    GeometryReader { page in
      TranscriptView(model: model, remote: remote, view: v, summary: s, ended: ended, openScreen: screen)
        .safeAreaInset(edge: .top, spacing: 0) { LinkNoteBar(remote: remote) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          VStack(spacing: 0) {
            if ended {
              HStack {
                Text("This session has ended.").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let screen { Button("Screen", action: screen).accessibilityIdentifier("ended-screen") }
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 12)
              .background(.bar)
              .accessibilityIdentifier("session-ended")
            } else {
              if let ask = s?.ask {
                Group {
                  if ask.isMenu {
                    MenuCard(
                      remote: remote, session: key, window: model.can(windowKey, .keys) ? windowKey : nil, ask: ask,
                      onScreen: screen, maxHeight: page.size.height * 0.4)
                  } else {
                    AskCard(remote: remote, session: key, ask: ask, onScreen: screen, maxHeight: page.size.height * 0.45)
                  }
                }
                .id(ask.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
              }
              Composer(
                model: model, attachments: model.attachments, summary: s,
                online: online && (s != nil || !model.starting), openQueue: { showQueue = true }
              )
              .background(.bar)
            }
          }
          .animation(.snappy, value: s?.ask?.id)
        }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        VStack(spacing: 0) {
          Text(title).font(.headline).lineLimit(1)
          SessionStatusLine(summary: s, agent: model.agent(s))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-title")
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        if let activities = remote.activities, let s {
          FollowButton(activities: activities, key: key) { Task { await model.toggleFollow(activities, s) } }
        }
        if let screen {
          Button(action: screen) {
            Label("Screen", systemImage: "terminal")
          }
          .accessibilityIdentifier("open-screen")
          .appTip(.openScreen)
        }
        if let window, online, window.can(.close) {
          Button {
            closing = window
          } label: {
            Label("Close window", systemImage: "xmark")
          }
          .accessibilityIdentifier("close-window")
        }
      }
    }
    .closeConfirmation(remote: remote, window: $closing) { dismiss() }
    .fullScreenCover(isPresented: $showQueue) {
      QueueScreen(remote: remote, session: key).toasts()
    }
    .onAppear { model.appear() }
    .onDisappear { model.disappear() }
    .onChange(of: scenePhase) { _, phase in if phase != .active { model.saveDraft() } }
  }
}

/// Under the title: "Needs you", "Working…" or how long it has been idle, then its profile, model and context.
private struct SessionStatusLine: View {
  let summary: LiveSummary?
  let agent: Agent
  @EnvironmentObject private var look: Appearance

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { _ in
      Group {
        if let s = summary {
          let state = s.ask != nil ? "Needs you" : s.busy ? "Working…" : "Idle\(s.at.map { " · \(ago($0))" } ?? "")"
          let color: Color = s.ask != nil ? .orange : s.busy ? look.theme.tint : .secondary
          Text(state).foregroundStyle(color) + Text(facts(s)).foregroundStyle(.secondary)
        } else {
          Text(agent.label).foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .lineLimit(1)
    }
  }

  /// " · profile · model · 49%", each part only when known.
  private func facts(_ s: LiveSummary) -> String {
    var rest = ""
    if !s.profile.isEmpty { rest += " · \(s.profile)" }
    if !s.model.isEmpty { rest += " · \(s.model)" }
    if let ctx = s.ctx { rest += " · \(ctx)%" }
    return rest
  }
}

/// Follow on Lock Screen (a Live Activity), or stop.
private struct FollowButton: View {
  @ObservedObject var activities: LiveActivities
  let key: String
  let action: () -> Void

  var body: some View {
    let on = activities.following(key)
    Button(action: action) {
      Label(on ? "Stop following on Lock Screen" : "Follow on Lock Screen", systemImage: on ? "bell.badge.fill" : "bell.badge")
    }
    .tint(on ? nil : .secondary)
    .accessibilityIdentifier("follow-lock-screen")
    .appTip(.follow)
  }
}

/// The transcript, newest at the bottom by the composer: it keeps following the newest while the reader is there,
/// and keeps still while they read further up.
private struct TranscriptView: View {
  @ObservedObject var model: SessionModel
  let remote: TerminalRemote
  let view: LiveView?
  let summary: LiveSummary?
  let ended: Bool
  let openScreen: (() -> Void)?

  @State private var atBottom = true
  @State private var viewport: CGFloat = 0
  @State private var pinned: String?

  /// What changes when the transcript grows: the page follows it down while at the bottom.
  private struct Tail: Equatable {
    let count: Int
    let last: LiveItem?
    let outgoing: Int
    let working: Bool
  }

  var body: some View {
    let items = view?.items ?? []
    let s = summary
    let working = s.map { $0.busy && $0.ask == nil } ?? false
    if items.isEmpty && model.outgoing.isEmpty {
      empty(s)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            if view?.older == true { earlier(items, proxy) }
            ForEach(items, id: \.id) { i in
              TranscriptItemView(item: i, open: model.expanded.contains(i.id), toggle: { model.toggle(i.id) })
                .equatable()
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .id(i.id)
            }
            // Sent from here, until each comes back in the transcript.
            ForEach(model.outgoing) { o in
              OutgoingBubble(o: o) { model.retry(o) }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if working {
              HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Working…").font(.footnote).foregroundStyle(.secondary)
              }
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .transition(.opacity)
              .accessibilityIdentifier("working")
            }
            Color.clear
              .frame(height: 12)
              .id(bottomId)
              .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(space)).minY } action: { y in
                atBottom = y <= viewport + 24
              }
          }
          .animation(.snappy, value: model.outgoing.map(\.id))
        }
        .coordinateSpace(.named(space))
        .scrollDismissesKeyboard(.interactively)
        .modifier(BottomAnchored())
        .onAppear { DispatchQueue.main.async { proxy.scrollTo(bottomId, anchor: .bottom) } }
        .onGeometryChange(for: CGFloat.self) { $0.size.height - $0.safeAreaInsets.bottom } action: { viewport = $0 }
        .onChange(of: Tail(count: items.count, last: items.last, outgoing: model.outgoing.count, working: working)) {
          if atBottom { proxy.scrollTo(bottomId, anchor: .bottom) }
        }
        .onChange(of: items.first?.id) {
          // Earlier messages came in above: the one that was on top stays where it was.
          if let pinned { proxy.scrollTo(pinned, anchor: .top) }
        }
        .onChange(of: view?.epoch) {
          atBottom = true
          proxy.scrollTo(bottomId, anchor: .bottom)
        }
        .onChange(of: model.bottomRequest) {
          atBottom = true
          withAnimation(.snappy) { proxy.scrollTo(bottomId, anchor: .bottom) }
        }
      }
    }
  }

  private let space = "transcript"
  private let bottomId = "transcript-bottom"

  private func earlier(_ items: [LiveItem], _ proxy: ScrollViewProxy) -> some View {
    Group {
      if model.loadingOlder {
        ProgressView()
      } else {
        Button("Earlier messages") {
          pinned = items.first?.id
          Task {
            await model.older()
            try? await Task.sleep(for: .seconds(2))
            pinned = nil
          }
        }
        .disabled(!remote.online)
        .accessibilityIdentifier("earlier")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 12)
    .padding(.bottom, 6)
  }

  @ViewBuilder private func empty(_ s: LiveSummary?) -> some View {
    let agent = model.agent(s).label
    let starting = model.starting && !model.seen
    let text =
      starting
      ? (model.late
        ? "\(agent) hasn't reported yet. It may be asking something on its screen first (like whether to trust this "
          + "folder): open the screen to answer." : "Starting \(agent)…")
      : ended
        ? "This session has ended."
        : view != nil ? "Nothing yet. Prompt \(agent) below." : remote.online ? "Loading…" : "Not on this phone yet."
    // Scrolls when the room is short (keyboard up, landscape, large text).
    ScrollView {
      VStack(spacing: 12) {
        if starting && !model.late { ProgressView() }
        Text(text)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("session-empty")
        if starting, let openScreen, remote.online {
          Button(action: openScreen) {
            Label("Open its screen", systemImage: "terminal")
          }
          .accessibilityIdentifier("open-its-screen")
        }
      }
      .padding(32)
      .frame(maxWidth: .infinity)
      .containerRelativeFrame(.vertical, alignment: .center) { h, _ in h }
    }
    .scrollBounceBehavior(.basedOnSize)
  }
}

/// Opens at the newest, and a short transcript sits down by the composer; what arrives below doesn't move what
/// the reader looks at further up (the page follows it only while at the bottom).
private struct BottomAnchored: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 18, *) {
      content
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
    } else {
      content
    }
  }
}
