import Foundation
import PocketTermKit
import Sentry

/// Crash and error reports to GlitchTip, only when whoever runs this Mac opts in: `POCKETTERM_SENTRY_DSN` in the
/// app's environment (`launchctl setenv POCKETTERM_SENTRY_DSN …`, then relaunch PocketTerm). Never built in:
/// PocketTerm is self-hosted and open source, a report goes where its operator says. POCKETTERM_SENTRY_ENVIRONMENT
/// and POCKETTERM_SENTRY_RELEASE override the defaults. Not the plain SENTRY_* names: `launchctl setenv` is global,
/// so a developer's own SENTRY_DSN would opt PocketTerm in, and PocketTerm's would reach every terminal's programs.
/// The built-in server inherits this environment (Subprocess), so the same variables reach it. Nonisolated: the
/// SDK calls `beforeSend` on its own queues.
nonisolated enum ErrorReports {
  static func start(environment env: [String: String] = ProcessInfo.processInfo.environment) {
    let dsn = (env["POCKETTERM_SENTRY_DSN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !dsn.isEmpty else { return }
    let home = NSHomeDirectory()
    SentrySDK.start { o in
      o.dsn = dsn
      if let e = nonEmpty(env["POCKETTERM_SENTRY_ENVIRONMENT"]) {
        o.environment = e
      } else {
        #if DEBUG
          o.environment = "development"
        #else
          o.environment = "production"
        #endif
      }
      // Else the SDK's <bundle id>@<version>+<build>.
      if let r = nonEmpty(env["POCKETTERM_SENTRY_RELEASE"]) { o.releaseName = r }
      // Errors and crashes only: no performance data or sessions.
      o.sendDefaultPii = false
      o.tracesSampleRate = 0
      o.enableAutoPerformanceTracing = false
      o.enableNetworkTracking = false
      o.enableFileIOTracing = false
      o.enableCoreDataTracing = false
      o.enableAutoSessionTracking = false
      // A failed request's report would carry its URL (a tailnet name); expected network errors aren't crashes.
      o.enableCaptureFailedRequests = false
      // AppKit swallows an exception on the main thread and runs on in a broken state: crash and report it instead.
      o.enableUncaughtNSExceptionReporting = true
      // No breadcrumbs at all: they can hold terminal output, log lines and URLs.
      o.maxBreadcrumbs = 0
      o.enableAutoBreadcrumbTracking = false
      o.enableNetworkBreadcrumbs = false
      o.beforeBreadcrumb = { _ in nil }
      o.beforeSend = { scrub($0, home: home) }
      o.initialScope = { scope in
        scope.setTag(value: "app", key: "component")
        return scope
      }
    }
  }

  /// [event] as it may leave the Mac: texts through scrubErrorReport (the [home] folder as `~`), nothing about the
  /// person, the machine's name or binaries' paths under [home]; exception types and stack frames stay.
  static func scrub(_ event: Event, home: String) -> Event {
    if let m = event.message {
      event.message = SentryMessage(formatted: scrubErrorReport(m.formatted, home: home))
    }
    for e in event.exceptions ?? [] { e.value = e.value.map { scrubErrorReport($0, home: home) } }
    // A copy run from ~/Downloads names the user in its binaries' paths: the images and each frame's image.
    func unhome(_ path: String?) -> String? {
      guard let path, path.hasPrefix(home + "/") else { return path }
      return "~" + path.dropFirst(home.count)
    }
    for d in event.debugMeta ?? [] { d.codeFile = unhome(d.codeFile) }
    let stacks = (event.exceptions ?? []).map(\.stacktrace) + (event.threads ?? []).map(\.stacktrace) + [event.stacktrace]
    for f in stacks.compactMap({ $0 }).flatMap(\.frames) { f.package = unhome(f.package) }
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

  private static func nonEmpty(_ s: String?) -> String? {
    guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
  }
}
