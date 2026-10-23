// The end-to-end run (tool/e2e/run.sh): for each terminal, a fresh local
// PocketTerm server, the real desktop app under integration_test with a
// throwaway home and terminals, and the phone's Maestro flows in the
// Simulator, phase by phase. Prints a pass/fail table; everything it saw is
// in build/e2e/<stamp>/.
//
//   dart run tool/e2e/bin/run.dart [--terminal kitty|ghostty|wezterm|all]
//       [--server local|builtin|supabase|<https url> (--setup-link <link> |
//        --setup-link-file <file>) [--server-stop-cmd <sh> --server-start-cmd <sh>]
//        [--server-ca <pem>]]
//       [--no-phone] [--platform ios|android [--avd <name>]]
//       [--phone-only <flow>,…] [--from-head] [--artifacts <dir>]
//
// --from-head runs what's committed: a detached worktree of HEAD in /tmp
// (others' uncommitted edits stay out), artifacts still in this checkout's
// build/e2e. --artifacts: where the stamped run folders go. --avd: the
// Android emulator the phone phases boot when none is running. --phone-only:
// just these phone flows (the phone run.sh's --only).
//
// --server builtin: the desktop's own "On this computer" server, published
// by `tailscale serve` (Tailscale must be running with HTTPS on and serve
// nothing yet; whatever serves after the run is removed). --server <url>:
// a server elsewhere; its setup link best from a file (it stays off the
// command line and out of the artifacts). --server-stop-cmd and
// --server-start-cmd (sh -c) stop and start it for the server restart,
// e.g. `ssh host docker stop <container>`. --server-ca: a root the desktop
// trusts for it (a test server with its own CA, e.g. Caddy's `tls internal`).
// --server supabase: PocketTerm on the local Supabase in Docker
// (tool/supabase-local.sh, started when it isn't, emptied for each terminal);
// the server restart stops and starts its function and Realtime.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocketterm_e2e/e2e.dart';

