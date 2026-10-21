import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_desktop/onboarding/supabase_admin.dart';

/// One migration: `supabase/migrations/<version>_<name>.sql`.
typedef Migration = ({String version, String name, String sql});

/// The backend the app ships with (the pubspec bundles supabase/ as assets),
/// so a downloaded app can set up a server without the repo or the CLI.
abstract interface class BackendSource {
  /// Oldest first.
  Future<List<Migration>> migrations();
  Future<String> function(String slug);
}

class AssetBackendSource implements BackendSource {
  const AssetBackendSource();

  @override
  Future<List<Migration>> migrations() async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final paths =
        manifest.listAssets().where((p) => p.startsWith('supabase/migrations/') && p.endsWith('.sql')).toList()..sort();
    return [for (final p in paths) migrationFromFile(p, await rootBundle.loadString(p))];
  }

  @override
  Future<String> function(String slug) => rootBundle.loadString('supabase/functions/$slug/index.ts');
}

/// `…/20261101000000_server.sql` → version `20261101000000`, name `server`.
Migration migrationFromFile(String path, String sql) {
  final file = path.split('/').last.replaceFirst(RegExp(r'\.sql$'), '');
  final cut = file.indexOf('_');
  return (version: cut < 0 ? file : file.substring(0, cut), name: cut < 0 ? '' : file.substring(cut + 1), sql: sql);
}

enum ProvisionStep {
  database('Database'),
  signIn('GitHub sign-in'),
  functions('Server functions'),
  keys('Connection key');

  const ProvisionStep(this.label);
  final String label;
}

/// Sets up (or updates) a PocketTerm server on a Supabase project, the same thing
/// tool/setup-backend.sh does with the CLI. Every step can run again: applied
/// migrations are skipped, the rest is overwritten with the same values.
class Provisioner {
  Provisioner({
    required this.admin,
    required this.ref,
    this.source = const AssetBackendSource(),
    this.schemaPoll = const Duration(seconds: 3),
    this.schemaWait = const Duration(minutes: 3),
    Future<void> Function(Provisioner)? wakeRealtime,
  }) : wakeRealtime = wakeRealtime ?? _connectRealtime;

  final SupabaseAdmin admin;
  final String ref;
  final BackendSource source;

  /// A new project reports healthy before Realtime and Storage have created
  /// their tables, which the migrations add policies to. Realtime creates
  /// `realtime.messages` only once a client first connects, so [migrate]
  /// connects ([wakeRealtime]) and waits.
  final Duration schemaPoll;
  final Duration schemaWait;
  final Future<void> Function(Provisioner) wakeRealtime;

  static Future<void> _connectRealtime(Provisioner p) async {
    final key = await p.admin.publishableKey(p.ref);
    final ws = await WebSocket.connect(
      'wss://${p.ref}.supabase.co/realtime/v1/websocket?apikey=${Uri.encodeQueryComponent(key)}&vsn=1.0.0',
    ).timeout(const Duration(seconds: 15));
    ws.add(
      jsonEncode({
        'topic': 'realtime:pocketterm-setup',
        'event': 'phx_join',
        'payload': <String, Object>{},
        'ref': '1',
      }),
    );
    try {
      await ws.first.timeout(const Duration(seconds: 15));
    } finally {
      await ws.close();
    }
  }

  static const redirect = 'pocketterm://login-callback';
  static const hook = 'pg-functions://postgres/public/before_user_created';

  String get url => 'https://$ref.supabase.co';

  /// GitHub's "Authorization callback URL" for this project.
  String get githubCallback => '$url/auth/v1/callback';

