import PocketTermDesktop
import PocketTermKit
import PocketTermTerminals
import SwiftUI

/// What Start new windows in tmux does, said where it's offered (the checklist and Settings' Ghostty card).
let ghosttyTmuxWhy =
  "Click once: from then on every new Ghostty window opens in tmux by itself, so your phone gets full control. "
  + "Nothing changes in how you use Ghostty. Settings → Terminals can undo it."

/// The setup checklist's terminals (GetReadyView): the terminals found on this Mac, each with its one-click fix where
/// it needs one (kitty's config, Automation), tmux when it's missing (installed with Homebrew once the person
/// confirms; MacPorts' line to type; without either, where to get Homebrew), and Ghostty's new windows in tmux.
/// Nothing to pick: new sessions open in the terminal used last, as Settings' Auto does. Looks again every few
/// seconds, so a permission given in System Settings or a new Homebrew shows; `onStatuses` hears each look.
struct MacTerminalsCard: View {
  @EnvironmentObject var app: AppController
  var poll: TimeInterval = 3
  var onStatuses: (([TermStatus]) -> Void)?

  @State private var statuses: [TermStatus]?

  /// What a fix told the person, by terminal, with the fix it was for and whether it failed: shown until a status no
  /// longer carries that fix (permission given, kitty.conf set), then the live status speaks.
  @State private var fixed: [String: Fixed] = [:]
  @State private var ghosttyCommand: GhosttyCommand?
  @State private var ghosttyError: String?

  private struct Fixed {
    let fix: TermFix?
    let note: String
    let failed: Bool
  }

  static let tmuxCommand = "brew install tmux"
  static let macPortsCommand = "sudo port install tmux"
  static let homebrew = URL(string: "https://brew.sh")!

  /// What tmux is and why Ghostty needs it.
  static let tmuxWhy =
    "tmux runs terminal sessions inside a window and lets other apps read and type into them. Ghostty doesn’t "
    + "let other apps do that, so sessions in Ghostty run in tmux to give your phone full control."

  /// Ghostty's config (new windows in tmux), where Ghostty can be.
  private var ghosttyConfig: GhosttyConfig? {
    app.terminals.ghostty == nil ? nil : GhosttyConfig.standard(home: app.terminals.home)
  }

  var body: some View {
    let all = statuses
    let found = (all ?? []).filter { $0.state != .missing && $0.id != "tmux" }
    let tmux = all?.first { $0.id == "tmux" }
    VStack(alignment: .leading, spacing: 12) {
      Text(
        found.isEmpty && all != nil
          ? "No terminal app found. PocketTerm works with kitty, iTerm2, Ghostty and WezTerm."
          : "Sessions you start from your phone open in the one you used last (Settings can pin one)."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if all == nil {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
      }
      ForEach(found, id: \.id) { row($0) }
      if let tmux, tmux.state == .missing {
        tmuxOffer
      } else if let tmux {
        row(tmux)
      }
      ghosttyInTmux(found, tmux)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mac-terminals")
    .task {
      while !Task.isCancelled {
        await look()
        try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
      }
    }
  }

  @ViewBuilder private var tmuxOffer: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Recommended: tmux").fontWeight(.semibold)
      Text(Self.tmuxWhy).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if app.commands.brew != nil {
        ConfirmedCommand(
          commands: app.commands,
          label: "Install tmux",
          argv: Commands.tmuxInstall,
          what: "Homebrew downloads and installs tmux, a free terminal tool. It takes a minute or two.",
          onDone: { Task { await look() } }
        )
        .padding(.top, 2)
        Text("Or type it in a terminal:").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
        CopyCommand(Self.tmuxCommand)
      } else if app.commands.macPorts != nil {
        Text("With MacPorts, type this in a terminal:").font(.caption).foregroundStyle(.secondary)
        CopyCommand(Self.macPortsCommand, id: "tmux-macports")
      } else {
        Text(
          "tmux comes from Homebrew, the free installer most Mac developers use, which isn’t on this Mac. Install "
            + "Homebrew from brew.sh, then come back: PocketTerm installs tmux from here. With MacPorts: "
            + "\(Self.macPortsCommand)."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("tmux-no-homebrew")
        Button("Get Homebrew") { openLink(Self.homebrew) }
          .accessibilityIdentifier("tmux-get-homebrew")
          .padding(.top, 2)
      }
    }
    .padding(.top, 2)
  }

  /// Ghostty with tmux here: its new windows in tmux, one click, saying first what it changes.
  @ViewBuilder private func ghosttyInTmux(_ found: [TermStatus], _ tmux: TermStatus?) -> some View {
    if let command = ghosttyCommand, let tmux, tmux.state != .missing, found.contains(where: { $0.id == "ghostty" }) {
      switch command.state {
      case .ours:
        Label {
          Text("New Ghostty windows open in tmux")
        } icon: {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        .accessibilityIdentifier("ghostty-tmux-on")
      case .theirs:
        Text(
          "Your Ghostty config already sets command = \(command.command), so PocketTerm leaves it alone. Add tmux "
            + "to that command yourself for full control."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      case .none:
        VStack(alignment: .leading, spacing: 8) {
          Text(ghosttyTmuxWhy).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Button("Start new windows in tmux") { Task { await startGhosttyInTmux() } }
            .accessibilityIdentifier("ghostty-tmux")
          if let ghosttyError {
            Text(ghosttyError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  private func row(_ s: TermStatus) -> some View {
    let ok = s.state == .ready || s.state == .idle
    let note = fixed[s.id]?.note ?? (s.state == .setup ? s.note : (ok ? "Ready" : s.note))
    let showFix =
      (s.fix == .kittyConfig || s.fix == .automation)
      && (fixed[s.id] == nil || fixed[s.id]!.failed || s.fix == .automation)
    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: ok ? "checkmark.circle.fill" : (s.state == .setup ? "exclamationmark.circle" : "minus.circle"))
        .foregroundStyle(ok ? Color.green : (s.state == .setup ? Color.orange : Color.secondary))
      VStack(alignment: .leading, spacing: 2) {
        Text(s.label)
        if !note.isEmpty {
          Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
      if showFix {
        Button(s.fix == .kittyConfig ? "Set up" : "Allow…") { Task { await fix(s) } }
          .accessibilityIdentifier("terminal-fix-\(s.id)")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal-\(s.id)")
  }

  private func look() async {
    let s = await app.terminals.statuses()
    if Task.isCancelled { return }
    statuses = s
    ghosttyCommand = ghosttyConfig?.read()
    for t in s {
      if let f = fixed[t.id], f.fix != t.fix { fixed[t.id] = nil }
    }
    onStatuses?(s)
  }

  /// New Ghostty windows open in tmux from now on.
  private func startGhosttyInTmux() async {
    guard let tmux = app.terminals.tmux?.executable, let config = ghosttyConfig else { return }
    do {
      try config.add(tmux)
      ghosttyError = nil
    } catch let e as TerminalException {
      ghosttyError = e.message
    } catch {
      ghosttyError = "\(error)"
    }
    await look()
  }

  private func fix(_ s: TermStatus) async {
    let result = await fixTerminal(app.terminals, s)
    fixed[s.id] = Fixed(fix: s.fix, note: result.note, failed: result.failed)
    await look()
  }
}
