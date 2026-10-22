import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_desktop/setup_page.dart';
import 'package:pocketterm_server/pocketterm_server.dart';

import 'app_fakes.dart';

/// What the window shows once this computer is signed in.
const ValueKey<String> signedIn = ValueKey('signed-in');

void main() {
  late Directory dir;
  late FakeTailscale fake;

  setUp(() {
    // The real server on 127.0.0.1 some of these sign in to.
    HttpOverrides.global = null;
    dir = Directory.systemTemp.createTempSync('pocketterm-setup');
    fake = FakeTailscale(installed: true);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// The setup of a computer with no server yet, Session's own sign-in; signed in, the window moves on.
  Future<FakeApp> pumpSetup(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(900, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = await FakeApp.create(tailscale: fake.tailscale, serverDir: dir, real: true);
    await tester.pumpWidget(
      window(
        ListenableBuilder(
          listenable: app,
          builder: (_, _) =>
              app.user == null ? SetupPage(app: app, poll: Duration.zero) : const Text('Signed in', key: signedIn),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  /// Stops what a signed-in app keeps running: the built-in server, the server connection.
  Future<void> finish(WidgetTester tester, FakeApp app) async {
    await tester.runAsync(() async => await app.hosting?.stop());
    app.server?.close();
    await tester.pump();
  }

  /// Lets real I/O (the server, sockets) and the window take turns until [done] holds, 5 seconds at most.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 250 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pump();
  }

  bool startEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const ValueKey('setup-start-server'))).onPressed != null;

  Future<void> openThisComputer(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('setup-this-computer')));
    await tester.pump();
    await until(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
  }

  group('This computer', () {
    testWidgets('without Tailscale: Install, and nothing to start yet', (tester) async {
      fake.installed = false;
      await pumpSetup(tester);
      await openThisComputer(tester);
      expect(find.text('Install Tailscale'), findsOneWidget);
      expect(startEnabled(tester), isFalse);
    });

    testWidgets('signed out of Tailscale: Open Tailscale opens its app', (tester) async {
      fake.backendState = 'NeedsLogin';
      await pumpSetup(tester);
      await openThisComputer(tester);
      expect(startEnabled(tester), isFalse);
      await tester.tap(find.text('Open Tailscale'));
      await until(tester, () => fake.calls.contains('-a Tailscale'));
      expect(fake.calls, contains('-a Tailscale'));
    });

    testWidgets('HTTPS off for the tailnet: it says where to turn it on, and the server can start', (tester) async {
      fake.https = false;
      await pumpSetup(tester);
      await openThisComputer(tester);
      expect(find.text('Turn on HTTPS…'), findsOneWidget);
      expect(startEnabled(tester), isTrue);
    });

    testWidgets('Start the server signs this computer in to it, and the setup is done', (tester) async {
      final app = await pumpSetup(tester);
      await openThisComputer(tester);
      expect(startEnabled(tester), isTrue);
      await tester.tap(find.byKey(const ValueKey('setup-start-server')));
      await until(tester, () => app.user != null);
      expect(app.hostsServer, isTrue);
      expect(find.byKey(signedIn), findsOneWidget);
      await finish(tester, app);
    });
  });

  group('Your own server', () {
    late PocketTermServer server;

    setUp(() async {
      server = await PocketTermServer.start(
        dataDir: Directory('${dir.path}/vps')..createSync(),
        address: InternetAddress.loopbackIPv4,
        port: 0,
        publicUrl: Uri.parse('http://127.0.0.1'),
      );
    });
    tearDown(() => server.stop());

    /// The server's setup link, at its port.
    Uri setupLink() => PocketTermServer.setupLinkFor(Directory('${dir.path}/vps'), server.url);

    Future<FakeApp> connect(WidgetTester tester, String link) async {
      final app = await pumpSetup(tester);
      await tester.tap(find.byKey(const ValueKey('setup-own-server')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('setup-link')), link);
      await tester.tap(find.byKey(const ValueKey('setup-connect')));
      await tester.pump();
      final button = find.byKey(const ValueKey('setup-connect'));
      await until(tester, () => button.evaluate().isEmpty || tester.widget<FilledButton>(button).onPressed != null);
      return app;
    }

    testWidgets('its setup link signs this computer in', (tester) async {
      final app = await connect(tester, '${setupLink()}');
      expect(app.user, isNotNull);
      expect(app.user!.device.role, DeviceRole.desktop);
      expect(app.hostsServer, isFalse);
      expect(find.byKey(signedIn), findsOneWidget);
      await finish(tester, app);
    });

    testWidgets('a replaced setup link stays on the form, saying why, with nothing kept', (tester) async {
      final old = setupLink();
      PocketTermServer.setupLinkFor(Directory('${dir.path}/vps'), server.url, replace: true);
      final app = await connect(tester, '$old');
      expect(app.user, isNull);
      expect(app.backend, isNull);
      expect(find.byKey(const ValueKey('setup-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-link')), findsOneWidget);
    });

    testWidgets("a phone's code or other text isn't a computer's setup link", (tester) async {
      final app = await connect(tester, 'https://pt.example.com');
      expect(find.byKey(const ValueKey('setup-error')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('setup-link')),
        'pocketterm://setup?url=${Uri.encodeQueryComponent('${server.url}')}&code=K7QM-3XRT',
      );
      await tester.tap(find.byKey(const ValueKey('setup-connect')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('setup-error')), findsOneWidget);
      expect(app.backend, isNull);
    });
  });
}
