import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Coding session (Live Activity)

/// The app's colours (packages/pocketterm_core/lib/ui.dart's C).
private enum Palette {
  static let win = Color(red: 0x17 / 255, green: 0x18 / 255, blue: 0x1D / 255)
  static let dim = Color(red: 0x8A / 255, green: 0x8F / 255, blue: 0x9C / 255)
  static let accent = Color(red: 0x7C / 255, green: 0x9C / 255, blue: 0xFF / 255)
  static let ok = Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
  static let warn = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
}

private typealias SessionState = SessionActivity.ContentState

/// What a followed session shows: its state, or, once past the stale date
/// every update carries (the server sends updates with one a few minutes
/// ahead), that the computer went quiet. Ended stays Ended.
private struct Shown {
  let state: SessionState
  let isStale: Bool

  init(_ context: ActivityViewContext<SessionActivity>) {
    state = context.state
    isStale = context.isStale && context.state.state != .ended
  }

  var color: Color {
    if isStale { return Palette.dim }
    switch state.state {
    case .working: return Palette.accent
    case .needs: return Palette.warn
    case .done: return Palette.ok
    case .ended: return Palette.dim
    }
  }

  var symbol: String {
    if isStale { return "wifi.slash" }
    switch state.state {
    case .working: return "sparkles"
    case .needs: return "exclamationmark.bubble.fill"
    case .done: return "checkmark.circle.fill"
    case .ended: return "stop.circle"
    }
  }

  /// What it waits for, after "Needs you".
  var waitsFor: String? {
    switch state.kind {
    case .question: "Question"
    case .approval: "Approval"
    case .plan: "Plan review"
    case nil: nil
    }
  }
}

/// Working with the time since it started, Needs you with what for,
/// Finished, or Ended; stale, that the computer went quiet.
private struct SessionChip: View {
  let shown: Shown

  var body: some View {
    HStack(spacing: 4) {
      if shown.isStale {
        Text("No word from the computer")
      } else {
        switch shown.state.state {
        case .working:
          Text("Working")
          Text(shown.state.sinceDate, style: .timer).monospacedDigit()
        case .needs:
          Text(shown.waitsFor.map { "Needs you · \($0)" } ?? "Needs you")
        case .done:
          Text("Finished")
        case .ended:
          Text("Ended")
        }
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(shown.color)
    .lineLimit(1)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(shown.color.opacity(0.15), in: Capsule())
  }
}

private struct SessionLockScreen: View {
  let context: ActivityViewContext<SessionActivity>

  var body: some View {
    let shown = Shown(context)
    HStack(spacing: 12) {
      Image(systemName: shown.symbol).font(.title2).foregroundStyle(shown.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(context.attributes.title).font(.headline).foregroundStyle(.white).lineLimit(1)
        if !context.attributes.project.isEmpty {
          Text(context.attributes.project).font(.caption).foregroundStyle(Palette.dim).lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      SessionChip(shown: shown)
    }
    .padding(16)
  }
}

struct SessionLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: SessionActivity.self) { context in
      SessionLockScreen(context: context)
        .activityBackgroundTint(Palette.win)
        .activitySystemActionForegroundColor(.white)
        .widgetURL(context.attributes.link)
    } dynamicIsland: { context in
      let shown = Shown(context)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: shown.symbol).font(.title2).foregroundStyle(shown.color).padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 2) {
            Text(context.attributes.title).font(.headline).lineLimit(1)
            if !context.attributes.project.isEmpty {
              Text(context.attributes.project).font(.caption).foregroundStyle(Palette.dim).lineLimit(1)
            }
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          SessionChip(shown: shown)
        }
      } compactLeading: {
        Image(systemName: shown.symbol).foregroundStyle(shown.color)
      } compactTrailing: {
        if shown.isStale {
          Text("Quiet").font(.caption2).foregroundStyle(shown.color)
        } else {
          switch shown.state.state {
          case .working:
            Text(shown.state.sinceDate, style: .timer)
              .monospacedDigit()
              .font(.caption2)
              .foregroundStyle(shown.color)
              .frame(maxWidth: 44)
          case .needs:
            Text("Needs you").font(.caption2.weight(.semibold)).foregroundStyle(shown.color)
          case .done:
            Text("Done").font(.caption2.weight(.semibold)).foregroundStyle(shown.color)
          case .ended:
            Text("Ended").font(.caption2).foregroundStyle(shown.color)
          }
        }
      } minimal: {
        Image(systemName: shown.symbol).foregroundStyle(shown.color)
      }
      .widgetURL(context.attributes.link)
      .keylineTint(shown.color)
    }
  }
}

@main
struct PocketTermLiveBundle: WidgetBundle {
  var body: some Widget {
    SessionLiveActivity()
  }
}
