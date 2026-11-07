import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pocketterm_server/src/relay.dart';
import 'package:pocketterm_server/src/server.dart';
import 'package:pocketterm_server/src/store.dart';

const _usage =
    '''
PocketTerm server $serverVersion

The server built into the PocketTerm desktop apps. The app runs it on this machine's loopback address and
publishes it to your tailnet with `tailscale serve`; it never listens on another address.

Usage:
  pocketterm-server serve [options]        Runs the server.
  pocketterm-server setup-link [options]   Prints the setup link for computers.
  pocketterm-server health [options]       Exits 0 when the server on this machine answers GET /v1/health.

Options (each also read from the environment variable in brackets):
  --data <dir>           Where everything is kept [POCKETTERM_DATA] (default: ./data)
  --public-url <url>     The address phones and computers reach the server at, put in setup links, like
                         https://mac.tail1234.ts.net [POCKETTERM_PUBLIC_URL] (required for setup-link; serve
                         defaults to http://<address>:<port>)
  --port <n>             serve, health: the port to listen on [POCKETTERM_PORT] (default: 47900; serve: 0 lets
                         the system pick a free one)
  --address <ip>         serve, health: the loopback address to listen on [POCKETTERM_ADDRESS] (default: 127.0.0.1)
  --relay <url>          serve: the push relay [PUSH_RELAY_URL] (default: the publisher's)
  --relay-key <base64>   serve: the relay's X25519 public key, every push is sealed to it [PUSH_RELAY_KEY]
                         (default: the publisher's relay's)
  --trust-loopback-proxy serve: rate limit by the last X-Forwarded-For address for connections from a loopback
                         address (a proxy on this machine, like `tailscale serve`)
                         [POCKETTERM_TRUST_LOOPBACK_PROXY=1]
  --exit-with-stdin      serve: stop when stdin closes, so the server never outlives the app that started it
  --new                  setup-link: replace the setup token first (the old link stops working; computers
                         already signed in stay signed in)

serve prints one line to stdout once it listens, {"event":"listening","address":"127.0.0.1","port":47900};
everything else goes to stderr. Exit codes: 0 stopped (SIGINT, SIGTERM or stdin closed), 1 didn't start,
$exitPortInUse the port is taken, 64 bad usage.
''';

/// `serve`'s exit code when its port is taken: try another.
const exitPortInUse = 98;

/// EADDRINUSE on Linux, macOS and Windows.
const _addressInUse = {98, 48, 10048};

