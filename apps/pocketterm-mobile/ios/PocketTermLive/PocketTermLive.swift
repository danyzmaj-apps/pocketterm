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

extension SessionActivity.ContentState {
  fileprivate var color: Color {
    switch state {
    case .working: Palette.accent
    case .needs: Palette.warn
    case .done: Palette.ok
    case .ended: Palette.dim
    }
  }

  fileprivate var symbol: String {
    switch state {
    case .working: "sparkles"
    case .needs: "exclamationmark.bubble.fill"
    case .done: "checkmark.circle.fill"
    case .ended: "stop.circle"
    }
  }

  /// What it waits for, after "Needs you".
  fileprivate var waitsFor: String? {
    switch kind {
    case .question: "Question"
    case .approval: "Approval"
    case .plan: "Plan review"
    case nil: nil
    }
  }
}

/// Working with the time since it started, Needs you with what for,
/// Finished, or Ended. A stale one (no word for 8 hours) says so.
private struct SessionChip: View {
  let state: SessionState
  let stale: Bool

  var body: some View {
    HStack(spacing: 4) {
      if stale && state.state == .working {
        Text("No word lately")
      } else {
        switch state.state {
        case .working:
          Text("Working")
          Text(state.sinceDate, style: .timer).monospacedDigit()
        case .needs:
          Text(state.waitsFor.map { "Needs you · \($0)" } ?? "Needs you")
        case .done:
          Text("Finished")
        case .ended:
          Text("Ended")
        }
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(stale ? Palette.dim : state.color)
    .lineLimit(1)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background((stale ? Palette.dim : state.color).opacity(0.15), in: Capsule())
  }
}

private struct SessionLockScreen: View {
  let context: ActivityViewContext<SessionActivity>

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: context.state.symbol).font(.title2).foregroundStyle(context.state.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(context.attributes.title).font(.headline).foregroundStyle(.white).lineLimit(1)
        if !context.attributes.project.isEmpty {
          Text(context.attributes.project).font(.caption).foregroundStyle(Palette.dim).lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      SessionChip(state: context.state, stale: context.isStale)
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
      let state = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: state.symbol).font(.title2).foregroundStyle(state.color).padding(.leading, 4)
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
          SessionChip(state: state, stale: context.isStale)
        }
      } compactLeading: {
        Image(systemName: state.symbol).foregroundStyle(state.color)
      } compactTrailing: {
        switch state.state {
        case .working:
          Text(state.sinceDate, style: .timer)
            .monospacedDigit()
            .font(.caption2)
            .foregroundStyle(state.color)
            .frame(maxWidth: 44)
        case .needs:
          Text("Needs you").font(.caption2.weight(.semibold)).foregroundStyle(state.color)
        case .done:
          Text("Done").font(.caption2.weight(.semibold)).foregroundStyle(state.color)
        case .ended:
          Text("Ended").font(.caption2).foregroundStyle(state.color)
        }
      } minimal: {
        Image(systemName: state.symbol).foregroundStyle(state.color)
      }
      .widgetURL(context.attributes.link)
      .keylineTint(state.color)
    }
  }
}

@main
struct PocketTermLiveBundle: WidgetBundle {
  var body: some Widget {
    SessionLiveActivity()
  }
}