Future<void> main(List<String> args) async {
  final opts = _parse(args);
  final repo = p.normalize(p.join(p.dirname(Platform.script.toFilePath()), '..', '..', '..'));
  if (opts['from-head'] != null) exit(await _fromHead(repo, args));
  final stamp = _stamp();
  final root = p.join(opts['artifacts'] ?? p.join(repo, 'build', 'e2e'), stamp);
  Directory(root).createSync(recursive: true);
  final terminals = opts['terminal'] == 'all' ? terminalIds : [opts['terminal']!];
  stdout.writeln('PocketTerm e2e $stamp: ${terminals.join(', ')} → $root');
  if (opts['server'] == 'builtin') {
    if (await _tailscaleServes() case final serves?) {
      stderr.writeln('--server builtin needs `tailscale serve` to serve nothing yet; it serves:\n$serves');
      exit(1);
    }
  }

  final interrupted = Completer<void>();
  final sigint = ProcessSignal.sigint.watch().listen((_) {
    if (!interrupted.isCompleted) interrupted.complete();
  });

  final bin = p.join(root, 'bin');
  Directory(bin).createSync(recursive: true);
  await _must('compile fake omp', 'fvm', [
    'dart',
    'compile',
    'exe',
    'tool/e2e/bin/fake_omp.dart',
    '-o',
    p.join(bin, 'omp'),
  ], repo);
  final serverExe = p.join(bin, 'pocketterm-server');
  if (opts['server'] == 'local') {
    await _must('compile server', 'fvm', [
      'dart',
      'compile',
      'exe',
      'apps/pocketterm-server/bin/pocketterm_server.dart',
      '-o',
      serverExe,
    ], repo);
  }

  final table = <String, Map<String, String>>{};
  var allOk = true;
  for (final t in terminals) {
    if (interrupted.isCompleted) break;
    final r = await _runTerminal(
      t,
      repo: repo,
      root: root,
      stamp: stamp,
      bin: bin,
      serverExe: serverExe,
      opts: opts,
      interrupted: interrupted,
    );
    for (final MapEntry(:key, :value) in r.entries) {
      (table[key] ??= {})[t] = value;
      if (!value.startsWith('pass') && !value.startsWith('skip')) allOk = false;
    }
  }
  await sigint.cancel();

  final width = [10, ...table.keys.map((k) => k.length)].reduce((a, b) => a > b ? a : b);
  final out = StringBuffer()
    ..writeln()
    ..writeln('${'scenario'.padRight(width)}  ${terminals.map((t) => t.padRight(9)).join('  ')}')
    ..writeln('${'-' * width}  ${terminals.map((_) => '-' * 9).join('  ')}');
  for (final MapEntry(key: scenario, value: row) in table.entries) {
    out.writeln(
      '${scenario.padRight(width)}  ${terminals.map((t) => (row[t]?.split(':').first ?? '-').padRight(9)).join('  ')}',
    );
  }
  out.writeln();
  for (final MapEntry(key: scenario, value: row) in table.entries) {
    for (final MapEntry(key: t, value: v) in row.entries) {
      if (!v.startsWith('pass') && !v.startsWith('skip')) {
        out.writeln('FAIL $t/$scenario: ${v.split(':').skip(1).join(':').trim()}');
      }
    }
  }
  out.writeln(allOk ? 'ALL PASSED' : 'FAILED (artifacts: $root)');
  stdout.write(out);
  File(p.join(root, 'summary.txt')).writeAsStringSync('$out');
  File(p.join(root, 'summary.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(table));
  _junit(p.join(root, 'junit.xml'), table);
  exit(allOk ? 0 : 1);
}

Map<String, String> _parse(List<String> args) {
  final o = <String, String>{'terminal': 'all', 'server': 'local', 'platform': 'ios'};
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--terminal' || '--server' || '--setup-link' || '--platform' || '--artifacts' || '--avd' || '--phone-only':
        o[args[i].substring(2)] = args[++i];
      case '--setup-link-file' || '--server-stop-cmd' || '--server-start-cmd' || '--server-ca':
        o[args[i].substring(2)] = args[++i];
        if (args[i - 1] == '--setup-link-file') o['setup-link'] = File(args[i]).readAsStringSync().trim();
      case '--no-phone':
        o['phone'] = 'no';
      case '--from-head':
        o['from-head'] = 'yes';
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        exit(64);
    }
  }
  if (o['terminal'] != 'all' && !terminalIds.contains(o['terminal'])) {
    stderr.writeln('--terminal: one of ${terminalIds.join(', ')} or all');
    exit(64);
  }
  if (!{'local', 'builtin', 'supabase'}.contains(o['server']) && o['setup-link'] == null) {
    stderr.writeln('--server <url> needs --setup-link-file <file> (or --setup-link <link>)');
    exit(64);
  }
  if ((o['server-stop-cmd'] == null) != (o['server-start-cmd'] == null)) {
    stderr.writeln('--server-stop-cmd and --server-start-cmd go together');
    exit(64);
  }
  return o;
}

/// The same run from a detached worktree of HEAD (in /tmp, removed after),
/// so uncommitted edits in this checkout don't go into the build; its
/// artifacts land in this checkout's build/e2e.
Future<int> _fromHead(String repo, List<String> args) async {
  final head = '${(await Process.run('git', ['rev-parse', '--short', 'HEAD'], workingDirectory: repo)).stdout}'.trim();
  final src = '/private/tmp/pte2e-src-$head-${DateTime.now().millisecondsSinceEpoch}';
  await _must('git worktree add', 'git', ['worktree', 'add', '--detach', src, 'HEAD'], repo);
  // Firebase's config stays out of git: without it the Android phone builds
  // without push, so it has no Follow and its notifications flows can't run.
  const firebase = 'apps/pocketterm-mobile/android/app/google-services.json';
  if (File(p.join(repo, firebase)) case final f when f.existsSync()) f.copySync(p.join(src, firebase));
  stdout.writeln('Running HEAD $head from $src');
  try {
    await _must('pub get', 'fvm', ['flutter', 'pub', 'get'], src);
    final run = await Process.start(
      'fvm',
      [
        'dart',
        'run',
        'tool/e2e/bin/run.dart',
        ...args.where((a) => a != '--from-head'),
        if (!args.contains('--artifacts')) ...['--artifacts', p.join(repo, 'build', 'e2e')],
      ],
      workingDirectory: src,
      mode: ProcessStartMode.inheritStdio,
    );
    // Ctrl+C reaches the run too (same process group); this side waits for it.
    final sigint = ProcessSignal.sigint.watch().listen((_) {});
    final code = await run.exitCode;
    await sigint.cancel();
    return code;
  } finally {
    await Process.run('git', ['worktree', 'remove', '--force', src], workingDirectory: repo);
  }
}

