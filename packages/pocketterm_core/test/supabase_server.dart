import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/supabase_server.dart';

import 'own_server.dart';

/// PocketTerm on the local Supabase that `tool/supabase-local.sh start` runs in Docker (ports 55420-55429),
/// emptied before each test, with a push relay on port 55429 that records what reaches it ([relayed]). The
/// client tests run against it when POCKETTERM_SUPABASE is set (to anything); [skip] says why they don't.
class SupabaseServer implements TestBackend {
  SupabaseServer._(this._relay, this.setupToken);

  static const url = 'http://127.0.0.1:55421';
  static final _script = '${_repo()}/tool/supabase-local.sh';

  /// Null when the tests run against it, else why not.
  static String? get skip => Platform.environment.containsKey('POCKETTERM_SUPABASE')
      ? null
      : 'PocketTerm on Supabase: run tool/supabase-local.sh start, then the tests with POCKETTERM_SUPABASE=1';

  static String _repo() {
    var dir = Directory.current;
    while (!File('${dir.path}/tool/supabase-local.sh').existsSync()) {
      if (dir.parent.path == dir.path) throw StateError('tool/supabase-local.sh not found above ${Directory.current}');
      dir = dir.parent;
    }
    return dir.path;
  }

  /// Runs [sql] in the local project's database as its owner.
  static Future<String> sql(String sql) async {
    final r = await Process.run(_script, ['sql', sql]);
    if (r.exitCode != 0) throw StateError('supabase-local.sh sql: ${r.stderr}');
    return '${r.stdout}'.trim();
  }

  static Future<SupabaseServer> start() async {
    await sql(
      'truncate pocketterm.devices, pocketterm.desktops, pocketterm.pairing_codes, pocketterm.push_tokens, '
      'pocketterm.activity_tokens, pocketterm.redeem_failures, pocketterm.blobs cascade',
    );
    final setup = base64Url.encode(List.generate(32, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    await sql("select pocketterm.set_setup_hash('${sha256.convert(utf8.encode(setup))}')");
    // Where the function in Docker reaches this machine (tool/supabase-local.sh: host.docker.internal:55429).
    final relay = await HttpServer.bind(InternetAddress.anyIPv4, 55429, shared: true);
    final server = SupabaseServer._(relay, setup);
    relay.listen((req) async {
      server.relayed.add(jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>);
      await req.response.close();
    });
    return server;
  }

  final HttpServer _relay;

  @override
  final String setupToken;

  @override
  final relayed = <Map<String, dynamic>>[];

  @override
  Backend get backend => const Backend(url: url, kind: BackendKind.supabase);

  @override
  SupabaseServerClient client([DeviceTokens? tokens]) =>
      SupabaseServerClient(backend, tokens: tokens ?? MemoryDeviceTokens());

  @override
  Future<SupabaseServerClient> desktop({String label = 'MacBook Pro'}) async {
    final c = client();
    await c.redeemSetup(setupToken, label: label, platform: 'macos');
    return c;
  }

  @override
  Future<SupabaseServerClient> phone(Server desktop, {String label = 'iPhone'}) async {
    final c = client();
    await c.redeemCode(await desktop.createPairingCode(), label: label, platform: 'ios');
    return c;
  }

  /// What [sealed] (one of [relayed]) says, opened with the test relay's key (seed 32 x 0x07, the public half
  /// tool/supabase-local.sh gives the function): as apps/pocketterm-relay/src/seal.ts opens it.
  static Future<Map<String, dynamic>> open(Map<String, dynamic> sealed) async {
    final relay = await X25519().newKeyPairFromSeed(List.filled(32, 7));
    final publicKey = (await relay.extractPublicKey()).bytes;
    final epk = base64.decode(sealed['epk'] as String);
    final c = base64.decode(sealed['c'] as String);
    final shared = await X25519().sharedSecretKey(
      keyPair: relay,
      remotePublicKey: SimplePublicKey(epk, type: KeyPairType.x25519),
    );
    final key = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(secretKey: shared, nonce: [...epk, ...publicKey], info: utf8.encode('pocketterm-relay/v1'));
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(
        c.sublist(0, c.length - 16),
        nonce: base64.decode(sealed['n'] as String),
        mac: Mac(c.sublist(c.length - 16)),
      ),
      secretKey: key,
    );
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  @override
  Future<void> stop() => _relay.close(force: true);
}
