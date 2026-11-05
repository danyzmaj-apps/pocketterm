import PocketTermKit
import SwiftUI

/// What the close question says about [w] on [remote]'s computer: its agent's session ends (or the window
/// closes), and what runs in it with it.
func closeWording(_ remote: TerminalRemote, _ w: TermWindow) -> (title: String, detail: String, action: String) {
  closeWording(w, computer: remote.desktopName, path: w.cwd.isEmpty ? "" : shortPath(remote, w.cwd))
}

/// [closeWording] for a computer named [computer] (nil while not known), [path] being where [w] runs, short.
func closeWording(_ w: TermWindow, computer: String?, path: String) -> (title: String, detail: String, action: String) {
  let who = computer ?? "the computer"
  let at = path.isEmpty ? "" : " in \(path)"
  if let agent = w.agent {
    return ("End this \(agent.label) session on \(who)?", "Its window\(at) closes with it.", "End session")
  }
  return (
    "Close this window on \(who)?",
    "\(w.program.isEmpty ? "Whatever runs in it" : w.program)\(at) stops with it.",
    "Close window"
  )
}

/// Asks before [window] closes on the computer (Dart's CloseConfirm, as iOS's action sheet): shown while
/// [window] is set, cleared when answered. Closing runs `remote.close`, says what went wrong, and calls
/// [onClosed] once the window closed.
private struct CloseConfirmation: ViewModifier {
  @ObservedObject var remote: TerminalRemote
  @Binding var window: TermWindow?
  let onClosed: () -> Void

  /// The window asked about, kept while the sheet slides away so its wording doesn't blank.
  @State private var asked: TermWindow?

  func body(content: Content) -> some View {
    let w = window ?? asked
    let words = w.map { closeWording(remote, $0) }
    content
      .confirmationDialog(
        words?.title ?? "",
        isPresented: Binding(get: { window != nil }, set: { if !$0 { window = nil } }),
        titleVisibility: .visible,
        presenting: w
      ) { w in
        Button(closeWording(remote, w).action, role: .destructive) { close(w) }
          .accessibilityIdentifier("close-confirm")
        Button("Keep", role: .cancel) {}
          .accessibilityIdentifier("close-cancel")
      } message: { w in
        Text(closeWording(remote, w).detail)
      }
      .onChange(of: window) { _, w in if let w { asked = w } }
  }

  private func close(_ w: TermWindow) {
    Task {
      do {
        try await remote.close(w.key)
        Haptics.done()
        onClosed()
      } catch {
        Haptics.failed()
        Toaster.shared.show(errorText(error))
      }
    }
  }
}

extension View {
  /// Asks before [window] closes on the computer; see [CloseConfirmation].
  func closeConfirmation(remote: TerminalRemote, window: Binding<TermWindow?>, onClosed: @escaping () -> Void = {})
    -> some View
  {
    modifier(CloseConfirmation(remote: remote, window: window, onClosed: onClosed))
  }
}