String _stamp() {
  final n = DateTime.now();
  String two(int v) => '$v'.padLeft(2, '0');
  return '${n.year}${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}${two(n.second)}';
}

Future<void> _must(String what, String exe, List<String> args, String cwd) async {
  final r = await Process.run(exe, args, workingDirectory: cwd);
  if (r.exitCode != 0) {
    stderr.writeln('$what failed:\n${r.stdout}\n${r.stderr}');
    exit(1);
  }
}

/// [name] on this terminal's PATH, as an absolute path (the desktop's PATH
/// is launchd's, which hasn't it).
String _which(String name) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isNotEmpty && File(p.join(dir, name)).existsSync()) return p.join(dir, name);
  }
  stderr.writeln('$name is not on the PATH');
  exit(1);
}

/// A folder in [work] with just what `flutter test` runs by name that
/// launchd's PATH hasn't: CocoaPods' `pod`. Nothing else of Homebrew's, so
/// whatever PocketTerm finds there it finds as from Finder.
String _flutterTools(String work) {
  final dir = Directory(p.join(work, 'flutter-tools'))..createSync(recursive: true);
  Link(p.join(dir.path, 'pod')).createSync(_which('pod'));
  return dir.path;
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

const _tailscale = '/Applications/Tailscale.app/Contents/MacOS/Tailscale';

/// What `tailscale serve status` lists; null when it serves nothing.
Future<String?> _tailscaleServes() async {
  final r = await Process.run(_tailscale, ['serve', 'status']);
  final out = '${r.stdout}${r.stderr}'.trim();
  return out.contains('No serve config') ? null : out;
}

/// The local server for one terminal's run, restartable on the same port
/// and data.
class _Server {
  _Server(this.exe, this.data, this.port, this.logPath);
  final String exe;
  final String data;
  final int port;
  final String logPath;
  Process? _proc;
  String? setupLink;

  String get url => 'http://127.0.0.1:$port';

  Future<void> start() async {
    final log = File(logPath).openWrite(mode: FileMode.append)..writeln('--- start ${DateTime.now()}');
    final proc = await Process.start(exe, [
      'serve',
      '--data',
      data,
      '--public-url',
      url,
      '--port',
      '$port',
      '--address',
      '127.0.0.1',
      '--relay',
      'http://127.0.0.1:9',
    ], environment: cleanEnv());
    _proc = proc;
    final link = Completer<String?>();
    proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      log.writeln(l);
      if (l.startsWith('pocketterm://') || l.contains('/setup?') || l.contains('setup=')) {
        if (!link.isCompleted) link.complete(l.trim());
      }
    });
    proc.stderr.transform(utf8.decoder).listen(log.write);
    unawaited(proc.exitCode.then((c) => log.writeln('--- exit $c ${DateTime.now()}')));
    await until('server answering on $url', () async {
      try {
        final c = HttpClient();
        final r = await (await c.get('127.0.0.1', port, '/v1/health')).close();
        c.close(force: true);
        return r.statusCode < 500;
      } on Object {
        return false;
      }
    });
    setupLink ??= await link.future.timeout(const Duration(seconds: 2), onTimeout: () => null);
    if (setupLink == null) {
      final r = await Process.run(exe, ['setup-link', '--data', data, '--public-url', url]);
      setupLink = '${r.stdout}'.trim();
    }
  }

  Future<void> stop() async {
    final proc = _proc;
    _proc = null;
    if (proc == null) return;
    proc.kill();
    await proc.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }
}

/// PocketTerm on the local Supabase in Docker (tool/supabase-local.sh): started if it isn't, emptied for each
/// terminal's run ([prepare]), its function and Realtime stopped and started for the server restart.
class _Supabase {
  _Supabase(this.repo, this.logPath);
  final String repo;
  final String logPath;
  static const url = 'http://127.0.0.1:55421';
  static const _containers = ['supabase_edge_runtime_pocketterm-local', 'supabase_realtime_pocketterm-local'];

