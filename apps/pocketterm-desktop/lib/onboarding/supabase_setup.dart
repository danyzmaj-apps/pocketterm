import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_desktop/onboarding/supabase_admin.dart';
import 'package:pointycastle/export.dart' as pc;

/// One migration: `supabase/migrations/<version>_<name>.sql`.
typedef Migration = ({String version, String name, String sql});

/// What PocketTerm puts on a Supabase project, shipped with the app (the
/// pubspec bundles supabase/ as assets), so a downloaded app sets a project
/// up without the repo or the Supabase CLI.
abstract interface class SupabaseSource {
  /// Oldest first.
  Future<List<Migration>> migrations();

  /// The Edge Function `pocketterm` (supabase/functions/pocketterm/index.ts).
  Future<String> function();
}

class AssetSupabaseSource implements SupabaseSource {
  const AssetSupabaseSource();

  @override
  Future<List<Migration>> migrations() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths =
        manifest.listAssets().where((p) => p.startsWith('supabase/migrations/') && p.endsWith('.sql')).toList()..sort();
    return [for (final p in paths) migrationFromFile(p, await rootBundle.loadString(p))];
  }

  @override
  Future<String> function() => rootBundle.loadString('supabase/functions/pocketterm/index.ts');
}

/// `…/20261023000000_pocketterm.sql` → version `20261023000000`, name `pocketterm`.
Migration migrationFromFile(String path, String sql) {
  final file = path.split('/').last.replaceFirst(RegExp(r'\.sql$'), '');
  final cut = file.indexOf('_');
  return (version: cut < 0 ? file : file.substring(0, cut), name: cut < 0 ? '' : file.substring(cut + 1), sql: sql);
}

