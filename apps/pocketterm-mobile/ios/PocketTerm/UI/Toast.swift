import Combine
import SwiftUI

/// Short messages at the bottom of the screen (Flutter's snackbars): what went wrong, what happened, with an
/// optional action (Undo, Settings). iOS has no such control; this is a floating capsule over the app,
/// clear of the keyboard and the composer, read out by VoiceOver as it comes.
final class Toaster: ObservableObject {
  static let shared = Toaster()

  struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let action: String?
    let handler: (() -> Void)?
    let duration: TimeInterval

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
  }

  @Published private(set) var current: Toast?
  private var hide: Task<Void, Never>?

  /// Shows [message] in place of the one showing, for [duration] seconds (longer with an action: time to read it and reach Undo).
  func show(_ message: String, action: String? = nil, duration: TimeInterval? = nil, handler: (() -> Void)? = nil) {
    let t = Toast(message: message, action: action, handler: handler, duration: duration ?? (action == nil ? 4 : 10))
    current = t
    UIAccessibility.post(notification: .announcement, argument: message)
    hide?.cancel()
    hide = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(t.duration))
      if !Task.isCancelled, self?.current == t { self?.current = nil }
    }
  }

  func dismiss() {
    hide?.cancel()
    current = nil
  }

  /// The hosts on screen, newest last: only the newest (the sheet or cover in front) shows the toast, so one
  /// behind it doesn't sit, unseen but tappable to tests and VoiceOver, under what's in front.
  @Published private(set) var hosts: [UUID] = []

  func appeared(_ host: UUID) { hosts.append(host) }
  func disappeared(_ host: UUID) { hosts.removeAll { $0 == host } }
}

/// Shows the [Toaster]'s messages over [content], above the bottom safe area (and the keyboard).
struct ToastHost: ViewModifier {
  @ObservedObject var toaster: Toaster
  @State private var id = UUID()

  func body(content: Content) -> some View {
    content.overlay(alignment: .bottom) {
      if let t = toaster.current, toaster.hosts.last == id {
        HStack(spacing: 12) {
          Text(t.message)
            .font(.subheadline)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("toast")
          if let action = t.action {
            Button(action) {
              toaster.dismiss()
              t.handler?()
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("toast-action")
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 72)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onTapGesture { toaster.dismiss() }
        .id(t.id)
      }
    }
    .animation(.snappy, value: toaster.current)
    .onAppear { toaster.appeared(id) }
    .onDisappear { toaster.disappeared(id) }
  }
}

extension View {
  func toasts(_ toaster: Toaster = .shared) -> some View { modifier(ToastHost(toaster: toaster)) }
}
