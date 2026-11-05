import AppKit
import PocketTermDesktop
import PocketTermKit
import SwiftUI

// The small parts every screen uses (the Flutter app's setup_page.dart widgets and onboarding/commands_view.dart),
// in the Mac's own controls: system colors, the theme only as the accent.

extension Color {
  /// A theme color (PocketTermKit's palettes) as SwiftUI's.
  init(_ c: TermColor) {
    self.init(
      .sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255,
      opacity: Double(c.alpha) / 255)
  }
}

/// Opens `url` in the browser (or the app that takes it).
func openLink(_ url: URL) { NSWorkspace.shared.open(url) }

/// Opens `string` as a link; nothing when it isn't one.
func openLink(_ string: String) {
  if let url = URL(string: string) { openLink(url) }
}

/// A command as typed in a terminal.
let commandFont = Font.system(.callout, design: .monospaced)

/// How a line of status reads: fine, needs doing, broken, or only says something.
enum StatusKind {
  case ok, warn, error, info, working

  var symbol: String {
    switch self {
    case .ok: "checkmark.circle.fill"
    case .warn: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    case .info: "info.circle"
    case .working: "ellipsis.circle"
    }
  }

  var color: Color {
    switch self {
    case .ok: .green
    case .warn: .orange
    case .error: .red
    case .info, .working: .secondary
    }
  }
}

/// A line of status with its sign: ✓ done, ⚠︎ needs doing, ✕ broken.
struct StatusText: View {
  let kind: StatusKind
  let text: String

  init(_ kind: StatusKind, _ text: String) {
    self.kind = kind
    self.text = text
  }

  var body: some View {
    Label {
      Text(text).foregroundStyle(kind == .error ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: kind.symbol).foregroundStyle(kind.color)
    }
  }
}

/// A question with its answer folded away ("What is Tailscale, and why?"): a click shows it.
struct Explainer<Content: View>: View {
  let title: String
  let id: String
  @ViewBuilder let content: () -> Content
  @State private var open = false

  init(_ title: String, id: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.id = id
    self.content = content
  }

  var body: some View {
    DisclosureGroup(isExpanded: $open) {
      VStack(alignment: .leading, spacing: 8) { content() }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    } label: {
      Text(title)
    }
    .accessibilityIdentifier(id)
  }
}

/// A note in a box: what the person must not miss.
struct Notice: View {
  let text: String
  var systemImage = "info.circle"
  var id: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: systemImage).foregroundStyle(.tint)
      Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .font(.callout)
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(id ?? "")
  }
}

/// Where one step of a live checklist stands.
enum CheckState {
  /// Not known yet: the first look is on its way.
  case looking
  /// Done: one line, nothing to do.
  case done
  /// The step to do now: what and how, with its buttons.
  case now
  /// Waits for an earlier one.
  case later
}

/// One step of a live checklist: done ones collapse to a line, the one to do now shows its note and actions, later
/// ones only their title.
struct CheckRow<Actions: View>: View {
  let state: CheckState
  let title: String
  var note: String?
  var id: String
  @ViewBuilder let actions: () -> Actions

