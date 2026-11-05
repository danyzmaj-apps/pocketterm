/// The native Mac app under test: built once per run as a test build of its own
/// (`com.danyzmaj.pocketterm.e2e`, Debug: the test hooks compiled in), started by
/// Launch Services as from Finder with the run's throwaway home, and reached
/// two ways, as the Flutter integration test reached its app in-process:
///
/// * its hooks (apps/pocketterm-desktop/macos/PocketTerm/App/E2E.swift):
///   requests in a folder of the run's, answered with what the controller,
///   the terminals and the server say (`MacApp.call`);
/// * macOS accessibility (tool/smoke/ax.swift, one `serve` process per app
///   run): what a person sees and clicks, by the identifiers the screens
///   carry (`MacApp.press`, `MacApp.texts`, …).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:pocketterm_e2e/e2e.dart';

class MacApp {
  MacApp(this.c, {required this.appPath, required this.axExe});

  static const bundleId = 'com.danyzmaj.pocketterm.e2e';

  /// The test build, made from [repo] as it is, into the Mac app's build/e2e; its path.
  static Future<String> build(String repo, String logPath) async {
    final mac = p.join(repo, 'apps', 'pocketterm-desktop', 'macos');
    final log = File(logPath).openWrite();
    Future<void> step(String exe, List<String> args) async {
      log.writeln('\$ $exe ${args.join(' ')}');
      final r = await Process.run(exe, args, workingDirectory: mac);
      log
        ..write(r.stdout)
        ..write(r.stderr);
      if (r.exitCode != 0) {
        await log.close();
        throw StateError('$exe failed (exit ${r.exitCode}): see $logPath');
      }
    }

    await step('/opt/homebrew/bin/xcodegen', ['generate', '--quiet']);
    await step('/usr/bin/xcodebuild', [
      '-quiet',
      ...['-project', 'PocketTerm.xcodeproj', '-scheme', 'PocketTerm', '-configuration', 'Debug'],
      ...['-derivedDataPath', 'build/e2e'],
      'ONLY_ACTIVE_ARCH=YES',
      // An app of its own beside the person's PocketTerm: its own preferences, Automation grants and
      // single-instance check.
      'POCKETTERM_BUNDLE_ID=$bundleId',
      'build',
    ]);
    await log.close();
    return p.join(mac, 'build', 'e2e', 'Build', 'Products', 'Debug', 'PocketTerm.app');
  }

  /// ax.swift, compiled into [dir].
  static Future<String> buildAx(String repo, String dir) async {
    final out = p.join(dir, 'ax');
    final r = await Process.run('/usr/bin/swiftc', ['-O', '-o', out, p.join(repo, 'tool', 'smoke', 'ax.swift')]);
    if (r.exitCode != 0) throw StateError('ax.swift: ${r.stderr}');
    return out;
  }

  final E2eConfig c;
  final String appPath;
  final String axExe;

  /// Where the app's hooks read requests and keep their secrets (in the throwaway work folder).
  String get ctl => p.join(c.work, 'ctl');

  int? pid;
  _Ax? _ax;
  var _req = 0;
  var _launches = 0;

  String get _exe => p.join(appPath, 'Contents', 'MacOS', 'PocketTerm');

  Future<int?> _pid() async {
    final r = await Process.run('/usr/bin/pgrep', ['-f', '^$_exe']);
    return '${r.stdout}'.split('\n').map((l) => int.tryParse(l.trim())).whereType<int>().firstOrNull;
  }

  /// Starts it as Finder does: Launch Services (`open -n`), launchd's PATH, no TERM, no locale; the run's
  /// throwaway home, tmux, kitty sockets and hooks on top. Waits for its hooks to answer.
  Future<void> launch({Map<String, String> extra = const {}}) async {
    if (await _pid() case final running?) throw StateError('a PocketTerm E2E app already runs (pid $running)');
    Directory(ctl).createSync(recursive: true);
    // A run cut short (killed, a timeout) left its preferences behind: the first start begins signed out.
    if (_launches == 0) {
      for (final d in [bundleId, '$bundleId.e2e']) {
        await Process.run('/usr/bin/defaults', ['delete', d]);
      }
    }
    _launches++;
    final env = {
      'HOME': c.home,
      'TMUX_TMPDIR': c.tmuxTmp,
      'POCKETTERM_KITTY_DIR': c.kittyDir,
      'POCKETTERM_PROFILE': 'e2e',
      'POCKETTERM_CLI_JSON': c.cliJson,
      'POCKETTERM_E2E_DIR': ctl,
      'POCKETTERM_E2E_FOLDER': c.projects,
      'POCKETTERM_E2E_DEVICE': 'PocketTerm E2E ${c.terminal}',
      'POCKETTERM_E2E_OMP': p.join(c.bin, 'omp'),
      ...extra,
    };
    final r = await Process.run(
      '/usr/bin/open',
      [
        '-n',
        '-a',
        appPath,
        ...['--stdout', p.join(c.artifacts, 'desktop-$_launches.log')],
        ...['--stderr', p.join(c.artifacts, 'desktop-$_launches.log')],
        for (final MapEntry(:key, :value) in env.entries) ...['--env', '$key=$value'],
      ],
      // `open` hands the app its own environment: Finder's, as launchServicesEnv has it.
      environment: launchServicesEnv(),
      includeParentEnvironment: false,
    );
    if (r.exitCode != 0) throw StateError('open: ${r.stderr}');
    pid = await until('the app started', _pid, timeout: const Duration(seconds: 20));
    await until('its hooks answer', () async {
      try {
        await call('state', timeout: const Duration(seconds: 2));
        return true;
      } on Object {
        return false;
      }
    }, timeout: const Duration(seconds: 60));
    _ax = await _Ax.start(axExe, pid!);
  }