  String get _script => p.join(repo, 'tool', 'supabase-local.sh');
  Map<String, String> get _env => {
    'DOCKER_HOST': Platform.environment['DOCKER_HOST'] ?? 'unix://${Platform.environment['HOME']}/.colima/default/docker.sock',
  };

  Future<String> _run(String what, String exe, List<String> args) async {
    final r = await Process.run(exe, args, environment: _env);
    File(logPath).writeAsStringSync('--- $what ${DateTime.now()}\n${r.stdout}${r.stderr}', mode: FileMode.append);
    if (r.exitCode != 0) throw StateError('$what: exit ${r.exitCode} ${r.stderr}'.trim());
    return '${r.stdout}'.trim();
  }

  Future<bool> _answers() async {
    try {
      final c = HttpClient();
      final r = await (await c.getUrl(Uri.parse('$url/functions/v1/pocketterm/v1/health'))).close();
      c.close(force: true);
      return r.statusCode == 200;
    } on Object {
      return false;
    }
  }

  /// Empty, with a new setup token; the computer's setup link.
  Future<String> prepare() async {
    if (!await _answers()) await _run('supabase start', _script, ['start']);
    await _run('supabase reset', _script, ['reset']);
    await until('PocketTerm on Supabase answering', _answers);
    return await _run('setup link', _script, ['link']);
  }

  Future<void> stop() => _run('stop function and Realtime', 'docker', ['stop', ..._containers]);

  Future<void> start() async {
    await _run('start function and Realtime', 'docker', ['start', ..._containers]);
    await until('PocketTerm on Supabase answering', _answers);
  }
}

