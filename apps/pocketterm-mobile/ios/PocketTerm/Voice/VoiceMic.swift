import SwiftUI
import UIKit

/// Held this long, a press is a hold rather than a tap.
private let holdAfter: Duration = .milliseconds(300)

/// Slid this far up or left while held, lifting the finger cancels.
let voiceCancelDistance: CGFloat = 100

/// Moved this far before it counted as a hold: a scroll or a slip, neither a tap nor a hold.
private let touchSlop: CGFloat = 18

/// The composer's microphone. A tap opens the voice sheet, which listens until Stop; a hold opens it at once and
/// listens while held: lifting the finger stops and leaves what was said to check, sliding far up or left first
/// cancels. [existing]: the composer's text then, shown dimmed above what's said. [small]: inside the field,
/// beside the send button: smaller and dimmer.
struct VoiceMic: View {
  init(enabled: Bool, existing: @escaping () -> String, small: Bool = false, onResult: @escaping (VoiceResult) -> Void) {
    self.enabled = enabled
    self.existing = existing
    self.small = small
    self.onResult = onResult
  }

  let enabled: Bool
  let existing: () -> String
  let small: Bool
  let onResult: (VoiceResult) -> Void

  /// A finger is on it and it hasn't opened yet: it grows on a disc, so a hold shows it's taking before the
  /// sheet slides up.
  @State private var pressed = false
  @State private var open = OpenFlag()

  var body: some View {
    let style: AnyShapeStyle =
      !enabled ? AnyShapeStyle(.quaternary) : small ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)
    ZStack {
      Circle()
        .fill(style)
        .opacity(pressed ? 0.16 : 0)
        .frame(width: small ? 32 : 40, height: small ? 32 : 40)
      Image(systemName: "mic")
        .font(.system(size: small ? 18 : 21, weight: .regular))
        .foregroundStyle(style)
        .scaleEffect(pressed ? 1.15 : 1)
    }
    .frame(width: small ? 36 : 48, height: 48)
    .contentShape(Rectangle())
    .animation(.easeOut(duration: 0.15), value: pressed)
    .overlay { MicTouches(enabled: enabled, pressed: $pressed, open: openSheet) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Voice prompt")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier(small ? "session-mic-small" : "session-mic")
    .accessibilityAction {
      if enabled { openSheet(nil) }
    }
    .disabled(!enabled)
  }

  private func openSheet(_ hold: VoiceHold?) {
    guard !open.value else { return }
    open.value = true
    pressed = false
    let onResult = self.onResult
    let open = self.open
    VoiceSheetPresenter.present(existing: existing(), hold: hold) { result in
      open.value = false
      if let result { onResult(result) }
    }
  }
}

/// Whether this microphone's sheet is up: one at a time.
private final class OpenFlag {
  var value = false
}

/// The microphone's touches, followed from UIKit: a hold's finger stays with this view while the sheet covers
/// the screen, so its slide and its lift still arrive.
private struct MicTouches: UIViewRepresentable {
  let enabled: Bool
  @Binding var pressed: Bool
  let open: (VoiceHold?) -> Void

  func makeCoordinator() -> Tracker { Tracker() }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .clear
    view.isAccessibilityElement = false
    let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Tracker.touched(_:)))
    press.minimumPressDuration = 0
    press.allowableMovement = .greatestFiniteMagnitude
    view.addGestureRecognizer(press)
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.parent = self
  }

  final class Tracker: NSObject {
    var parent: MicTouches?
    private var down: CGPoint?
    private var timer: Task<Void, Never>?
    private var hold: VoiceHold?

    @objc func touched(_ g: UILongPressGestureRecognizer) {
      let at = g.location(in: nil)
      switch g.state {
      case .began:
        guard let parent, parent.enabled, down == nil, hold == nil else { return }
        down = at
        timer = Task { [weak self] in
          try? await Task.sleep(for: holdAfter)
          if !Task.isCancelled { self?.startHold() }
        }
        press(true)
      case .changed:
        guard let origin = down else { return }
        if let hold {
          hold.setAway(at.y - origin.y < -voiceCancelDistance || at.x - origin.x < -voiceCancelDistance)
        } else if hypot(at.x - origin.x, at.y - origin.y) > touchSlop {
          reset()
          press(false)
        }
      case .ended:
        if let hold { return lifted(hold) }
        guard down != nil else { return }
        reset()
        parent?.open(nil)
      case .cancelled, .failed:
        // A hold's finger taken back still lifts it; a press that hadn't become one opens nothing.
        if let hold { return lifted(hold) }
        reset()
        press(false)
      default:
        break
      }
    }

    private func startHold() {
      guard down != nil else { return }
      timer = nil
      let hold = VoiceHold()
      self.hold = hold
      parent?.open(hold)
    }

    private func lifted(_ hold: VoiceHold) {
      self.hold = nil
      down = nil
      hold.release()
    }

    private func reset() {
      timer?.cancel()
      timer = nil
      down = nil
    }

    private func press(_ on: Bool) {
      if parent?.pressed != on { parent?.pressed = on }
    }
  }
}
