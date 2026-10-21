import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_desktop/onboarding/flow.dart';
import 'package:pocketterm_desktop/onboarding/provision.dart';
import 'package:pocketterm_desktop/onboarding/supabase_admin.dart';
import 'package:pocketterm_desktop/onboarding/wizard.dart';

/// The Management API of an account with one organization, enough of it for
/// the wizard from token to finished server.
class FakeSupabase {
  final projects = <Map<String, dynamic>>[
    {'id': 'other', 'name': 'blog', 'status': 'ACTIVE_HEALTHY', 'region': 'eu-central-1'},
  ];
  int posts = 0;
  int polls = 0;

  /// What the next project poll says.
  String status = 'COMING_UP';
  http.Response? createError;

  // A project's insides, the same for every project here.
  bool pocketTermInstalled = false;
  int users = 0;
  String taken = '';
  final applied = <String>{};
  final queries = <String>[];
  Map<String, dynamic> auth = {'site_url': 'http://localhost:3000', 'uri_allow_list': ''};
  int authPatches = 0;
  final deploys = <String>[];

  /// Function deploys fail while this is above zero, one at a time.
  int failDeploys = 0;

  http.Response _json(Object? body, [int status = 200]) => http.Response(jsonEncode(body), status);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (path == '/v1/organizations') {
      return _json([
        {'slug': 'org1', 'name': 'Me'},
      ]);
    }
    if (path == '/v1/projects' && req.method == 'GET') return _json(projects);
    if (path == '/v1/projects' && req.method == 'POST') {
      posts++;
      if (createError case final e?) return e;
      final body = jsonDecode(req.body) as Map;
      final p = {'id': 'new$posts', 'name': body['name'], 'status': 'COMING_UP', 'region': 'eu-central-1'};
      projects.add(p);
      return _json(p, 201);
    }
    final project = RegExp(r'^/v1/projects/(\w+)$').firstMatch(path);
    if (project != null) {
      polls++;
      return _json({'id': project.group(1), 'name': 'pocketterm', 'status': status});
    }
    if (path.endsWith('/database/query')) {
      final sql = (jsonDecode(req.body) as Map)['query'] as String;
      queries.add(sql);
      if (sql.contains('as ready')) {
        return _json([
          {'ready': true},
        ], 201);
      }
      if (sql.contains('as recorded')) {
        return _json([
          {'recorded': pocketTermInstalled},
        ], 201);
      }
      if (sql.contains('as ours')) {
        return _json([
          {'ours': pocketTermInstalled},
        ], 201);
      }
      if (sql.contains('as taken')) {
        return _json([
          {'users': users, 'taken': taken},
        ], 201);
      }
      if (sql.startsWith('select version')) {
        return _json([
          for (final v in applied) {'version': v},
        ], 201);
      }
      final m = RegExp(r"values \('(\d+)'").firstMatch(sql);
      if (m != null) applied.add(m.group(1)!);
      return _json([], 201);
    }
    if (path.endsWith('/config/auth')) {
      if (req.method == 'PATCH') {
        authPatches++;
        auth = {...auth, ...jsonDecode(req.body) as Map<String, dynamic>};
      }
      return _json(auth);
    }
    if (path.endsWith('/api-keys')) {
      return _json([
        {'name': 'default', 'type': 'publishable', 'api_key': 'sb_publishable_abc'},
      ]);
    }
    return http.Response('not found', 404);
  }

  late final client = MockClient.streaming((req, body) async {
    final bytes = await body.toBytes();
    if (req.url.path.endsWith('/functions/deploy')) {
      if (failDeploys > 0) {
        failDeploys--;
        return http.StreamedResponse(Stream.value(utf8.encode('{"message":"Bundling failed"}')), 500);
      }
      deploys.add(req.url.queryParameters['slug']!);
      return http.StreamedResponse(Stream.value(utf8.encode('{}')), 201);
    }
    final res = await _handle(http.Request(req.method, req.url)..bodyBytes = bytes);
    return http.StreamedResponse(Stream.value(res.bodyBytes), res.statusCode);
  });
}

