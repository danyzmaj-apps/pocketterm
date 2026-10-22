import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/supabase_server.dart';
import 'package:pocketterm_desktop/hosting/vps.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:pocketterm_desktop/onboarding/supabase_admin.dart';
import 'package:pocketterm_desktop/onboarding/supabase_setup.dart';
import 'package:pocketterm_desktop/setup_page.dart';
import 'package:pointycastle/export.dart' as pc;

import 'app_fakes.dart';

/// The Management API of one Supabase account, in memory: two organizations,
/// projects as created, SQL answered by what it asks.
class FakeSupabase {
  final requests = <String>[];

  /// The bodies of POST /v1/projects.
  final created = <Map<String, dynamic>>[];

  final projects = <Map<String, Object?>>[
    {'id': 'hopjarref0000000', 'name': 'hopjar', 'status': 'ACTIVE_HEALTHY', 'organization_id': 'org-work'},
  ];

  /// Projects PocketTerm is on already.
  final ours = <String>{};

  /// What the next deploy answers with, once: a status and a message.
  (int, String)? deployFails;

  /// Times the signing key is refused before it's taken (Supabase's wait).
  int keyRefusals = 0;

  /// While set, a refused signing key waits for it before the next try.
  Completer<void>? keyGate;

  /// While true, POST /v1/projects is refused for the free plan's limit.
  bool atLimit = false;

  int keyTries = 0;

  /// How many [requests] were [request] (`METHOD /path`).
  int count(String request) => requests.where((r) => r == request).length;

  late final client = MockClient((req) async {
    final path = req.url.path;
    requests.add('${req.method} $path');
    http.Response json(Object? body, [int status = 200]) => http.Response(jsonEncode(body), status);
    final parts = path.split('/');
    switch ((req.method, path)) {
      case ('GET', '/v1/organizations'):
        return json([
          {'slug': 'org-mine', 'name': 'Mine', 'plan': 'free'},
          {'slug': 'org-work', 'name': 'Work', 'plan': 'pro'},
        ]);
      case ('GET', '/v1/projects'):
        return json(projects);
      case ('POST', '/v1/projects') when atLimit:
        return json({'message': 'The maximum limit of 2 free projects has been reached'}, 400);
      case ('POST', '/v1/projects'):
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        created.add(body);
        final p = {
          'id': 'newproject000000',
          'name': body['name'],
          'status': 'COMING_UP',
          'organization_id': body['organization_slug'],
        };
        projects.add(p);
        return json(p, 201);
    }
    if (parts.length >= 4 && parts[2] == 'projects') {
      final ref = parts[3];
      final rest = parts.skip(4).join('/');
      final project = projects.firstWhere((p) => p['id'] == ref);
      switch ((req.method, rest)) {
        case ('GET', ''):
          project['status'] = 'ACTIVE_HEALTHY';
          return json(project);
        case ('POST', 'database/query'):
          final sql = (jsonDecode(req.body) as Map)['query'] as String;
          if (sql.contains('to_regnamespace')) {
            return json([
              {'ours': ours.contains(ref)},
            ]);
          }
          if (sql.contains("to_regclass('realtime.messages')")) {
            return json([
              {'ready': true},
            ]);
          }
          return json(<Object>[]);
        case ('GET', 'secrets'):
          return json(<Object>[]);
        case ('POST', 'secrets'):
          return json({});
        case ('GET', 'config/auth/signing-keys'):
          return json({'keys': <Object>[]});
        case ('POST', 'config/auth/signing-keys'):
          return json({'id': 'key-1'}, 201);
        case ('PATCH', 'config/auth/signing-keys/key-1'):
          if (keyTries++ < keyRefusals) {
            if (keyTries > 1) await keyGate?.future;
            return json({'message': 'Wait before rotating again'}, 400);
          }
          return json({});
        case ('GET', 'api-keys'):
          return json([
            {'type': 'publishable', 'api_key': 'sb_publishable_test'},
          ]);
        case ('PATCH', 'config/realtime'):
          return json({});
        case ('POST', 'functions/deploy'):
          if (deployFails case (final status, final message)) {
            deployFails = null;
            return json({'message': message}, status);
          }
          return json({'id': 'fn'}, 201);
      }
    }
    return json({'message': 'Not found'}, 404);
  });
}

