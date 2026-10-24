// The desktop side of the end-to-end run (tool/e2e/run.sh starts it):
//
//   fvm flutter test integration_test/e2e_test.dart -d macos --dart-define=E2E_CONFIG=<run>/config.json
//
// Boots the real app (controller, terminals, local API, server client) with
// its data in memory and its files in the run's throwaway home, sets it up
// through the first-run wizard against the run's server, gets the computer
// ready, opens throwaway terminal windows with the fake omp in them, hands
// pairing links to the phone's flows and checks on the computer what each
// phone scenario should have done. See tool/e2e/lib/e2e.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/live.dart' show LiveAnswer, LiveAsk, routedKey;
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/supabase_server.dart' show SupabaseServerClient;
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_remote.dart' show TerminalLink;
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/hosting/vps.dart' show ServerAddress;
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/local_api.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:pocketterm_desktop/setup_page.dart'
    show CheckState, SetupCheck, SetupPage, SupabaseTools, setupLinkProblem;
import 'package:pocketterm_e2e/e2e.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/app.dart';
import 'e2e/phone.dart';
import 'e2e/report.dart';

const _configPath = String.fromEnvironment('E2E_CONFIG');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('PocketTerm end to end', (tester) async {
    if (_configPath.isEmpty) fail('Run through tool/e2e/run.sh (--dart-define=E2E_CONFIG=<config.json>).');
    final c = E2eConfig.read(_configPath);
    if (c.serverCa case final ca?) HttpOverrides.global = _TrustCa(File(ca).readAsBytesSync());
    final run = _Run(tester, c);
    try {
      await run.all();
    } finally {
      await run.end();
    }
    expect(run.report.failures, isEmpty, reason: 'see ${run.c.results}');
    // kitty on a server across the internet (every phone flow, each phase) took just over 150 minutes.
  }, timeout: const Timeout(Duration(minutes: 210)));
}

/// The app's HTTPS and WebSockets also trust [ca] (a test server's own CA),
/// in this process only: the Mac's keychain stays as it is.
class _TrustCa extends HttpOverrides {
  _TrustCa(this.ca);
  final List<int> ca;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient((context ?? SecurityContext(withTrustedRoots: true))..setTrustedCertificatesBytes(ca));
}

/// A 1×1 PNG, the stand-in phone's image.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

/// A document the stand-in phone sends, with a name that needs quoting.
const _docName = 'notes from the phone.txt';
final Uint8List _doc = utf8.encode('PocketTerm e2e notes\n');

class _Run {
  _Run(this.tester, this.c) : report = Report(c), owned = Owned(c.owned);

  final WidgetTester tester;
  final E2eConfig c;
  final Report report;
  final Owned owned;
  final secrets = MemorySecrets();
  late SharedPreferences prefs;
  late E2eApp app;
  LocalApi? api;
  late final Throwaway term = Throwaway.of(c.terminal, c, owned);
  StandInPhone? phone;

  /// The spare computer (_handOff), signed in until the end.
  Server? _spare;

  /// The phones on the server before this run's paired.
  Set<String> _phonesBefore = const {};

  String get t => c.terminal;
  String name(String what) => '$t-$what';
  String dir(String what) => c.project(name(what));

  /// What the window list calls the terminal's windows' keys.
  bool ours(String key) => switch (t) {
    'kitty' => key.startsWith('kitty'),
    'wezterm' => key.startsWith('wezterm:'),
    _ => key.startsWith('ghostty:') || key.startsWith('tmux:'),
  };

  // ---------------------------------------------------------------- the run

  Future<void> all() async {
    writeHome(c);
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await startTmux(c, owned);
    await _launch();

    await report.step('desktop: runs as from Finder (launchd PATH, no TERM, no locale)', _asFromFinder, critical: true);
    await report.step('terminals: throwaway windows open', _openEarlyWindows, critical: true);
    if (!c.builtIn) await report.step('setup: On this computer shows Tailscale as it is', _thisComputer);
    await report.step('setup: Not yet shows the server guide', _serverGuide);
    await report.step('setup: link problems are explained', _linkProblems);
    if (c.builtIn) {
      await report.step(
        'setup: On this computer starts its server, Tailscale serves it',
        _thisComputer,
        critical: true,
      );
    } else if (c.supabaseCloud) {
      await report.step('setup: Supabase, set up a new project (real Management API)', _supabaseCloud, critical: true);
      await report.step('setup: Supabase set up with no Retry', () async {
        if (_supabaseErrors.isNotEmpty) throw StateError('Retry needed after: ${_supabaseErrors.join(' | ')}');
      });
    } else {
      await report.step('setup: own server, paste link', _ownServer, critical: true);
    }
    await _getReady();
    await report.step('windows: sessions in their own windows', _sessionsLocated, critical: true);
    await report.step('windows: plain shell is a screen', _shellIsScreen);
    await report.step('settings: status bar and Open setup checklist', _statusBar);
    await report.step('settings: coding agents tab', _agentsTab);
    await report.step('settings: data protection', _dataProtection);
    await report.step('settings: launch at login switch', _launchAtLogin);
    await report.step('settings: new sessions open in $t', _chooseTerminal);
    await report.step('add a phone: two pairing links', _pairingLinks, critical: true);
    await report.step('hand-off files', _handOff, critical: true);

    if (c.phone) {
      if (t == 'ghostty') unawaited(_answerOnComputer());
      final code = await handOff(c.phaseDir, 'main', out: 'ready', timeout: const Duration(minutes: 45));
      _mainDone = true;
      report.log('phone main → $code');
    } else {
      await report.step('stand-in phone: main scenarios', _standInMain);
    }
    await _verifyMain();
    await report.step('phone: computer off, then Retry brings it back', _computerOff);

    if (c.supabaseCloud) {
      report.skip('restart: server', 'a project on supabase.com can\u2019t be taken off the network for the test');
    } else {
      await report.step('restart: server', _serverRestart);
    }
    await report.step('restart: desktop app', _desktopRestart);
    if (File(_omp).existsSync()) {
      await report.step('real omp: /new from the phone starts a fresh session in place', _realOmp);
    } else {
      report.skip('real omp: /new from the phone starts a fresh session in place', 'omp is not installed');
    }
    await report.step('revoke: phone removed on the server', _revoke);
    if (t == 'ghostty') {
      await report.step('ghostty: Start new windows in tmux', _ghosttyTmux);
      await report.step('ghostty: Remove takes tmux out', _ghosttyTmuxRemove);
    }
    await report.step('settings: project folders remove and add', _projectFolders);
    if (c.builtIn) {
      await report.step('account: Add a computer', _addComputer);
    } else {
      report.skip('account: Add a computer', 'only a computer that runs the built-in server offers it (app.hosting)');
    }
    await report.step('phone tab: Reset key', _resetKey);
    if (c.builtIn) {
      await report.step('account: Erase', _erase);
    } else {
      report.skip('account: Erase', 'only the computer running the server erases it (Session.hostsServer)');
    }
    await report.step('account: sign out', _signOut);
  }

  /// The run started this app as Launch Services does (tool/e2e/lib/e2e.dart's
  /// launchServicesEnv), not with the environment of the terminal it was run from.
  Future<void> _asFromFinder() async {
    final env = Platform.environment;
    final path = (env['PATH'] ?? '').split(':');
    final home = env['HOME'] ?? '';
    final leaks = [
      for (final dir in ['/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin', '$home/.local/bin', '$home/.bun/bin'])
        if (path.contains(dir)) '$dir on the PATH',
      for (final k in ['TERM', 'TERM_PROGRAM', 'LANG', 'LC_ALL', 'LC_CTYPE', 'ZDOTDIR'])
        if (env[k] case final v? when v.isNotEmpty) '$k=$v',
    ];
    if (leaks.isNotEmpty) throw StateError('the desktop has a terminal\u2019s environment: ${leaks.join(', ')}');
  }

  Future<void> end() async {
    phone?.dispose();
    await report.shot('end');
    // What the run signed in leaves the server (it may be shared): its
    // phones should a failure have kept them, the spare computer, then this one.
    try {
      if (_spare != null && app.user != null) {
        for (final d in await app.serverDevices()) {
          if (d.role == DeviceRole.phone && !_phonesBefore.contains(d.id)) await app.server!.revokeDevice(d.id);
        }
      }
      await _spare?.leave();
      _spare?.close();
      if (app.user != null) await app.server?.leave();
    } on Object catch (e) {
      report.log('end: leaving the server: $e');
    }
    try {
      await tester.pumpWidget(const SizedBox());
      await api?.stop();
      await app.shutDown();
    } on Object catch (e) {
      report.log('end: $e');
    }
    final stopped = await Owned.stopAll(c.owned);
    report.log('stopped ${stopped.join(', ')}');
  }