/// A new P-256 key pair as a private JWK (ES256) with a random `kid`: what
/// the function signs live channel tokens with, imported as the project's
/// JWT signing key so Realtime takes those tokens.
Map<String, Object?> newLiveSigningKey({Random? random}) {
  final rng = random ?? Random.secure();
  final secure = pc.FortunaRandom()..seed(pc.KeyParameter(Uint8List.fromList(List.generate(32, (_) => rng.nextInt(256)))));
  final params = pc.ECKeyGeneratorParameters(pc.ECCurve_secp256r1());
  final pair = (pc.ECKeyGenerator()..init(pc.ParametersWithRandom(params, secure))).generateKeyPair();
  final private = pair.privateKey;
  final public = pair.publicKey;
  String b64(BigInt n) {
    final hex = n.toRadixString(16).padLeft(64, '0');
    return base64Url
        .encode([for (var i = 0; i < 64; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)])
        .replaceAll('=', '');
  }

  final kid = [for (var i = 0; i < 16; i++) rng.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  return {
    'kty': 'EC',
    'crv': 'P-256',
    'alg': 'ES256',
    'kid': '${kid.substring(0, 8)}-${kid.substring(8, 12)}-4${kid.substring(13, 16)}-a${kid.substring(17, 20)}-'
        '${kid.substring(20)}',
    'x': b64(public.Q!.x!.toBigInteger()!),
    'y': b64(public.Q!.y!.toBigInteger()!),
    'd': b64(private.d!),
  };
}

/// A setup token: 32 random bytes, base64url without padding (43 characters).
String newSetupToken({Random? random}) {
  final rng = random ?? Random.secure();
  return base64Url.encode(List.generate(32, (_) => rng.nextInt(256))).replaceAll('=', '');
}

enum SupabaseStep {
  project('Starting the project'),
  database('Database'),
  liveChannel('Live channel key'),
  function('Server function'),
  signIn('Signing this computer in');

  const SupabaseStep(this.label);
  final String label;
}

/// Puts PocketTerm on a Supabase project (or updates it there): the
/// migrations, the live channel's signing key, the Edge Function, and a
/// setup token for this computer. Every step can run again: applied
/// migrations are skipped, a project that has its live channel key keeps
/// it, the function is deployed anew.
class SupabaseSetup {
  SupabaseSetup({
    required this.admin,
    required this.ref,
    this.source = const AssetSupabaseSource(),
    this.poll = const Duration(seconds: 3),
    this.schemaWait = const Duration(minutes: 3),
    this.keyWait = const Duration(minutes: 8),
    Future<void> Function(SupabaseSetup)? wakeRealtime,
    Future<String?> Function(Backend)? health,
  }) : wakeRealtime = wakeRealtime ?? _connectRealtime,
       health = health ?? ((b) => b.check());

  final SupabaseAdmin admin;
  final String ref;
  final SupabaseSource source;

  /// How often waits look again.
  final Duration poll;

  /// A new project says it's healthy before Realtime and Storage have made
  /// their tables, which the migrations add to. Realtime makes
  /// `realtime.messages` only once a client first connects, so [migrate]
  /// connects ([wakeRealtime]) and waits up to this long.
  final Duration schemaWait;

  /// How long [liveChannel] waits for Supabase to take a new signing key:
  /// it allows a signing key change only every few minutes.
  final Duration keyWait;

  final Future<void> Function(SupabaseSetup) wakeRealtime;

  /// The function's GET /v1/health once deployed (null: it answers).
  final Future<String?> Function(Backend) health;

  String get url => 'https://$ref.supabase.co';

  Backend get backend => Backend(url: url, kind: BackendKind.supabase);

  static Future<void> _connectRealtime(SupabaseSetup s) async {
    final key = await s.admin.publishableKey(s.ref);
    final ws = await WebSocket.connect(
      'wss://${s.ref}.supabase.co/realtime/v1/websocket?apikey=${Uri.encodeQueryComponent(key)}&vsn=1.0.0',
    ).timeout(const Duration(seconds: 15));
    ws.add(jsonEncode({'topic': 'realtime:pocketterm-setup', 'event': 'phx_join', 'payload': <String, Object>{}, 'ref': '1'}));
    try {
      await ws.first.timeout(const Duration(seconds: 15));
    } finally {
      await ws.close();
    }
  }

  /// Whether PocketTerm is on this project already (an update).
  Future<bool> hasPocketTerm() async =>
      (await admin.query(ref, "select to_regnamespace('pocketterm') is not null as ours")).firstOrNull?['ours'] ==
      true;

  /// Applies the migrations the project hasn't had yet, each in its own
  /// transaction, recorded where the Supabase CLI keeps them. How many.
  Future<int> migrate() async {
    await _waitForSchemas();
    await admin.query(
      ref,
      'create schema if not exists supabase_migrations;\n'
      'create table if not exists supabase_migrations.schema_migrations '
      '(version text primary key, statements text[], name text);',
    );
    final applied = {
      for (final r in await admin.query(ref, 'select version from supabase_migrations.schema_migrations'))
        r['version'] as String,
    };
    var count = 0;
    for (final m in await source.migrations()) {
      if (applied.contains(m.version)) continue;
      await admin.query(
        ref,
        'begin;\n${m.sql}\n;\n'
        'insert into supabase_migrations.schema_migrations (version, name) '
        "values ('${m.version}', '${m.name.replaceAll("'", "''")}');\ncommit;",
      );
      count++;
    }
    return count;
  }

  Future<void> _waitForSchemas() async {
    final deadline = DateTime.now().add(schemaWait);
    var woken = false;
    while (true) {
      final r = await admin.query(
        ref,
        "select to_regclass('realtime.messages') is not null and to_regclass('storage.buckets') is not null as ready",
      );
      if (r.firstOrNull?['ready'] == true) return;
      if (DateTime.now().isAfter(deadline)) {
        throw const AdminException('Supabase is still starting the project. Wait a minute, then retry.');
      }
      if (!woken) {
        woken = true;
        try {
          await wakeRealtime(this);
        } on Object catch (e) {
          debugPrint('PocketTerm: waking Realtime failed: $e');
        }
      }
      await Future<void>.delayed(poll);
    }
  }

  /// The live channel's key: a new ES256 key, imported as the project's JWT
  /// signing key and put to use (Realtime then takes tokens it signs), and
  /// given to the function as its secret PT_REALTIME_JWK with the
  /// publishable key (PT_PUBLISHABLE_KEY). Realtime takes private channels
  /// only. A project that has its key already keeps it. [onWait] hears when
  /// Supabase makes it wait (a signing key changes every few minutes at most).
  Future<void> liveChannel({VoidCallback? onWait}) async {
    final secrets = await admin.secretNames(ref);
    if (!secrets.contains('PT_REALTIME_JWK')) {
      final jwk = newLiveSigningKey();
      // A standby key the project made itself would refuse a second one; it never signed anything.
      for (final k in await admin.signingKeys(ref)) {
        if (k['status'] == 'standby') await admin.setSigningKeyStatus(ref, k['id'] as String, 'previously_used');
      }
      final id = await admin.addSigningKey(ref, jwk);
      final deadline = DateTime.now().add(keyWait);
      var told = false;
      while (true) {
        try {
          await admin.setSigningKeyStatus(ref, id, 'in_use');
          break;
        } on AdminException catch (e) {
          if (DateTime.now().isAfter(deadline) || e.status == 401 || e.status == 403) rethrow;
          debugPrint('PocketTerm: signing key not in use yet: $e');
          if (!told) onWait?.call();
          told = true;
          await Future<void>.delayed(poll * 10);
        }
      }
      await admin.setSecrets(ref, {'PT_REALTIME_JWK': jsonEncode(jwk)});
    }
    await admin.setSecrets(ref, {'PT_PUBLISHABLE_KEY': await admin.publishableKey(ref)});
    try {
      await admin.realtimePrivateOnly(ref);
    } on AdminException catch (e) {
      // Every channel PocketTerm opens is private anyway.
      debugPrint('PocketTerm: Realtime private-only not set: $e');
    }
  }

  /// Deploys the function and waits for it to answer.
  Future<void> deploy() async {
    await admin.deployFunction(ref, 'pocketterm', await source.function(), verifyJwt: false);
    String? problem;
    for (var i = 0; i < 20; i++) {
      problem = await health(backend);
      if (problem == null) return;
      await Future<void>.delayed(poll);
    }
    throw AdminException('The PocketTerm function on Supabase doesn’t answer yet: $problem');
  }

  /// A new setup token for this project (only its SHA-256 goes there); the
  /// link this computer signs in with. The one before stops working.
  Future<Uri> setupLink() async {
    final token = newSetupToken();
    await admin.query(ref, "select pocketterm.set_setup_hash('${sha256.convert(utf8.encode(token))}')");
    return backend.linkWithSetup(token);
  }

  /// Everything, in order; [onStep] hears each step as it starts, [onWait]
  /// when Supabase makes the live channel key wait. Steps in [done] are
  /// skipped (a retry picks up where it stopped). The setup link this
  /// computer signs in with.
  Future<Uri> run({
    void Function(SupabaseStep step)? onStep,
    VoidCallback? onWait,
    Set<SupabaseStep> done = const {},
  }) async {
    Future<void> step(SupabaseStep s, Future<void> Function() work) async {
      if (done.contains(s)) return;
      onStep?.call(s);
      await work();
    }

    await step(SupabaseStep.project, () => admin.waitUntilReady(ref, poll: poll));
    await step(SupabaseStep.database, migrate);
    await step(SupabaseStep.liveChannel, () => liveChannel(onWait: onWait));
    await step(SupabaseStep.function, deploy);
    onStep?.call(SupabaseStep.signIn);
    return await setupLink();
  }
}
