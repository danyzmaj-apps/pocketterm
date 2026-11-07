/// The desktop side of the end-to-end run (bin/run.dart runs it for each
/// terminal): the native Mac app (mac_app.dart) started as from Finder with
/// the run's throwaway home, set up through its first-run window against the
/// run's server, made ready, throwaway terminal windows with the fake omp in
/// them, pairing links handed to the phone's flows, and on the computer what
/// each phone scenario should have done. What the Flutter app's
/// integration_test/e2e_test.dart did, step for step (docs/TESTING.md maps
/// one to the other).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:pocketterm_e2e/e2e.dart';
import 'package:pocketterm_e2e/mac_app.dart';

/// The run's scenarios as they pass and fail: a line each in results.jsonl
/// (bin/run.dart makes the table of them), a screenshot of the app's window
/// for each failure.
class Report {
  Report(this.c, this.app);
  final E2eConfig c;
  final MacApp app;
  final List<String> failures = [];

  void log(String line) {
    stdout.writeln('  E2E $line');
    File(p.join(c.artifacts, 'desktop-e2e.log'))
        .writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append);
  }

  void _record(String scenario, {required bool ok, bool skip = false, String detail = ''}) {
    File(c.results)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${jsonEncode({'scenario': scenario, 'ok': ok, 'skip': skip, 'detail': detail, 'at': DateTime.now().toIso8601String()})}\n',
        mode: FileMode.append,
        flush: true,
      );
  }

  /// Runs scenario [name]; a failure is recorded with a screenshot and, if
  /// [critical] (the rest can't go on without it), thrown on. A run limited
  /// to some steps (`--desktop-only`) skips it unless it's one of them, or
  /// critical, or [needed] (the steps after it need it done).
  Future<bool> step(String name, Future<void> Function() body, {bool critical = false, bool needed = false}) async {
    if (!critical && !needed && !c.desktopRuns(name)) {
      skip(name, 'not in --desktop-only');
      return false;
    }
    log('▶ $name');
    try {
      await body();
      _record(name, ok: true);
      log('✓ $name');
      return true;
    } on Object catch (e, st) {
      failures.add(name);
      _record(name, ok: false, detail: '$e'.split('\n').first);
      log('✗ $name: $e\n$st');
      await shot('fail-$name');
      if (critical) rethrow;
      return false;
    }
  }

  void skip(String name, String why) {
    _record(name, ok: false, skip: true, detail: why);
    log('- $name: $why');
  }

  /// A screenshot of the app's window; for a failure also what accessibility read in it (what steps look by).
  Future<void> shot(String name) async {
    if (app.pid == null) return;
    await app.shot(name);
    if (!name.startsWith('fail-')) return;
    try {
      final (_, dump) = await app.ax(['dump']);
      final safe = name.replaceAll(RegExp(r'[^\w.-]+'), '_');
      File(p.join(c.screenshots, '$safe.ax.txt'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(dump);
    } on Object {
      // Not running any more.
    }
  }
}

class Failed implements Exception {
  Failed(this.message);
  final String message;
  @override
  String toString() => message;
}

// Read as package:test's expect(condition, reason).
// ignore: avoid_positional_boolean_parameters
void expect(bool ok, String why) {
  if (!ok) throw Failed(why);
}

/// Tailscale's CLI, asked how it stands and what it serves.
const tailscaleCli = '/Applications/Tailscale.app/Contents/MacOS/Tailscale';

/// A document the phone sends (file.yaml; maestro/e2e/run.sh puts it in the phone's files), a name that needs
/// quoting.
const _docName = 'notes from the phone.txt';
final List<int> _doc = utf8.encode('PocketTerm e2e notes\n');

class DesktopRun {
  DesktopRun(this.c, {required this.app, required this.phonePhase, required this.serverControl, this.hold = false})
    : report = Report(c, app),
      owned = Owned(c.owned);

  final E2eConfig c;
  final MacApp app;
  final Report report;
  final Owned owned;

  /// Runs the phone's flows of a phase (maestro/e2e/run.sh); its exit code, `skipped` without a phone.
  final Future<String> Function(String phase) phonePhase;

  /// `server-stop` / `server-start` for a server outside the app; `ok` or what went wrong.
  final Future<String> Function(String what) serverControl;

  /// `--hold`: after the hand-off the phone's main flows are left to the person (maestro/e2e/run.sh by hand,
  /// against this run's folder), and the run goes on once `<artifacts>/hold` is deleted.
  final bool hold;

  late final Throwaway term = Throwaway.of(c.terminal, c, owned);

  /// The spare computer (_handOff) is signed in until the end.
  var _spare = false;

  /// The phones on the server before this run's paired.
  Set<String> _phonesBefore = const {};

  String get t => c.terminal;
  String name(String what) => '$t-$what';
  String dir(String what) => c.project(name(what));

  /// What the window list calls the terminal's windows' keys.
  bool ours(String key) => switch (t) {
    'kitty' => key.startsWith('kitty'),
    'wezterm' => key.startsWith('wezterm:'),
    'iterm' => key.startsWith('iterm:'),
    _ => key.startsWith('ghostty:') || key.startsWith('tmux:'),
  };

  static String _ws(Iterable<Map<String, dynamic>> windows) =>
      windows.map((w) => '${w['key']} "${w['title']}" ${w['cwd']} tty=${w['tty']} program=${w['program']}').join('; ');

  Future<List<Map<String, dynamic>>> _sessions() => app.sessions();
  Future<List<Map<String, dynamic>>> _windows() => app.windows();
  Future<Map<String, dynamic>> _state() => app.state();

  Future<List<Map<String, dynamic>>> _devices() async => [
    for (final d in (await app.call('server-devices')) as List) d as Map<String, dynamic>,
  ];

  // ---------------------------------------------------------------- the run

  Future<void> all() async {
    writeHome(c);
    await startTmux(c, owned);
    await app.launch();

    await report.step('desktop: runs as from Finder (launchd PATH, no TERM, no locale)', _asFromFinder, critical: true);
    await report.step('terminals: throwaway windows open', _openEarlyWindows, critical: true);
    if (!c.builtIn) await report.step('setup: the Tailscale checklist shows Tailscale as it is', _thisComputer);
    await report.step('setup: link problems are explained', _linkProblems);
    if (c.builtIn) {
      await report.step(
        'setup: On this computer starts its server, Tailscale serves it',
        _thisComputer,
        critical: true,
      );
    } else {
      await report.step('setup: join another computer, paste link', _join, critical: true);
    }
    await _getReady();
    await report.step('windows: sessions in their own windows', _sessionsLocated, critical: true);
    await report.step('windows: plain shell is a screen', _shellIsScreen);
    await report.step('settings: status bar and Open setup checklist', _statusBar);
    await report.step('settings: coding agents tab', _agentsTab);
    await report.step('settings: data protection', _dataProtection);
    await report.step('settings: launch at login switch', _launchAtLogin);
    await report.step('settings: new sessions open in $t', _chooseTerminal, needed: true);
    await report.step('add a phone: two pairing links', _pairingLinks, critical: true);
    await report.step('hand-off files', _handOff, critical: true);

    if (c.phone) {
      final answering = t == 'ghostty' ? _answerOnComputer() : Future<void>.value();
      final code = hold ? await _held() : await phonePhase('main');
      _mainDone = true;
      await answering;
      report.log('phone main → $code');
    }
    await _verifyMain();
    await _profiles();
    await report.step('phone: computer off, then Retry brings it back', _computerOff);

    await report.step('restart: server', _serverRestart);
    await report.step('restart: desktop app', _desktopRestart);
    if (File(_omp).existsSync()) {
      // The phone sends the /new: only when its flow runs (--phone-only may leave it out).
      await _after('real-omp', 'real omp: /new from the phone starts a fresh session in place', _realOmp);
      await report.step('real omp: a profile loads PocketTerm from its own folder and says so', _realOmpProfile);
    } else {
      report
        ..skip('real omp: /new from the phone starts a fresh session in place', 'omp is not installed')
        ..skip('real omp: a profile loads PocketTerm from its own folder and says so', 'omp is not installed');
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

  /// The run started this app as Launch Services does, not with the environment of the terminal it was run from.
  Future<void> _asFromFinder() async {
    final env = ((await _state())['env'] as Map).cast<String, String>();
    final path = (env['PATH'] ?? '').split(':');
    final home = Platform.environment['HOME'] ?? '';
    final leaks = [
      for (final dir in ['/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin', '$home/.local/bin', '$home/.bun/bin'])
        if (path.contains(dir)) '$dir on the PATH',
      for (final k in ['TERM', 'TERM_PROGRAM', 'LANG', 'LC_ALL', 'LC_CTYPE', 'ZDOTDIR'])
        if (env[k] case final v? when v.isNotEmpty) '$k=$v',
    ];
    if (leaks.isNotEmpty) throw Failed('the desktop has a terminal\u2019s environment: ${leaks.join(', ')}');
    expect(env['HOME'] == c.home, 'its HOME is the run\u2019s: ${env['HOME']}');
  }

  Future<void> end() async {
    await report.shot('end');
    // What the run signed in leaves the server (it may be shared): its phones should a failure have kept them,
    // the spare computer, then this one.
    try {
      if (app.pid != null) {
        final signedIn = (await _state())['user'] != null;
        if (_spare && signedIn) {
          for (final d in await _devices()) {
            if (d['role'] == 'phone' && !_phonesBefore.contains(d['id'])) {
              await app.call('revoke', args: {'id': d['id']});
            }
          }
        }
        if (_spare) await app.call('spare-leave');
        if (signedIn) await app.call('leave');
      }
    } on Object catch (e) {
      report.log('end: leaving the server: $e');
    }
    try {
      await app.quit();
      await app.forget();
    } on Object catch (e) {
      report.log('end: $e');
    }
    final stopped = await Owned.stopAll(c.owned);
    report.log('stopped ${stopped.join(', ')}');
  }

  // ---------------------------------------------------------------- windows

  /// Before PocketTerm is set up: the terminal with a plain shell, another plain shell the phone closes, two omp
  /// at work (started before PocketTerm was in omp, so they don't report: the phone switches them to their
  /// conversation later), and folders the phone opens a session and a shell in, and starts sessions in an omp
  /// profile in (the computer lists its projects to the phone every few minutes: they're there from the start).
  Future<void> _openEarlyWindows() async {
    await term.start(makeProject(c, name('shell')));
    await _open('closeme');
    await _open('switchgo', autorun: 'omp --busy');
    await _open('switchstop', autorun: 'omp --busy');
    makeProject(c, name('newsess'));
    makeProject(c, name('newshell'));
    makeProject(c, name('profnew'));
    for (final w in ['switchgo', 'switchstop']) {
      await until('fake omp at work in ${name(w)}', () => fakeOmpLog(dir(w)).any((e) => e['event'] == 'start'));
    }
  }

  /// A window in project [what] that runs [autorun]: opened with the terminal's own command line, Ghostty's
  /// through the app's Ghostty host (AppleScript, all it has).
  Future<void> _open(String what, {String? autorun}) async {
    final d = makeProject(c, name(what), autorun: autorun);
    if (t == 'ghostty') {
      await _ghosttyLaunch(d);
    } else {
      await term.open(d);
    }
  }

  /// Ghostty's window through the app. A test build is a new app to macOS: the first run asks a person
  /// whether it may control Ghostty, and the app says so at once; the run waits up to 3 minutes for them.
  Future<void> _ghosttyLaunch(String dir) async {
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    var told = false;
    while (true) {
      try {
        await app.call('ghostty-launch', args: {'dir': dir});
        return;
      } on AppError catch (e) {
        if (!'$e'.contains('is asking whether') || DateTime.now().isAfter(deadline)) rethrow;
        if (!told)
          report.log(
            'waiting for a person to allow PocketTerm E2E to control Ghostty (System Settings › Privacy & Security › Automation)',
          );
        told = true;
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
  }

  // ---------------------------------------------------------------- setup

  /// The setup's first screen, the Tailscale checklist, follows Tailscale's real state (asked here of its own
  /// CLI). Nothing is signed in or started, unless the run uses the built-in server: then Start.
  Future<void> _thisComputer() async {
    await _toChoose();
    final installed = File(tailscaleCli).existsSync();
    var json = const <String, dynamic>{};
    if (installed) {
      final cli = await Process.run(tailscaleCli, ['status', '--json']);
      try {
        json = jsonDecode('${cli.stdout}') as Map<String, dynamic>;
      } on FormatException {
        // Not running: no JSON.
      }
    }
    final backend = json['BackendState'];
    final running = backend == 'Running';
    final started = running || backend == 'NeedsLogin' || backend == 'NeedsMachineAuth';
    final certs = (json['CertDomains'] as List?)?.isNotEmpty ?? false;
    // Port 443 free: Tailscale serves nothing there yet (the person's own PocketTerm may already).
    final serve = running ? await Process.run(tailscaleCli, ['serve', 'status', '--json']) : null;
    final serveFree = serve != null && !'${serve.stdout}'.contains(':443"');
    final expected = [
      (key: 'check-installed', done: installed, yes: 'Tailscale is installed', no: 'Install Tailscale'),
      (key: 'check-running', done: started, yes: 'Tailscale is running', no: 'Start Tailscale'),
      (key: 'check-signed-in', done: running, yes: 'Signed in to Tailscale', no: 'Sign in to Tailscale'),
      (key: 'check-https', done: running && certs, yes: 'HTTPS certificates are on', no: 'Turn on HTTPS certificates'),
      (
        key: 'check-serve-free',
        done: running && certs && serveFree,
        yes: 'Tailscale’s HTTPS port is free for PocketTerm',
        no: running && certs ? 'Free Tailscale’s HTTPS port (443)' : 'Tailscale’s HTTPS port (443) for PocketTerm',
      ),
    ];
    report.log('tailscale: $backend, certs $certs, 443 free $serveFree');
    // Steps after the first one not done read "to do" whatever they are.
    final firstTodo = expected.indexWhere((e) => !e.done);
    String? wrong;
    try {
      await until('Tailscale checklist read', () async {
        for (final (i, e) in expected.indexed) {
          final done = e.done && (firstTodo < 0 || i < firstTodo);
          final text = done ? e.yes : e.no;
          if (!await app.says(e.key, text)) {
            wrong = '${e.key}: wanted "$text", shows ${await app.texts(e.key)}';
            return false;
          }
        }
        return true;
      }, timeout: const Duration(seconds: 20));
    } on TimeoutException {
      throw Failed('Tailscale checklist: $wrong');
    }
    // Tailscale already serving something there (the person's own PocketTerm) keeps Start off too: PocketTerm
    // won't replace it.
    final serving =
        installed && !'${(await Process.run(tailscaleCli, ['serve', 'status'])).stdout}'.contains('No serve config');
    final on = await app.enabled('setup-start-server');
    expect(
      on == (firstTodo < 0 && !serving),
      'Start is on only when every check is done and Tailscale serves nothing yet (on: $on)',
    );
    await report.shot('setup-this-computer');
    if (!c.builtIn) return;
    // Start: the server runs here, Tailscale publishes it, this computer signs in on 127.0.0.1.
    await app.press('setup-start-server');
    await until('signed in', () async => (await _state())['user'] != null, timeout: const Duration(seconds: 60));
    final url = await until(
      'Tailscale serves it',
      () async => ((await _state())['hosting'] as Map?)?['publicUrl'] as String?,
      timeout: const Duration(seconds: 60),
    );
    report.log('built-in server at $url');
    final client = HttpClient();
    try {
      final health = await (await client.getUrl(Uri.parse(url).resolve('/v1/health'))).close();
      expect(health.statusCode == 200, '$url/v1/health through tailscale serve: ${health.statusCode}');
    } finally {
      client.close(force: true);
    }
    await _signedInChecks();
  }

  /// What every first sign-in does: the checklist opens, Terminal from phone goes on, no login item.
  Future<void> _signedInChecks() async {
    await app.seeText('Get this computer ready');
    final s = await _state();
    expect(s['terminalOn'] == true, 'the first sign-in turns Terminal from phone on');
    expect(s['hostLaunchAtLogin'] == false, 'the first sign-in adds no login item on its own');
  }

  /// Join another computer's PocketTerm with the run's sidecar setup link (test builds take its http URL).
  Future<void> _join() async {
    await _toChoose();
    await app.press('setup-join');
    await app.see('setup-link');
    await app.set('setup-link', c.setupLink);
    await app.seeText('answers', id: 'setup-link-health');
    await app.press('setup-connect');
    await until('signed in', () async => (await _state())['user'] != null);
    await _signedInChecks();
  }

  /// Back to the setup's first screen (the Tailscale checklist), from any setup screen a step before left open.
  Future<void> _toChoose() async {
    if (!await app.has('setup-join')) await app.call('open-main');
    for (var i = 0; i < 4 && !await app.has('setup-join'); i++) {
      if (!await app.has('setup-back')) break;
      await app.press('setup-back');
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await app.see('setup-join');
  }

  /// Join another computer's PocketTerm: a pasted link that isn't a computer's setup link says what is wrong
  /// with it, asks no server, and Connect signs nothing in; a setup link whose server doesn't answer says that.
  /// Back to the first screen after.
  Future<void> _linkProblems() async {
    await _toChoose();
    await app.press('setup-join');
    await app.see('setup-link');
    String link(Map<String, String> q) => '${Uri(scheme: 'pocketterm', host: 'setup', queryParameters: q)}';
    const url = 'https://pocketterm.example.com';
    Future<String> error() async => (await app.texts('setup-error')).join(' ');
    for (final (text, why) in [
      ('not a link', 'That isn’t a setup link.'),
      (link({'url': url}), 'That link has no setup token'),
      (link({'url': url, 'code': 'E2E-PHONE'}), 'That link signs in a phone, not a computer.'),
    ]) {
      await app.set('setup-link', text);
      await until(
        'the error for $text',
        () async => (await error()).contains(why),
        timeout: const Duration(seconds: 10),
      ).catchError((Object e) async => throw Failed('$e: shows "${await error()}"'));
      expect(!await app.has('setup-link-health'), 'no server asked for $text');
      await app.press('setup-connect');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect((await _state())['backend'] == null, 'Connect with $text signs nothing in');
      expect((await error()).contains(why), 'Connect says it again');
    }
    final down = link({'url': 'https://127.0.0.1:9', 'setup': 'e2e-not-a-token'});
    await app.set('setup-link', down);
    final said = await until('the server not answering said', () async {
      final e = await error();
      return e.isEmpty ? null : e;
    }, timeout: const Duration(seconds: 20));
    expect(said.contains('127.0.0.1'), 'it names the server: $said');
    expect(!await app.says('setup-link-health', 'answers'), 'nothing says it answers');
    await report.shot('setup-link-problem');
    await app.set('setup-link', '');
    await _toChoose();
  }

  Future<void> _getReady() async {
    await report.step('get ready: omp gets PocketTerm once confirmed', () async {
      final ext = File(p.join(c.home, '.omp', 'agent', 'extensions', 'pocketterm-live.ts'));
      // Nothing goes in on its own: omp's Install, then the popup's Install once read (confirmAgentInstall).
      await app.pressLabel('Install', timeout: const Duration(seconds: 30));
      await app.seeText('~/.omp/agent/extensions', id: 'confirm-install');
      expect(!ext.existsSync(), 'installed before the person confirmed');
      await app.press('confirm-install-go');
      await until('extension installed', ext.existsSync);
      await app.seeText('PocketTerm is installed in omp');
    }, needed: true);
    await report.step('get ready: sessions already open are listed', () async {
      await app.see('get-ready-open-sessions', timeout: const Duration(seconds: 20));
      final unreported = [for (final w in (await app.call('unreported')) as List) w as Map<String, dynamic>];
      final early = unreported.where((w) => '${w['cwd']}'.contains(name('switch'))).toList();
      expect(early.length == 2, 'both omp started before PocketTerm: ${_ws(unreported)}');
      for (final w in early) {
        await app.see('get-ready-unreported-${w['key']}');
      }
    });
    await report.step('get ready: terminals', () async {
      final statuses = [for (final s in (await app.call('statuses')) as List) s as Map<String, dynamic>];
      final s = statuses.firstWhere((s) => s['id'] == t);
      expect(s['usable'] == true, '$t: ${s['state']} ${s['note']}');
      await app.see('get-ready-terminals');
      await app.see('mac-terminals');
    });
    await report.step('get ready: project folders', () async {
      await app.press('get-ready-choose-folder');
      await until('project folder added', () async => ((await _state())['projectRoots'] as List).contains(c.projects));
    }, needed: true);
    await report.step('get ready: phone code', () async {
      // A shared server (--server <url>) may still list another run's phone: then the card says one is signed
      // in, and this run's links come from Add a phone.
      if ((await _devices()).any((d) => d['role'] == 'phone')) {
        await app.seeText('A phone is signed in');
      } else {
        await app.see('pairing-qr');
        await until('a pairing link made', () async => ((await _state())['pairingLinks'] as List).isNotEmpty);
      }
      await report.shot('get-ready');
    });
    await report.step('get ready: Done', () async {
      await app.press('get-ready-done');
      await until('settings shown', () async => (await _state())['getReadyDone'] == true);
      await app.see('settings-content');
    }, critical: true);
  }

  /// The fake omp, started now that PocketTerm is in omp, reports; each session is placed in its own window, once.
  Future<void> _sessionsLocated() async {
    await _open('chat', autorun: 'omp');
    await _open('approve', autorun: 'omp --ask');
    await _open('endme', autorun: 'omp');
    for (final w in ['chat', 'approve', 'endme']) {
      final s =
          await until('${name(w)} reports in a window', () async {
            final s = (await _sessions()).where((s) => s['cwd'] == dir(w)).toList();
            return s.length == 1 && s.single['window'] != null ? s.single : null;
          }).catchError((Object e) async {
            final sessions = [for (final s in await _sessions()) '${s['cwd']} window=${s['window']}'];
            throw Failed('$e; sessions: $sessions; windows: ${_ws(await _windows())}');
          });
      expect(ours(s['window'] as String), '${name(w)} placed in ${s['window']}');
    }
    final windows = await _windows();
    final sessions = await _sessions();
    for (final s in sessions) {
      expect(
        windows.where((w) => w['key'] == s['window']).length == 1,
        '${s['cwd']}: its window once: ${_ws(windows)}',
      );
    }
    final claimed = {for (final s in sessions) s['window']};
    final others = windows.where((w) => !claimed.contains(w['key'])).toList();
    for (final w in ['chat', 'approve', 'endme']) {
      expect(others.where((o) => o['cwd'] == dir(w)).isEmpty, '${name(w)} also among Other windows: ${_ws(others)}');
    }
    final unreported = [for (final w in (await app.call('unreported')) as List) w as Map<String, dynamic>];
    expect(
      unreported.where((w) => !'${w['cwd']}'.contains(name('switch'))).isEmpty,
      'only the two started before PocketTerm are unreported: ${_ws(unreported)}',
    );
  }

  Future<void> _shellIsScreen() async {
    final windows = await _windows();
    final sessions = await _sessions();
    for (final what in ['shell', 'closeme']) {
      final shell = windows.where((w) => w['cwd'] == dir(what)).toList();
      expect(shell.length == 1, 'the ${name(what)} window: ${_ws(windows)}');
      expect(shell.single['agent'] == null, '${name(what)} runs no agent');
      expect(!sessions.any((s) => s['window'] == shell.single['key']), 'no session in ${name(what)}');
    }
  }

  /// Settings, on [tab] (its toolbar button).
  Future<void> _tab(String tab) async {
    if (!await app.has('settings-content')) await app.call('open-main');
    await app.see('settings-content');
    await app.pressLabel(tab);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  /// Settings' status section says how this computer stands; Open setup checklist goes back to Get this
  /// computer ready, whose Done returns.
  Future<void> _statusBar() async {
    await _tab('Phone');
    await until('the status read', () async {
      final texts = await app.texts('settings-status');
      return texts.any((l) => l.contains('All set') || l.contains('attention'));
    });
    await app.press('settings-open-checklist');
    await until('the checklist open', () async => (await _state())['getReadyDone'] == false);
    await app.seeText('Get this computer ready');
    await app.press('get-ready-done');
    await until('the checklist done', () async => (await _state())['getReadyDone'] == true);
    await app.see('settings-content');
    await app.see('settings-status');
  }

  /// Settings → Coding agents: omp has PocketTerm, up to date, and is the default; Claude Code isn't on this
  /// computer (the run keeps it out).
  Future<void> _agentsTab() async {
    await _tab('Coding agents');
    await app.seeText('PocketTerm installed, up to date', id: 'settings-agent-omp');
    await app.see('settings-default-omp');
    await app.seeText('Not found on this computer', id: 'settings-agent-claude');
    expect(!await app.has('settings-default-claude'), 'Claude Code is not the default');
    await report.shot('settings-agents');
  }

  /// Settings → Account → How your data is protected: Read… opens it, Done closes it.
  Future<void> _dataProtection() async {
    await _tab('Account');
    await app.press('settings-data-protection');
    await app.see('data-protection');
    await app.press('data-protection-done');
    await app.gone('data-protection');
  }

  /// Settings → Account → Launch at login, switched over and back: the run's host keeps it (the Mac's login
  /// items stay as they are).
  Future<void> _launchAtLogin() async {
    await _tab('Account');
    await until('launch at login read', () async => (await _state())['launchAtLogin'] != null);
    final was = (await _state())['launchAtLogin'] as bool;
    for (final on in [!was, was]) {
      await app.press('settings-launch-at-login');
      await until('launch at login ${on ? 'on' : 'off'}', () async {
        final s = await _state();
        return s['launchAtLogin'] == on && s['hostLaunchAtLogin'] == on;
      });
      await until(
        'the switch ${on ? 'on' : 'off'}',
        () async => await app.value('settings-launch-at-login') == (on ? '1' : '0'),
      );
    }
  }

  Future<void> _chooseTerminal() async {
    await _tab('Terminals');
    // The picker lists only the terminals found here.
    await app.see('settings-terminal-$t');
    final apps = [for (final a in (await app.call('apps')) as List) a as Map<String, dynamic>];
    final label = apps.firstWhere((h) => h['id'] == t)['label'] as String;
    await app.pick('settings-terminal-app', label);
    await until('terminal app is $t', () async => (await _state())['terminalApp'] == t);
  }

  Future<void> _pairingLinks() async {
    await _tab('Phone');
    final before = ((await _state())['pairingLinks'] as List).length;
    for (var i = 0; i < 2; i++) {
      await app.press('settings-add-phone');
      await until('pairing link ${i + 1}', () async => ((await _state())['pairingLinks'] as List).length > before + i);
      await app.seeText('Set up your phone');
      await report.shot('add-a-phone-${i + 1}');
      await app.pressSheet('Done');
      await app.gone('pairing-qr');
    }
  }

  Future<void> _handOff() async {
    final s = await _state();
    final all = (s['pairingLinks'] as List).cast<String>();
    final links = all.sublist(all.length - 2);
    final desktopId = s['desktopId'] as String;
    File(p.join(c.artifacts, 'phone-link.txt')).writeAsStringSync('${links[0]}\n');
    File(p.join(c.artifacts, 'phone-link-2.txt')).writeAsStringSync('${links[1]}\n');
    File(p.join(c.artifacts, 'desktop-id.txt')).writeAsStringSync('$desktopId\n');
    // Phones signed in before this run's (another run's on a shared server) aren't revoked.
    _phonesBefore = {
      for (final d in await _devices())
        if (d['role'] == 'phone') d['id'] as String,
    };
    // A second computer on the same server that no phone link names: the phone lists it locked. It leaves the
    // server at the end.
    final setup = c.builtIn ? (await app.call('computer-setup-link')) as String : c.setupLink;
    await app.call('spare', args: {'link': setup, 'label': 'Spare Mac $t', 'id': 'spare${t.substring(0, 3)}'});
    _spare = true;
    final windows = await _windows();
    final shell = windows.firstWhere((w) => w['cwd'] == dir('shell'));
    final closeme = await until('the closeme window', () async {
      return (await _windows()).where((w) => w['cwd'] == dir('closeme')).firstOrNull;
    });
    final host = (await app.call('opens-in')) as Map<String, dynamic>;
    final sessions = await _sessions();
    File(p.join(c.artifacts, 'expect.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'runId': p.basename(p.dirname(c.artifacts)),
        'phase': 'main',
        'terminalId': t,
        'computer': s['device'],
        'terminal': host['describe'],
        // How the phone heads that app's windows: "kitty window 1", "Ghostty window 1" (tmux inside it).
        'terminalApp': host['label'],
        'sessions': [
          for (final w in ['chat', 'approve', 'endme'])
            {
              'title': name(w),
              'project': name(w),
              // What a followed session's link and a push name it by (routedKey).
              'key': '$desktopId/${sessions.firstWhere((s) => s['cwd'] == dir(w))['key']}',
            },
        ],
        'approval': {'session': name('approve'), 'answer': 'Approve'},
        'screen': {'window': shell['title']},
        'switchContinue': name('switchgo'),
        'switchRestart': name('switchstop'),
        'newSessionProject': name('newsess'),
        // The session the + flow starts; the steer, stop, ask and menu flows run on it.
        'askSession': name('newsess'),
        'closeWindow': closeme['title'],
        'newShellProject': name('newshell'),
        'newProjectName': name('made'),
        'endSession': name('endme'),
        'realOmp': {'title': name('realomp'), 'project': name('realomp')},
        // What orchestrator.yaml tells the orchestrator to send, and to which project.
        'orchestrator': {'project': name('newsess'), 'text': 'orchestrated from phone $t'},
        // Phase profiles (_profiles): omp in profile [_profile] (a session, a screen-only window to switch, a
        // project to start one in), and a profile with no sessions.
        'profiles': {
          'profile': _profile,
          'empty': _emptyProfile,
          'session': name('profchat'),
          'switch': name('profswitch'),
          'project': name('profnew'),
        },
        'lockedComputer': 'Spare Mac $t',
        'prompt': 'hello from phone $t',
      }),
    );
  }

  // ---------------------------------------------------------------- phone

  /// `--hold`: waits, as long as it takes, for `<artifacts>/hold` to go.
  Future<String> _held() async {
    final f = File(p.join(c.artifacts, 'hold'))..writeAsStringSync('${DateTime.now()}\n');
    report.log(
      'holding: the phone\u2019s main flows are yours to run, e.g.\n'
      '    apps/pocketterm-mobile/maestro/e2e/run.sh --run-dir ${c.artifacts} --phase main --from-tree [--only <flow>,…]\n'
      '  then rm ${f.path} to go on',
    );
    while (f.existsSync()) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return 'held';
  }

  bool _mainDone = false;

  /// Ghostty, phone main phase: the approval was still unanswered when the phone was told to answer it on the
  /// computer.
  bool? _leftToComputer;

  /// Ghostty: the phone can't answer an approval (no screen to read), so once it was told so, approval.yaml asks
  /// (rpc `approve-on-computer`) and the approval is answered here, as a person at the computer would, before the
  /// phone's next scenarios find omp still waiting.
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
      final s = (await _sessions()).firstWhere((s) => s['cwd'] == dir('approve'));
      await app.call(
        'press-keys',
        args: {
          'window': s['window'],
          'keys': ['enter'],
        },
      );
    } on Object catch (e) {
      answer = 'not answered: $e';
      report.log('approve on the computer: $e');
    }
    File(p.join(c.rpcDir, 'approve-on-computer.done')).writeAsStringSync(answer);
  }

  /// Scenario [name], checked here once the phone ran [flow]; without the phone, or limited to other flows
  /// (`--phone-only`), skipped: nothing did it.
  Future<void> _after(String flow, String name, Future<void> Function() body) async {
    if (!c.phone) {
      report.skip(name, 'no phone (--no-phone)');
    } else if (c.phoneRan(flow)) {
      await report.step(name, body, needed: true);
    } else {
      report.skip(name, 'phone flow $flow not run (--phone-only)');
    }
  }

  /// What every phone scenario should have done on the computer, from the fake omp's and the shells' own logs.
  Future<void> _verifyMain() async {
    List<Map<String, dynamic>> log(String w) => fakeOmpLog(dir(w));
    Iterable<Map<String, dynamic>> prompts(String w) =>
        log(w).where((e) => e['event'] == 'prompt' && e['source'] == 'phone');

    await _after('conversation-0', 'phone: prompt reaches the agent', () async {
      await until('prompt in chat', () => prompts('chat').any((e) => '${e['text']}'.startsWith('hello from phone')));
      final n = prompts('chat').where((e) => '${e['text']}'.startsWith('hello from phone')).length;
      expect(n == 1, 'heard once: $n');
    });
    await _after(
      'approval',
      t == 'ghostty'
          ? 'phone: approval left to the computer (Ghostty has no screen to read)'
          : 'phone: approval answered',
      () async {
        if (t == 'ghostty') expect(_leftToComputer == true, 'the phone was told, then the approval was answered here');
        final answered = await until(
          'approval answered',
          () => log('approve').where((e) => e['event'] == 'answered').firstOrNull,
        );
        expect(answered['approve'] == true, 'approved: $answered');
      },
    );
    await _after('screen', 'phone: keys reach the window', () async {
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
    await _after('image', 'phone: image arrives decrypted at the agent', () async {
      final e = await until(
        'image prompt',
        () => prompts('chat').where((e) => (e['images'] as List).isNotEmpty).firstOrNull,
      );
      final image = (e['images'] as List).first as Map<String, dynamic>;
      expect(image['decoded'] == true, 'PNG or JPEG bytes, not sealed ones: $image');
      expect((image['bytes'] as int) > 0, 'some bytes');
    });
    await _after('file', 'phone: a document arrives decrypted at the agent, named as @path', () async {
      final e = await until(
        'file prompt',
        () => prompts('chat').where((e) => (e['files'] as List? ?? const []).isNotEmpty).firstOrNull,
      );
      final file = (e['files'] as List).single as Map<String, dynamic>;
      expect(file['name'] == _docName, 'named ${file['name']}');
      expect(file['bytes'] == _doc.length, 'the bytes, not sealed ones: $file');
      expect(
        const ListEquality().equals(File(file['path'] as String).readAsBytesSync(), _doc),
        'the document as it was',
      );
      expect((e['text'] as String).contains('@"${file['path']}"'), 'a name with spaces is quoted: ${e['text']}');
    });
    await _after('new-session', 'phone: new session (+) opens in $t', () async {
      final s = await until('a session in ${name('newsess')}', () async {
        return (await _sessions()).where((s) => s['cwd'] == dir('newsess') && s['window'] != null).firstOrNull;
      }, timeout: const Duration(seconds: 40));
      final key = s['window'] as String;
      expect(key.startsWith(_opensWith), 'opened in $key, expected $_opensWith…');
      if (t == 'ghostty') {
        final w = (await _windows()).firstWhere((w) => w['key'] == key);
        expect(w['via'] == 'Ghostty', 'the tmux pane shows in a Ghostty window: ${w['via']}');
      }
    });
    // On the session the + flow started: what the phone's steer, stop, ask and menu flows did.
    bool says(Map<String, dynamic> e, String event, String text) =>
        e['event'] == event && '${e['text']}'.contains(text);
    Future<Map<String, dynamic>> heard(String what, bool Function(Map<String, dynamic> e) which) =>
        until(what, () => log('newsess').where(which).firstOrNull, timeout: const Duration(seconds: 60));
    await _after('steer-queue', 'phone: steer reaches the agent while it works', () async {
      final e = await heard('a steer', (e) => says(e, 'steer', 'steer from phone'));
      expect('${e['text']}'.startsWith('steer from phone'), '$e');
    });
    await _after('steer-queue', 'phone: a queued prompt runs after the turn', () async {
      await until('steered, then run on its own', () {
        final l = log('newsess');
        final steer = l.indexWhere((e) => says(e, 'steer', 'steer from phone'));
        return steer >= 0 && l.skip(steer + 1).any((e) => says(e, 'prompt', 'queue from phone'));
      }, timeout: const Duration(seconds: 60));
      expect(
        log('newsess').where((e) => says(e, 'queued', 'queue from phone')).isEmpty,
        'it waited on the computer, not in the agent',
      );
    });
    await _after('stop', 'phone: Stop interrupts the agent', () async {
      await until('stopped from the phone', () {
        final l = log('newsess');
        final slow = l.indexWhere((e) => says(e, 'prompt', 'e2e-slow stop run'));
        return slow >= 0 && l.skip(slow + 1).any((e) => e['event'] == 'abort' && e['why'] == 'phone');
      }, timeout: const Duration(seconds: 60));
    });
    await _after('stop', 'phone: Stop holds the queue; Resume sends what waits', () async {
      await until('stopped, then the held prompt', () {
        final l = log('newsess');
        final stop = l.indexWhere((e) => e['event'] == 'abort' && e['why'] == 'phone');
        return stop >= 0 && l.skip(stop + 1).any((e) => says(e, 'prompt', 'after stop'));
      }, timeout: const Duration(seconds: 60));
    });
    await _after('question', 'phone: the agent\u2019s question answered', () async {
      final e = await heard('the question answered', (e) => e['event'] == 'question-answered');
      expect(e['answer'] == 'Green' && e['custom'] == false, '$e');
    });
    await _after('plan', 'phone: the plan review answered', () async {
      final e = await heard('the plan picked', (e) => e['event'] == 'plan-picked');
      expect(e['option'] == 'Approve and execute', '$e');
    });
    await _after('menu-model', 'phone: /model picker answered', () async {
      final e = await heard('a model picked', (e) => e['event'] == 'model');
      expect(e['model'] == 'fake-model-fast', '$e');
    });
    await _after('menu-resume', 'phone: /resume picker searched and answered', () async {
      final e = await heard('a session resumed', (e) => e['event'] == 'resume');
      expect(e['session'] == 'e2e beta session', '$e');
    });
    await _after('screen-keys', 'phone: screen keys Tab, Enter, Ctrl+C reach the window', () async {
      await until('keys in the shell', () {
        final l = typedLog(c, name('shell'));
        return l.contains('key:tab') && l.contains('key:enter') && l.contains('key:ctrl+c');
      });
    });
    await _after('close-window', 'phone: close a shell window from the window list', () async {
      await until('closeme window gone', () async => !(await _windows()).any((w) => w['cwd'] == dir('closeme')));
      final windows = await _windows();
      for (final w in ['shell', 'chat', 'approve']) {
        expect(windows.any((x) => x['cwd'] == dir(w)), '${name(w)} still open: ${_ws(windows)}');
      }
    });
    await _after('new-shell', 'phone: new shell opens in $t without an agent', () async {
      final w = await until('a window in ${name('newshell')}', () async {
        return (await _windows()).where((w) => w['cwd'] == dir('newshell')).firstOrNull;
      }, timeout: const Duration(seconds: 40));
      expect('${w['key']}'.startsWith(_opensWith), 'opened in ${w['key']}, expected $_opensWith…');
      expect(w['agent'] == null, 'a plain shell: ${_ws([w])}');
      expect(
        (await _sessions()).where((s) => s['window'] == w['key'] || s['cwd'] == dir('newshell')).isEmpty,
        'no session there',
      );
    });
    await _after('new-tab', 'phone: a second shell in a project opens as a tab of its window', () async {
      final ws = await until('two windows in ${name('newshell')}', () async {
        final ws = (await _windows()).where((w) => w['cwd'] == dir('newshell')).toList();
        return ws.length >= 2 ? ws : null;
      }, timeout: const Duration(seconds: 40));
      expect(ws.map((w) => w['osWindow']).toSet().length == 1, 'one app window: ${_ws(ws)}');
      expect('${ws.first['osWindow']}'.isNotEmpty, _ws(ws));
      expect(ws.map((w) => w['tabId']).toSet().length == ws.length, 'a tab each: ${_ws(ws)}');
    });
    await _after('new-project', 'phone: new project made in the project folder', () async {
      final made = dir('made');
      expect(Directory(made).existsSync(), '$made made');
      await until('a session or window in ${name('made')}', () async {
        return (await _sessions()).any((s) => s['cwd'] == made) || (await _windows()).any((w) => w['cwd'] == made);
      }, timeout: const Duration(seconds: 40));
    });
    await _after('switch-continue', 'phone: switch to conversation, continue', () async {
      final starts = await until('switchgo restarted with -c', () {
        final s = log('switchgo').where((e) => e['event'] == 'start').toList();
        return s.length >= 2 ? s : null;
      }, timeout: const Duration(seconds: 40));
      expect(starts.first['extension'] == false, 'first without PocketTerm');
      expect(starts.last['resume'] == true && starts.last['extension'] == true, 'then -c with it: ${starts.last}');
      await until('continue prompt', () => prompts('switchgo').any((e) => e['text'] == 'continue'));
    });
    await _after('switch-restart', 'phone: switch to conversation, just restart', () async {
      final starts = await until('switchstop restarted with -c', () {
        final s = log('switchstop').where((e) => e['event'] == 'start').toList();
        return s.length >= 2 ? s : null;
      }, timeout: const Duration(seconds: 40));
      expect(starts.last['resume'] == true, 'resumed: ${starts.last}');
      expect(prompts('switchstop').isEmpty, 'just restart sends nothing');
      await until(
        'switchstop reports',
        () async => (await _sessions()).any((s) => s['cwd'] == dir('switchstop') && s['window'] != null),
      );
    });
    await _after('slash-new', 'phone: /new starts a fresh session in place', () async {
      await until('/new in chat', () => log('chat').any((e) => e['event'] == 'new'));
      final lastNew = log('chat').lastWhere((e) => e['event'] == 'new');
      // By its id: the image flow prompts it again after /new.
      final s = await until('chat session renewed', () async {
        final s = (await _sessions()).where((s) => s['cwd'] == dir('chat')).toList();
        return s.length == 1 && s.single['id'] == lastNew['session'] ? s.single : null;
      });
      expect(ours('${s['window'] ?? ''}'), 'still in its window: ${s['window']}');
    });
    await _after('end-session', 'phone: close window closes only that one', () async {
      await until('endme quit', () => log('endme').any((e) => e['event'] == 'quit'));
      await until('endme window gone', () async => !(await _windows()).any((w) => w['cwd'] == dir('endme')));
      final windows = await _windows();
      for (final w in ['shell', 'chat', 'approve']) {
        expect(windows.any((x) => x['cwd'] == dir(w)), '${name(w)} still open: ${_ws(windows)}');
      }
    });
    await _after('orchestrator', 'phone: the orchestrator starts in $t and steers a session', () async {
      final folder = p.join(p.dirname(c.cliJson), 'orchestrator');
      // The sessions are LiveSummary's JSON, as on the wire: the orchestrator is `orch`.
      final o = await until(
        'the orchestrator reports',
        () async => (await _sessions()).where((s) => s['orch'] == true && s['window'] != null).firstOrNull,
        timeout: const Duration(seconds: 40),
      );
      expect(ours(o['window'] as String), 'opened in ${o['window']}');
      final promptFile = File(p.join(folder, _orchestratorPromptFile));
      expect(promptFile.existsSync(), 'the orchestrator\u2019s prompt file in $folder');
      final instructions = promptFile.readAsStringSync();
      final start = fakeOmpLog(folder).firstWhere((e) => e['event'] == 'start');
      expect(start['orchestrator'] == true, 'the extension gives its tools to omp in that folder: $start');
      expect(
        const ListEquality().equals(start['args'] as List, ['--append-system-prompt', _orchestratorPromptFile]),
        'always omp, with its prompt: ${start['args']}',
      );
      expect(start['systemPrompt'] == instructions, 'omp read the file from its folder');
      final told = await until(
        'the prompt the orchestrator sent',
        () => log('newsess').where((e) => says(e, 'prompt', 'orchestrated from phone')).firstOrNull,
        timeout: const Duration(seconds: 60),
      );
      expect(told['text'] == 'orchestrated from phone $t', '$told');
      final results = fakeOmpLog(folder).where((e) => e['event'] == 'result').toList();
      expect(results.where((e) => e['error'] != null).isEmpty, '$results');
      final ops = results.map((e) => e['op']).toSet();
      expect(ops.containsAll(['sessions', 'prompt']), 'listed and prompted: $ops');
      final listed = '${results.firstWhere((e) => e['op'] == 'sessions')['text']}';
      expect(listed.contains(' | ${name('newsess')} | '), 'lists ${name('newsess')}: $listed');
      expect(!listed.contains('${o['key']}'), 'the orchestrator leaves itself out');
      // Out of the way of the phases after.
      await app.call('close', args: {'window': o['window']});
      await until('the orchestrator gone', () async => !(await _sessions()).any((s) => s['orch'] == true));
    });
  }

  /// The orchestrator's prompt, which the app writes into its folder (PocketTermDesktop's Orchestrator.swift).
  static const _orchestratorPromptFile = 'ORCHESTRATOR.md';

  // ---------------------------------------------------------------- profiles

  /// The omp profile the profiles scenarios run in, besides the default.
  static const _profile = 'personal';

  /// A profile with no sessions: the phone's filter finds nothing from it.
  static const _emptyProfile = 'work';

  /// Where omp in [profile] ('' the default) loads extensions from in the run's home.
  String _extensions(String profile) => p.joinAll([
    c.home,
    '.omp',
    if (profile.isNotEmpty) ...['profiles', profile],
    'agent',
    'extensions',
  ]);

  /// Settings → Coding agents, looked at afresh as when the window is shown again: the omp card lists
  /// [profiles] (sorted) and offers Install, which (confirmed) puts PocketTerm in the default profile and each of
  /// them, after which the card says it's up to date.
  Future<void> _installInProfiles(List<String> profiles) async {
    for (final n in profiles) {
      Directory(p.join(c.home, '.omp', 'profiles', n)).createSync(recursive: true);
    }
    await app.call('open-main');
    await _tab('Coding agents');
    await app.seeText('Profiles: default, ${profiles.join(', ')}', id: 'settings-omp-profiles');
    await app.pressIn('settings-agent-omp', 'Install');
    for (final n in ['', ...profiles]) {
      final shown = '~/${p.relative(_extensions(n), from: c.home)}';
      await app.seeText(shown, id: 'confirm-install');
    }
    await report.shot('install-omp-profiles');
    await app.press('confirm-install-go');
    for (final n in ['', ...profiles]) {
      final ext = File(p.join(_extensions(n), 'pocketterm-live.ts'));
      await until('PocketTerm in ${n.isEmpty ? 'the default profile' : n}', ext.existsSync);
    }
    // In everywhere: the card no longer offers it.
    await until(
      'omp up to date',
      () async => (((await _state())['agents'] as Map?)?['omp'] as Map?)?['integration'] == 'installed',
    );
    // In everywhere: the card says so (and to restart the sessions open before), and no longer offers it.
    await app.seeText('Installed', id: 'settings-agent-omp');
    expect(!(await app.texts('settings-agent-omp')).contains('Install'), 'Install no longer offered');
  }

  /// omp profiles: the desktop finds them and installs into each; omp in one reports its profile, which a window
  /// running it shows too; then the phone's flow (phase profiles) lists, filters, starts and switches sessions in
  /// it, and what it did is checked here.
  Future<void> _profiles() async {
    await report.step('profiles: Settings lists them, Install puts PocketTerm in each', () async {
      // Started before PocketTerm is in its profile: it shows only its screen until Switch restarts it.
      Directory(p.join(c.home, '.omp', 'profiles', _profile)).createSync(recursive: true);
      await _open('profswitch', autorun: 'omp --profile=$_profile --busy');
      final first = await until(
        'fake omp at work in ${name('profswitch')}',
        () => fakeOmpLog(dir('profswitch')).where((e) => e['event'] == 'start').firstOrNull,
      );
      expect(first['profile'] == _profile, 'in $_profile: $first');
      expect(first['extension'] == false, 'no PocketTerm in $_profile yet');
      await _installInProfiles([_profile, _emptyProfile]);
      await report.shot('settings-omp-profiles');
    });
    await report.step('profiles: omp in a profile reports it; its window says so', () async {
      // As a person types it: the flag's other form.
      await _open('profchat', autorun: 'omp --profile $_profile');
      final s = await until(
        '${name('profchat')} reports in a window',
        () async => (await _sessions()).where((s) => s['cwd'] == dir('profchat') && s['window'] != null).firstOrNull,
        timeout: const Duration(seconds: 40),
      );
      expect(s['profile'] == _profile, 'its profile: ${s['profile']}');
      expect(ours(s['window'] as String), 'placed in ${s['window']}');
      final windows = await _windows();
      final w = windows.firstWhere((w) => w['key'] == s['window']);
      expect(w['profile'] == _profile, 'from its command line: ${_ws([w])}');
      final screen = windows.where((w) => w['cwd'] == dir('profswitch')).single;
      expect(screen['agent'] == 'omp' && screen['profile'] == _profile, _ws([screen]));
      expect((await _sessions()).where((s) => s['cwd'] == dir('profswitch')).isEmpty, 'only its screen');
      final profiles = ((await _state())['ompProfiles'] as List).cast<String>();
      expect(const ListEquality().equals(profiles, [_profile, _emptyProfile]), 'profiles: $profiles');
    });
    // The phone's flow, and what it did, only when the computer was made ready for it.
    if (!c.desktopRuns('profiles:')) return;
    if (c.phone) {
      final code = await phonePhase('profiles');
      report.log('phone profiles → $code');
    }
    await _verifyProfiles();
  }

  /// What the profiles flow should have done on the computer, from the fake omp's and the shells' own logs; and a
  /// profile's finished run named in its notification.
  Future<void> _verifyProfiles() async {
    List<Map<String, dynamic>> starts(String w) => fakeOmpLog(dir(w)).where((e) => e['event'] == 'start').toList();
    Future<Map<String, dynamic>> reports(String w) => until(
      '${name(w)} reports in a window',
      () async => (await _sessions()).where((s) => s['cwd'] == dir(w) && s['window'] != null).firstOrNull,
      timeout: const Duration(seconds: 40),
    );

    await _after('profiles', 'phone: New session in a profile types omp --profile=$_profile', () async {
      final s = await until('omp started in ${name('profnew')}', () => starts('profnew').firstOrNull);
      expect(s['profile'] == _profile, '$s');
      expect(const ListEquality().equals(s['args'] as List, ['--profile=$_profile']), 'args ${s['args']}');
      expect(s['extension'] == true, 'with PocketTerm');
      expect(typedLog(c, name('profnew')).contains('cmd:omp --profile=$_profile'), 'typed omp --profile=$_profile');
      expect((await reports('profnew'))['profile'] == _profile, 'reports its profile');
    });
    await _after('profiles', 'phone: a project\u2019s New omp \u00b7 $_profile session here starts in it', () async {
      final s = await until('a second omp in ${name('profnew')}', () {
        final s = starts('profnew');
        return s.length >= 2 ? s : null;
      }, timeout: const Duration(seconds: 40));
      expect({for (final e in s) e['pid']}.length == s.length, 'each its own omp');
      expect({for (final e in s) e['profile']}.toList().join() == _profile, 'all in $_profile');
      await until(
        'both report in $_profile',
        () async =>
            (await _sessions())
                .where((x) => x['cwd'] == dir('profnew') && x['window'] != null && x['profile'] == _profile)
                .length >=
            2,
        timeout: const Duration(seconds: 40),
      );
    });
    await _after('profiles', 'phone: Switch to conversation resumes in the profile', () async {
      final s = await until('profswitch restarted with -c', () {
        final s = starts('profswitch');
        return s.length >= 2 ? s : null;
      }, timeout: const Duration(seconds: 40));
      expect(s.first['extension'] == false, 'first without PocketTerm');
      expect(
        const ListEquality().equals(s.last['args'] as List, ['--profile=$_profile', '-c']),
        'args ${s.last['args']}',
      );
      expect(s.last['resume'] == true && s.last['extension'] == true, '${s.last}');
      expect(typedLog(c, name('profswitch')).contains('cmd:omp --profile=$_profile -c'), 'typed omp --profile -c');
      await until(
        'continue prompt',
        () =>
            fakeOmpLog(dir('profswitch'))
                .any((e) => e['event'] == 'prompt' && e['source'] == 'phone' && e['text'] == 'continue'),
      );
      expect((await reports('profswitch'))['profile'] == _profile, 'reports its profile');
    });
    await report.step('profiles: a finished run is notified as omp \u00b7 $_profile finished', () async {
      final s = await reports('profchat');
      await until('profchat at rest', () async {
        final live = (await app.call('live', args: {'key': s['key']})) as Map<String, dynamic>?;
        return live != null && live['busy'] != true;
      });
      final before = ((await _state())['notices'] as List).length;
      await app.call('send', args: {'window': s['window'], 'text': 'e2e notify $t', 'enter': true});
      final want = 'omp \u00b7 $_profile finished \u00b7 ${name('profchat')}';
      // Another profile session's run (profswitch's continue) may finish meanwhile: wait for this one's.
      await until('its notification: $want', () async {
        final notices = ((await _state())['notices'] as List).skip(before);
        return notices.any((n) => (n as Map)['title'] == want);
      });
    });
  }

  /// Where a window the phone opens goes: the terminal's own windows, tmux for Ghostty (whose windows can't be
  /// read).
  String get _opensWith => switch (t) {
    'ghostty' => 'tmux:',
    'kitty' => 'kitty',
    'iterm' => 'iterm:',
    _ => 'wezterm:',
  };

  /// Settings → Phone → Terminal from phone off: the phone finds the computer not answering (phase computer-off)
  /// and asks for it back on (rpc terminal-on); Retry then brings its sessions back. It is on again after,
  /// whatever the phase did.
  Future<void> _computerOff() async {
    await _tab('Phone');
    await app.press('settings-terminal-from-phone');
    await until('Terminal from phone off', () async => (await _state())['terminalOn'] == false);
    Future<void> turnOn() async {
      if ((await _state())['terminalOn'] == true) return;
      await _tab('Phone');
      await app.press('settings-terminal-from-phone');
      await until('Terminal from phone on', () async => (await _state())['terminalOn'] == true);
    }

    if (!c.phone) {
      await turnOn();
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
      code = await phonePhase('computer-off');
    } finally {
      over = true;
      await serving;
      await turnOn();
    }
    expect(code == '0', 'phone phase computer-off: exit $code');
  }

  // ---------------------------------------------------------------- restarts

  /// Prompts from the phone, by text, each heard once.
  void _noReplays() {
    for (final w in ['chat', 'approve', 'switchgo', 'switchstop', 'newsess']) {
      final texts = [
        for (final e in fakeOmpLog(dir(w)))
          if (e['event'] == 'prompt' && e['source'] == 'phone') '${e['text']}|${(e['images'] as List).length}',
      ];
      expect(texts.toSet().length == texts.length, '${name(w)} heard a prompt twice: $texts');
      final answers = fakeOmpLog(dir(w)).where((e) => e['event'] == 'answered').length;
      expect(answers <= 1, '${name(w)} answered twice');
    }
  }

  /// The server stops and starts again; while it is down the phone's flow (phase server-down) finds it
  /// unreachable. It starts again whatever that phase found.
  Future<void> _serverRestart() async {
    Future<String?> down() async => c.phone ? await phonePhase('server-down') : null;
    String? downCode;
    if (c.builtIn) {
      // It runs in this app: stopped (Tailscale stops serving it) and started on the same port and data.
      final port = ((await _state())['hosting'] as Map)['port'] as int;
      await app.call('hosting-stop');
      try {
        downCode = await down();
      } finally {
        await Future<void>.delayed(const Duration(seconds: 3));
        await app.call('hosting-start', args: {'port': port});
      }
      expect(((await _state())['hosting'] as Map)['port'] == port, 'the same port again');
      await until(
        'Tailscale serves it again',
        () async => ((await _state())['hosting'] as Map?)?['publicUrl'],
        timeout: const Duration(seconds: 60),
      );
    } else {
      final stopped = await serverControl('server-stop');
      expect(stopped == 'ok', 'server stopped: $stopped');
      try {
        downCode = await down();
      } finally {
        await Future<void>.delayed(const Duration(seconds: 3));
        final started = await serverControl('server-start');
        expect(started == 'ok', 'server started: $started');
      }
    }
    await until('desktop back on the server', () async {
      try {
        return (await _devices()).isNotEmpty;
      } on Object {
        return false;
      }
    }, timeout: const Duration(seconds: 60));
    await _phoneAfter('server-restart');
    _noReplays();
    if (downCode != null) expect(downCode == '0', 'phone phase server-down: exit $downCode');
  }

  /// The app quits and starts again, as after a reboot: still signed in, its sessions back.
  Future<void> _desktopRestart() async {
    final sessions = (await _sessions()).where((s) => s['window'] != null).length;
    await app.quit();
    await app.launch();
    expect((await _state())['user'] != null, 'still signed in after the restart');
    await until(
      'sessions back',
      () async => (await _sessions()).where((s) => s['window'] != null).length >= sessions,
      timeout: const Duration(seconds: 40),
    );
    await app.call('open-main');
    await app.see('settings-content');
    await _phoneAfter('desktop-restart');
    _noReplays();
  }

  /// After a restart: the phone's flow reconnects and sends a prompt once; it reaches the agent once.
  Future<void> _phoneAfter(String phase) async {
    if (!c.phone) return;
    final code = await phonePhase(phase);
    expect(code == '0', 'phone phase $phase: exit $code');
  }

  static const _omp = '/opt/homebrew/bin/omp';

  /// The real omp, once, as the owner runs it but in the throwaway home: it finds the extension where this run's
  /// Get ready installed it (~/.omp/agent/extensions), no setup wizard, no model (nothing here calls one),
  /// sessions kept in the run's folder, no title generation. A `!` shell command typed at the computer gives it a
  /// transcript; the phone's `/new` then starts a fresh session in the same window.
  Future<void> _realOmp() async {
    final sessions = p.join(c.work, 'omp-sessions');
    await _open('realomp', autorun: 'OMP_SKIP_SETUP=1 $_omp --session-dir ${_sh(sessions)} --no-title --no-lsp');
    bool here(Object? cwd) => _isDir('$cwd', 'realomp');
    final Map<String, dynamic> s;
    try {
      s = await until(
        'real omp reports',
        () async => (await _sessions()).where((s) => here(s['cwd']) && s['window'] != null).firstOrNull,
        timeout: const Duration(seconds: 60),
      );
    } on TimeoutException {
      for (final x in await _sessions()) {
        report.log('real omp: live ${x['key']} ${x['agent']} window=${x['window']} cwd=${x['cwd']}');
      }
      for (final w in await _windows()) {
        if (!here(w['cwd'])) continue;
        report.log(
          'real omp: window ${w['key']} ${w['program']}\n${await app.call('plain-screen', args: {'window': w['key']})}',
        );
      }
      rethrow;
    }
    expect(ours(s['window'] as String), 'real omp placed in ${s['window']}');
    await Future<void>.delayed(const Duration(seconds: 2));
    await app.call('send', args: {'window': s['window'], 'text': '!echo e2e-real', 'enter': true});
    Future<Map<String, dynamic>?> live(String key) async =>
        (await app.call('live', args: {'key': key})) as Map<String, dynamic>?;
    final before = await until('the shell command in its transcript', () async {
      final now = await live(s['key'] as String);
      return now != null && jsonEncode(now['items']).contains('e2e-real') ? now['id'] as String : null;
    });
    // The phone lists it by its title, or "omp" while it has none (the real omp names a session later).
    final expectFile = File(p.join(c.artifacts, 'expect.json'));
    final expected = jsonDecode(expectFile.readAsStringSync()) as Map<String, dynamic>;
    final title = '${(await live(s['key'] as String))?['title'] ?? ''}';
    (expected['realOmp'] as Map<String, dynamic>)['title'] = title.isNotEmpty ? title : 'omp';
    expectFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(expected));
    final code = await phonePhase('real-omp');
    expect(code == '0', 'phone phase real-omp: exit $code');
    final Map<String, dynamic> after;
    try {
      after = await until('real omp on a new session', () async {
        final now = (await _sessions()).where((x) => here(x['cwd'])).toList();
        return now.length == 1 && now.single['id'] != before ? now.single : null;
      });
    } on TimeoutException {
      report.log('real omp: before /new $before');
      for (final x in (await _sessions()).where((x) => here(x['cwd']))) {
        report.log('real omp: live ${x['key']} id=${x['id']} window=${x['window']}');
      }
      rethrow;
    }
    expect(after['key'] == s['key'], 'the same window, the same session key');
    final items = (await live(after['key'] as String))?['items'];
    expect(!jsonEncode(items).contains('e2e-real'), 'the new session starts without the old transcript');
  }

  /// The real omp in a profile of its own (`omp --profile <name>`), in the throwaway home: Install put PocketTerm
  /// in the profile's folder, omp loads it from there, and the extension's hello names the profile.
  Future<void> _realOmpProfile() async {
    const profile = 'pt-e2e';
    await _installInProfiles(
      [
        ...{..._profilesMade, profile},
      ]..sort(),
    );
    final sessions = p.join(c.work, 'omp-sessions');
    await _open(
      'realprof',
      autorun: 'OMP_SKIP_SETUP=1 $_omp --profile $profile --session-dir ${_sh(sessions)} --no-title --no-lsp',
    );
    bool here(Object? cwd) => _isDir('$cwd', 'realprof');
    final Map<String, dynamic> s;
    try {
      s = await until(
        'real omp in $profile reports',
        () async => (await _sessions()).where((s) => here(s['cwd']) && s['window'] != null).firstOrNull,
        timeout: const Duration(seconds: 60),
      );
    } on TimeoutException {
      for (final w in await _windows()) {
        if (!here(w['cwd'])) continue;
        report.log(
          'real omp $profile: window ${w['key']} ${w['program']}\n${await app.call('plain-screen', args: {'window': w['key']})}',
        );
      }
      rethrow;
    }
    expect(s['profile'] == profile, 'its hello names the profile: ${s['profile']}');
    expect(ours(s['window'] as String), 'placed in ${s['window']}');
    final w = (await _windows()).firstWhere((w) => w['key'] == s['window']);
    expect(w['profile'] == profile, 'from its command line: ${_ws([w])}');
  }

  /// The profiles the run made in its home so far.
  List<String> get _profilesMade {
    final d = Directory(p.join(c.home, '.omp', 'profiles'));
    return d.existsSync() ? [for (final e in d.listSync().whereType<Directory>()) p.basename(e.path)] : const [];
  }

  /// [s] quoted for the throwaway shell.
  static String _sh(String s) => "'${s.replaceAll("'", r"'\''")}'";

  /// Whether [cwd], as an agent reports it, is project [what]'s folder. The real omp drops macOS's /private: the
  /// run's /private/tmp/… is /tmp/… to it.
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
      for (final d in await _devices())
        if (d['role'] == 'phone' && !_phonesBefore.contains(d['id'])) d,
    ];
    expect(phones.isNotEmpty || !c.phone, 'a phone signed in');
    for (final d in phones) {
      await app.call('revoke', args: {'id': d['id']});
    }
    final left = {for (final d in await _devices()) d['id']};
    expect(phones.where((d) => left.contains(d['id'])).isEmpty, 'the phones are gone from the server');
    if (c.phone) {
      final code = await phonePhase('revoke');
      expect(code == '0', 'phone phase revoke: exit $code');
    }
  }

  /// Settings → Terminals → Start new windows in tmux, in the throwaway Ghostty config; a Ghostty window opened
  /// after it runs in tmux.
  Future<void> _ghosttyTmux() async {
    await _tab('Terminals');
    await app.press('settings-ghostty-tmux');
    final config = File(p.join(c.home, '.config', 'ghostty', 'config'));
    await until('config has tmux', () => config.readAsStringSync().contains('new-session'));
    final probe = (await _windows()).firstWhere((w) => '${w['key']}'.startsWith('ghostty:'));
    final reload = await Process.run('/usr/bin/osascript', [
      '-e',
      'tell application "Ghostty" to perform action "reload_config" on (first terminal whose id is "${'${probe['key']}'.substring(8)}")',
    ]);
    report.log('reload_config: ${reload.exitCode} ${reload.stderr}');
    final d = makeProject(c, name('tmuxwin'), autorun: 'omp');
    await _ghosttyLaunch(d);
    final s = await until('a session from the tmux window', () async {
      return (await _sessions()).where((s) => s['cwd'] == d && s['window'] != null).firstOrNull;
    }, timeout: const Duration(seconds: 40));
    expect('${s['window']}'.startsWith('tmux:'), 'the new Ghostty window runs tmux: ${s['window']}');
    final w = (await _windows()).firstWhere((w) => w['key'] == s['window']);
    expect(w['via'] == 'Ghostty', 'shown in Ghostty: ${w['via']}');
  }

  /// Settings → Terminals → Remove: the throwaway Ghostty config no longer starts tmux.
  Future<void> _ghosttyTmuxRemove() async {
    await _tab('Terminals');
    await app.seeText('Remove', id: 'settings-ghostty-tmux');
    await app.press('settings-ghostty-tmux');
    final config = File(p.join(c.home, '.config', 'ghostty', 'config'));
    await until('config without tmux', () => !config.readAsStringSync().contains('new-session'));
  }

  /// Settings → Phone → Project folders: a folder's Remove takes it off; Add folder… (the run's host picks the
  /// run's projects folder) puts it back.
  Future<void> _projectFolders() async {
    await _tab('Phone');
    final chip = 'settings-folder-${c.projects}';
    await app.seeText('Remove', id: chip);
    await app.press(chip);
    await until('folder removed', () async => !((await _state())['projectRoots'] as List).contains(c.projects));
    await app.gone(chip);
    await app.press('settings-add-folder');
    await until('folder added', () async => ((await _state())['projectRoots'] as List).contains(c.projects));
    await app.see(chip);
  }

  /// Settings → Account → Add a computer…: the link shown is the built-in server's setup link, one another
  /// computer can paste.
  Future<void> _addComputer() async {
    await _tab('Account');
    await app.press('settings-add-computer');
    await app.see('add-computer-link');
    final shown = (await app.texts('add-computer-link')).join().trim();
    final link = (await app.call('computer-setup-link')) as String?;
    expect(shown.contains('$link'), 'the setup link: shows $shown, is $link');
    expect(Uri.parse(link!).queryParameters['setup'] != null, 'with a setup token');
    await app.pressSheet('Done');
    await app.gone('add-computer-link');
  }

  /// Settings → Phone → Reset key…, confirmed: a new channel key, said so.
  Future<void> _resetKey() async {
    final before = (await _state())['channelKey'];
    await _tab('Phone');
    await app.press('settings-reset-key');
    await app.seeText('Reset this computer’s key?');
    await app.pressSheet('Reset key');
    await app.seeText('New key made');
    expect((await _state())['channelKey'] != before, 'a new channel key');
  }

  /// Settings → Account → Erase…, confirmed: every computer and phone is signed out of the server (the spare
  /// computer's sign-in stops working) and this computer signs in again at once, the only one on it.
  Future<void> _erase() async {
    final before = ((await _state())['user'] as Map)['device'];
    await _tab('Account');
    await app.press('settings-erase');
    await app.seeText('Erase this server\u2019s data?');
    await app.pressSheet('Erase');
    final after = await until('signed in again', () async {
      final u = (await _state())['user'] as Map?;
      return u != null && u['device'] != before ? u : null;
    }, timeout: const Duration(seconds: 60));
    final left = [for (final d in await _devices()) d['id']];
    expect(left.length == 1 && left.single == after['device'], 'only this computer, signed in again: $left');
    try {
      await app.call('spare-devices');
      throw Failed('the spare computer is still signed in');
    } on AppError {
      // Signed out.
    }
    _spare = false;
  }

  /// Settings → Account → Sign out, last: a computer running the server asks first (signing out stops it); one
  /// joined to another computer's goes to sign-in, whose other-server choice returns to the setup.
  Future<void> _signOut() async {
    await _tab('Account');
    final hosts = (await _state())['hosting'] != null;
    await app.press('settings-sign-out');
    if (hosts) {
      await app.seeText('Stop your server and sign out?');
      await app.pressSheet('Sign out');
    }
    await until('signed out', () async => (await _state())['user'] == null);
    if ((await _state())['backend'] != null) await app.press('sign-in-other-server');
    await until('no server', () async => (await _state())['backend'] == null);
    // The first-run window, on whichever of its screens the setup was left.
    await app.see('pocketterm-setup-window');
    await report.shot('signed-out');
  }
}

/// Element-wise equality of two lists (package:collection's, without the dependency).
class ListEquality {
  const ListEquality();
  bool equals(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
