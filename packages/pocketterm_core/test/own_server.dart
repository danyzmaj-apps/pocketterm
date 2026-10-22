import 'dart:convert';
import 'dart:io';

import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_server/pocketterm_server.dart';

/// A server the client tests run against: the PocketTerm server ([OwnServer])
/// or PocketTerm on a local Supabase (test/supabase_server.dart).
abstract interface class TestBackend {
  Backend get backend;

  /// A computer's setup token for it.
  String get setupToken;

  /// What it sent the push relay, in order (sealed to the relay's key).
  List<Map<String, dynamic>> get relayed;

  /// A client for it signed in as nobody yet.
  Server client([DeviceTokens? tokens]);

  /// A computer signed in with the setup token.
  Future<Server> desktop({String label = 'MacBook Pro'});

  /// A phone signed in with a code from [desktop].
  Future<Server> phone(Server desktop, {String label = 'iPhone'});

  Future<void> stop();
}

/// packages/pocketterm_server on loopback, in a temporary data directory,
/// with a push relay that records what reaches it ([relayed]).
class OwnServer implements TestBackend {
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

  @override
  final relayed = <Map<String, dynamic>>[];

  @override
  Backend get backend => Backend(url: 'http://127.0.0.1:${server.port}');

  /// The server's setup token, from the link it prints.
  @override
  String get setupToken => server.setupLink().queryParameters['setup']!;

  /// The link a computer opens to sign in, pointing at this server's port.
  Uri get setupLink => backend.linkWithSetup(setupToken);

  @override
  PocketTermServerClient client([DeviceTokens? tokens]) =>
      PocketTermServerClient(backend, tokens: tokens ?? MemoryDeviceTokens());

  @override
  Future<PocketTermServerClient> desktop({String label = 'MacBook Pro'}) async {
    final c = client();
    await c.redeemSetup(setupToken, label: label, platform: 'macos');
    return c;
  }

  @override
  Future<PocketTermServerClient> phone(Server desktop, {String label = 'iPhone'}) async {
    final c = client();
    await c.redeemCode(await desktop.createPairingCode(), label: label, platform: 'ios');
    return c;
  }

  @override
  Future<void> stop() async {
    await server.stop();
    await _relay.close(force: true);
    await _dir.delete(recursive: true);
  }
}