/// Runs the `pocketterm-server` command with [args]; returns the exit code.
/// [input] stands in for stdin and [output] for stdout (tests).
Future<int> runCli(
  List<String> args, {
  Map<String, String>? environment,
  Stream<List<int>>? input,
  IOSink? output,
}) async {
  final env = environment ?? Platform.environment;
  final out = output ?? stdout;
  final command = args.isEmpty ? '' : args.first;
  final Map<String, String> flags;
  try {
    flags = _flags(args.skip(1).toList());
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n$_usage');
    return 64;
  }
  String? option(String flag, String variable) => flags[flag] ?? env[variable];

  final data = Directory(option('data', 'POCKETTERM_DATA') ?? 'data');
  final publicUrlText = option('public-url', 'POCKETTERM_PUBLIC_URL');
  Uri? publicUrl;
  if (publicUrlText != null) {
    publicUrl = Uri.tryParse(publicUrlText);
    if (publicUrl == null || !publicUrl.isScheme('https') && !publicUrl.isScheme('http') || publicUrl.host.isEmpty) {
      stderr.writeln('--public-url must be an http(s) address, like https://pocketterm.example.com');
      return 64;
    }
  }

  switch (command) {
    case 'serve':
      final port = int.tryParse(option('port', 'POCKETTERM_PORT') ?? '47900');
      final address = InternetAddress.tryParse(option('address', 'POCKETTERM_ADDRESS') ?? '127.0.0.1');
      final relayText = option('relay', 'PUSH_RELAY_URL');
      final relay = relayText == null || relayText.isEmpty ? null : Uri.tryParse(relayText);
      final relayKeyText = option('relay-key', 'PUSH_RELAY_KEY');
      final relayKey = relayKeyText == null || relayKeyText.isEmpty ? null : parseRelayKey(relayKeyText);
      if (port == null ||
          port < 0 ||
          port > 65535 ||
          address == null ||
          (relayText ?? '').isNotEmpty && relay == null ||
          (relayKeyText ?? '').isNotEmpty && relayKey == null) {
        stderr.writeln('--port, --address, --relay or --relay-key is not valid.\n\n$_usage');
        return 64;
      }
      // Only `tailscale serve` on this machine should reach the server; it is never published directly.
      if (!address.isLoopback) {
        stderr.writeln('--address must be a loopback address, like 127.0.0.1.\n\n$_usage');
        return 64;
      }
      final firstStart = !Store.hasSetupToken(data);
      final PocketTermServer server;
      try {
        server = await PocketTermServer.start(
          dataDir: data,
          address: address,
          port: port,
          // Without one: http://<address>:<bound port>, known once bound (publicUrlFor).
          publicUrl: publicUrl,
          publicUrlFor: publicUrl == null ? (p) => _loopbackUrl(address, p) : null,
          relay: relay,
          relayKey: relayKey,
          trustLoopbackProxy:
              flags.containsKey('trust-loopback-proxy') || env['POCKETTERM_TRUST_LOOPBACK_PROXY'] == '1',
          log: stderr.writeln,
        );
      } on SocketException catch (e) {
        if (_addressInUse.contains(e.osError?.errorCode)) {
          stderr.writeln('Port $port on ${address.address} is taken: $e');
          return exitPortInUse;
        }
        stderr.writeln("The server didn't start: $e");
        return 1;
      } on Object catch (e) {
        stderr.writeln("The server didn't start: $e");
        return 1;
      }
      out.writeln(jsonEncode({'event': 'listening', 'address': address.address, 'port': server.port}));
      await out.flush();
      stderr.writeln('PocketTerm server $serverVersion on ${address.address}:${server.port}, data in ${data.path}');
      if (firstStart) {
        stderr.writeln(
          "Open this setup link on each of your computers (PocketTerm, Join another computer's PocketTerm); "
          'keep it private:\n'
          '${server.setupLink()}',
        );
      } else {
        stderr.writeln('Run `pocketterm-server setup-link` for the setup link.');
      }
      final stopping = Completer<void>();
      void stop() => stopping.isCompleted ? null : stopping.complete();
      // Windows delivers Ctrl+C as sigint (and closing the console as sighup); Ctrl+Break can't be watched.
      final signals = [
        ProcessSignal.sigint.watch(),
        if (Platform.isWindows) ProcessSignal.sighup.watch() else ProcessSignal.sigterm.watch(),
      ].map((s) => s.listen((_) => stop())).toList();
      final watchInput = flags.containsKey('exit-with-stdin')
          ? (input ?? stdin).listen((_) {}, onDone: stop, onError: (Object _) => stop(), cancelOnError: true)
          : null;
      await stopping.future;
      for (final s in signals) {
        await s.cancel();
      }
      unawaited(watchInput?.cancel());
      await server.stop();
      return 0;
    case 'setup-link':
      if (publicUrl == null) {
        stderr.writeln('--public-url (or POCKETTERM_PUBLIC_URL) is required.\n\n$_usage');
        return 64;
      }
      final replace = flags.containsKey('new');
      out.writeln(PocketTermServer.setupLinkFor(data, publicUrl, replace: replace));
      if (replace) stderr.writeln('The previous setup link no longer works.');
      return 0;
    case 'health':
      final port = int.tryParse(option('port', 'POCKETTERM_PORT') ?? '47900');
      final address = InternetAddress.tryParse(option('address', 'POCKETTERM_ADDRESS') ?? '127.0.0.1');
      if (port == null || port < 1 || port > 65535 || address == null) {
        stderr.writeln('--port or --address is not valid.\n\n$_usage');
        return 64;
      }
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      try {
        final request = await client.get(address.address, port, '/v1/health');
        final response = await request.close().timeout(const Duration(seconds: 3));
        await response.drain<void>();
        if (response.statusCode == 200) return 0;
        stderr.writeln('GET /v1/health answered ${response.statusCode}');
        return 1;
      } on Object catch (e) {
        stderr.writeln('GET /v1/health failed: $e');
        return 1;
      } finally {
        client.close(force: true);
      }
    case 'help' || '--help' || '-h':
      stdout.write(_usage);
      return 0;
    default:
      stderr.write(_usage);
      return 64;
  }
}

const _switches = {'trust-loopback-proxy', 'exit-with-stdin', 'new'};
const _valued = {'data', 'public-url', 'port', 'address', 'relay', 'relay-key'};

/// `--name value`, `--name=value` and bare switches.
Map<String, String> _flags(List<String> args) {
  final flags = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (!arg.startsWith('--')) throw FormatException('Unexpected argument: $arg');
    final eq = arg.indexOf('=');
    final name = arg.substring(2, eq < 0 ? arg.length : eq);
    if (_switches.contains(name) && eq < 0) {
      flags[name] = '';
    } else if (_valued.contains(name)) {
      if (eq >= 0) {
        flags[name] = arg.substring(eq + 1);
      } else if (i + 1 < args.length) {
        flags[name] = args[++i];
      } else {
        throw FormatException('$arg needs a value.');
      }
    } else {
      throw FormatException('Unknown option: $arg');
    }
  }
  return flags;
}

Uri _loopbackUrl(InternetAddress address, int port) => Uri(scheme: 'http', host: address.address, port: port);