  /// Asks it to quit as Quit would, and waits until it's gone (killed after 15 s).
  Future<void> quit() async {
    final was = pid ?? await _pid();
    _ax?.close();
    _ax = null;
    pid = null;
    if (was == null) return;
    await Process.run('/usr/bin/osascript', ['-e', 'tell application id "$bundleId" to quit']);
    for (var i = 0; i < 150 && _alive(was); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_alive(was)) Process.killPid(was, ProcessSignal.sigkill);
    for (var i = 0; i < 30 && _alive(was); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  static bool _alive(int pid) => Process.runSync('/bin/kill', ['-0', '$pid']).exitCode == 0;

  /// After the run: no preferences of the e2e app's left, and Launch Services forgets it.
  Future<void> forget() async {
    for (final d in [bundleId, '$bundleId.e2e']) {
      await Process.run('/usr/bin/defaults', ['delete', d]);
    }
    await Process.run(
      '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
      ['-u', appPath],
    );
  }

  // ---------------------------------------------------------------- hooks

  /// Request [cmd] with [args]; its answer, or throws what went wrong.
  Future<dynamic> call(String cmd, {Map<String, Object?> args = const {}, Duration? timeout}) async {
    final name = '${DateTime.now().microsecondsSinceEpoch}-${_req++}.json';
    final req = p.join(ctl, 'req');
    Directory(req).createSync(recursive: true);
    File(p.join(ctl, '.$name'))
      ..writeAsStringSync(jsonEncode({'cmd': cmd, ...args}))
      ..renameSync(p.join(req, name));
    final res = File(p.join(ctl, 'res', name));
    final answer = await until(
      'the app answers $cmd',
      () => res.existsSync() ? res.readAsStringSync() : null,
      timeout: timeout ?? const Duration(seconds: 60),
      every: const Duration(milliseconds: 100),
    );
    res.deleteSync();
    final j = jsonDecode(answer) as Map<String, dynamic>;
    if (j['error'] case final e?) throw AppError('$cmd: $e');
    return j['ok'];
  }

  Future<Map<String, dynamic>> state() async => (await call('state')) as Map<String, dynamic>;

  /// The sessions reporting, as LiveSummary's JSON.
  Future<List<Map<String, dynamic>>> sessions() async => [
    for (final s in (await state())['sessions'] as List) s as Map<String, dynamic>,
  ];

  Future<List<Map<String, dynamic>>> windows() async => [
    for (final w in (await call('windows')) as List) w as Map<String, dynamic>,
  ];

  // ---------------------------------------------------------------- accessibility

  Future<(int, String)> ax(List<String> cmd) {
    final a = _ax;
    if (a == null) throw StateError('the app is not running');
    return a.run(cmd);
  }

  Future<bool> has(String id) async => (await ax(['has-id', id])).$1 == 0;

  /// The labels of element [id] and all in it; empty when there's no such element.
  Future<List<String>> texts(String id) async {
    final (code, out) = await ax(['texts-id', id]);
    return code == 0 ? out.split('\n') : const [];
  }

  /// Whether element [id] or something in it says [text] (a line, or within one).
  Future<bool> says(String id, String text) async => (await texts(id)).any((l) => l.contains(text));

  /// Every label on screen.
  Future<List<String>> allTexts() async => (await ax(['texts'])).$2.split('\n');

  Future<bool> onScreen(String text) async => (await allTexts()).any((l) => l.contains(text));

  Future<void> see(String id, {Duration timeout = const Duration(seconds: 30)}) =>
      until('$id on screen', () => has(id), timeout: timeout, every: const Duration(milliseconds: 200));

  Future<void> gone(String id, {Duration timeout = const Duration(seconds: 30)}) =>
      until('$id gone', () async => !await has(id), timeout: timeout, every: const Duration(milliseconds: 200));

  /// Until element [id] (or the window, with no [id]) says [text].
  Future<void> seeText(String text, {String? id, Duration timeout = const Duration(seconds: 30)}) => until(
    '"$text"${id == null ? '' : ' in $id'}',
    () => id == null ? onScreen(text) : says(id, text),
    timeout: timeout,
    every: const Duration(milliseconds: 250),
  );

  Future<void> _must(List<String> cmd, {Duration timeout = const Duration(seconds: 20)}) async {
    await until(
      'ax ${cmd.join(' ')}',
      () async {
        final (code, _) = await ax(cmd);
        return code == 0;
      },
      timeout: timeout,
      every: const Duration(milliseconds: 250),
    );
  }

  /// Presses the element [id] once it's there.
  Future<void> press(String id, {Duration timeout = const Duration(seconds: 20)}) =>
      _must(['press-id', id], timeout: timeout);

  /// Presses what's labelled [label] (a button's title) once it's there.
  Future<void> pressLabel(String label, {Duration timeout = const Duration(seconds: 20)}) =>
      _must(['press', label], timeout: timeout);

  /// Presses what's labelled [label] inside element [id].
  Future<void> pressIn(String id, String label, {Duration timeout = const Duration(seconds: 20)}) =>
      _must(['press-in', id, label], timeout: timeout);

  /// Text field [id] (or the one in it) holds [text].
  Future<void> set(String id, String text) => _must(['set-id', id, text]);

  /// Picks [label] in pop-up button [id].
  Future<void> pick(String id, String label) => _must(['pick-id', id, label]);

  /// Presses [label] in the alert or sheet showing (its Sign out, not the window's own Sign out).
  Future<void> pressSheet(String label) => _must(['press-sheet', label]);

  /// Element [id]'s value: a switch's `0` or `1`, a field's text; null when there's none.
  Future<String?> value(String id) async {
    final (code, out) = await ax(['value-id', id]);
    return code == 0 ? out : null;
  }

  /// Whether element [id] can be used; null when there's none.
  Future<bool?> enabled(String id) async {
    final (code, _) = await ax(['enabled-id', id]);
    return code == 3 ? null : code == 0;
  }

  /// A PNG of its window (or its menu-bar panel) in the run's screenshots.
  Future<void> shot(String name, {bool panel = false}) async {
    try {
      final (code, out) = await ax([if (panel) 'panel-window' else 'window']);
      if (code != 0) return;
      final safe = name.replaceAll(RegExp(r'[^\w.-]+'), '_');
      Directory(c.screenshots).createSync(recursive: true);
      await Process.run('/usr/sbin/screencapture', ['-x', '-o', '-l', out.trim(), p.join(c.screenshots, '$safe.png')]);
    } on Object {
      // No window to photograph.
    }
  }
}

/// One `ax <pid> serve`: a command a line in, an answer a line out, in order.
class _Ax {
  _Ax(this._proc) {
    _proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      if (_waiting.isEmpty) return;
      final j = jsonDecode(l) as Map<String, dynamic>;
      _waiting.removeAt(0).complete((j['code'] as int, j['out'] as String));
    });
    unawaited(_proc.stderr.drain<void>());
    unawaited(
      _proc.exitCode.then((_) {
        for (final w in _waiting) {
          w.completeError(StateError('ax ended'));
        }
        _waiting.clear();
      }),
    );
  }

  static Future<_Ax> start(String exe, int pid) async => _Ax(await Process.start(exe, ['$pid', 'serve']));

  final Process _proc;
  final _waiting = <Completer<(int, String)>>[];
  Future<void> _last = Future.value();

  Future<(int, String)> run(List<String> cmd) {
    // One at a time: the answers come in order.
    final done = Completer<(int, String)>();
    _last = _last.then((_) async {
      _waiting.add(done);
      _proc.stdin.writeln(jsonEncode(cmd));
      try {
        await done.future.timeout(const Duration(seconds: 30));
      } on Object {
        // The caller hears it.
      }
    });
    return done.future.timeout(const Duration(seconds: 40), onTimeout: () => (1, 'ax did not answer ${cmd.join(' ')}'));
  }

  void close() => _proc.kill();
}

/// What the app's hooks said went wrong with a request.
class AppError implements Exception {
  AppError(this.message);
  final String message;
  @override
  String toString() => message;
}
