import Foundation
import PocketTermKit
import Sentry

/// Crash and error reports to GlitchTip, only in builds made with a DSN: build-ipa.sh bakes `SENTRY_DSN` into
/// Info.plist (`SentryDSN`) for the store builds; every other build has none and never starts the SDK. Nonisolated:
/// the SDK calls `beforeSend` on its own queues.
nonisolated enum ErrorReports {
  static func start(bundle: Bundle = .main) {
    let dsn = (bundle.object(forInfoDictionaryKey: "SentryDSN") as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !dsn.isEmpty else { return }
    SentrySDK.start { o in
      o.dsn = dsn
      #if DEBUG
        o.environment = "development"
      #else
        o.environment = "production"
      #endif
      // Errors and crashes only: no performance data, sessions, screenshots or view hierarchy.
      o.sendDefaultPii = false
      o.tracesSampleRate = 0
      o.enableAutoPerformanceTracing = false
      o.enableUIViewControllerTracing = false
      o.enableUserInteractionTracing = false
      o.enableNetworkTracking = false
      o.enableFileIOTracing = false
      o.enableCoreDataTracing = false
      o.enableAutoSessionTracking = false
      o.attachScreenshot = false
      o.attachViewHierarchy = false
      // A failed request's report would carry its URL (the computer's tailnet name); expected network errors
      // aren't crashes anyway.
      o.enableCaptureFailedRequests = false
      // No breadcrumbs at all: they can hold terminal output, log lines and URLs.
      o.maxBreadcrumbs = 0
      o.enableAutoBreadcrumbTracking = false
      o.enableNetworkBreadcrumbs = false
      o.beforeBreadcrumb = { _ in nil }
      o.beforeSend = { scrub($0) }
      o.initialScope = { scope in
        scope.setTag(value: "app", key: "component")
        return scope
      }
    }
  }

  /// [event] as it may leave the phone: texts through scrubErrorReport, nothing about the person or the device's
  /// name; exception types and stack frames stay.
  static func scrub(_ event: Event) -> Event {
    if let m = event.message {
      event.message = SentryMessage(formatted: scrubErrorReport(m.formatted))
    }
    for e in event.exceptions ?? [] { e.value = e.value.map { scrubErrorReport($0) } }
    event.serverName = nil
    event.user = nil
    event.request = nil
    event.extra = nil
    event.breadcrumbs = nil
    if var device = event.context?["device"] {
      device["name"] = nil
      event.context?["device"] = device
    }
    return event
  }
}