/// The Supabase branch's tools over [fake], waiting for nothing.
class FakeTools extends SupabaseTools {
  FakeTools(this.fake);
  final FakeSupabase fake;

  /// The tokens the screen made an admin with.
  final tokens = <String>[];

  @override
  SupabaseAdmin admin(String token) {
    tokens.add(token);
    return SupabaseAdmin(token, client: fake.client);
  }

  @override
  SupabaseSetup setup(SupabaseAdmin admin, String ref) => SupabaseSetup(
    admin: admin,
    ref: ref,
    source: const _Source(),
    poll: Duration.zero,
    wakeRealtime: (_) async {},
    health: (_) async => null,
  );
}

class _Source implements SupabaseSource {
  const _Source();

  @override
  Future<List<Migration>> migrations() async => [(version: '20261023000000', name: 'pocketterm', sql: 'select 1')];

  @override
  Future<String> function() async => 'Deno.serve(() => new Response("ok"));';
}

/// Health checks that answer for any server, remembering what was asked.
class AnyServerChecks extends ServerChecks {
  final asked = <Backend>[];

  @override
  Future<ServerHealth> answers(Backend backend) async {
    asked.add(backend);
    return (error: null, clockOffset: null);
  }
}

/// A Supabase project's client, its setup links made up (`token-1`, …).
class FakeSupabaseServer extends SupabaseServerClient {
  FakeSupabaseServer(super.backend) : super(tokens: MemoryDeviceTokens());

  /// What the next [newSetupLink] throws, if anything.
  ServerException? fails;
  int made = 0;

  @override
  Future<Uri> newSetupLink() async {
    if (fails case final e?) throw e;
    return backend.linkWithSetup('token-${++made}');
  }
}

const project = Backend(url: 'https://abcdefghijklmnop.supabase.co', kind: BackendKind.supabase);