  /// Looks at a project before PocketTerm goes on it. `stop`: why it can't (it has
  /// accounts, so the private-server hook would turn the owner away, or
  /// tables and the like the migrations need to create). `replaces`: the
  /// settings of its own that PocketTerm would overwrite. Both null for a fresh
  /// project, or one PocketTerm is already on (an update).
  Future<({String? stop, String? replaces})> inspect() async {
    final migrations = await source.migrations();
    String list(Iterable<String> names) =>
        'array[${names.map((n) => "'${n.replaceAll("'", "''")}'").join(',')}]::text[]';
    final recorded = await admin.query(
      ref,
      "select to_regclass('supabase_migrations.schema_migrations') is not null as recorded",
    );
    if (recorded.firstOrNull?['recorded'] == true) {
      final ours = await admin.query(
        ref,
        'select exists (select 1 from supabase_migrations.schema_migrations '
        'where version = any(${list(migrations.map((m) => m.version))})) as ours',
      );
      if (ours.firstOrNull?['ours'] == true) return (stop: null, replaces: null);
    }

    Set<String> named(String pattern) => {
      for (final m in migrations)
        for (final hit in RegExp(pattern, caseSensitive: false).allMatches(m.sql)) hit.group(1)!,
    };
    final relations = named(
      r'create\s+(?:table|view|(?:unique\s+)?index)\s+(?:if\s+not\s+exists\s+)?(?:public\.)?(\w+)(?![\w.])',
    );
    final functions = named(r'create\s+function\s+public\.(\w+)');
    final buckets = named(r"insert\s+into\s+storage\.buckets[^;]*?values\s*\(\s*'([^']+)'");
    final found = (await admin.query(ref, '''
select
  (select count(*) from auth.users)::int as users,
  concat_ws(', ',
    (select string_agg(relname, ', ' order by relname) from pg_class
      where relnamespace = 'public'::regnamespace and relname = any(${list(relations)})),
    (select string_agg(distinct proname || '()', ', ') from pg_proc
      where pronamespace = 'public'::regnamespace and proname = any(${list(functions)})),
    (select string_agg('storage bucket ' || id, ', ' order by id) from storage.buckets where id = any(${list(buckets)}))
  ) as taken''')).firstOrNull;
    final users = (found?['users'] as num?) ?? 0;
    final taken = found?['taken'] as String? ?? '';
    if (users > 0) {
      return (
        stop:
            'This project already has accounts. A PocketTerm server lets in only the first account to sign in, so '
            'yours would be turned away. Create a new project for PocketTerm instead.',
        replaces: null,
      );
    }
    if (taken.isNotEmpty) {
      return (
        stop:
            'This project already has $taken, which PocketTerm needs to make itself. Create a new project for PocketTerm instead.',
        replaces: null,
      );
    }

    final auth = await admin.authConfig(ref);
    final site = auth['site_url'] as String? ?? '';
    final hookUri = auth['hook_before_user_created_uri'] as String? ?? '';
    final replaces = [
      if (site.isNotEmpty && site != redirect && site != 'http://localhost:3000') 'Site URL ($site)',
      if (auth['hook_before_user_created_enabled'] == true && hookUri != hook) 'before-user-created hook',
      if (auth['external_github_enabled'] == true) 'GitHub sign-in app',
    ];
    return (
      stop: null,
      replaces: replaces.isEmpty
          ? null
          : "PocketTerm sets sign-in up its own way and would replace this project's ${replaces.join(', ')}. "
                'Anything that uses them now stops working.',
    );
  }

  /// Applies the migrations the project hasn't had yet, each in its own
  /// transaction, recording them where the Supabase CLI does (so a later
  /// `supabase db push` agrees). Returns how many were applied.
  Future<int> migrate() async {
    await _waitForSchemas();
    await admin.query(
      ref,
      '''
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);''',
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
      await Future<void>.delayed(schemaPoll);
    }
  }

  /// GitHub as the only way in, the app's redirect, and the private-server
  /// hook (the first account owns the server).
  Future<void> configureSignIn({required String githubClientId, required String githubSecret}) async {
    final current = await admin.authConfig(ref);
    final allowed = {
      for (final u in (current['uri_allow_list'] as String? ?? '').split(','))
        if (u.trim().isNotEmpty) u.trim(),
      redirect,
    };
    await admin.updateAuthConfig(ref, {
      'site_url': redirect,
      'uri_allow_list': allowed.join(','),
      'external_github_enabled': true,
      'external_github_client_id': githubClientId.trim(),
      'external_github_secret': githubSecret.trim(),
      'hook_before_user_created_enabled': true,
      'hook_before_user_created_uri': hook,
      // No email/password sign-up (tool/setup-backend.sh pushes the same from
      // config.toml): only GitHub proves who someone is. The reviewer demo
      // account is made by functions/pair, not signed up.
      'external_email_enabled': false,
      // functions/pair swaps a phone's code for a magic-link token used at once.
      'mailer_otp_exp': 600,
    });
  }

  Future<void> deployFunctions() async {
    // The push relay is the publisher's alone (apps/pocketterm-relay): never on a user's server.
    for (final slug in ['pair', 'push']) {
      // Both check the caller themselves (a user token).
      await admin.deployFunction(ref, slug, await source.function(slug), verifyJwt: false);
    }
  }

  Future<Backend> backend() async => Backend(url: url, key: await admin.publishableKey(ref));

  /// Everything, in order; [onStep] hears each step as it starts. Skips the
  /// steps in [done] (a retry after a failure picks up where it stopped).
  Future<Backend> run({
    required String githubClientId,
    required String githubSecret,
    void Function(ProvisionStep step)? onStep,
    Set<ProvisionStep> done = const {},
  }) async {
    Future<void> step(ProvisionStep s, Future<void> Function() work) async {
      if (done.contains(s)) return;
      onStep?.call(s);
      await work();
    }

    await step(ProvisionStep.database, migrate);
    await step(ProvisionStep.signIn, () => configureSignIn(githubClientId: githubClientId, githubSecret: githubSecret));
    await step(ProvisionStep.functions, deployFunctions);
    onStep?.call(ProvisionStep.keys);
    return await backend();
  }
}