  init(
    _ state: CheckState, _ title: String, note: String? = nil, id: String,
    @ViewBuilder actions: @escaping () -> Actions
  ) {
    self.state = state
    self.title = title
    self.note = note
    self.id = id
    self.actions = actions
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Group {
        switch state {
        case .looking: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .now: Image(systemName: "arrow.right.circle.fill").foregroundStyle(.orange)
        case .later: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
      }
      .frame(width: 18)
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .fontWeight(state == .now ? .semibold : .regular)
          .foregroundStyle(state == .done || state == .now ? Color.primary : Color.secondary)
        if state == .now, let note {
          Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if state == .now {
          HStack(spacing: 8) { actions() }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(id)
  }
}

extension CheckRow where Actions == EmptyView {
  init(_ state: CheckState, _ title: String, note: String? = nil, id: String) {
    self.init(state, title, note: note, id: id) { EmptyView() }
  }
}

/// A command to type, with a button that copies it (and says so).
struct CopyCommand: View {
  let command: String
  var id: String?
  @State private var copied = false

  init(_ command: String, id: String? = nil) {
    self.command = command
    self.id = id
  }

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Text(command)
        .font(commandFont)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copied = true
      } label: {
        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
          .labelStyle(.iconOnly)
          .foregroundStyle(copied ? Color.green : Color.secondary)
      }
      .buttonStyle(.borderless)
      .help(copied ? "Copied" : "Copy")
      .accessibilityLabel(copied ? "Copied" : "Copy")
      .accessibilityIdentifier(id.map { "\($0)-copy" } ?? "copy-command")
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    .onChange(of: command) { _ in copied = false }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(id ?? "")
  }
}

/// A sheet's layout: its title, what it says, and its buttons at the bottom right.
struct SheetLayout<Content: View, Buttons: View>: View {
  let title: String
  var width: CGFloat = 460
  @ViewBuilder let content: () -> Content
  @ViewBuilder let buttons: () -> Buttons

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.title3.weight(.semibold))
      content()
      HStack {
        Spacer()
        buttons()
      }
      .padding(.top, 4)
    }
    .padding(20)
    .frame(width: width, alignment: .leading)
  }
}

/// A button that runs `argv` for the person, after they read what it does (`what`) and the command itself, and
/// confirmed it: never on its own. While it runs, it says so; then done, or what went wrong and Try again.
struct ConfirmedCommand: View {
  let commands: PocketTermDesktop.Commands
  /// The button's words: what it gets done ("Install tmux").
  let label: String
  let argv: [String]
  /// What running it does, a sentence or two, shown before it runs.
  let what: String
  /// Why macOS may ask for the password, for a command that may need it.
  var password: String?
  /// It went through.
  var onDone: (() -> Void)?

  private enum Run { case idle, running, done, failed }
  @State private var state = Run.idle
  @State private var failure = ""
  @State private var asking = false

  private var command: String { argv.joined(separator: " ") }

  var body: some View {
    Group {
      switch state {
      case .idle: button(label)
      case .running:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Running \(command)…").font(.callout).foregroundStyle(.secondary)
        }
      case .done:
        Label("Done", systemImage: "checkmark").foregroundStyle(.secondary)
          .accessibilityIdentifier("command-done")
      case .failed:
        VStack(alignment: .leading, spacing: 6) {
          Text("That didn’t work:\n\(failure)").font(.callout).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("command-failed")
          button("Try again")
        }
      }
    }
    .sheet(isPresented: $asking) {
      SheetLayout(title: label) {
        Text(what).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("PocketTerm will run:").font(.callout).foregroundStyle(.secondary)
        Text(command)
          .font(commandFont)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
          .accessibilityIdentifier("command-shown")
        if password != nil {
          Text("macOS asks for your Mac password during the install.").font(.callout).foregroundStyle(.secondary)
        }
      } buttons: {
        Button("Cancel", role: .cancel) { asking = false }.keyboardShortcut(.cancelAction)
        Button("Run") {
          asking = false
          Task { await runIt() }
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("command-run")
      }
    }
  }

  private func button(_ text: String) -> some View {
    Button(text) { asking = true }.accessibilityIdentifier("command-\(argv.last ?? "")")
  }

  private func runIt() async {
    state = .running
    let result: CommandResult
    do {
      result = try await commands.run(argv, password: password)
    } catch {
      result = CommandResult(code: nil, output: "\(error)")
    }
    let ok = result.code == 0
    let lines = result.output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let last = lines.suffix(3).joined(separator: "\n")
    failure = last.isEmpty ? "It stopped with code \(result.code.map(String.init) ?? "null")." : last
    state = ok ? .done : .failed
    if ok { onDone?() }
  }
}

/// A small inline message under a control that did something ("New key made…", "Key not reset: …"): what the
/// Flutter app showed as a toast. It goes after a few seconds.
struct InlineMessage: View {
  @Binding var message: String?
  var error = false

  var body: some View {
    if let message {
      Text(message)
        .font(.callout)
        .foregroundStyle(error ? Color.red : Color.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: message) {
          try? await Task.sleep(nanoseconds: 6_000_000_000)
          if self.message == message { self.message = nil }
        }
    }
  }
}