/// One terminal's run; scenario → `pass`, `fail: why` or `skip: why`.
Future<Map<String, String>> _runTerminal(
  String terminal, {
  required String repo,
  required String root,
  required String stamp,
  required String bin,
  required String serverExe,
  required Map<String, String> opts,
  required Completer<void> interrupted,
}) async {
  final artifacts = p.join(root, terminal);
  final work = '/private/tmp/pte2e-${stamp.substring(9)}-${terminal.substring(0, 1)}';
  Directory(artifacts).createSync(recursive: true);
  if (Directory(work).existsSync()) Directory(work).deleteSync(recursive: true);
  final results = <String, String>{};
  final phone = opts['phone'] != 'no';
  _Server? server;
  _Supabase? supabase;
  Process? desktop;
  stdout.writeln('\n== $terminal ==');
  try {
    String setupLink;
    String serverUrl;
    if (opts['server'] == 'local') {
      server = _Server(serverExe, p.join(artifacts, 'server-data'), await _freePort(), p.join(artifacts, 'server.log'));
      await server.start();
      setupLink = server.setupLink!;
      serverUrl = server.url;
    } else if (opts['server'] == 'builtin') {
      // The desktop starts it ("On this computer") and makes its links.
      setupLink = '';
      serverUrl = 'builtin';
    } else if (opts['server'] == 'supabase') {
      supabase = _Supabase(repo, p.join(artifacts, 'supabase.log'));
      setupLink = await supabase.prepare();
      serverUrl = _Supabase.url;
    } else {
      setupLink = opts['setup-link']!;
      serverUrl = opts['server']!;
    }
    final c = E2eConfig(
      terminal: terminal,
      artifacts: artifacts,
      work: work,
      serverUrl: serverUrl,
      setupLink: setupLink,
      phone: phone,
      terminalPath: Platform.environment['PATH'] ?? launchdPath,
      serverCa: opts['server-ca'],
    );
    writeHome(c);
    File(p.join(bin, 'omp')).copySync(p.join(c.bin, 'omp'));
    Process.runSync('/bin/chmod', ['755', p.join(c.bin, 'omp')]);
    final configPath = p.join(artifacts, 'config.json');
    File(configPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(c.toJson()));
    stdout.writeln('server $serverUrl, work $work');

    final desktopLog = File(p.join(artifacts, 'desktop.log')).openWrite();
    // As Launch Services starts the app from Finder (no TERM, no locale,
    // launchd's PATH), with only what `flutter test` needs besides.
    desktop = await Process.start(
      _which('fvm'),
      [
        'flutter',
        'test',
        'integration_test/e2e_test.dart',
        '-d',
        'macos',
        '--dart-define=E2E_CONFIG=$configPath',
        // A test build: it honours the POCKETTERM_* stand-ins (lib/test_hooks.dart), a released one doesn't.
        '--dart-define=POCKETTERM_SMOKE=true',
      ],
      workingDirectory: p.join(repo, 'apps', 'pocketterm-desktop'),
      environment: launchServicesEnv(
        tools: [_flutterTools(work)],
        extra: {'TMUX_TMPDIR': c.tmuxTmp, 'POCKETTERM_CLI_JSON': c.cliJson},
      ),
      includeParentEnvironment: false,
    );
    desktop.stdout.transform(utf8.decoder).listen((s) {
      desktopLog.write(s);
      for (final l in const LineSplitter().convert(s)) {
        if (l.contains('E2E ')) stdout.writeln('  $l'.replaceFirst(RegExp(r'^\s*(flutter: )?'), '  '));
      }
    });
    desktop.stderr.transform(utf8.decoder).listen(desktopLog.write);
    var ended = false;
    final exit = desktop.exitCode.then((code) {
      ended = true;
      return code;
    });

    final handled = <String>{};
    while (!ended) {
      final stop = await Future.any([
        exit.then((_) => true),
        interrupted.future.then((_) => true),
        Future<bool>.delayed(const Duration(milliseconds: 500), () => false),
      ]);
      if (stop) {
        break;
      }
      for (final f in Directory(c.rpcDir).listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (!name.endsWith('.req')) continue;
        final what = name.substring(0, name.length - 4);
        // The rest (approve-on-computer, terminal-on …) the desktop test answers itself.
        if (what != 'server-stop' && what != 'server-start') continue;
        if (!handled.add(name)) continue;
        var answer = 'ok';
        try {
          switch (what) {
            case 'server-stop' || 'server-start' when supabase != null:
              stdout.writeln('  server: ${what == 'server-stop' ? 'stopping' : 'starting'} Supabase function and Realtime');
              await (what == 'server-stop' ? supabase.stop() : supabase.start());
            case 'server-stop' || 'server-start' when server == null:
              final cmd = opts[what == 'server-stop' ? 'server-stop-cmd' : 'server-start-cmd'];
              if (cmd == null) {
                answer = 'no way to $what this server: --server-stop-cmd / --server-start-cmd';
                break;
              }
              stdout.writeln('  server: $what (command)');
              final r = await Process.run('/bin/sh', ['-c', cmd]);
              if (r.exitCode != 0) answer = 'failed: exit ${r.exitCode} ${r.stderr}'.trim();
            case 'server-stop':
              stdout.writeln('  server: stopping');
              await server?.stop();
            case 'server-start':
              stdout.writeln('  server: starting');
              await server?.start();
          }
        } on Object catch (e) {
          answer = 'failed: $e';
        }
        File(p.join(c.rpcDir, '$what.done')).writeAsStringSync(answer);
      }
      for (final f in Directory(c.phaseDir).listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (!name.endsWith('.ready') || !handled.add(name)) continue;
        final phase = name.substring(0, name.length - 6);
        final code = phone ? await _phonePhase(repo, artifacts, phase, opts) : 'skipped';
        results['phone: $phase'] = code == '0'
            ? 'pass'
            : (code == 'skipped' ? 'skip: --no-phone' : 'fail: phone flow exit $code (see phone/)');
        File(p.join(c.phaseDir, '$phase.done')).writeAsStringSync(code);
      }
    }
    if (interrupted.isCompleted && !ended) {
      desktop.kill();
      results['run'] = 'fail: interrupted';
    }
    final code = await exit.timeout(const Duration(seconds: 30), onTimeout: () => -1);
    await desktopLog.flush();
    await desktopLog.close();
    final resultsFile = File(c.results);
    if (resultsFile.existsSync()) {
      for (final l in resultsFile.readAsLinesSync().where((l) => l.trim().isNotEmpty)) {
        final j = jsonDecode(l) as Map<String, dynamic>;
        results[j['scenario'] as String] = j['ok'] == true
            ? 'pass'
            : (j['skip'] == true ? 'skip: ${j['detail']}' : 'fail: ${j['detail']}');
      }
    }
    results['desktop test'] = code == 0 ? 'pass' : 'fail: flutter test exit $code (see desktop.log)';
  } on Object catch (e, st) {
    results['run'] = 'fail: $e';
    File(p.join(artifacts, 'run-error.txt')).writeAsStringSync('$e\n$st');
  } finally {
    desktop?.kill();
    final stopped = await Owned.stopAll(p.join(artifacts, 'owned.jsonl'));
    if (stopped.isNotEmpty) stdout.writeln('  stopped: ${stopped.join(', ')}');
    await server?.stop();
    // A Supabase stopped for the restart and not started again (the run ended between).
    if (supabase != null) await supabase.start().then((_) {}, onError: (Object _) {});
    _keepLogs(work, artifacts);
    // Another server's setup link stays out of the artifacts.
    final config = File(p.join(artifacts, 'config.json'));
    if (opts['server'] != 'local' && config.existsSync()) {
      final j = jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
      config.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({...j, 'setupLink': '(removed)'}));
    }
    // The built-in server unpublishes itself when it stops; should the app
    // have died first, what it left in Tailscale goes (nothing served before).
    if (opts['server'] == 'builtin') {
      if (await _tailscaleServes() case final left?) {
        stdout.writeln('  tailscale serve left behind, removing:\n$left');
        await Process.run(_tailscale, ['serve', 'reset']);
      }
      stdout.writeln('  tailscale serve: ${await _tailscaleServes() ?? 'No serve config'}');
    }
  }
  return results;
}

