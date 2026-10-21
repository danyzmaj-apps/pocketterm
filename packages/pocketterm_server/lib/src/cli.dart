import 'dart:async';
import 'dart:io';

import 'package:pocketterm_server/src/server.dart';
import 'package:pocketterm_server/src/store.dart';

const _usage =
    '''
PocketTerm server $serverVersion

Usage:
  pocketterm-server serve [options]        Runs the server.
  pocketterm-server setup-link [options]   Prints the setup link for computers.

Options (each also read from the environment variable in brackets):
  --data <dir>           Where everything is kept [POCKETTERM_DATA] (default: ./data)
  --public-url <url>     The https address phones and computers reach the server at, put in setup links
                         [POCKETTERM_PUBLIC_URL] (required)
  --port <n>             serve: the port to listen on [POCKETTERM_PORT] (default: 47900)
  --address <ip>         serve: the address to listen on [POCKETTERM_ADDRESS] (default: 0.0.0.0)
  --relay <url>          serve: the push relay [PUSH_RELAY_URL] (default: the publisher's)
  --trust-proxy          serve: rate limit by the last X-Forwarded-For address; only behind a reverse proxy
                         [POCKETTERM_TRUST_PROXY=1]
  --new                  setup-link: replace the setup token first (the old link stops working; computers
                         already signed in stay signed in)
''';

/// Runs the `pocketterm-server` command with [args]; returns the exit code.
Future<int> runCli(List<String> args, {Map<String, String>? environment}) async {
  final env = environment ?? Platform.environment;
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
      if (publicUrl == null) {
        stderr.writeln('--public-url (or POCKETTERM_PUBLIC_URL) is required.\n\n$_usage');
        return 64;
      }
      final port = int.tryParse(option('port', 'POCKETTERM_PORT') ?? '47900');
      final address = InternetAddress.tryParse(option('address', 'POCKETTERM_ADDRESS') ?? '0.0.0.0');
      final relayText = option('relay', 'PUSH_RELAY_URL');
      final relay = relayText == null || relayText.isEmpty ? null : Uri.tryParse(relayText);
      if (port == null ||
          port < 0 ||
          port > 65535 ||
          address == null ||
          (relayText ?? '').isNotEmpty && relay == null) {
        stderr.writeln('--port, --address or --relay is not valid.\n\n$_usage');
        return 64;
      }
      final firstStart = !Store.hasSetupToken(data);
      final PocketTermServer server;
      try {
        server = await PocketTermServer.start(
          dataDir: data,
          address: address,
          port: port,
          publicUrl: publicUrl,
          relay: relay,
          trustProxy: flags.containsKey('trust-proxy') || env['POCKETTERM_TRUST_PROXY'] == '1',
          log: stderr.writeln,
        );
      } on Object catch (e) {
        stderr.writeln("The server didn't start: $e");
        return 1;
      }
      stdout.writeln('PocketTerm server $serverVersion on ${address.address}:${server.port}, data in ${data.path}');
      if (firstStart) {
        stdout.writeln(
          'Open this setup link on each of your computers (PocketTerm, Your own server); keep it private:\n'
          '${server.setupLink()}',
        );
      } else {
        stdout.writeln('Run `pocketterm-server setup-link` for the setup link.');
      }
      final stopping = Completer<void>();
      final signals = [
        ProcessSignal.sigint.watch(),
        if (!Platform.isWindows) ProcessSignal.sigterm.watch(),
      ].map((s) => s.listen((_) => stopping.isCompleted ? null : stopping.complete())).toList();
      await stopping.future;
      for (final s in signals) {
        await s.cancel();
      }
      await server.stop();
      return 0;
    case 'setup-link':
      if (publicUrl == null) {
        stderr.writeln('--public-url (or POCKETTERM_PUBLIC_URL) is required.\n\n$_usage');
        return 64;
      }
      final replace = flags.containsKey('new');
      stdout.writeln(PocketTermServer.setupLinkFor(data, publicUrl, replace: replace));
      if (replace) stderr.writeln('The previous setup link no longer works.');
      return 0;
    case 'help' || '--help' || '-h':
      stdout.write(_usage);
      return 0;
    default:
      stderr.write(_usage);
      return 64;
  }
}

const _switches = {'trust-proxy', 'new'};
const _valued = {'data', 'public-url', 'port', 'address', 'relay'};

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
