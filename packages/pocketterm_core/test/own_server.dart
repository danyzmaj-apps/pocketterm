import 'dart:convert';
import 'dart:io';

import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_server/pocketterm_server.dart';

/// packages/pocketterm_server on loopback, in a temporary data directory,
/// with a push relay that records what reaches it ([relayed]).
class OwnServer {
  OwnServer._(this._dir, this._relay, this.server);

  static Future<OwnServer> start() async {
    final dir = await Directory.systemTemp.createTemp('pocketterm_core_server');
    final relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = await PocketTermServer.start(
      dataDir: dir,
      address: InternetAddress.loopbackIPv4,
      port: 0,
      publicUrl: Uri.parse('http://127.0.0.1'),
      relay: Uri.parse('http://127.0.0.1:${relay.port}/relay'),
    );
    final own = OwnServer._(dir, relay, server);
    relay.listen((req) async {
      own.relayed.add(jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>);
      await req.response.close();
    });
    return own;
  }

  final Directory _dir;
  final HttpServer _relay;
  final PocketTermServer server;

  /// What the server sent the push relay, in order.
  final relayed = <Map<String, dynamic>>[];

  Backend get backend => Backend(url: 'http://127.0.0.1:${server.port}');

  /// The server's setup token, from the link it prints.
  String get setupToken => server.setupLink().queryParameters['setup']!;

  /// The link a computer opens to sign in, pointing at this server's port.
  Uri get setupLink => backend.link.replace(queryParameters: {...backend.link.queryParameters, 'setup': setupToken});

  /// A client for this server signed in as nobody yet.
  PocketTermServerClient client([DeviceTokens? tokens]) =>
      PocketTermServerClient(backend, tokens: tokens ?? MemoryDeviceTokens());

  /// A computer signed in with the setup token.
  Future<PocketTermServerClient> desktop({String label = 'MacBook Pro'}) async {
    final c = client();
    await c.redeemSetup(setupToken, label: label, platform: 'macos');
    return c;
  }

  /// A phone signed in with a code from [desktop].
  Future<PocketTermServerClient> phone(PocketTermServerClient desktop, {String label = 'iPhone'}) async {
    final c = client();
    await c.redeemCode(await desktop.createPairingCode(), label: label, platform: 'ios');
    return c;
  }

  Future<void> stop() async {
    await server.stop();
    await _relay.close(force: true);
    await _dir.delete(recursive: true);
  }
}
