import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pocketterm_server/pocketterm_server.dart';
import 'package:test/test.dart';

/// `pocketterm-server serve` as the desktop apps run it: a child process they read the listening line from and
/// stop by closing its stdin.
void main() {
  late Directory data;
  final started = <Process>[];
  setUp(() => data = Directory.systemTemp.createTempSync('pocketterm-cli-'));
  tearDown(() async {
    for (final p in started) {
      p.kill();
      await p.exitCode;
    }
    started.clear();
    data.deleteSync(recursive: true);
  });

  Future<Process> cli(List<String> args) async {
    final p = await Process.start(Platform.resolvedExecutable, ['run', 'test/cli_main.dart', ...args]);
    started.add(p);
    return p;
  }

  Future<Process> serve([List<String> extra = const []]) =>
      cli(['serve', '--data', data.path, '--address', '127.0.0.1', '--exit-with-stdin', ...extra]);

  /// The process's stdout lines, decoded once (a process's stdout can be listened to only once).
  final lines = Expando<Stream<String>>();
  Stream<String> out(Process p) =>
      lines[p] ??= p.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();

  Future<Map<String, Object?>> listening(Process p) async =>
      jsonDecode(await out(p).first.timeout(const Duration(seconds: 60))) as Map<String, Object?>;

  test('--port 0 picks a free port, announced in one JSON line, and the server answers on it', () async {
    final p = await serve(['--port', '0']);
    final line = await listening(p);
    expect(line, {'event': 'listening', 'address': '127.0.0.1', 'port': isA<int>()});
    final port = line['port']! as int;
    expect(port, isNot(0));
    final client = HttpClient();
    final response = await (await client.get('127.0.0.1', port, '/v1/health')).close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    client.close();
  });

  test('a taken port exits with exitPortInUse', () async {
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final p = await serve(['--port', '${taken.port}']);
      expect(await p.exitCode.timeout(const Duration(seconds: 60)), exitPortInUse);
    } finally {
      await taken.close();
    }
  });

  test('closing stdin stops the server and frees the data folder', () async {
    final p = await serve(['--port', '0']);
    await listening(p);
    await p.stdin.close();
    expect(await p.exitCode.timeout(const Duration(seconds: 30)), 0);
    // The lock is released: another server starts on the same folder.
    final again = await serve(['--port', '0']);
    expect((await listening(again))['event'], 'listening');
  });

  test('the public url defaults to http://<address>:<port>, and setup-link works while it runs', () async {
    final p = await serve(['--port', '0', '--trust-loopback-proxy']);
    final port = (await listening(p))['port']! as int;
    final link = await cli(['setup-link', '--data', data.path, '--public-url', 'http://127.0.0.1:$port']);
    final printed = await link.stdout.transform(utf8.decoder).join();
    expect(await link.exitCode, 0);
    final uri = Uri.parse(printed.trim());
    expect(printed.trim().split('\n'), hasLength(1));
    expect(uri.queryParameters['url'], 'http://127.0.0.1:$port');
    // The setup link the server printed on its first start (stderr) carries the default url and the same token.
    final logged = await p.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.startsWith('pocketterm://'))
        .timeout(const Duration(seconds: 30));
    expect(Uri.parse(logged), uri);
  });

  test('serve refuses an address that is not loopback', () async {
    for (final address in ['0.0.0.0', '192.168.1.20', '::']) {
      final p = await cli(['serve', '--data', data.path, '--address', address, '--port', '0']);
      expect(await p.exitCode, 64, reason: address);
    }
  });

  test('setup-link needs --public-url', () async {
    final p = await cli(['setup-link', '--data', data.path]);
    expect(await p.exitCode, 64);
  });
}
