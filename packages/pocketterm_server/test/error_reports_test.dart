import 'package:pocketterm_server/pocketterm_server.dart';
import 'package:pocketterm_server/src/error_reports.dart' show maxReportText, scrubErrorReport, scrubReportText;
import 'package:sentry/sentry.dart';
import 'package:test/test.dart';

/// Error reports are off unless the operator sets POCKETTERM_SENTRY_DSN, and never carry the owner's machines,
/// addresses or home folder.
void main() {
  group('errorReportOptions', () {
    test('is off without a DSN, whatever SENTRY_* say', () {
      expect(errorReportOptions({}), isNull);
      expect(errorReportOptions({'POCKETTERM_SENTRY_DSN': '  '}), isNull);
      expect(errorReportOptions({'SENTRY_DSN': 'https://dev@sentry.example/9'}), isNull);
    });

    // Options as the SDK hands them over: its defaults, plus what it read from a developer's own SENTRY_* variables.
    SentryOptions defaults() => SentryOptions()
      ..dsn = 'https://dev@sentry.example/9'
      ..environment = 'dev'
      ..release = 'their-app@9.9.9'
      ..dist = '42'
      ..debug = true
      ..maxBreadcrumbs = 100
      ..serverName = 'ana-mac'
      ..enablePrintBreadcrumbs = true;

    test('sends errors only, with no breadcrumbs, PII, host name or SENTRY_* values', () {
      final options = defaults();
      errorReportOptions({
        'POCKETTERM_SENTRY_DSN': ' https://k@glitchtip.example/1 ',
        'SENTRY_ENVIRONMENT': 'dev',
        'SENTRY_RELEASE': 'their-app@9.9.9',
      })!(options);
      expect(options.dsn, 'https://k@glitchtip.example/1');
      expect(options.environment, 'production');
      expect(options.release, 'pocketterm-server@$serverVersion');
      expect(options.dist, isNull);
      expect(options.sendDefaultPii, isFalse);
      expect(options.tracesSampleRate, 0);
      expect(options.maxBreadcrumbs, 0);
      expect(options.enablePrintBreadcrumbs, isFalse);
      expect(options.serverName, isNull);
      expect(options.debug, isFalse);
      expect(options.beforeBreadcrumb!(Breadcrumb(message: 'ls ~/secret'), Hint()), isNull);
    });

    test('takes the environment and release from POCKETTERM_SENTRY_ENVIRONMENT and POCKETTERM_SENTRY_RELEASE', () {
      final options = defaults();
      errorReportOptions({
        'POCKETTERM_SENTRY_DSN': 'https://k@glitchtip.example/1',
        'POCKETTERM_SENTRY_ENVIRONMENT': 'staging',
        'POCKETTERM_SENTRY_RELEASE': 'pocketterm@1.2.3',
      })!(options);
      expect(options.environment, 'staging');
      expect(options.release, 'pocketterm@1.2.3');
    });

    test('its beforeSend scrubs with the home folder from the environment', () async {
      final options = SentryOptions();
      errorReportOptions({'POCKETTERM_SENTRY_DSN': 'https://k@glitchtip.example/1', 'HOME': '/Users/ana'})!(options);
      final event = await options.beforeSend!(SentryEvent(message: SentryMessage('/Users/ana/x failed')), Hint());
      expect(event!.message!.formatted, '~/x failed');
    });
  });

  group('scrubReportText', () {
    test('hides URLs, addresses, tailnet and LAN names, emails and the home folder', () {
      expect(
        scrubReportText('GET https://mac.tail1234.ts.net:8443/v1/blobs?x=1 failed', home: '/Users/ana'),
        'GET https://<redacted> failed',
      );
      expect(scrubReportText('connect to 100.101.102.103:47900 refused'), 'connect to <ip>:47900 refused');
      expect(scrubReportText('bound fd7a:115c:a1e0::1 and ::1'), 'bound <ip> and <ip>');
      expect(scrubReportText('bound 2001:db8:0:0:0:0:0:1'), 'bound <ip>');
      expect(
        scrubReportText('peer ana-mac.tail1234.ts.net and nas.local and box.home.lan'),
        'peer <host> and <host> and <host>',
      );
      expect(scrubReportText('owner ana.b+pt@example.com'), 'owner <email>');
      expect(
        scrubReportText("Can't write /Users/ana/Library/x (denied)", home: '/Users/ana'),
        "Can't write ~/Library/x (denied)",
      );
    });

    test('keeps what identifies the bug', () {
      const text = 'RangeError (index): Invalid value: Not in inclusive range 0..3: 4 at 12:30:45, Foo::bar';
      expect(scrubReportText(text, home: '/Users/ana'), text);
    });

    test('cuts long text', () {
      expect(scrubReportText('x' * 1000), hasLength(maxReportText));
    });
  });

  test('scrubErrorReport keeps the error and stack, drops who and where, tags the server', () {
    final frames = SentryStackTrace(
      frames: [SentryStackFrame(function: 'main', package: 'pocketterm_server')],
    );
    final event = scrubErrorReport(
      SentryEvent(
        message: SentryMessage('from 10.0.0.2', template: 'from %s', params: ['10.0.0.2']),
        exceptions: [SentryException(type: 'StateError', value: 'Bad state: ana@example.com', stackTrace: frames)],
        user: SentryUser(ipAddress: '10.0.0.2'),
        request: SentryRequest(url: 'http://127.0.0.1:47900/v1/health'),
        serverName: 'ana-mac',
        breadcrumbs: [Breadcrumb(message: 'terminal output')],
        tags: {'kind': 'x'},
      ),
    );
    expect(event.message!.formatted, 'from <ip>');
    expect(event.message!.params, isNull);
    expect(event.exceptions!.single.type, 'StateError');
    expect(event.exceptions!.single.value, 'Bad state: <email>');
    expect(event.exceptions!.single.stackTrace, same(frames));
    expect(event.user, isNull);
    expect(event.request, isNull);
    expect(event.serverName, isNull);
    expect(event.breadcrumbs, isNull);
    expect(event.tags, {'kind': 'x', 'component': 'server'});
  });
}