void main() {
  late FakeSupabase fake;
  late FakeTools tools;
  late AnyServerChecks checks;

  /// The links the setup signed in with.
  late List<Uri> links;

  /// The links opened in the browser.
  late List<String> opened;

  setUp(() {
    fake = FakeSupabase();
    tools = FakeTools(fake);
    checks = AnyServerChecks();
    links = [];
  });

  Future<FakeApp> pumpSetup(WidgetTester tester, {Map<String, Object> prefs = const {}}) async {
    tester.view
      ..physicalSize = const Size(900, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    opened = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        if (call.method == 'launch') opened.add((call.arguments as Map)['url'] as String);
        return true;
      },
    );
    final app = await FakeApp.create(prefs: prefs)
      ..fakeUser = null
      ..fakeBackend = null;
    app.onConnectLink = (link) async {
      links.add(link);
      app.fakeUser = const Account(
        id: 'server-1',
        device: Device(id: 'device-1', role: DeviceRole.desktop, label: 'Mac', platform: 'macos'),
      );
    };
    await tester.pumpWidget(window(SetupPage(app: app, poll: Duration.zero, checks: checks, supabase: tools)));
    await tester.pump();
    return app;
  }

  /// Lets the fake API and the screen take turns until [done] holds.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 500 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(done(), isTrue, reason: 'timed out');
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
  }

  bool shows(String text) => find.textContaining(text).evaluate().isNotEmpty;

  CheckState step(WidgetTester tester, SupabaseStep s) =>
      tester.widget<SetupCheck>(find.byKey(ValueKey('supabase-step-${s.name}'))).state;

  Future<void> choose(WidgetTester tester, String dropdown, String item) async {
    await tester.tap(find.byKey(ValueKey(dropdown)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text(item).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// To the token screen, a token pasted, Continue.
  Future<void> paste(WidgetTester tester, String token) async {
    await tap(tester, 'setup-supabase');
    await tap(tester, 'supabase-new');
    await tester.enterText(find.byKey(const ValueKey('supabase-token')), token);
    await tap(tester, 'supabase-continue');
  }

  testWidgets('the first screen offers three options and compares them in a table', (tester) async {
    await pumpSetup(tester);
    for (final key in ['setup-this-computer', 'setup-own-server', 'setup-supabase']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    expect(find.byKey(const ValueKey('compare-table')), findsNothing);
    await tester.tap(find.text('How the three options compare'));
    await tester.pump();
    expect(find.byKey(const ValueKey('compare-table')), findsOneWidget);
    expect(shows('Supabase, in a region you pick'), isTrue);
    expect(shows('end-to-end encrypted in all three'), isTrue);
  });

  testWidgets('Supabase says what it holds and what the token covers before asking Supabase anything', (tester) async {
    final app = await pumpSetup(tester);
    await tap(tester, 'setup-supabase');
    expect(app.setupStep, 'supabase');
    await tap(tester, 'supabase-new');
    expect(shows('stay end-to-end encrypted'), isTrue);
    expect(shows('sees the IP addresses'), isTrue);
    expect(shows('covers your whole Supabase organization'), isTrue);
    expect(shows('never stores it'), isTrue);
    expect(shows('pauses a free project after about a week'), isTrue);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('supabase-token'))).obscureText, isTrue);

    await tap(tester, 'supabase-open-tokens');
    await until(tester, () => opened.isNotEmpty);
    expect(opened, ['https://supabase.com/dashboard/account/tokens']);
    expect(tools.tokens, isEmpty);
    expect(fake.requests, isEmpty);

    // Not a token: still nothing asked.
    await tester.enterText(find.byKey(const ValueKey('supabase-token')), 'hello');
    await tap(tester, 'supabase-continue');
    expect(shows('It starts with sbp_'), isTrue);
    expect(fake.requests, isEmpty);
  });

  testWidgets('a new project in the picked organization and region, set up step by step, signs this computer in', (
    tester,
  ) async {
    fake
      ..keyRefusals = 2
      ..keyGate = Completer<void>();
    await pumpSetup(tester);
    await paste(tester, 'sbp_secret');
    await until(tester, () => find.byKey(const ValueKey('supabase-org')).evaluate().isNotEmpty);
    expect(tools.tokens, ['sbp_secret']);
    // Two organizations: none picked for the person, and nothing to create in yet.
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('supabase-create'))).onPressed, isNull);

    await choose(tester, 'supabase-org', 'Work (pro plan)');
    await until(tester, () => fake.count('GET /v1/projects') == 1);
    await tester.pump();
    // Another project there isn't PocketTerm's: it's only asked about, never offered.
    expect(find.byKey(const ValueKey('supabase-update')), findsNothing);
    expect(shows('hopjar'), isFalse);
    await choose(tester, 'supabase-region', 'Europe (London)');
    await tap(tester, 'supabase-create');

    // Supabase makes the signing key wait: the screen says so.
    await until(tester, () => find.byKey(const ValueKey('supabase-wait')).evaluate().isNotEmpty);
    expect(step(tester, SupabaseStep.database), CheckState.done);
    expect(step(tester, SupabaseStep.liveChannel), CheckState.looking);
    expect(step(tester, SupabaseStep.function), CheckState.later);
    fake.keyGate!.complete();

    await until(tester, () => links.isNotEmpty);
    expect(fake.created.single, {
      'organization_slug': 'org-work',
      'name': 'PocketTerm',
      'db_pass': isA<String>().having((p) => p.length, 'length', 32),
      'region_selection': {'type': 'specific', 'code': 'eu-west-2'},
    });
    final link = links.single;
    expect(
      Backend.fromLink(link),
      const Backend(url: 'https://newproject000000.supabase.co', kind: BackendKind.supabase),
    );
    expect(Backend.setupToken(link), isNotNull);
    expect(fake.count('POST /v1/projects/newproject000000/functions/deploy'), 1);
    expect(find.byKey(const ValueKey('supabase-error')), findsNothing);
  });

  testWidgets('a Supabase error shows its message, and Retry picks up at the step that failed', (tester) async {
    fake.deployFails = (500, 'Bundling the function failed.');
    await pumpSetup(tester);
    await paste(tester, 'sbp_secret');
    await until(tester, () => find.byKey(const ValueKey('supabase-org')).evaluate().isNotEmpty);
    await choose(tester, 'supabase-org', 'Mine (free plan)');
    await tap(tester, 'supabase-create');
    await until(tester, () => find.byKey(const ValueKey('supabase-retry')).evaluate().isNotEmpty);
    expect(tester.widget<Text>(find.byKey(const ValueKey('supabase-error'))).data, 'Bundling the function failed.');
    expect(step(tester, SupabaseStep.liveChannel), CheckState.done);
    expect(step(tester, SupabaseStep.function), CheckState.now);
    expect(links, isEmpty);

    await tap(tester, 'supabase-retry');
    await until(tester, () => links.isNotEmpty);
    // Nothing done before runs again: one project, one migration, one signing key.
    expect(fake.count('POST /v1/projects'), 1);
    expect(fake.count('POST /v1/projects/newproject000000/config/auth/signing-keys'), 1);
    expect(fake.count('POST /v1/projects/newproject000000/functions/deploy'), 2);
    expect(Backend.fromLink(links.single)!.isSupabase, isTrue);
  });

  testWidgets('a project Supabase won’t create says why, and Create works once it would', (tester) async {
    fake.atLimit = true;
    await pumpSetup(tester);
    await paste(tester, 'sbp_secret');
    await until(tester, () => find.byKey(const ValueKey('supabase-org')).evaluate().isNotEmpty);
    await choose(tester, 'supabase-org', 'Mine (free plan)');
    await tap(tester, 'supabase-create');
    await until(tester, () => find.byKey(const ValueKey('supabase-error')).evaluate().isNotEmpty);
    expect(shows('already has the two active projects the free plan allows'), isTrue);
    expect(find.byKey(const ValueKey('supabase-step-project')), findsNothing);

    fake.atLimit = false;
    await tap(tester, 'supabase-create');
    await until(tester, () => links.isNotEmpty);
    expect(fake.created, hasLength(1));
  });

  testWidgets('an organization PocketTerm is on already offers to update that project, not to make another', (
    tester,
  ) async {
    fake.projects.add({
      'id': 'oldpocketterm000',
      'name': 'PocketTerm',
      'status': 'ACTIVE_HEALTHY',
      'organization_id': 'org-mine',
    });
    fake.ours.add('oldpocketterm000');
    await pumpSetup(tester);
    await paste(tester, 'sbp_secret');
    await until(tester, () => find.byKey(const ValueKey('supabase-org')).evaluate().isNotEmpty);
    await choose(tester, 'supabase-org', 'Mine (free plan)');
    await until(tester, () => find.byKey(const ValueKey('supabase-update')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('supabase-create')), findsNothing);
    await tap(tester, 'supabase-update');
    await until(tester, () => links.isNotEmpty);
    expect(fake.created, isEmpty);
    expect(Backend.fromLink(links.single)!.url, 'https://oldpocketterm000.supabase.co');
  });

  testWidgets('Back forgets the token', (tester) async {
    await pumpSetup(tester);
    await paste(tester, 'sbp_secret');
    await until(tester, () => find.byKey(const ValueKey('supabase-org')).evaluate().isNotEmpty);
    await tap(tester, 'setup-back');
    await tap(tester, 'supabase-new');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('supabase-token'))).controller!.text, isEmpty);
  });

  testWidgets('a second computer pastes the setup link another computer made', (tester) async {
    final link = project.linkWithSetup('s3cret');
    await pumpSetup(tester, prefs: {'setup_step': 'supabase'});
    await tap(tester, 'supabase-paste');
    await tester.enterText(find.byKey(const ValueKey('setup-link')), '$link');
    await tester.pump();
    await until(tester, () => shows('abcdefghijklmnop.supabase.co answers'));
    expect(checks.asked.single.isSupabase, isTrue);
    await tap(tester, 'setup-connect');
    await until(tester, () => links.isNotEmpty);
    expect(links.single, link);
    expect(fake.requests, isEmpty);
  });

  group('a pasted setup link', () {
    test('of a Supabase project is a computer’s; its phone link and unknown kinds say what to do', () {
      expect(setupLinkProblem('${project.linkWithSetup('s3cret')}'), isNull);
      expect(setupLinkProblem('${project.linkWithCode('K7QM-3XRT')}'), contains('Add a computer…'));
      expect(
        setupLinkProblem('pocketterm://setup?kind=mars&url=https%3A%2F%2Fpt.example.com&setup=s3cret'),
        contains('Update PocketTerm'),
      );
      expect(
        setupLinkProblem('pocketterm://setup?kind=supabase&url=nope&setup=s3cret'),
        startsWith('The server address in that link doesn’t work.'),
      );
      // A PocketTerm server's link still works, and its phone link still names the server's command.
      expect(setupLinkProblem('${const Backend(url: 'https://pt.example.com').linkWithSetup('s3cret')}'), isNull);
      expect(
        setupLinkProblem('pocketterm://setup?url=https%3A%2F%2Fpt.example.com&code=K7QM-3XRT'),
        contains('pocketterm-server setup-link'),
      );
    });
  });

  group('Settings, Account, on a Supabase project', () {
    Future<(FakeApp, FakeSupabaseServer)> pumpAccount(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(900, 1600)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = FakeSupabaseServer(project);
      addTearDown(server.close);
      final app = await FakeApp.create()
        ..fakeBackend = project
        ..fakeServer = server;
      await tester.pumpWidget(window(SettingsPage(app: app)));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('settings-tab-account')));
      await tester.pumpAndSettle();
      return (app, server);
    }

    testWidgets('names Supabase, and Add a computer shows a new setup link', (tester) async {
      final (_, server) = await pumpAccount(tester);
      expect(shows('Signed in to your Supabase project'), isTrue);
      expect(shows('Supabase, abcdefghijklmnop.supabase.co'), isTrue);

      await tap(tester, 'settings-add-computer');
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(find.byKey(const ValueKey('add-computer-link'))).data,
        '${project.linkWithSetup('token-1')}',
      );
      expect(shows('choose Supabase, then Paste a setup link'), isTrue);
      expect(shows('stops working'), isTrue);
      expect(server.made, 1);
    });

    testWidgets('a link the project refuses to make says why', (tester) async {
      final (_, server) = await pumpAccount(tester);
      server.fails = const ServerException(0, 'offline', 'Can’t reach abcdefghijklmnop.supabase.co.');
      await tap(tester, 'settings-add-computer');
      await tester.pump();
      expect(shows('No link: Can’t reach abcdefghijklmnop.supabase.co.'), isTrue);
      expect(find.byKey(const ValueKey('add-computer-link')), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });

  test('the live channel key is a P-256 key pair: x and y are d·G, 32 bytes each, its kid a UUID', () {
    final jwk = newLiveSigningKey();
    expect(jwk, containsPair('kty', 'EC'));
    expect(jwk, containsPair('crv', 'P-256'));
    expect(jwk, containsPair('alg', 'ES256'));
    Uint8List bytes(String name) => base64Url.decode(base64Url.normalize(jwk[name]! as String));
    BigInt number(Uint8List b) => b.fold(BigInt.zero, (n, byte) => (n << 8) | BigInt.from(byte));
    final (x, y, d) = (bytes('x'), bytes('y'), bytes('d'));
    expect([x.length, y.length, d.length], [32, 32, 32]);
    final q = (pc.ECCurve_secp256r1().G * number(d))!;
    expect(number(x), q.x!.toBigInteger());
    expect(number(y), q.y!.toBigInteger());
    expect(jwk['kid'], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(newLiveSigningKey()['kid'], isNot(jwk['kid']));
  });
}
