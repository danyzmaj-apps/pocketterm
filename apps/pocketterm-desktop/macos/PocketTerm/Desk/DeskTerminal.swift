import AppKit
import PocketTermTerminals
import SwiftTerm
import SwiftUI

/// One Desk terminal on screen: SwiftTerm's view running `tmux attach` to its session. tmux keeps the session; this
/// is only a window onto it, so it can come and go (another project shown, Desk closed) and attach again.
final class DeskTerminalView: LocalProcessTerminalView {
  let session: String
  /// Its client ended (the session ended, or tmux went): attach again before showing it.
  fileprivate(set) var ended = false
  /// Clicked: Desk moves the focus here.
  var onFocus: (() -> Void)?
  private let watcher = Watcher()

  /// SwiftTerm's process delegate, apart: the view itself has its own methods by those names.
  private final class Watcher: LocalProcessTerminalViewDelegate {
    weak var view: DeskTerminalView?
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { view?.ended = true }
  }

  init(session: String) {
    self.session = session
    super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    watcher.view = self
    processDelegate = watcher
    font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    // Option types its own characters (é, and @ or [ on some layouts).
    optionAsMetaKey = false
    applyColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// Attaches to the session (again, once its last client ended).
  func attach(_ desk: Desk) {
    guard let (exe, args) = desk.attach(session) else { return }
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    if env["LANG"].map({ !$0.lowercased().contains("utf") }) ?? true { env["LANG"] = "en_US.UTF-8" }
    env.removeValue(forKey: "TMUX")
    ended = false
    startProcess(executable: exe, args: args, environment: env.map { "\($0.key)=\($0.value)" }, execName: "tmux")
  }

  /// The system's text colors, light or dark with the Mac.
  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      nativeForegroundColor = NSColor.textColor.usingColorSpace(.sRGB) ?? .textColor
      nativeBackgroundColor = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .textBackgroundColor
      caretColor = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .controlAccentColor
      selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB) ?? .selectedTextBackgroundColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }
}

/// Desk's terminal views, one per session, kept while PocketTerm runs: showing another project and coming back
/// finds the terminal as it was, without attaching again.
@MainActor
final class DeskTerminals {
  static let shared = DeskTerminals()
  private var views: [String: DeskTerminalView] = [:]
  private var mouse: Any?
  /// The terminal a Shift-drag selects in, mouse reporting off until the button is up.
  private var selecting: DeskTerminalView?

  private init() {
    // A click in a terminal gives it Desk's focus. tmux takes the mouse (scrolling back, its own selection); with
    // Shift held the terminal selects as a Mac text view does, for ⌘C. (SwiftTerm's mouse methods can't be
    // overridden from here.)
    mouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
      MainActor.assumeIsolated { self?.saw(event) }
      return event
    }
  }

  private func saw(_ event: NSEvent) {
    if event.type == .leftMouseUp {
      // After the terminal has had the button up.
      if let v = selecting { DispatchQueue.main.async { v.allowMouseReporting = true } }
      selecting = nil
      return
    }
    guard let window = event.window, let content = window.contentView else { return }
    var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
    while let h = hit, !(h is DeskTerminalView) { hit = h.superview }
    guard let v = hit as? DeskTerminalView else { return }
    v.onFocus?()
    if event.modifierFlags.contains(.shift) {
      v.allowMouseReporting = false
      selecting = v
    }
  }

  func view(_ session: String, _ desk: Desk) -> DeskTerminalView {
    if let v = views[session] {
      if v.ended { v.attach(desk) }
      return v
    }
    let v = DeskTerminalView(session: session)
    v.attach(desk)
    views[session] = v
    return v
  }

  /// The session ended: its view goes (its tmux client ended with it).
  func drop(_ session: String) {
    views.removeValue(forKey: session)?.terminate()
  }

  /// Only `sessions` are left.
  func keep(_ sessions: Set<String>) {
    for name in views.keys where !sessions.contains(name) { drop(name) }
  }
}

/// A Desk terminal in SwiftUI: a holder the terminal's view moves into, so one view can show in any layout.
struct DeskTerminal: NSViewRepresentable {
  let session: String
  let desk: Desk
  let focused: Bool
  /// Bumped when the focused terminal should take the keyboard.
  let focusTick: Int
  let onFocus: () -> Void

  final class Holder: NSView {
    var lastTick = -1
  }

  func makeNSView(context: Context) -> Holder { Holder() }

  func updateNSView(_ holder: Holder, context: Context) {
    let term = DeskTerminals.shared.view(session, desk)
    term.onFocus = onFocus
    if term.superview !== holder {
      term.removeFromSuperview()
      term.translatesAutoresizingMaskIntoConstraints = false
      holder.addSubview(term)
      NSLayoutConstraint.activate([
        term.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 6),
        term.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -2),
        term.topAnchor.constraint(equalTo: holder.topAnchor, constant: 4),
        term.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -2),
      ])
    }
    if focused && holder.lastTick != focusTick {
      holder.lastTick = focusTick
      DispatchQueue.main.async {
        if let w = term.window, w.firstResponder !== term { w.makeFirstResponder(term) }
      }
    }
  }
}