Future<String> _phonePhase(String repo, String artifacts, String phase, Map<String, String> opts) async {
  final script = p.join(repo, 'apps', 'pocketterm-mobile', 'maestro', 'e2e', 'run.sh');
  if (!File(script).existsSync()) return 'missing';
  stdout.writeln('  phone: $phase');
  final log = File(p.join(artifacts, 'phone-$phase.log')).openWrite();
  final proc = await Process.start(
    script,
    [
      ...['--run-dir', artifacts, '--phase', phase, '--platform', opts['platform']!],
      if (opts['avd'] case final avd?) ...['--avd', avd],
      if (opts['phone-only'] case final only?) ...['--only', only],
    ],
    workingDirectory: repo,
    environment: cleanEnv(),
    includeParentEnvironment: false,
  );
  proc.stdout.listen(log.add);
  proc.stderr.listen(log.add);
  final code = await proc.exitCode;
  await log.close();
  stdout.writeln('  phone: $phase → ${code == 0 ? 'pass' : 'exit $code'}');
  return '$code';
}

/// The fake omp's logs, the shells' typed logs and the throwaway configs go
/// to the artifacts; the throwaway folder goes.
void _keepLogs(String work, String artifacts) {
  final w = Directory(work);
  if (!w.existsSync()) return;
  final keep = p.join(artifacts, 'work');
  for (final e in w.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = p.relative(e.path, from: work);
    final wanted =
        rel.contains('.fake_omp${p.separator}') ||
        rel.startsWith('typed') ||
        rel.startsWith('home${p.separator}.config') ||
        rel.endsWith('.zshrc');
    if (!wanted || rel.contains('${p.separator}images${p.separator}')) continue;
    final to = File(p.join(keep, rel))..parent.createSync(recursive: true);
    e.copySync(to.path);
  }
  w.deleteSync(recursive: true);
}

void _junit(String path, Map<String, Map<String, String>> table) {
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;');
  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="pocketterm-e2e">\n');
  final byTerminal = <String, Map<String, String>>{};
  for (final MapEntry(key: s, value: row) in table.entries) {
    for (final MapEntry(key: t, value: v) in row.entries) {
      (byTerminal[t] ??= {})[s] = v;
    }
  }
  for (final MapEntry(key: t, value: cases) in byTerminal.entries) {
    final failures = cases.values.where((v) => v.startsWith('fail')).length;
    b.writeln('  <testsuite name="$t" tests="${cases.length}" failures="$failures">');
    for (final MapEntry(key: s, value: v) in cases.entries) {
      b.write('    <testcase classname="$t" name="${esc(s)}"');
      if (v.startsWith('fail')) {
        b.writeln('><failure message="${esc(v)}"/></testcase>');
      } else if (v.startsWith('skip')) {
        b.writeln('><skipped message="${esc(v)}"/></testcase>');
      } else {
        b.writeln('/>');
      }
    }
    b.writeln('  </testsuite>');
  }
  b.writeln('</testsuites>');
  File(path).writeAsStringSync('$b');
}
