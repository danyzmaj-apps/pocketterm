// The end-to-end run (tool/e2e/run.sh): for each terminal, a fresh local
// PocketTerm server, the native Mac app (a test build, lib/mac_app.dart)
// with a throwaway home and terminals, driven by lib/desktop.dart, and the
// phone's Maestro flows on the iPhone Simulator or the Android emulator,
// phase by phase. Prints a pass/fail table; everything it saw is in
// build/e2e/<stamp>/.
//
//   dart run tool/e2e/bin/run.dart [--terminal kitty|ghostty|wezterm|iterm|all]
//       [--server local|builtin|supabase|supabase-cloud --supabase-token-file <file>|<https url> (--setup-link <link> |
//        --setup-link-file <file>) [--server-stop-cmd <sh> --server-start-cmd <sh>]]
//       [--no-phone] [--platform ios|android [--avd <name>]] [--device <udid or serial>]
//       [--phone-only <flow>,…] [--phone-from-tree] [--desktop-only <text>,…] [--hold] [--from-head]
//       [--artifacts <dir>]
//
// --hold: after the hand-off the phone's main flows are left to you (the
// run prints the maestro/e2e/run.sh line to run them, one by one if you
// like), and the run goes on once you delete <run>/<terminal>/hold: for
// working on a flow without setting the desktop up each time.
//
// --from-head runs what's committed: a detached worktree of HEAD in /tmp
// (others' uncommitted edits stay out), artifacts still in this checkout's
// build/e2e. --artifacts: where the stamped run folders go. --avd: the
// Android emulator the phone phases boot when none is running. --device: the
// Simulator or emulator the phone phases use (the phone run.sh's; by default
// the Simulator "PocketTerm E2E", which runs started side by side would
// share). --phone-only:
// just these phone flows (the phone run.sh's --only); the desktop skips its
// checks of the others. --phone-from-tree: the phone app built from this
// checkout as it is, uncommitted edits included (by default the phone builds
// HEAD; the desktop always runs this checkout). --desktop-only: just the
// desktop steps whose name contains one of these texts, besides what every
// run needs (setup, Get ready, the windows, pairing and the hand-off) and
// the checks of the phone flows that ran; the rest are skipped. --no-phone:
// the desktop steps alone, the checks of what the phone did skipped.
//
// --server builtin: the desktop's own "On this computer" server, published
// by `tailscale serve` (Tailscale must be running with HTTPS on and serve
// nothing yet; whatever serves after the run is removed). --server <url>:
// a server elsewhere; its setup link best from a file (it stays off the
// command line and out of the artifacts). --server-stop-cmd and
// --server-start-cmd (sh -c) stop and start it for the server restart,
// e.g. `ssh host docker stop <container>`. Its certificate must be one macOS
// trusts (a test CA goes in the login keychain, as for any app).
// --server supabase: PocketTerm on the local Supabase in Docker
// (tool/supabase-local.sh, started when it isn't, emptied for each terminal);
// the server restart stops and starts its function and Realtime.
// --server supabase-cloud: the desktop's setup makes a new project on
// supabase.com (Supabase → Set up a project) with the personal access
// token in --supabase-token-file, in the token's first organization, and
// this run deletes that project after each terminal's run, whatever
// happened. The free plan allows 2 active projects: one slot must be free.
// No server restart (a hosted project can't be taken off the network).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocketterm_e2e/desktop.dart';
import 'package:pocketterm_e2e/e2e.dart';
import 'package:pocketterm_e2e/mac_app.dart';

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
  stdout.writeln('building the Mac app (test build) → ${p.join(root, 'mac-build.log')}');
  final String appPath;
  final String axExe;
  try {
    appPath = await MacApp.build(repo, p.join(root, 'mac-build.log'));
    axExe = await MacApp.buildAx(repo, bin);
  } on Object catch (e) {
    stderr.writeln('$e');
    exit(1);
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
      appPath: appPath,
      axExe: axExe,
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
      case '--terminal' ||
          '--server' ||
          '--setup-link' ||
          '--platform' ||
          '--artifacts' ||
          '--avd' ||
          '--device' ||
          '--phone-only' ||
          '--desktop-only':
        o[args[i].substring(2)] = args[++i];
      case '--setup-link-file' || '--server-stop-cmd' || '--server-start-cmd' || '--supabase-token-file':
        o[args[i].substring(2)] = args[++i];
        if (args[i - 1] == '--setup-link-file') o['setup-link'] = File(args[i]).readAsStringSync().trim();
      case '--no-phone':
        o['phone'] = 'no';
      case '--from-head':
        o['from-head'] = 'yes';
      case '--phone-from-tree':
        o['phone-from-tree'] = 'yes';
      case '--hold':
        o['hold'] = 'yes';
      default:
        stderr.writeln('Unknown argument: ${args[i]}');
        exit(64);
    }
  }
  if (o['terminal'] != 'all' && !terminalIds.contains(o['terminal'])) {
    stderr.writeln('--terminal: one of ${terminalIds.join(', ')} or all');
    exit(64);
  }
  if (o['server'] == 'supabase-cloud' && !File(o['supabase-token-file'] ?? '').existsSync()) {
    stderr.writeln('--server supabase-cloud needs --supabase-token-file <file> (a Supabase personal access token)');
    exit(64);
  }
  if (!{'local', 'builtin', 'supabase', 'supabase-cloud'}.contains(o['server']) && o['setup-link'] == null) {
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
    await _must('pub get', 'fvm', ['dart', 'pub', 'get'], src);
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
    proc.stdout.transform(utf8.decoder).listen(log.write);
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
    'DOCKER_HOST':
        Platform.environment['DOCKER_HOST'] ?? 'unix://${Platform.environment['HOME']}/.colima/default/docker.sock',
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

/// The Supabase Management API with the run's access token: only what the
/// clean-up needs (the desktop's setup makes the project itself).
class _SupabaseCloud {
  _SupabaseCloud(this.tokenFile, this.logPath);
  final String tokenFile;
  final String logPath;

  void _log(String line) => File(logPath).writeAsStringSync('${DateTime.now()} $line\n', mode: FileMode.append);

  Future<(int, String)> _call(String method, String path) async {
    final c = HttpClient();
    try {
      final req = await c.openUrl(method, Uri.parse('https://api.supabase.com$path'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${File(tokenFile).readAsStringSync().trim()}');
      final res = await req.close();
      return (res.statusCode, await utf8.decodeStream(res));
    } finally {
      c.close(force: true);
    }
  }

  /// The refs of the account's projects now.
  Future<Set<String>> refs() async {
    final (status, body) = await _call('GET', '/v1/projects');
    _log('GET /v1/projects → $status');
    if (status != 200) throw StateError('listing Supabase projects: $status $body');
    return {for (final p in jsonDecode(body) as List) '${(p as Map)['id'] ?? p['ref']}'};
  }

  /// Deletes project [ref] and waits until Supabase no longer lists it.
  Future<void> delete(String ref) async {
    final (status, body) = await _call('DELETE', '/v1/projects/$ref');
    _log('DELETE /v1/projects/$ref → $status $body');
    if (status >= 300 && status != 404) throw StateError('deleting Supabase project $ref: $status $body');
    await until(
      'Supabase project $ref gone',
      () async {
        final (s, b) = await _call('GET', '/v1/projects/$ref');
        _log('GET /v1/projects/$ref → $s ${s == 200 ? (jsonDecode(b) as Map)['status'] : b}');
        return s == 404 || (s == 200 && (jsonDecode(b) as Map)['status'] == 'REMOVED');
      },
      timeout: const Duration(minutes: 5),
      every: const Duration(seconds: 10),
    );
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
  required String appPath,
  required String axExe,
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
  _SupabaseCloud? cloud;
  var cloudBefore = <String>{};
  DesktopRun? desktop;
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
    } else if (opts['server'] == 'supabase-cloud') {
      // The desktop's setup makes the project and signs in with the link it makes; what the account had before
      // stays as it is.
      cloud = _SupabaseCloud(opts['supabase-token-file']!, p.join(artifacts, 'supabase.log'));
      cloudBefore = await cloud.refs();
      setupLink = '';
      serverUrl = 'supabase-cloud';
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
      supabaseTokenFile: switch (opts['supabase-token-file']) {
        final f? => p.absolute(f),
        null => null,
      },
      phoneOnly: opts['phone-only']?.split(','),
      desktopOnly: opts['desktop-only']?.split(','),
    );
    writeHome(c);
    File(p.join(bin, 'omp')).copySync(p.join(c.bin, 'omp'));
    Process.runSync('/bin/chmod', ['755', p.join(c.bin, 'omp')]);
    File(p.join(artifacts, 'config.json')).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(c.toJson()));
    stdout.writeln('server $serverUrl, work $work');

    Future<String> serverControl(String what) async {
      try {
        if (supabase != null) {
          stdout.writeln('  server: ${what == 'server-stop' ? 'stopping' : 'starting'} Supabase function and Realtime');
          await (what == 'server-stop' ? supabase.stop() : supabase.start());
        } else if (server == null) {
          final cmd = opts[what == 'server-stop' ? 'server-stop-cmd' : 'server-start-cmd'];
          if (cmd == null) return 'no way to $what this server: --server-stop-cmd / --server-start-cmd';
          stdout.writeln('  server: $what (command)');
          final r = await Process.run('/bin/sh', ['-c', cmd]);
          if (r.exitCode != 0) return 'failed: exit ${r.exitCode} ${r.stderr}'.trim();
        } else if (what == 'server-stop') {
          stdout.writeln('  server: stopping');
          await server.stop();
        } else {
          stdout.writeln('  server: starting');
          await server.start();
        }
        return 'ok';
      } on Object catch (e) {
        return 'failed: $e';
      }
    }

    Future<String> phonePhase(String phase) async {
      if (!phone) return 'skipped';
      final code = await _phonePhase(repo, artifacts, phase, opts);
      results['phone: $phase'] = code == '0' ? 'pass' : 'fail: phone flow exit $code (see phone/)';
      return code;
    }

    final run = desktop = DesktopRun(
      c,
      app: MacApp(c, appPath: appPath, axExe: axExe),
      phonePhase: phonePhase,
      serverControl: serverControl,
      supabaseToken: c.supabaseTokenFile == null ? null : File(c.supabaseTokenFile!).readAsStringSync().trim(),
      hold: opts['hold'] != null,
    );
    Object? failure;
    await Future.any([
      run.all().then(
        (_) {},
        onError: (Object e, StackTrace st) {
          failure = e;
          File(p.join(artifacts, 'run-error.txt')).writeAsStringSync('$e\n$st');
        },
      ),
      interrupted.future,
    ]);
    if (interrupted.isCompleted) results['run'] = 'fail: interrupted';
    if (failure != null) results['run'] = 'fail: $failure';
    final resultsFile = File(c.results);
    if (resultsFile.existsSync()) {
      for (final l in resultsFile.readAsLinesSync().where((l) => l.trim().isNotEmpty)) {
        final j = jsonDecode(l) as Map<String, dynamic>;
        results[j['scenario'] as String] = j['ok'] == true
            ? 'pass'
            : (j['skip'] == true ? 'skip: ${j['detail']}' : 'fail: ${j['detail']}');
      }
    }
  } on Object catch (e, st) {
    results['run'] = 'fail: $e';
    File(p.join(artifacts, 'run-error.txt')).writeAsStringSync('$e\n$st');
  } finally {
    await desktop?.end();
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
    // The project the desktop's setup made goes, whatever happened: the one it signed in to, else any the
    // account didn't have before the run.
    if (cloud != null) {
      final made = File(p.join(artifacts, 'supabase-project.txt'));
      var refs = made.existsSync() ? {made.readAsStringSync().trim()}.where((r) => r.isNotEmpty).toSet() : <String>{};
      if (refs.isEmpty) {
        try {
          refs = (await cloud.refs()).difference(cloudBefore);
        } on Object catch (e) {
          stdout.writeln('  supabase: projects not listed: $e');
        }
      }
      if (refs.isEmpty) {
        results['supabase: test project deleted'] = 'skip: the setup made no project';
      } else {
        try {
          for (final ref in refs) {
            await cloud.delete(ref);
            stdout.writeln('  supabase: project $ref deleted');
          }
          results['supabase: test project deleted'] = 'pass';
        } on Object catch (e) {
          results['supabase: test project deleted'] = 'fail: $e';
          stdout.writeln('  supabase: project(s) $refs NOT deleted: $e');
        }
      }
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
      if (opts['device'] case final device?) ...['--device', device],
      if (opts['phone-only'] case final only?) ...['--only', only],
      if (opts['phone-from-tree'] != null) '--from-tree',
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
    // Regular files only: iTerm2 leaves a socket in the throwaway home's ~/.config.
    if (e is! File || e.statSync().type != FileSystemEntityType.file) continue;
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
