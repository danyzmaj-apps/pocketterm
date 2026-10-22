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
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/local_api.dart';
import 'package:pocketterm_desktop/main_window.dart';
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
    final run = _Run(tester, E2eConfig.read(_configPath));
    try {
      await run.all();
    } finally {
      await run.end();
    }
    expect(run.report.failures, isEmpty, reason: 'see ${run.c.results}');
  }, timeout: const Timeout(Duration(minutes: 150)));
}

/// A 1×1 PNG, the stand-in phone's image.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

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

    await report.step('terminals: throwaway windows open', _openEarlyWindows, critical: true);
    await report.step('setup: On this computer shows Tailscale as it is', _thisComputer);
    await report.step('setup: own server, paste link', _ownServer, critical: true);
    await _getReady();
    await report.step('windows: sessions in their own windows', _sessionsLocated, critical: true);
    await report.step('windows: plain shell is a screen', _shellIsScreen);
    await report.step('settings: new sessions open in $t', _chooseTerminal);
    await report.step('add a phone: two pairing links', _pairingLinks, critical: true);
    await report.step('hand-off files', _handOff, critical: true);

    if (c.phone) {
      final code = await handOff(c.phaseDir, 'main', out: 'ready', timeout: const Duration(minutes: 45));
      report.log('phone main → $code');
    } else {
      await report.step('stand-in phone: main scenarios', _standInMain);
    }
    await _verifyMain();

    await report.step('restart: server', _serverRestart);
    await report.step('restart: desktop app', _desktopRestart);
    if (File(_omp).existsSync()) {
      await report.step('real omp: /new from the phone starts a fresh session in place', _realOmp);
    } else {
      report.skip('real omp: /new from the phone starts a fresh session in place', 'omp is not installed');
    }
    await report.step('revoke: phone removed on the server', _revoke);
    if (t == 'ghostty') await report.step('ghostty: Start new windows in tmux', _ghosttyTmux);
  }

  Future<void> end() async {
    phone?.dispose();
    await report.shot('end');
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
                builder: (_, _) => MainWindow(app: a),
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

  Finder _key(String k) => find.byKey(ValueKey(k));

  /// [windows] as a failure reason can show them.
  static String _ws(Iterable<TermWindow> windows) =>
      windows.map((w) => '${w.key} "${w.title}" ${w.cwd} tty=${w.tty} program=${w.program}').join('; ');

  // ---------------------------------------------------------------- windows

  /// Before PocketTerm is set up: the terminal with a plain shell, and two
  /// omp at work (started before PocketTerm was in omp, so they don't
  /// report: the phone switches them to their conversation later).
  Future<void> _openEarlyWindows() async {
    await term.start(makeProject(c, name('shell')));
    await _open('switchgo', autorun: 'omp --busy');
    await _open('switchstop', autorun: 'omp --busy');
    makeProject(c, name('newsess'));
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
    await _tap(find.text('Back'));
    await _see(_key('setup-own-server'));
  }

  Future<void> _ownServer() async {
    await _tap(_key('setup-own-server'));
    await _tap(_key('setup-have-server'));
    await _see(_key('setup-link'));
    await tester.enterText(_key('setup-link'), c.setupLink);
    await _see(find.textContaining('answers'));
    await _tap(_key('setup-connect'));
    await until('signed in', () => app.user != null);
    await _see(find.text('Get this computer ready'));
    expect(app.terminalOn, isTrue, reason: 'the first sign-in turns Terminal from phone on');
    expect(await app.host.launchAtLogin(), isTrue, reason: 'the first sign-in asks for launch at login');
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
      await _see(find.descendant(of: _key('get-ready-phone'), matching: find.byType(QrImageView)));
      await until('a pairing link made', () => app.pairingLinks.isNotEmpty);
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
      final s = await until('${name(w)} reports in a window', () {
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
      expect(others.where((o) => o.cwd == dir(w)), isEmpty, reason: '${name(w)} also among Other windows: ${_ws(others)}');
    }
    expect(app.unreportedAgentWindows(windows).where((w) => !w.cwd.contains(name('switch'))), isEmpty);
  }

  Future<void> _shellIsScreen() async {
    final windows = await app.terminals.windows();
    final shell = windows.where((w) => w.cwd == dir('shell')).toList();
    expect(shell.length, 1, reason: 'the shell window: ${_ws(windows)}');
    expect(shell.single.agent, isNull);
    expect(app.live.sessions.any((s) => s.window == shell.single.key), isFalse);
  }

  Future<void> _chooseTerminal() async {
    await _tap(_key('settings-tab-terminals'));
    await _tap(_key('settings-terminal-app'));
    final label = app.terminals.apps.firstWhere((h) => h.id == t).label;
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
    // A second computer on the same server that no phone link names: the
    // phone lists it locked.
    final setup = Uri.parse(c.setupLink);
    final spare = PocketTermServerClient(Backend.fromLink(setup)!, tokens: MemoryDeviceTokens());
    await spare.redeemSetup(Backend.setupToken(setup)!, label: 'Spare Mac $t', platform: 'macos');
    await spare.putDesktop('spare${t.substring(0, 3)}', name: 'Spare Mac $t', platform: 'macos');
    spare.close();
    final windows = await app.terminals.windows();
    final shell = windows.firstWhere((w) => w.cwd == dir('shell'));
    final host = await app.terminals.opensIn(app.terminalApp);
    File(p.join(c.artifacts, 'expect.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'runId': p.basename(p.dirname(c.artifacts)),
        'phase': 'main',
        'terminalId': t,
        'computer': app.device,
        'terminal': app.terminals.describe(host),
        'sessions': [
          for (final w in ['chat', 'approve', 'endme']) {'title': name(w), 'project': name(w)},
        ],
        'approval': {'session': name('approve'), 'answer': 'Approve'},
        'screen': {'window': shell.title},
        'switchContinue': name('switchgo'),
        'switchRestart': name('switchstop'),
        'newSessionProject': name('newsess'),
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
      await r.send(shell.key, 'echo e2e-typed');
      await r.press(shell.key, 'esc');
      await r.press(shell.key, 'up');
      await r.press(shell.key, 'down');
    });
    await act('image', () async {
      await until('chat at rest', () => r.session(chat)?.busy == false);
      await r.prompt(chat, 'what is in this image $t', images: [_png]);
    });
    await act('new session', () async {
      final launched = await r.launch(dir('newsess'), startAgent: true);
      report.log('phone launched $launched');
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
      t == 'ghostty' ? 'phone: approval left to the computer (Ghostty has no screen to read)' : 'phone: approval answered',
      () async {
        if (t == 'ghostty') {
          expect(log('approve').where((e) => e['event'] == 'answered'), isEmpty);
          // Answered on the computer, so the run carries on.
          await app.terminals.pressKeys(app.live.sessions.firstWhere((s) => s.cwd == dir('approve')).window!, ['enter']);
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
        return l.contains('cmd:echo e2e-typed') &&
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
    await report.step('phone: new session (+) opens in $t', () async {
      final s = await until('a session in ${name('newsess')}', () {
        return app.live.sessions.where((s) => s.cwd == dir('newsess') && s.window != null).firstOrNull;
      }, timeout: const Duration(seconds: 40));
      final key = s.window!;
      final want = t == 'ghostty' ? 'tmux:' : (t == 'kitty' ? 'kitty' : 'wezterm:');
      expect(key.startsWith(want), isTrue, reason: 'opened in $key, expected $want…');
      if (t == 'ghostty') {
        final w = (await app.terminals.windows()).firstWhere((w) => w.key == key);
        expect(w.via, 'Ghostty', reason: 'the tmux pane shows in a Ghostty window');
      }
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
      final s = await until('chat session renewed', () {
        final s = app.live.sessions.where((s) => s.cwd == dir('chat')).toList();
        return s.length == 1 && s.single.log.items.isEmpty ? s.single : null;
      });
      expect(ours(s.window ?? ''), isTrue);
      final lastNew = log('chat').lastWhere((e) => e['event'] == 'new');
      expect(s.id, lastNew['session'], reason: 'the hub has the new session');
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

  Future<void> _serverRestart() async {
    expect(await handOff(c.rpcDir, 'server-stop', out: 'req', timeout: const Duration(seconds: 30)), 'ok');
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(await handOff(c.rpcDir, 'server-start', out: 'req', timeout: const Duration(seconds: 60)), 'ok');
    await until('desktop back on the server', () async {
      try {
        return (await app.serverDevices()).isNotEmpty;
      } on Object {
        return false;
      }
    }, timeout: const Duration(seconds: 60));
    await _phoneAfter('server-restart', 'after server restart $t');
    _noReplays();
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
    final phones = (await app.serverDevices()).where((d) => d.role == DeviceRole.phone).toList();
    expect(phones, isNotEmpty, reason: 'a phone signed in');
    for (final d in phones) {
      await app.server!.revokeDevice(d.id);
    }
    expect((await app.serverDevices()).where((d) => d.role == DeviceRole.phone), isEmpty);
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
}