class FakeSource implements BackendSource {
  @override
  Future<List<Migration>> migrations() async => [
    migrationFromFile(
      'supabase/migrations/20261101000000_server.sql',
      'create table public.pairing_codes (id uuid);\ncreate index pairing_codes_expiry on public.pairing_codes (id);\n'
          r'create function public.redeem_pairing_code() returns uuid language plpgsql as $$ begin end $$;',
    ),
    migrationFromFile(
      'supabase/migrations/20261101000100_terminal.sql',
      "insert into storage.buckets (id, name, public) values ('terminal', 'terminal', false);",
    ),
  ];

  @override
  Future<String> function(String slug) async => '// $slug';
}

/// GitHub's token endpoint, answering a made-up code for good credentials.
MockClient github([String error = 'bad_verification_code', int status = 200]) =>
    MockClient((_) async => http.Response(jsonEncode({'error': error}), status));

void main() {
  late FakeSupabase api;
  late List<String?> checks;

  SetupFlow newFlow({http.Client? web, Duration startTimeout = const Duration(minutes: 6)}) => SetupFlow(
    admin: (t) => SupabaseAdmin(t, client: api.client),
    source: FakeSource(),
    web: web ?? github(),
    check: (_) async => checks.isEmpty ? null : checks.removeAt(0),
    startTimeout: startTimeout,
    checkPause: Duration.zero,
  );

  /// A flow past the GitHub step on the account's existing, empty project:
  /// the setup has run.
  Future<SetupFlow> setUpServer() async {
    final flow = newFlow();
    await flow.submitToken('sbp_token');
    flow
      ..createNew = false
      ..existingRef = 'other';
    await flow.submitProject();
    flow
      ..githubId = 'Iv1.id'
      ..githubSecret = 'secret';
    await flow.submitGithub();
    expect(flow.step, WizardStep.setup, reason: flow.error);
    return flow;
  }

  setUp(() {
    api = FakeSupabase();
    checks = [];
  });

  group('new project', () {
    test('continuing after the wait timed out waits for the same project, never makes a second', () async {
      final flow = newFlow(startTimeout: Duration.zero);
      await flow.submitToken('sbp_token');
      expect(flow.createNew, isTrue);

      await flow.submitProject();
      expect(flow.error, contains('still starting'));
      expect(flow.step, WizardStep.project);
      // It's offered as the project to use now, marked as still starting.
      expect(flow.createNew, isFalse);
      expect(flow.existingRef, 'new1');
      expect(flow.usableProjects.map((p) => p.ref), contains('new1'));

      api.status = 'ACTIVE_HEALTHY';
      await flow.submitProject();
      expect(flow.error, isNull);
      expect(flow.step, WizardStep.github);
      expect(flow.ref, 'new1');
      expect(api.posts, 1);
      // Fresh: nothing to look at in it first.
      expect(api.queries, isEmpty);
    });

    test('Back while the project starts stops waiting and keeps it for next time', () async {
      final flow = newFlow();
      await flow.submitToken('sbp_token');
      final submitting = flow.submitProject();
      while (flow.waiting == null) {
        await Future<void>.delayed(Duration.zero);
      }
      while (api.polls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      flow.go(WizardStep.token);
      await submitting;
      final polls = api.polls;
      expect(flow.step, WizardStep.token);
      expect((flow.busy, flow.waiting, flow.error), (false, null, null));

      await flow.submitToken('sbp_token');
      expect((flow.createNew, flow.existingRef), (false, 'new1'));
      expect(api.polls, polls);
      expect(api.posts, 1);
    });

    test('the plan limit says what to do', () async {
      api.createError = http.Response(
        jsonEncode({
          'message':
              'The following organization members have reached their maximum limits for the number of active '
              'free projects within organizations where they are an administrator or owner: me (2 project limit).',
        }),
        400,
      );
      final flow = newFlow();
      await flow.submitToken('sbp_token');
      await flow.submitProject();

      expect(flow.error, contains('Pause or delete one'));
      expect(flow.error, contains('Create project again'));
      expect((flow.createNew, flow.ref, flow.step), (true, null, WizardStep.project));
    });

    test('rate-limiting is not the plan limit', () async {
      api.createError = http.Response('{"message":"Too many requests"}', 429);
      final flow = newFlow();
      await flow.submitToken('sbp_token');
      await flow.submitProject();

      expect(flow.error, contains('rate-limiting'));
    });
  });

  group('existing project', () {
    Future<SetupFlow> pick() async {
      final flow = newFlow();
      await flow.submitToken('sbp_token');
      flow
        ..createNew = false
        ..existingRef = 'other';
      await flow.submitProject();
      return flow;
    }

    test('one with accounts is refused: its owner could never sign in', () async {
      api.users = 3;
      final flow = await pick();
      expect(flow.error, contains('already has accounts'));
      expect(flow.step, WizardStep.project);
    });

    test('one with tables of the same names is refused, naming them', () async {
      api.taken = 'pairing_codes, storage bucket terminal';
      final flow = await pick();
      expect(flow.error, contains('pairing_codes, storage bucket terminal'));
      expect(flow.step, WizardStep.project);
      // It asked about what the migrations make.
      final asked = api.queries.singleWhere((q) => q.contains('as taken'));
      for (final name in ["'pairing_codes'", "'pairing_codes_expiry'", "'redeem_pairing_code'", "'terminal'"]) {
        expect(asked, contains(name));
      }
    });

    test('settings it would replace need a second Continue', () async {
      api.auth = {
        'site_url': 'https://myblog.example',
        'hook_before_user_created_enabled': true,
        'hook_before_user_created_uri': 'pg-functions://postgres/public/mine',
      };
      final flow = await pick();
      expect(flow.error, isNull);
      expect(flow.caution, allOf(contains('https://myblog.example'), contains('before-user-created hook')));
      expect(flow.step, WizardStep.project);

      await flow.submitProject();
      expect(flow.step, WizardStep.github);
    });

    test('one PocketTerm is already on is an update: no questions', () async {
      api
        ..pocketTermInstalled = true
        ..users = 1
        ..auth = {'site_url': 'pocketterm://login-callback', 'external_github_enabled': true};
      final flow = await pick();
      expect(flow.error, isNull);
      expect(flow.caution, isNull);
      expect(flow.step, WizardStep.github);
    });
  });

  group('GitHub app', () {
    Future<SetupFlow> atGithub(MockClient web) async {
      final flow = newFlow(web: web);
      await flow.submitToken('sbp_token');
      flow
        ..createNew = false
        ..existingRef = 'other';
      await flow.submitProject();
      flow
        ..githubId = 'Iv1.id'
        ..githubSecret = 'secret';
      await flow.submitGithub();
      return flow;
    }

    test('a wrong secret is caught before the setup', () async {
      final flow = await atGithub(github('incorrect_client_credentials'));
      expect(flow.error, contains('client secret'));
      expect(flow.step, WizardStep.github);
      expect(api.deploys, isEmpty);
    });

    test('an unknown Client ID is caught', () async {
      final flow = await atGithub(github('Not Found', 404));
      expect(flow.error, contains('Client ID'));
    });

    test('a wrong callback URL is caught, with the right one', () async {
      final flow = await atGithub(github('redirect_uri_mismatch'));
      expect(flow.error, contains('https://other.supabase.co/auth/v1/callback'));
    });

    test("GitHub unreachable doesn't hold the setup up", () async {
      final flow = await atGithub(MockClient((_) async => throw http.ClientException('offline')));
      expect(flow.error, isNull);
      expect(flow.ready, isTrue);
    });
  });

  group('setup', () {
    test('runs everything right after GitHub takes the app, and is ready', () async {
      final flow = await setUpServer();

      expect(flow.error, isNull);
      expect(flow.step, WizardStep.setup);
      expect(flow.ready, isTrue);
      expect(api.deploys, ['pair', 'push']);
      expect(flow.backend?.key, 'sb_publishable_abc');
    });

    test('an edit after Back runs that step again, and only that one', () async {
      final flow = await setUpServer();
      expect(flow.ready, isTrue);
      expect((api.authPatches, api.deploys.length), (1, 2));

      flow
        ..go(WizardStep.github)
        ..githubSecret = 'new secret';
      await flow.submitGithub();

      expect(flow.ready, isTrue);
      expect(api.authPatches, 2);
      expect(api.auth['external_github_secret'], 'new secret');
      expect(api.deploys.length, 2);
    });

    test('another project gets every step', () async {
      api.projects.add({'id': 'second', 'name': 'spare', 'status': 'ACTIVE_HEALTHY'});
      final flow = await setUpServer();

      // The fake's settings are the first project's; the second one is fresh.
      api.auth = {'site_url': 'http://localhost:3000'};
      flow
        ..go(WizardStep.project)
        ..existingRef = 'second';
      await flow.submitProject();
      await flow.submitGithub();

      expect(flow.ref, 'second');
      expect((api.authPatches, api.deploys.length), (2, 4));
    });

    test('a step that fails again is still not done', () async {
      api.failDeploys = 2;
      final flow = await setUpServer();
      expect(flow.error, contains('Bundling failed'));
      await flow.setUp();
      expect(flow.error, contains('Bundling failed'));
      expect(flow.done, isNot(contains(ProvisionStep.functions)));

      await flow.setUp();
      expect(flow.ready, isTrue);
      expect(api.deploys, ['pair', 'push']);
    });

    test('the check waits a little for the auth service to pick up the settings', () async {
      checks = ['GitHub sign-in is off on this project.', 'GitHub sign-in is off on this project.'];
      final flow = await setUpServer();
      expect(flow.ready, isTrue);
      expect(api.authPatches, 1);
    });

    test('a check that keeps failing makes Retry set sign-in up again', () async {
      checks = List.filled(10, 'GitHub sign-in is off on this project.', growable: true);
      final flow = await setUpServer();
      expect(flow.error, contains('GitHub sign-in is off'));
      expect(flow.ready, isFalse);

      await flow.setUp();
      expect(flow.ready, isTrue);
      expect(api.authPatches, 2);
      expect(api.deploys.length, 2);
    });

    test('a failed connect shows why and can be tried again; the server stays ready', () async {
      final flow = await setUpServer();

      await flow.connect((_) async => throw StateError('Sign out before switching projects.'));
      expect(flow.error, contains("Couldn't connect"));
      expect(flow.ready, isTrue);

      Backend? opened;
      await flow.connect((b) async => opened = b);
      expect(flow.error, isNull);
      expect(opened?.url, 'https://other.supabase.co');
    });
  });

  testWidgets('the finished screen shows a failed connect and keeps its button', (tester) async {
    final flow = await tester.runAsync(setUpServer);
    addTearDown(flow!.dispose);
    var tries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SetupWizard(
            flow: flow,
            onConnect: (_) async {
              tries++;
              throw StateError('Sign out before switching projects.');
            },
            onExisting: () {},
          ),
        ),
      ),
    );
    expect(find.text('Your server is ready'), findsOneWidget);

    await tester.tap(find.text('Connect and sign in'));
    await tester.pump();
    expect(find.textContaining("Couldn't connect: Bad state: Sign out"), findsOneWidget);

    await tester.tap(find.text('Connect and sign in'));
    await tester.pump();
    expect(tries, 2);
  });
}