  /// The app, as main.dart starts it, with the run's stand-ins for the
  /// owner's prefs, keychain and home.
  Future<void> _launch() async {
    final guard = GuardedRun(c);
    final a = app = E2eApp(
      c,
      prefs,
      E2eHost(c),
      secrets: secrets,
      integrations: Integrations(home: c.home, run: guard.call, claudePaths: const [], ompPaths: const []),
    );
    final local = api = LocalApi(a.live, file: File(c.cliJson));
    await local.start();
    a.onQuit = local.stop;
    await tester.pumpWidget(
      RepaintBoundary(
        key: report.shotKey,
        child: MaterialApp(
          title: 'PocketTerm',
          debugShowCheckedModeBanner: false,
          theme: appTheme(),
          home: Material(
            color: C.win,
            child: Toaster(
              child: ListenableBuilder(
                listenable: a,
                builder: (_, _) =>
                    MainWindow(app: a, supabase: c.supabaseCloud ? E2eSupabaseTools(c) : const SupabaseTools()),
              ),
            ),
          ),
        ),
      ),
    );
    await a.start();
    await _frames();
  }

  // ---------------------------------------------------------------- UI

  Future<void> _frames([int n = 3]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await tester.pump();
    }
  }

  Future<Finder> _see(Finder f, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (f.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) throw TestFailure('Not on screen: $f');
      await _frames(1);
    }
    return f;
  }

  Future<void> _tap(Finder f) async {
    await _see(f);
    await tester.ensureVisible(f.first);
    await _frames(1);
    await tester.tap(f.first, warnIfMissed: false);
    await _frames();
  }

  /// Types [text] into field [f] as a person would: clicked first. A button
  /// clicked before took the focus, and text entered without it is lost.
  Future<void> _type(Finder f, String text) async {
    await _tap(f);
    await tester.enterText(f, text);
    await _frames();
  }

  Finder _key(String k) => find.byKey(ValueKey(k));

  /// [windows] as a failure reason can show them.
  static String _ws(Iterable<TermWindow> windows) =>
      windows.map((w) => '${w.key} "${w.title}" ${w.cwd} tty=${w.tty} program=${w.program}').join('; ');

  // ---------------------------------------------------------------- windows

  /// Before PocketTerm is set up: the terminal with a plain shell, another
  /// plain shell the phone closes, two omp at work (started before PocketTerm
  /// was in omp, so they don't report: the phone switches them to their
  /// conversation later), and folders the phone opens a session and a shell in.
  Future<void> _openEarlyWindows() async {
    await term.start(makeProject(c, name('shell')));
    await _open('closeme');
    await _open('switchgo', autorun: 'omp --busy');
    await _open('switchstop', autorun: 'omp --busy');
    makeProject(c, name('newsess'));
    makeProject(c, name('newshell'));
    for (final w in ['switchgo', 'switchstop']) {
      await until('fake omp at work in ${name(w)}', () => fakeOmpLog(dir(w)).any((e) => e['event'] == 'start'));
    }
  }

  /// A window in project [what] that runs [autorun]: opened with the
  /// terminal's own command line, Ghostty's through the app's Ghostty host
  /// (AppleScript, all it has).
  Future<void> _open(String what, {String? autorun}) async {
    final d = makeProject(c, name(what), autorun: autorun);
    if (t == 'ghostty') {
      await app.terminals.ghostty!.launch(d);
    } else {
      await term.open(d);
    }
  }

  // ---------------------------------------------------------------- setup

  /// On this computer: the Tailscale checklist follows Tailscale's real
  /// state (asked here of its own CLI). Nothing is signed in or started.
  Future<void> _thisComputer() async {
    await _toChoose();
    await _tap(_key('setup-this-computer'));
    final cli = await Process.run('/Applications/Tailscale.app/Contents/MacOS/Tailscale', ['status', '--json']);
    final installed = File('/Applications/Tailscale.app/Contents/MacOS/Tailscale').existsSync();
    var json = const <String, dynamic>{};
    try {
      json = jsonDecode('${cli.stdout}') as Map<String, dynamic>;
    } on FormatException {
      // Not running: no JSON.
    }
    final backend = json['BackendState'];
    final running = backend == 'Running';
    final started = running || backend == 'NeedsLogin' || backend == 'NeedsMachineAuth';
    final certs = (json['CertDomains'] as List?)?.isNotEmpty ?? false;
    final expected = [
      (key: 'check-installed', done: installed, yes: 'Tailscale is installed', no: 'Install Tailscale'),
      (key: 'check-running', done: started, yes: 'Tailscale is running', no: 'Start Tailscale'),
      (key: 'check-signed-in', done: running, yes: 'Signed in to Tailscale', no: 'Sign in to Tailscale'),
      (key: 'check-https', done: running && certs, yes: 'HTTPS certificates are on', no: 'Turn on HTTPS certificates'),
    ];
    report.log('tailscale: $backend, certs $certs');
    // Steps after the first one not done read "to do" whatever they are.
    final firstTodo = expected.indexWhere((e) => !e.done);
    await until('Tailscale checklist read', () async {
      await _frames(1);
      for (final (i, e) in expected.indexed) {
        final done = e.done && (firstTodo < 0 || i < firstTodo);
        final f = find.descendant(of: _key(e.key), matching: find.text(done ? e.yes : e.no));
        if (f.evaluate().isEmpty) return false;
      }
      return true;
    }, timeout: const Duration(seconds: 20));
    final start = tester.widget<FilledButton>(_key('setup-start-server'));
    expect(start.onPressed != null, firstTodo < 0, reason: 'Start is on only when every check is done');
    await report.shot('setup-this-computer');
    if (!c.builtIn) {
      await _tap(find.text('Back'));
      await _see(_key('setup-own-server'));
      return;
    }
    // Start: the server runs here, Tailscale publishes it, this computer signs in on 127.0.0.1.
    await _tap(_key('setup-start-server'));
    await until('signed in', () => app.user != null, timeout: const Duration(seconds: 60));
    final url = await until('Tailscale serves it', () => app.hosting?.publicUrl, timeout: const Duration(seconds: 60));
    report.log('built-in server ${app.hosting!.port} at $url');
    final health = await HttpClient().getUrl(url.resolve('/v1/health')).then((r) => r.close());
    expect(health.statusCode, 200, reason: '$url/v1/health through tailscale serve');
    await _see(find.text('Get this computer ready'));
    expect(app.terminalOn, isTrue, reason: 'the first sign-in turns Terminal from phone on');
    expect(await app.host.launchAtLogin(), isFalse, reason: 'the first sign-in adds no login item on its own');
  }

  Future<void> _ownServer() async {
    await _toChoose();
    await _tap(_key('setup-own-server'));
    await _tap(_key('setup-have-server'));
    await _see(_key('setup-link'));
    await tester.enterText(_key('setup-link'), c.setupLink);
    await _see(find.textContaining('answers'));
    await _tap(_key('setup-connect'));
    await until('signed in', () => app.user != null);
    await _see(find.text('Get this computer ready'));
    expect(app.terminalOn, isTrue, reason: 'the first sign-in turns Terminal from phone on');
    expect(await app.host.launchAtLogin(), isFalse, reason: 'the first sign-in adds no login item on its own');
  }

  /// What the Supabase setup said went wrong, each time Retry was needed.
  final _supabaseErrors = <String>[];

  /// Supabase, Set up a project, on supabase.com with the run's access
  /// token: a non-token is refused without asking Supabase; the token
  /// lists the organizations (the only one picked), the region is picked,
  /// Create makes the project (E2eSupabaseTools names it for the run and
  /// keeps it to itself) and the setup goes through its steps (Supabase's
  /// wait between signing keys included), then signs this computer in.
  /// An error is retried as a person would, at most 3 times, and recorded.
  Future<void> _supabaseCloud() async {
    final token = File(c.supabaseTokenFile!).readAsStringSync().trim();
    await _toChoose();
    await _tap(_key('setup-supabase'));
    await _tap(_key('supabase-new'));
    await _see(_key('supabase-security'));
    await _type(_key('supabase-token'), 'not-a-token');
    await _tap(_key('supabase-continue'));
    await _see(find.textContaining('starts with sbp_'));
    await report.shot('supabase-token');
    await _type(_key('supabase-token'), token);
    var started = DateTime.now();
    await _tap(_key('supabase-continue'));

    final org = await _see(_key('supabase-org'), timeout: const Duration(seconds: 60));
    final orgs = tester.widget<DropdownButton<String>>(org).items!;
    report.log('supabase: ${orgs.length} organization(s) after ${DateTime.now().difference(started).inSeconds} s');
    if (tester.widget<DropdownButton<String>>(org).value == null) {
      await _tap(org);
      await _tap(find.text((orgs.first.child as Text).data!).last);
    }
    FilledButton create() => tester.widget<FilledButton>(_key('supabase-create'));
    await until('Create the project on', () async {
      await _frames(1);
      return _key('supabase-create').evaluate().isNotEmpty && create().onPressed != null;
    }, timeout: const Duration(seconds: 60));
    expect(_key('supabase-existing'), findsNothing, reason: 'the run lists only the project it makes');
    await _tap(_key('supabase-region'));
    await _tap(find.text('Europe (Frankfurt)').last);
    await _gone(find.byType(DropdownMenuItem<String>));
    expect(tester.widget<DropdownButton<String>>(_key('supabase-region')).value, 'eu-central-1');
    await report.shot('supabase-project');
    started = DateTime.now();
    await _tap(_key('supabase-create'));

    // The steps as they go, until this computer is signed in.
    final seen = <String, CheckState>{};
    var waited = false;
    String? shownError;
    await until(
      'signed in on the new Supabase project',
      () async {
        await _frames(1);
        if (app.user != null) return true;
        final at = '${DateTime.now().difference(started).inSeconds} s';
        for (final f in find.byType(SetupCheck).evaluate()) {
          final w = f.widget as SetupCheck;
          if (seen[w.title] != w.state) {
            seen[w.title] = w.state;
            report.log('supabase: ${w.title} → ${w.state.name} at $at');
          }
        }
        if (!waited && _key('supabase-wait').evaluate().isNotEmpty) {
          waited = true;
          report.log('supabase: waiting for Supabase to take the signing key, at $at');
          await report.shot('supabase-key-wait');
        }
        final error = _key('supabase-error').evaluate().isEmpty
            ? null
            : tester.widget<Text>(_key('supabase-error')).data;
        if (error != null && error != shownError) {
          shownError = error;
          _supabaseErrors.add(error);
          report.log('supabase: error at $at: $error');
          await report.shot('supabase-error-${_supabaseErrors.length}');
          if (_key('supabase-retry').evaluate().isEmpty) throw StateError('Supabase setup: $error (no Retry)');
          if (_supabaseErrors.length > 3) throw StateError('Supabase setup still failing: $error');
          await _tap(_key('supabase-retry'));
          shownError = null;
        }
        return false;
      },
      timeout: const Duration(minutes: 30),
      every: const Duration(milliseconds: 500),
    );
    final ref = File(c.supabaseProject).readAsStringSync().trim();
    report.log('supabase: project $ref set up and signed in after ${DateTime.now().difference(started).inSeconds} s');
    expect(app.backend?.host, '$ref.supabase.co');
    await _see(find.text('Get this computer ready'));
    expect(app.terminalOn, isTrue, reason: 'the first sign-in turns Terminal from phone on');
    expect(await app.host.launchAtLogin(), isFalse, reason: 'the first sign-in adds no login item on its own');
  }

  /// Back to the setup's first screen (where the server runs), from any
  /// setup screen a step before left open.
  Future<void> _toChoose() async {
    for (var i = 0; i < 4 && _key('setup-own-server').evaluate().isEmpty; i++) {
      if (_key('setup-back').evaluate().isEmpty) break;
      await _tap(_key('setup-back'));
    }
    await _see(_key('setup-own-server'));
  }

  /// [f] off the screen.
  Future<void> _gone(Finder f, {Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (f.evaluate().isNotEmpty) {
      if (DateTime.now().isAfter(end)) throw TestFailure('Still on screen: $f');
      await _frames(1);
    }
  }

  /// Own server, Not yet: an address that can't be a server's says why; a
  /// public IP address gets its sslip.io name and the commands that set the
  /// server up there. Back returns to the own-server choice, then the first
  /// screen.
  Future<void> _serverGuide() async {
    await _toChoose();
    await _tap(_key('setup-own-server'));
    await _tap(_key('setup-new-server'));
    await _see(_key('setup-address'));
    for (final bad in ['not a server', '10.0.0.5']) {
      await tester.enterText(_key('setup-address'), bad);
      // The error of the address typed before may still show for a frame.
      final want = ServerAddress.parse(bad).error;
      await until('the error for $bad', () async {
        await _frames(1);
        final e = _key('setup-address-error');
        return e.evaluate().isNotEmpty && tester.widget<Text>(e).data == want;
      }, timeout: const Duration(seconds: 10));
      expect(_key('setup-command-0'), findsNothing, reason: 'no commands for $bad');
    }
    await tester.enterText(_key('setup-address'), '203.0.113.7');
    await _see(find.textContaining('203-0-113-7.sslip.io'));
    await _see(_key('setup-command-0'));
    expect(_key('setup-address-error'), findsNothing);
    await report.shot('setup-new-server');
    // What was typed stays with the setup; empty, it doesn't open there again.
    await tester.enterText(_key('setup-address'), '');
    await _tap(_key('setup-back'));
    await _see(_key('setup-have-server'));
    await _tap(_key('setup-back'));
    await _see(_key('setup-own-server'));
  }

  /// Own server, Yes: a pasted link that isn't a computer's setup link says
  /// what is wrong with it, asks no server, and Connect signs nothing in; a
  /// setup link whose server doesn't answer says that. Back to the first
  /// screen after.
  Future<void> _linkProblems() async {
    await _toChoose();
    await _tap(_key('setup-own-server'));
    await _tap(_key('setup-have-server'));
    await _see(_key('setup-link'));
    String link(Map<String, String> q) => '${Uri(scheme: 'pocketterm', host: 'setup', queryParameters: q)}';
    const url = 'https://pocketterm.example.com';
    String? error() => _key('setup-error').evaluate().isEmpty ? null : tester.widget<Text>(_key('setup-error')).data;
    for (final text in [
      'not a link',
      link({'url': url}),
      link({'url': url, 'code': 'E2E-PHONE'}),
      link({'url': 'http://pocketterm.example.com', 'setup': 'e2e'}),
    ]) {
      final why = setupLinkProblem(text);
      expect(why, isNotNull, reason: '$text is no setup link');
      await _type(_key('setup-link'), text);
      // The error of the link pasted before may still show for a frame.
      await until('the error for $text', () async {
        await _frames(1);
        return error() == why;
      }, timeout: const Duration(seconds: 10));
      expect(_key('setup-link-health'), findsNothing, reason: 'no server asked for $text');
      await _tap(_key('setup-connect'));
      expect(app.backend, isNull, reason: 'Connect with $text');
      expect(error(), why, reason: 'Connect says it again');
    }
    final down = link({'url': 'https://127.0.0.1:9', 'setup': 'e2e-not-a-token'});
    expect(setupLinkProblem(down), isNull, reason: 'a setup link as such');
    await _type(_key('setup-link'), down);
    final said = await until('the server not answering said', () async {
      await _frames(1);
      return error();
    }, timeout: const Duration(seconds: 20));
    expect(said, contains('127.0.0.1'));
    expect(find.textContaining('answers'), findsNothing);
    await report.shot('setup-link-problem');
    await _type(_key('setup-link'), '');
    await _toChoose();
  }

  Future<void> _getReady() async {
    await report.step('get ready: omp gets PocketTerm', () async {
      final ext = File(p.join(c.home, '.omp', 'agent', 'extensions', 'pocketterm-live.ts'));
      await until('extension installed', ext.existsSync);
      await _see(find.descendant(of: _key('get-ready-agents'), matching: find.textContaining('omp')));
    });
    await report.step('get ready: sessions already open are listed', () async {
      await _see(_key('get-ready-open-sessions'), timeout: const Duration(seconds: 20));
      final windows = await app.terminals.windows();
      final early = app.unreportedAgentWindows(windows).where((w) => w.cwd.contains(name('switch'))).toList();
      expect(early.length, 2, reason: 'both omp started before PocketTerm: ${_ws(windows)}');
      for (final w in early) {
        await _see(_key('get-ready-unreported-${w.key}'));
      }
    });
    await report.step('get ready: terminals', () async {
      final statuses = await app.terminals.statuses();
      final s = statuses.firstWhere((s) => s.id == t);
      expect(s.usable, isTrue, reason: '$t: ${s.state} ${s.note}');
      await _see(find.descendant(of: _key('get-ready-terminals'), matching: find.byType(Icon)));
    });
    await report.step('get ready: project folders', () async {
      await _tap(find.descendant(of: _key('get-ready-folders'), matching: find.text('Choose folder…')));
      await until('project folder added', () => app.projectRoots.contains(c.projects));
    });
    await report.step('get ready: phone code', () async {
      // A shared server (--server <url>) may still list another run's phone: then the card says one is signed
      // in, and this run's links come from Add a phone.
      if ((await app.serverDevices()).any((d) => d.role == DeviceRole.phone)) {
        await _see(find.descendant(of: _key('get-ready-phone'), matching: find.textContaining('A phone is signed in')));
      } else {
        await _see(find.descendant(of: _key('get-ready-phone'), matching: find.byType(QrImageView)));
        await until('a pairing link made', () => app.pairingLinks.isNotEmpty);
      }
      await report.shot('get-ready');
    });
    await report.step('get ready: Done', () async {
      await _tap(find.text('Done'));
      await until('settings shown', () => app.getReadyDone);
      await _see(_key('settings-content'));
    }, critical: true);
  }

  /// The fake omp, started now that PocketTerm is in omp, reports; each
  /// session is placed in its own window, once.
  Future<void> _sessionsLocated() async {
    await _open('chat', autorun: 'omp');
    await _open('approve', autorun: 'omp --ask');
    await _open('endme', autorun: 'omp');
    for (final w in ['chat', 'approve', 'endme']) {
      final s =
          await until('${name(w)} reports in a window', () {
            final s = app.live.sessions.where((s) => s.cwd == dir(w)).toList();
            return s.length == 1 && s.single.window != null ? s.single : null;
          }).catchError((Object e) async {
            final sessions = [for (final s in app.live.sessions) '${s.cwd} window=${s.window}'];
            throw TimeoutException('$e; sessions: $sessions; windows: ${_ws(await app.terminals.windows())}');
          });
      expect(ours(s.window!), isTrue, reason: '${name(w)} placed in ${s.window}');
    }
    final windows = await app.terminals.windows();
    for (final s in app.live.sessions) {
      expect(windows.where((w) => w.key == s.window).length, 1, reason: '${s.cwd}: its window once: ${_ws(windows)}');
    }
    final claimed = {for (final s in app.live.sessions) s.window};
    final others = windows.where((w) => !claimed.contains(w.key)).toList();
    for (final w in ['chat', 'approve', 'endme']) {
      expect(
        others.where((o) => o.cwd == dir(w)),
        isEmpty,
        reason: '${name(w)} also among Other windows: ${_ws(others)}',
      );
    }
    expect(app.unreportedAgentWindows(windows).where((w) => !w.cwd.contains(name('switch'))), isEmpty);
  }

  Future<void> _shellIsScreen() async {
    final windows = await app.terminals.windows();
    for (final what in ['shell', 'closeme']) {
      final shell = windows.where((w) => w.cwd == dir(what)).toList();
      expect(shell.length, 1, reason: 'the ${name(what)} window: ${_ws(windows)}');
      expect(shell.single.agent, isNull);
      expect(app.live.sessions.any((s) => s.window == shell.single.key), isFalse);
    }
  }

  /// Settings' status bar says how this computer stands; Open setup
  /// checklist goes back to Get this computer ready, whose Done returns.
  Future<void> _statusBar() async {
    Finder bar(Finder f) => find.descendant(of: _key('settings-status'), matching: f);
    await _see(
      bar(find.byWidgetPredicate((w) => w is Text && (w.data == 'All set' || (w.data ?? '').contains('attention')))),
    );
    await _tap(bar(find.text('Open setup checklist')));
    await until('the checklist open', () => !app.getReadyDone);
    await _see(find.text('Get this computer ready'));
    // The checklist's cards fill in as their checks come back and push Done
    // down; a tap that landed where Done was before is tried again.
    for (var i = 0; i < 5 && !app.getReadyDone; i++) {
      await _tap(find.widgetWithText(FilledButton, 'Done'));
      try {
        await until('the checklist done', () => app.getReadyDone, timeout: const Duration(seconds: 5));
      } on TimeoutException {
        if (i == 4) rethrow;
      }
    }
    await _see(_key('settings-content'));
    await _see(_key('settings-status'));
  }

  /// Settings → Coding agents: omp has PocketTerm, up to date, and is the
  /// default; Claude Code isn't on this computer (the run keeps it out).
  Future<void> _agentsTab() async {
    await _tap(_key('settings-tab-agents'));
    Finder on(String key, String text) => find.descendant(of: _key(key), matching: find.text(text));
    await _see(on('settings-agent-omp', 'PocketTerm installed, up to date'));
    await _see(on('settings-default-omp', 'Default'));
    await _see(on('settings-agent-claude', 'Not found on this computer'));
    expect(_key('settings-default-claude'), findsNothing);
    await report.shot('settings-agents');
  }

  /// Settings → Account → How your data is protected: Read… opens it, Done
  /// closes it.
  Future<void> _dataProtection() async {
    await _tap(_key('settings-tab-account'));
    await _tap(_key('settings-data-protection'));
    await _see(_key('data-protection'));
    await _tap(find.descendant(of: _key('data-protection'), matching: find.text('Done')));
    await _gone(_key('data-protection'));
  }

  /// Settings → Account → Launch at login, switched over and back: the
  /// run's host keeps it (the Mac's login items stay as they are).
  Future<void> _launchAtLogin() async {
    await _tap(_key('settings-tab-account'));
    await until('launch at login read', () => app.launchAtLogin != null);
    final was = app.launchAtLogin!;
    for (final on in [!was, was]) {
      await _tap(_key('settings-launch-at-login'));
      await until(
        'launch at login ${on ? 'on' : 'off'}',
        () async => app.launchAtLogin == on && await app.host.launchAtLogin() == on,
      );
      await _frames();
      expect(tester.widget<Switch>(_key('settings-launch-at-login')).value, on);
    }
  }

  Future<void> _chooseTerminal() async {
    await _tap(_key('settings-tab-terminals'));
    // The picker lists only the terminals found here: while the page is still
    // checking this computer it holds just Auto, and an open menu stays as it was.
    await _see(_key('settings-terminal-$t'));
    await _tap(_key('settings-terminal-app'));
    final label = app.terminals.apps.firstWhere((h) => h.id == t).label;
    // `.last` throws on no match instead of waiting: wait for the item first.
    await _see(find.text(label));
    await _tap(find.text(label).last);
    await until('terminal app is $t', () => app.terminalApp == t);
  }

  Future<void> _pairingLinks() async {
    await _tap(_key('settings-tab-phone'));
    final before = app.pairingLinks.length;
    for (var i = 0; i < 2; i++) {
      await _tap(find.text('Add a phone…'));
      await until('pairing link ${i + 1}', () => app.pairingLinks.length > before + i);
      await _see(find.text('Set up your phone'));
      await report.shot('add-a-phone-${i + 1}');
      await _tap(find.widgetWithText(TextButton, 'Done'));
    }
  }

  Future<void> _handOff() async {
    final links = app.pairingLinks.sublist(app.pairingLinks.length - 2);
    File(p.join(c.artifacts, 'phone-link.txt')).writeAsStringSync('${links[0]}\n');
    File(p.join(c.artifacts, 'phone-link-2.txt')).writeAsStringSync('${links[1]}\n');
    File(p.join(c.artifacts, 'desktop-id.txt')).writeAsStringSync('${app.desktopId(app.user!.id)}\n');
    // Phones signed in before this run's (another run's on a shared server) aren't revoked.
    _phonesBefore = {
      for (final d in await app.serverDevices())
        if (d.role == DeviceRole.phone) d.id,
    };
    // A second computer on the same server that no phone link names: the
    // phone lists it locked. It leaves the server at the end.
    final setup = c.builtIn
        ? app.computerSetupLink()!
        : c.supabaseCloud
        ? await (app.server! as SupabaseServerClient).newSetupLink()
        : Uri.parse(c.setupLink);
    final spare = _spare = Server(Backend.fromLink(setup)!, tokens: MemoryDeviceTokens());
    await spare.redeemSetup(Backend.setupToken(setup)!, label: 'Spare Mac $t', platform: 'macos');
    await spare.putDesktop('spare${t.substring(0, 3)}', name: 'Spare Mac $t', platform: 'macos');
    final windows = await app.terminals.windows();
    final shell = windows.firstWhere((w) => w.cwd == dir('shell'));
    final closeme = await until('the closeme window', () async {
      return (await app.terminals.windows()).where((w) => w.cwd == dir('closeme')).firstOrNull;
    });
    final host = await app.terminals.opensIn(app.terminalApp);
    File(p.join(c.artifacts, 'expect.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'runId': p.basename(p.dirname(c.artifacts)),
        'phase': 'main',
        'terminalId': t,
        'computer': app.device,
        'terminal': app.terminals.describe(host),
        'sessions': [
          for (final w in ['chat', 'approve', 'endme'])
            {
              'title': name(w),
              'project': name(w),
              // What a followed session's link and a push name it by.
              'key': routedKey(app.desktopId(app.user!.id), app.live.sessions.firstWhere((s) => s.cwd == dir(w)).key),
            },
        ],
        'approval': {'session': name('approve'), 'answer': 'Approve'},
        'screen': {'window': shell.title},
        'switchContinue': name('switchgo'),
        'switchRestart': name('switchstop'),
        'newSessionProject': name('newsess'),
        // The session the + flow starts; the steer, stop, ask and menu flows run on it.
        'askSession': name('newsess'),
        'closeWindow': closeme.title,
        'newShellProject': name('newshell'),
        'newProjectName': name('made'),
        'endSession': name('endme'),
        'realOmp': {'title': name('realomp'), 'project': name('realomp')},
        'lockedComputer': 'Spare Mac $t',
        'prompt': 'hello from phone $t',
      }),
    );
  }

  // ---------------------------------------------------------------- phone

  /// The scenarios the phone's main flow runs, done by the stand-in phone.
  Future<void> _standInMain() async {
    final links = app.pairingLinks.sublist(app.pairingLinks.length - 2);
    final support = Directory(p.join(c.work, 'phone'))..createSync(recursive: true);
    var ph = phone = await StandInPhone.pair(links[0], Directory(p.join(support.path, '1')));
    await until('phone online', () => ph.remote.online && ph.remote.sessions.isNotEmpty);
    await ph.signOut();
    phone = null;
    ph = phone = await StandInPhone.pair(links[1], Directory(p.join(support.path, '2')));
    final r = ph.remote;
    await until(
      'phone sees the sessions',
      () => r.online && r.sessions.length >= 3,
      timeout: const Duration(seconds: 40),
    );
    String sessionOf(String w) => r.sessions.firstWhere((s) => s.cwd == dir(w)).key;
    TermWindow windowOf(String w) => r.windows.firstWhere((x) => x.cwd == dir(w));
    final chat = sessionOf('chat');
    final stopWatching = r.watchSession(chat);
    var failed = 0;
    // Each as the phone's flow would do it; one failing doesn't stop the
    // others (what each did is checked on the computer next).
    Future<void> act(String what, Future<void> Function() body) async {
      try {
        await body();
      } on Object catch (e) {
        failed++;
        report.log('stand-in phone: $what failed: $e');
      }
    }

    await act('list', () async => expect(r.sessions.where((s) => s.cwd == dir('chat')).length, 1));
    await act('prompt', () async {
      await r.prompt(chat, 'hello from phone $t');
      await until(
        'reply on the phone',
        () => r.view(chat)?.items.any((i) => i.text.contains('fake reply: hello from phone')) ?? false,
      );
    });
    await act('approval', () async {
      final approve = sessionOf('approve');
      final ask = await until('the approval on the phone', () => r.session(approve)?.ask);
      if (t != 'ghostty') return await r.answer(approve, ask, approve: true);
      // Answering reads the screen, which Ghostty can't show: the phone is told to answer on the computer.
      await expectLater(
        r.answer(approve, ask, approve: true),
        throwsA(predicate((e) => '$e'.contains("Ghostty can't show its screen, so answer this on the computer"))),
      );
    });
    await act('keys', () async {
      final shell = windowOf('shell');
      await r.send(shell.key, r'echo e2e-$((6*7))');
      await r.press(shell.key, 'esc');
      await r.press(shell.key, 'up');
      await r.press(shell.key, 'down');
    });
    await act('image', () async {
      await until('chat at rest', () => r.session(chat)?.busy == false);
      await r.prompt(chat, 'what is in this image $t', images: [_png]);
    });
    await act('file', () async {
      await until('chat at rest', () => r.session(chat)?.busy == false);
      await r.prompt(chat, 'what is in this file $t', files: [(name: _docName, mime: 'text/plain', bytes: _doc)]);
    });
    await act('new session', () async {
      final launched = await r.launch(dir('newsess'), startAgent: true);
      report.log('phone launched $launched');
    });
    // On the session the + flow started, as the phone's steer, stop, ask and menu flows do.
    Future<String> newsess() => until(
      'the new session on the phone',
      () => r.sessions.where((s) => s.cwd == dir('newsess')).firstOrNull?.key,
      timeout: const Duration(seconds: 40),
    );
    Future<String> atRest() async {
      final key = await newsess();
      await until(
        '${name('newsess')} at rest',
        () => r.session(key)?.busy == false,
        timeout: const Duration(seconds: 60),
      );
      return key;
    }

    Future<LiveAsk> asked(String key, bool Function(LiveAsk a) which) => until('the ask on the phone', () {
      final a = r.session(key)?.ask;
      return a != null && which(a) ? a : null;
    });
    Future<void> pick(String key, LiveAsk ask, int i) => r.answer(
      key,
      ask,
      answers: [
        LiveAnswer(picks: [i]),
      ],
    );
    Future<void> working(String key) =>
        until('${name('newsess')} at work', () => r.session(key)?.busy ?? false, timeout: const Duration(seconds: 20));
    await act('steer and queue', () async {
      final key = await atRest();
      await r.prompt(key, 'e2e-slow steer run $t');
      await working(key);
      await r.prompt(key, 'steer from phone $t');
      await r.prompt(key, 'queue from phone $t', followUp: true);
      await until(
        'the queued prompt ran',
        () =>
            fakeOmpLog(dir('newsess'))
                .any((e) => e['event'] == 'prompt' && '${e['text']}'.contains('queue from phone')),
        timeout: const Duration(seconds: 120),
      );
    });
    await act('stop', () async {
      final key = await atRest();
      await r.prompt(key, 'e2e-slow stop run $t');
      await working(key);
      await r.abort(key);
      await atRest();
    });
    await act('question', () async {
      final key = await atRest();
      await r.prompt(key, 'e2e-question $t');
      final ask = await asked(key, (a) => a.questions?.isNotEmpty ?? false);
      await pick(key, ask, ask.questions!.first.options.indexOf('Green'));
    });
    await act('plan', () async {
      final key = await atRest();
      await r.prompt(key, 'e2e-plan $t');
      // Its options as the computer read them off the screen.
      final ask = await asked(key, (a) => a.isPlan && a.options.isNotEmpty);
      await pick(key, ask, ask.options.indexOf('Approve and execute'));
    });
    await act('/model', () async {
      final key = await atRest();
      await r.prompt(key, '/model');
      final ask = await asked(key, (a) => a.isMenu && a.title == 'Select a model');
      await pick(key, ask, ask.items.indexWhere((i) => i.label == 'fake-model-fast'));
    });
    await act('/resume', () async {
      final key = await atRest();
      await r.prompt(key, '/resume');
      final menu = await asked(key, (a) => a.isMenu && a.title == 'Resume a session');
      expect(menu.filter, isTrue, reason: '/resume can be searched');
      await r.answer(key, menu, answers: const [LiveAnswer(custom: 'beta')]);
      final found = await asked(
        key,
        (a) => a.isMenu && a.items.isNotEmpty && a.items.every((i) => i.label.toLowerCase().contains('beta')),
      );
      await pick(key, found, found.items.indexWhere((i) => i.label == 'e2e beta session'));
    });
    await act('screen keys', () async {
      final shell = windowOf('shell');
      for (final k in ['tab', 'enter', 'ctrl+c']) {
        await r.press(shell.key, k);
      }
    });
    await act('close a shell window', () => r.close(windowOf('closeme').key));
    await act('new shell', () async {
      report.log('phone opened ${await r.launch(dir('newshell'), startAgent: false)}');
    });
    await act('new project', () async {
      final root = (r.roots ?? const <String>[]).firstWhere((x) => x == c.projects);
      report.log('phone made ${await r.create(root, name('made'), startAgent: true)}');
    });
    await act('restart and continue', () async {
      final go = windowOf('switchgo');
      expect(await r.probe(go.key), isTrue, reason: 'omp at work in ${go.key}');
      await r.switchToConversation(go.key, Agent.omp);
      final resumed = await until(
        'switchgo reports at rest',
        () => r.sessions.where((s) => s.cwd == dir('switchgo') && !s.busy).firstOrNull,
        timeout: const Duration(seconds: 40),
      );
      await r.prompt(resumed.key, 'continue');
    });
    await act('just restart', () => r.switchToConversation(windowOf('switchstop').key, Agent.omp));
    await act('/new', () async {
      await until('chat at rest', () => r.session(chat)?.busy == false);
      await r.prompt(chat, '/new');
    });
    await act('close', () => r.close(r.sessions.firstWhere((s) => s.cwd == dir('endme')).window!));
    stopWatching();
    expect(failed, 0, reason: 'stand-in phone actions failed; see the log');
  }

  bool _mainDone = false;

  /// Ghostty, phone main phase: the approval was still unanswered when the
  /// phone was told to answer it on the computer.
  bool? _leftToComputer;

  /// Ghostty: the phone can't answer an approval (no screen to read), so once
  /// it was told so, approval.yaml asks (rpc `approve-on-computer`) and the
  /// approval is answered here, as a person at the computer would, before
  /// the phone's next scenarios find omp still waiting.
  Future<void> _answerOnComputer() async {
    final req = File(p.join(c.rpcDir, 'approve-on-computer.req'));
    while (!_mainDone && !req.existsSync()) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (_mainDone) return;
    req.deleteSync();
    _leftToComputer = !fakeOmpLog(dir('approve')).any((e) => e['event'] == 'answered');
    var answer = 'ok';
    try {
      await app.terminals.pressKeys(app.live.sessions.firstWhere((s) => s.cwd == dir('approve')).window!, ['enter']);
    } on Object catch (e) {
      answer = 'not answered: $e';
      report.log('approve on the computer: $e');
    }
    File(p.join(c.rpcDir, 'approve-on-computer.done')).writeAsStringSync(answer);
  }

  /// What every phone scenario should have done on the computer, from the
  /// fake omp's and the shells' own logs.
  Future<void> _verifyMain() async {
    List<Map<String, dynamic>> log(String w) => fakeOmpLog(dir(w));
    Iterable<Map<String, dynamic>> prompts(String w) =>
        log(w).where((e) => e['event'] == 'prompt' && e['source'] == 'phone');

    await report.step('phone: prompt reaches the agent', () async {
      await until('prompt in chat', () => prompts('chat').any((e) => '${e['text']}'.startsWith('hello from phone')));
      expect(prompts('chat').where((e) => '${e['text']}'.startsWith('hello from phone')).length, 1);
    });
    await report.step(
      t == 'ghostty'
          ? 'phone: approval left to the computer (Ghostty has no screen to read)'
          : 'phone: approval answered',
      () async {
        if (t == 'ghostty') {
          if (c.phone) {
            expect(_leftToComputer, isTrue, reason: 'the phone was told, then the approval was answered here');
          } else {
            expect(log('approve').where((e) => e['event'] == 'answered'), isEmpty);
            // Answered on the computer, so the run carries on.
            await app.terminals.pressKeys(app.live.sessions.firstWhere((s) => s.cwd == dir('approve')).window!, [
              'enter',
            ]);
          }
        }
        final answered = await until(
          'approval answered',
          () => log('approve').where((e) => e['event'] == 'answered').firstOrNull,
        );
        expect(answered['approve'], isTrue);
      },
    );
    await report.step('phone: keys reach the window', () async {
      final typed = await until('typed in the shell', () {
        final l = typedLog(c, name('shell'));
        // What screen.yaml types (the shell shows e2e-42).
        return l.contains(r'cmd:echo e2e-$((6*7))') &&
                l.contains('key:esc') &&
                l.any((k) => k == 'key:up' || k == 'key:down')
            ? l
            : null;
      });
      report.log('shell got: $typed');
    });
    await report.step('phone: image arrives decrypted at the agent', () async {
      final e = await until(
        'image prompt',
        () => prompts('chat').where((e) => (e['images'] as List).isNotEmpty).firstOrNull,
      );
      final image = (e['images'] as List).first as Map<String, dynamic>;
      expect(image['decoded'], isTrue, reason: 'PNG or JPEG bytes, not sealed ones: $image');
      expect(image['bytes'] as int, greaterThan(0));
    });
    await report.step('phone: a document arrives decrypted at the agent, named as @path', () async {
      final e = await until(
        'file prompt',
        () => prompts('chat').where((e) => (e['files'] as List? ?? const []).isNotEmpty).firstOrNull,
      );
      final file = (e['files'] as List).single as Map<String, dynamic>;
      expect(file['name'], _docName);
      expect(file['bytes'], _doc.length, reason: 'the bytes, not sealed ones: $file');
      expect(File(file['path'] as String).readAsBytesSync(), _doc);
      expect(e['text'] as String, contains('@"${file['path']}"'), reason: 'a name with spaces is quoted');
    });
    await report.step('phone: new session (+) opens in $t', () async {
      final s = await until('a session in ${name('newsess')}', () {
        return app.live.sessions.where((s) => s.cwd == dir('newsess') && s.window != null).firstOrNull;
      }, timeout: const Duration(seconds: 40));
      final key = s.window!;
      expect(key.startsWith(_opensWith), isTrue, reason: 'opened in $key, expected $_opensWith…');
      if (t == 'ghostty') {
        final w = (await app.terminals.windows()).firstWhere((w) => w.key == key);
        expect(w.via, 'Ghostty', reason: 'the tmux pane shows in a Ghostty window');
      }
    });
    // On the session the + flow started: what the phone's steer, stop, ask and menu flows did.
    bool says(Map<String, dynamic> e, String event, String text) =>
        e['event'] == event && '${e['text']}'.contains(text);
    Future<Map<String, dynamic>> heard(String what, bool Function(Map<String, dynamic> e) which) =>
        until(what, () => log('newsess').where(which).firstOrNull, timeout: const Duration(seconds: 60));
    await report.step('phone: steer reaches the agent while it works', () async {
      final e = await heard('a steer', (e) => says(e, 'steer', 'steer from phone'));
      expect('${e['text']}'.startsWith('steer from phone'), isTrue, reason: '$e');
    });
    await report.step('phone: a queued prompt runs after the turn', () async {
      await until('queued, then run', () {
        final l = log('newsess');
        final queued = l.indexWhere((e) => says(e, 'queued', 'queue from phone'));
        return queued >= 0 && l.skip(queued + 1).any((e) => says(e, 'prompt', 'queue from phone'));
      }, timeout: const Duration(seconds: 60));
    });
    await report.step('phone: Stop interrupts the agent', () async {
      await until('stopped from the phone', () {
        final l = log('newsess');
        final slow = l.indexWhere((e) => says(e, 'prompt', 'e2e-slow stop run'));
        return slow >= 0 && l.skip(slow + 1).any((e) => e['event'] == 'abort' && e['why'] == 'phone');
      }, timeout: const Duration(seconds: 60));
    });
    await report.step('phone: the agent\u2019s question answered', () async {
      final e = await heard('the question answered', (e) => e['event'] == 'question-answered');
      expect(e['answer'], 'Green');
      expect(e['custom'], isFalse);
    });
    await report.step('phone: the plan review answered', () async {
      final e = await heard('the plan picked', (e) => e['event'] == 'plan-picked');
      expect(e['option'], 'Approve and execute');
    });
    await report.step('phone: /model picker answered', () async {
      final e = await heard('a model picked', (e) => e['event'] == 'model');
      expect(e['model'], 'fake-model-fast');
    });
    await report.step('phone: /resume picker searched and answered', () async {
      final e = await heard('a session resumed', (e) => e['event'] == 'resume');
      expect(e['session'], 'e2e beta session');
    });
    await report.step('phone: screen keys Tab, Enter, Ctrl+C reach the window', () async {
      await until('keys in the shell', () {
        final l = typedLog(c, name('shell'));
        return l.contains('key:tab') && l.contains('key:enter') && l.contains('key:ctrl+c');
      });
    });
    await report.step('phone: close a shell window from the window list', () async {
      await until(
        'closeme window gone',
        () async => !(await app.terminals.windows()).any((w) => w.cwd == dir('closeme')),
      );
      final windows = await app.terminals.windows();
      for (final w in ['shell', 'chat', 'approve']) {
        expect(windows.where((x) => x.cwd == dir(w)), isNotEmpty, reason: '${name(w)} still open: ${_ws(windows)}');
      }
    });
    await report.step('phone: new shell opens in $t without an agent', () async {
      final w = await until('a window in ${name('newshell')}', () async {
        return (await app.terminals.windows()).where((w) => w.cwd == dir('newshell')).firstOrNull;
      }, timeout: const Duration(seconds: 40));
      expect(w.key.startsWith(_opensWith), isTrue, reason: 'opened in ${w.key}, expected $_opensWith…');
      expect(w.agent, isNull, reason: 'a plain shell: ${_ws([w])}');
      expect(app.live.sessions.where((s) => s.window == w.key || s.cwd == dir('newshell')), isEmpty);
    });
    await report.step('phone: new project made in the project folder', () async {
      final made = dir('made');
      expect(Directory(made).existsSync(), isTrue, reason: '$made made');
      await until('a session or window in ${name('made')}', () async {
        return app.live.sessions.any((s) => s.cwd == made) || (await app.terminals.windows()).any((w) => w.cwd == made);
      }, timeout: const Duration(seconds: 40));
    });
    await report.step('phone: switch to conversation, continue', () async {
      final starts = await until('switchgo restarted with -c', () {
        final s = log('switchgo').where((e) => e['event'] == 'start').toList();
        return s.length >= 2 ? s : null;
      }, timeout: const Duration(seconds: 40));
      expect(starts.first['extension'], isFalse);
      expect(starts.last['resume'], isTrue);
      expect(starts.last['extension'], isTrue);
      await until('continue prompt', () => prompts('switchgo').any((e) => e['text'] == 'continue'));
    });
    await report.step('phone: switch to conversation, just restart', () async {
      final starts = await until('switchstop restarted with -c', () {
        final s = log('switchstop').where((e) => e['event'] == 'start').toList();
        return s.length >= 2 ? s : null;
      }, timeout: const Duration(seconds: 40));
      expect(starts.last['resume'], isTrue);
      expect(prompts('switchstop'), isEmpty, reason: 'just restart sends nothing');
      await until(
        'switchstop reports',
        () => app.live.sessions.any((s) => s.cwd == dir('switchstop') && s.window != null),
      );
    });
    await report.step('phone: /new starts a fresh session in place', () async {
      await until('/new in chat', () => log('chat').any((e) => e['event'] == 'new'));
      final lastNew = log('chat').lastWhere((e) => e['event'] == 'new');
      // By its id: the image flow prompts it again after /new.
      final s = await until('chat session renewed', () {
        final s = app.live.sessions.where((s) => s.cwd == dir('chat')).toList();
        return s.length == 1 && s.single.id == lastNew['session'] ? s.single : null;
      });
      expect(ours(s.window ?? ''), isTrue);
    });
    await report.step('phone: close window closes only that one', () async {
      await until('endme quit', () => log('endme').any((e) => e['event'] == 'quit'));
      await until('endme window gone', () async => !(await app.terminals.windows()).any((w) => w.cwd == dir('endme')));
      final windows = await app.terminals.windows();
      for (final w in ['shell', 'chat', 'approve']) {
        expect(windows.where((x) => x.cwd == dir(w)), isNotEmpty, reason: '${name(w)} still open: ${_ws(windows)}');
      }
    });
  }

  /// Where a window the phone opens goes: the terminal's own windows, tmux
  /// for Ghostty (whose windows can't be read).
  String get _opensWith => t == 'ghostty' ? 'tmux:' : (t == 'kitty' ? 'kitty' : 'wezterm:');

  /// Settings → Phone → Terminal from phone off: the phone finds the computer
  /// not answering (phase computer-off) and asks for it back on (rpc
  /// terminal-on); Retry then brings its sessions back. It is on again after,
  /// whatever the phase did.
  Future<void> _computerOff() async {
    await _tap(_key('settings-tab-phone'));
    await _tap(_key('settings-terminal-from-phone'));
    await until('Terminal from phone off', () => !app.terminalOn);
    Future<void> turnOn() async {
      if (app.terminalOn) return;
      await _tap(_key('settings-terminal-from-phone'));
      await until('Terminal from phone on', () => app.terminalOn);
    }

    if (!c.phone) {
      final r = phone!.remote;
      try {
        await until(
          'the phone finds it offline',
          () => r.link == TerminalLink.offline,
          timeout: const Duration(seconds: 40),
        );
      } finally {
        await turnOn();
      }
      await until('the phone finds it online again', () => r.online, timeout: const Duration(seconds: 60));
      return;
    }
    final done = File(p.join(c.rpcDir, 'terminal-on.done'));
    if (done.existsSync()) done.deleteSync();
    var over = false;
    Future<void> serve() async {
      final req = File(p.join(c.rpcDir, 'terminal-on.req'));
      while (!over && !req.existsSync()) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (!req.existsSync()) return;
      req.deleteSync();
      var answer = 'ok';
      try {
        await turnOn();
      } on Object catch (e) {
        answer = 'not on: $e';
        report.log('terminal-on: $e');
      }
      done.writeAsStringSync(answer);
    }

    final serving = serve();
    final String code;
    try {
      code = await handOff(c.phaseDir, 'computer-off', out: 'ready', timeout: const Duration(minutes: 10));
    } finally {
      over = true;
      await serving;
      await turnOn();
    }
    expect(code, '0', reason: 'phone phase computer-off');
  }

  // ---------------------------------------------------------------- restarts

  /// Prompts from the phone, by text, each heard once.
  void _noReplays() {
    for (final w in ['chat', 'approve', 'switchgo', 'switchstop', 'newsess']) {
      final texts = [
        for (final e in fakeOmpLog(dir(w)))
          if (e['event'] == 'prompt' && e['source'] == 'phone') '${e['text']}|${(e['images'] as List).length}',
      ];
      expect(texts.toSet().length, texts.length, reason: '${name(w)} heard a prompt twice: $texts');
      final answers = fakeOmpLog(dir(w)).where((e) => e['event'] == 'answered').length;
      expect(answers, lessThanOrEqualTo(1), reason: '${name(w)} answered twice');
    }
  }

  /// The server stops and starts again; while it is down the phone's flow
  /// (phase server-down) finds it unreachable. It starts again whatever that
  /// phase found.
  Future<void> _serverRestart() async {
    Future<String?> down() async =>
        c.phone ? await handOff(c.phaseDir, 'server-down', out: 'ready', timeout: const Duration(minutes: 10)) : null;
    String? downCode;
    if (c.builtIn) {
      // It runs in this app: stopped (Tailscale stops serving it) and started on the same port and data.
      final h = app.hosting!;
      final port = h.port;
      await h.stop();
      try {
        downCode = await down();
      } finally {
        await Future<void>.delayed(const Duration(seconds: 3));
        await h.start(port: port);
      }
      expect(h.port, port, reason: 'the same port again');
      await until('Tailscale serves it again', () => h.publicUrl, timeout: const Duration(seconds: 60));
    } else {
      expect(await handOff(c.rpcDir, 'server-stop', out: 'req', timeout: const Duration(seconds: 60)), 'ok');
      try {
        downCode = await down();
      } finally {
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(await handOff(c.rpcDir, 'server-start', out: 'req', timeout: const Duration(seconds: 90)), 'ok');
      }
    }
    await until('desktop back on the server', () async {
      try {
        return (await app.serverDevices()).isNotEmpty;
      } on Object {
        return false;
      }
    }, timeout: const Duration(seconds: 60));
    await _phoneAfter('server-restart', 'after server restart $t');
    _noReplays();
    if (downCode != null) expect(downCode, '0', reason: 'phone phase server-down');
  }

  Future<void> _desktopRestart() async {
    final sessions = app.live.sessions.length;
    await tester.pumpWidget(const SizedBox());
    await api?.stop();
    await app.shutDown();
    app.dispose();
    await _launch();
    expect(app.user, isNotNull, reason: 'still signed in after the restart');
    await until(
      'sessions back',
      () => app.live.sessions.where((s) => s.window != null).length >= sessions,
      timeout: const Duration(seconds: 40),
    );
    await _see(_key('settings-content'));
    await _phoneAfter('desktop-restart', 'after desktop restart $t');
    _noReplays();
  }

  /// After a restart: the phone's flow (or the stand-in) reconnects and
  /// sends [prompt] once; it reaches the agent once.
  Future<void> _phoneAfter(String phase, String prompt) async {
    if (c.phone) {
      final code = await handOff(c.phaseDir, phase, out: 'ready', timeout: const Duration(minutes: 20));
      expect(code, '0', reason: 'phone phase $phase');
      return;
    }
    final r = phone!.remote;
    await until('phone back online', () => r.online, timeout: const Duration(seconds: 60));
    final chat = r.sessions.firstWhere((s) => s.cwd == dir('chat')).key;
    await r.prompt(chat, prompt);
    await until(
      '$prompt heard',
      () => fakeOmpLog(dir('chat')).any((e) => e['event'] == 'prompt' && e['text'] == prompt),
    );
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  static const _omp = '/opt/homebrew/bin/omp';

  /// The real omp, once, as the owner runs it but in the throwaway home: it
  /// finds the extension where this run's Get ready installed it
  /// (~/.omp/agent/extensions), no setup wizard, no model (nothing here
  /// calls one), sessions kept in the run's folder, no title generation. A
  /// `!` shell command typed at the computer gives it a transcript; the
  /// phone's `/new` then starts a fresh session in the same window.
  Future<void> _realOmp() async {
    final sessions = p.join(c.work, 'omp-sessions');
    String q(String s) => "'${s.replaceAll("'", r"'\''")}'";
    await _open('realomp', autorun: 'OMP_SKIP_SETUP=1 $_omp --session-dir ${q(sessions)} --no-title --no-lsp');
    bool here(String cwd) => _isDir(cwd, 'realomp');
    final LiveSession s;
    try {
      s = await until(
        'real omp reports',
        () => app.live.sessions.where((s) => here(s.cwd) && s.window != null).firstOrNull,
        timeout: const Duration(seconds: 60),
      );
    } on TimeoutException {
      for (final x in app.live.sessions) {
        report.log('real omp: live ${x.key} ${x.agent.name} window=${x.window} cwd=${x.cwd}');
      }
      for (final w in await app.terminals.windows()) {
        if (!here(w.cwd)) continue;
        report.log('real omp: window ${w.key} ${w.program}\n${await app.terminals.plainScreen(w.key)}');
      }
      rethrow;
    }
    expect(ours(s.window!), isTrue, reason: 'real omp placed in ${s.window}');
    await Future<void>.delayed(const Duration(seconds: 2));
    await app.terminals.send(s.window!, '!echo e2e-real', enter: true);
    final before = await until('the shell command in its transcript', () {
      final now = app.live[s.key];
      return now != null && now.log.items.any((i) => '${i.args}${i.output}${i.text}'.contains('e2e-real'))
          ? now.id
          : null;
    });
    if (c.phone) {
      // The phone lists it by its title, or "omp" while it has none (the real omp names a session later).
      final expectFile = File(p.join(c.artifacts, 'expect.json'));
      final expected = jsonDecode(expectFile.readAsStringSync()) as Map<String, dynamic>;
      final title = app.live[s.key]?.title ?? '';
      (expected['realOmp'] as Map<String, dynamic>)['title'] = title.isNotEmpty ? title : Agent.omp.label;
      expectFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(expected));
      final code = await handOff(c.phaseDir, 'real-omp', out: 'ready', timeout: const Duration(minutes: 15));
      expect(code, '0', reason: 'phone phase real-omp');
    } else {
      final r = phone!.remote;
      final key = await until('the phone lists real omp', () => r.sessions.where((x) => here(x.cwd)).firstOrNull?.key);
      await r.prompt(key, '/new');
    }
    final after = await until('real omp on a new session', () {
      final now = app.live.sessions.where((x) => here(x.cwd)).toList();
      return now.length == 1 && now.single.id != before ? now.single : null;
    });
    expect(after.key, s.key, reason: 'the same window, the same session key');
    expect(after.log.items.any((i) => '${i.args}${i.output}${i.text}'.contains('e2e-real')), isFalse);
  }

  /// Whether [cwd], as an agent reports it, is project [what]'s folder. The
  /// real omp drops macOS's /private: the run's /private/tmp/… is /tmp/… to it.
  bool _isDir(String cwd, String what) {
    final d = dir(what);
    if (cwd == d) return true;
    try {
      return Directory(cwd).resolveSymbolicLinksSync() == d;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _revoke() async {
    final phones = [
      for (final d in await app.serverDevices())
        if (d.role == DeviceRole.phone && !_phonesBefore.contains(d.id)) d,
    ];
    expect(phones, isNotEmpty, reason: 'a phone signed in');
    for (final d in phones) {
      await app.server!.revokeDevice(d.id);
    }
    final left = {for (final d in await app.serverDevices()) d.id};
    expect(phones.where((d) => left.contains(d.id)), isEmpty);
    if (c.phone) {
      final code = await handOff(c.phaseDir, 'revoke', out: 'ready', timeout: const Duration(minutes: 10));
      expect(code, '0', reason: 'phone phase revoke');
    } else {
      final ph = phone!;
      await expectLater(ph.server.devices(), throwsA(isA<ServerException>()));
    }
  }

  /// Settings → Terminals → Start new windows in tmux, in the throwaway
  /// Ghostty config; a Ghostty window opened after it runs in tmux.
  Future<void> _ghosttyTmux() async {
    await _tap(_key('settings-tab-terminals'));
    await _tap(_key('settings-ghostty-tmux'));
    final config = File(p.join(c.home, '.config', 'ghostty', 'config'));
    await until('config has tmux', () => config.readAsStringSync().contains('new-session'));
    final probe = (await app.terminals.windows()).firstWhere((w) => w.key.startsWith('ghostty:'));
    final reload = await Process.run('/usr/bin/osascript', [
      '-e',
      'tell application "Ghostty" to perform action "reload_config" on (first terminal whose id is "${probe.key.substring(8)}")',
    ]);
    report.log('reload_config: ${reload.exitCode} ${reload.stderr}');
    final d = makeProject(c, name('tmuxwin'), autorun: 'omp');
    await app.terminals.ghostty!.launch(d);
    final s = await until('a session from the tmux window', () {
      return app.live.sessions.where((s) => s.cwd == d && s.window != null).firstOrNull;
    }, timeout: const Duration(seconds: 40));
    expect(s.window!.startsWith('tmux:'), isTrue, reason: 'the new Ghostty window runs tmux: ${s.window}');
    final w = (await app.terminals.windows()).firstWhere((w) => w.key == s.window);
    expect(w.via, 'Ghostty');
  }

  /// Settings → Terminals → Remove: the throwaway Ghostty config no longer
  /// starts tmux.
  Future<void> _ghosttyTmuxRemove() async {
    await _tap(_key('settings-tab-terminals'));
    await _see(find.descendant(of: _key('settings-ghostty-tmux'), matching: find.text('Remove')));
    await _tap(_key('settings-ghostty-tmux'));
    final config = File(p.join(c.home, '.config', 'ghostty', 'config'));
    await until('config without tmux', () => !config.readAsStringSync().contains('new-session'));
  }

  /// Settings → Phone → Project folders: a folder's chip (Remove) takes it
  /// off; Add folder… (the run's host picks the run's projects folder) puts
  /// it back.
  Future<void> _projectFolders() async {
    await _tap(_key('settings-tab-phone'));
    final chip = _key('settings-folder-${c.projects}');
    await _see(find.ancestor(of: chip, matching: find.byTooltip('Remove')));
    await _tap(chip);
    await until('folder removed', () => !app.projectRoots.contains(c.projects));
    await _gone(chip);
    await _tap(find.descendant(of: _key('settings-content'), matching: find.text('Add folder…')));
    await until('folder added', () => app.projectRoots.contains(c.projects));
    await _see(chip);
  }

  /// Settings → Account → Add a computer…: the link shown is the built-in
  /// server's setup link, one another computer can paste.
  Future<void> _addComputer() async {
    await _tap(_key('settings-tab-account'));
    await _tap(_key('settings-add-computer'));
    await _see(_key('add-computer-link'));
    final shown = tester.widget<SelectableText>(_key('add-computer-link')).data!;
    expect(shown, '${app.computerSetupLink()}');
    expect(setupLinkProblem(shown), isNull, reason: 'another computer can paste it');
    expect(Backend.setupToken(Uri.parse(shown)), isNotNull);
    await _tap(find.widgetWithText(TextButton, 'Done'));
    await _gone(_key('add-computer-link'));
  }

  /// Settings → Phone → Reset key…, confirmed: a new channel key, said so.
  Future<void> _resetKey() async {
    final before = base64Encode((await app.channelKey()).bytes);
    await _tap(_key('settings-tab-phone'));
    await _tap(_key('settings-reset-key'));
    await _see(find.text('Reset this computer’s key?'));
    await _tap(find.widgetWithText(TextButton, 'Reset key'));
    await _see(find.textContaining('New key made'));
    expect(base64Encode((await app.channelKey()).bytes), isNot(before), reason: 'a new channel key');
  }

  /// Settings → Account → Erase…, confirmed: every computer and phone is
  /// signed out of the server (the spare computer's sign-in stops working)
  /// and this computer signs in again at once, the only one on it.
  Future<void> _erase() async {
    final before = app.user!.device.id;
    await _tap(_key('settings-tab-account'));
    await _tap(find.text('Erase…'));
    await _see(find.text('Erase this server\u2019s data?'));
    await _tap(find.widgetWithText(TextButton, 'Erase'));
    final after = await until('signed in again', () {
      final u = app.user;
      return u != null && u.device.id != before ? u : null;
    }, timeout: const Duration(seconds: 60));
    final left = [for (final d in await app.serverDevices()) d.id];
    expect(left, [after.device.id], reason: 'only this computer, signed in again');
    final spare = _spare!;
    await expectLater(spare.devices(), throwsA(isA<ServerException>()), reason: 'the spare computer was signed out');
    spare.close();
    _spare = null;
  }

  /// Settings → Account → Sign out, last: a computer running the server
  /// asks first (signing out stops it); one on its own server goes to
  /// sign-in, whose Use a different server returns to the setup.
  Future<void> _signOut() async {
    await _tap(_key('settings-tab-account'));
    final hosts = app.hosting != null;
    await _tap(_key('settings-sign-out'));
    if (hosts) {
      await _see(find.text('Stop your server and sign out?'));
      await _tap(find.widgetWithText(TextButton, 'Sign out'));
    }
    await until('signed out', () => app.user == null);
    await _frames();
    if (app.backend != null) await _tap(find.textContaining('Use a different server'));
    await until('no server', () => app.backend == null);
    await _see(find.byType(SetupPage));
    await report.shot('signed-out');
  }
}
