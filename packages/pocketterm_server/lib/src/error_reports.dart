import 'package:pocketterm_server/src/server.dart' show serverVersion;
import 'package:sentry/sentry.dart';

/// Longest message or exception value a report carries, so no large piece of what the server handled rides along.
const maxReportText = 300;

/// The Sentry options for error reports to the operator's Sentry-compatible service (GlitchTip), or null when
/// `POCKETTERM_SENTRY_DSN` is absent or blank: reports are opt-in and the SDK must then never start.
///
/// Only `POCKETTERM_SENTRY_*` count, never the SDK's own `SENTRY_*`: the desktop apps are opted in machine-wide
/// (`launchctl setenv`, `setx`) and the server inherits their environment, so a developer's own `SENTRY_DSN` would
/// otherwise send PocketTerm's errors to their project without anyone opting in.
///
/// The server runs on someone's own computer, so a report carries the error and its stack only: no breadcrumbs (log
/// lines), no request, no host name, no user, and text scrubbed by [scrubErrorReport].
void Function(SentryOptions)? errorReportOptions(Map<String, String> environment) {
  final dsn = environment['POCKETTERM_SENTRY_DSN']?.trim() ?? '';
  if (dsn.isEmpty) return null;
  String? setting(String name) {
    final value = environment[name]?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  // USERPROFILE: Windows has no HOME.
  final home = setting('HOME') ?? setting('USERPROFILE');
  return (options) {
    // Every value the SDK may have taken from SENTRY_* before this runs is set here, so none of it survives.
    options
      // The SDK turns its own diagnostics on when not AOT-compiled (`dart run`); the server's log stays its own.
      ..debug = false
      ..dsn = dsn
      ..environment = setting('POCKETTERM_SENTRY_ENVIRONMENT') ?? 'production'
      ..release = setting('POCKETTERM_SENTRY_RELEASE') ?? 'pocketterm-server@$serverVersion'
      ..dist = null
      ..sendDefaultPii = false
      ..tracesSampleRate = 0
      ..maxBreadcrumbs = 0
      ..beforeBreadcrumb = ((_, _) => null)
      ..enablePrintBreadcrumbs = false
      // The SDK leaves it unset; null keeps the machine's name out even if a default appears.
      ..serverName = null
      ..beforeSend = (event, _) => scrubErrorReport(event, home: home);
  };
}

/// Strips from [event] what could identify the owner or their machines, keeping the error's type and stack:
/// the user, request, server name, extra data and breadcrumbs go, and the message and exception values are passed
/// through [scrubReportText]. Tags it `component=server`.
SentryEvent scrubErrorReport(SentryEvent event, {String? home}) {
  event
    ..user = null
    ..request = null
    ..serverName = null
    // Deprecated, yet still sent when anything (an integration) fills it in.
    // ignore: deprecated_member_use
    ..extra = null
    ..breadcrumbs = null
    ..tags = {...?event.tags, 'component': 'server'};
  final message = event.message;
  if (message != null) {
    // The template and params would carry the same text unscrubbed.
    event.message = SentryMessage(scrubReportText(message.formatted, home: home));
  }
  for (final exception in event.exceptions ?? const <SentryException>[]) {
    final value = exception.value;
    if (value != null) exception.value = scrubReportText(value, home: home);
  }
  return event;
}

// scheme://anything up to whitespace or a quote: the host, port and path may all name the owner's machines.
final _url = RegExp(r'''\b[a-z][a-z0-9+.-]*://[^\s'"<>]+''', caseSensitive: false);
final _email = RegExp(r'[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+', caseSensitive: false);
// Tailnet and LAN names, like mac.tail1234.ts.net or mac.local.
final _localHost = RegExp(r'\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:ts\.net|local|lan)\b', caseSensitive: false);
final _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');
// Full (eight groups) or `::`-compressed IPv6; plain `12:30:45` times aren't matched.
final _ipv6 = RegExp(
  r'(?<![\w:])(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?::'
  r'(?:[0-9a-f]{1,4}(?::[0-9a-f]{1,4})*)?)(?![\w:])',
  caseSensitive: false,
);

/// [text] without URLs, email addresses, tailnet/LAN host names, IP addresses or the [home] folder (shown as `~`),
/// cut to [maxReportText] characters.
String scrubReportText(String text, {String? home}) {
  var s = text;
  if (home != null && home.length > 1) s = s.replaceAll(home, '~');
  s = s
      .replaceAllMapped(_url, (m) => '${m[0]!.substring(0, m[0]!.indexOf('://'))}://<redacted>')
      .replaceAll(_email, '<email>')
      .replaceAll(_localHost, '<host>')
      .replaceAll(_ipv4, '<ip>')
      .replaceAll(_ipv6, '<ip>');
  return s.length <= maxReportText ? s : s.substring(0, maxReportText);
}
