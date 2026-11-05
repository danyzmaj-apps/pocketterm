import PocketTermKit
import SwiftUI

/// One terminal window: its screen as text, live, plus a composer and the keys a terminal program needs (a coding
/// agent's menus: arrows, Enter, Esc), each as far as the window's terminal allows. The phone stays awake while it
/// shows: a terminal is something you watch.
struct TerminalPage: View {
  @ObservedObject var home: HomeModel
  @ObservedObject var remote: TerminalRemote
  let window: String

  /// Just launched: until the computer lists it, it's coming, not closed.
  let starting: Bool

  init(home: HomeModel, remote: TerminalRemote, window: String, starting: Bool) {
    self.home = home
    self.remote = remote
    self.window = window
    self.starting = starting
    // A shell's long lines reflow to the phone's width; a full-screen program (a coding agent) lays out to its
    // own width, so its lines stay whole.
    _wrap = State(initialValue: remote.window(window)?.agent == nil)
  }

  @EnvironmentObject private var look: Appearance
  @Environment(\.dismiss) private var dismiss

  @State private var wrap: Bool
  @State private var text = ""
  @State private var sending = false

  /// The close button was tapped: the page asks.
  @State private var closing: TermWindow?

  /// The window was listed once: missing from the list now, it closed.
  @State private var seen = false
  @State private var lines = ScreenLines()
  @State private var unwatch: (@MainActor () -> Void)?
  @FocusState private var typing: Bool

  /// The keys row: label, the key the computer presses, what VoiceOver calls it.
  private static let keys: [(String, String, String)] = [
    ("Esc", "esc", "Escape"),
    ("Tab", "tab", "Tab"),
    ("↑", "up", "Up arrow"),
    ("↓", "down", "Down arrow"),
    ("⏎", "enter", "Return"),
    ("^C", "ctrl+c", "Control C"),
  ]

  var body: some View {
    let w = remote.window(window)
    let online = remote.online
    let gone = online && !remote.fromCache && w == nil && (seen || !starting)
    // A window not in the list yet (just launched) can do everything.
    let can = { (c: TermCap) in w?.can(c) ?? true }
    let readable = can(.read)
    let keys = can(.keys)
    let compose = can(.line) || can(.type)
    let colors = self.colors
    // Dressed as its screen: the bars over and under it in the screen's light or dark, so a terminal reads as one
    // surface (no light bar on a dark screen, or the other way round).
    let scheme: ColorScheme = colors.background.isDark ? .dark : .light
    VStack(spacing: 0) {
      LinkNoteBar(remote: remote)
      SwitchBanner(home: home, remote: remote, window: window)
      content(w, gone: gone, readable: readable, online: online)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(colors.background.color.ignoresSafeArea())
    .environment(\.colorScheme, scheme)
    .toolbarBackground(colors.background.color, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarColorScheme(scheme, for: .navigationBar)
    .animation(.snappy, value: LinkNote(remote))
    .navigationTitle(w.map { $0.title.isEmpty ? $0.program : $0.title } ?? "Terminal")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        if readable {
          Button {
            wrap.toggle()
          } label: {
            Image(systemName: "text.word.spacing")
              .foregroundStyle(wrap ? look.theme.tint : Color.secondary)
          }
          .accessibilityLabel(wrap ? "Don't wrap lines" : "Wrap lines")
          .accessibilityIdentifier("wrap-lines")
        }
        if let w, online, w.can(.close) {
          Button {
            closing = w
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close window")
          .accessibilityIdentifier("close-window")
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if keys || compose {
        bar(enabled: online && !gone, keys: keys, compose: compose, canSend: online && !gone && !sending)
          .background(colors.background.color.ignoresSafeArea())
          .environment(\.colorScheme, scheme)
      }
    }
    .closeConfirmation(remote: remote, window: $closing) { dismiss() }
    .onAppear {
      KeepAwake.set(true)
      if unwatch == nil { unwatch = remote.watchWindow(window) }
      if w != nil { seen = true }
    }
    .onDisappear {
      KeepAwake.set(false)
      unwatch?()
      unwatch = nil
    }
    .onChange(of: w != nil) { _, listed in if listed { seen = true } }
  }

  @ViewBuilder
  private func content(_ w: TermWindow?, gone: Bool, readable: Bool, online: Bool) -> some View {
    if gone {
      ContentUnavailableView {
        Label("This window has closed.", systemImage: "rectangle.slash")
      }
      .accessibilityIdentifier("window-closed")
    } else if !readable, let w {
      unreadable(w)
    } else if let screen = remote.screen(window) {
      TerminalScreenView(screen: screen, colors: colors, wrap: wrap, cache: lines)
    } else if online {
      ProgressView()
    } else {
      Text("No screen yet.").foregroundStyle(.secondary)
    }
  }

  /// The computer's colours for this window's terminal, else the theme's (its half for the system's appearance).
  private var colors: TermColors { remote.colors[window] ?? look.theme.termColors }

  /// Why [w]'s screen doesn't show, and what would show it.
  private func unreadable(_ w: TermWindow) -> some View {
    let tmux = remote.terminals.first { $0.id == "tmux" }
    let fix =
      tmux.flatMap { $0.state == .missing ? $0.note : nil }
      ?? "Sessions you start from the phone open in tmux, which can."
    return ContentUnavailableView {
      Label {
        Text("\(termLabel(w.app)) can't share its screen.")
          .accessibilityIdentifier("screen-unreadable")
      } icon: {
        Image(systemName: "eye.slash")
      }
    } description: {
      Text(fix)
    }
  }

  // MARK: The keys and the composer

  /// The keys a terminal program needs, if the window's terminal can press them, and the composer, if it can
  /// type. It sits above the keyboard while typing.
  private func bar(enabled: Bool, keys: Bool, compose: Bool, canSend: Bool) -> some View {
    VStack(spacing: 6) {
      if keys && enabled {
        HStack(spacing: 6) {
          ForEach(Self.keys, id: \.1) { k in
            Button {
              press(k.1)
            } label: {
              Text(k.0)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .tint(.primary)
            .accessibilityLabel(k.2)
            .accessibilityIdentifier("key-\(k.1)")
          }
        }
      }
      if compose {
        HStack(alignment: .bottom, spacing: 8) {
          TextField("Type a line…", text: $text, axis: .vertical)
            .lineLimit(1...6)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($typing)
            .disabled(!enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityIdentifier("term-input")
          let ready = canSend && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          Button {
            Task { await send() }
          } label: {
            if sending {
              ProgressView().frame(width: 34, height: 34)
            } else {
              Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(ready ? look.theme.tint : Color.secondary)
            }
          }
          .frame(minWidth: 44, minHeight: 44)
          .disabled(!ready)
          .accessibilityLabel("Send (types it, then Enter)")
          .accessibilityIdentifier("term-send")
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private func press(_ key: String) {
    Haptics.picked()
    Task {
      do {
        try await remote.press(window, key)
      } catch {
        Toaster.shared.show(errorText(error))
      }
    }
  }

  /// Types the line, then Enter; the keyboard stays up for the next one.
  private func send() async {
    let line = text
    if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending { return }
    sending = true
    do {
      try await remote.send(window, line)
      text = ""
    } catch {
      Toaster.shared.show(errorText(error))
    }
    sending = false
  }
}
