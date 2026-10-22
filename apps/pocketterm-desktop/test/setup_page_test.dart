import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_desktop/commands.dart';
import 'package:pocketterm_desktop/hosting/vps.dart';
import 'package:pocketterm_desktop/onboarding/commands_view.dart';
import 'package:pocketterm_desktop/setup_page.dart';
import 'package:pocketterm_server/pocketterm_server.dart';

import 'app_fakes.dart';

/// What the window shows once this computer is signed in.
const ValueKey<String> signedIn = ValueKey('signed-in');

/// How often the live checks look again in these tests.
const poll = Duration(seconds: 1);

/// A VPS as the checks see it: its name resolves and HTTPS answers when
/// the test says so; its health is the real [server]'s.
class FakeChecks extends ServerChecks {
  FakeChecks(this.server);
  final Uri server;
  bool resolvesNow = false;
  bool httpsNow = false;

  /// The names asked about, in order.
  final asked = <String>[];

  @override
  Future<bool> resolves(String domain) async {
    asked.add(domain);
    return resolvesNow;
  }

  @override
  Future<bool> https(String domain) async => httpsNow;

  @override
  Backend backendFor(String domain) => Backend(url: '$server'.replaceFirst(RegExp(r'/$'), ''));
}

void main() {
  late Directory dir;
  late FakeTailscale fake;
  late PocketTermServer server;
  late FakeChecks checks;

  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'PocketTerm',
      packageName: 'com.danyzmaj.pocketterm',
      version: '0.3.0',
      buildNumber: '1',
      buildSignature: '',
    );
    // The real servers on 127.0.0.1 some of these sign in to.
    HttpOverrides.global = null;
    dir = Directory.systemTemp.createTempSync('pocketterm-setup');
    fake = FakeTailscale(installed: true);
    // The VPS: the real server on an ephemeral port.
    server = await PocketTermServer.start(
      dataDir: Directory('${dir.path}/vps')..createSync(),
      address: InternetAddress.loopbackIPv4,
      port: 0,
      publicUrl: Uri.parse('http://127.0.0.1'),
    );
    checks = FakeChecks(server.url);
  });
  tearDown(() async {
    await server.stop();
    dir.deleteSync(recursive: true);
  });

  /// The VPS's setup link, at its port.
  Uri setupLink() => PocketTermServer.setupLinkFor(Directory('${dir.path}/vps'), server.url);

  /// The links the setup opened in the browser.
  late List<String> opened;

  /// The setup of a computer with no server yet, Session's own sign-in; signed in, the window moves on.
  Future<FakeApp> pumpSetup(WidgetTester tester, {Map<String, Object> prefs = const {}, Commands? commands}) async {
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
    final app = await FakeApp.create(
      tailscale: fake.tailscale,
      serverDir: dir,
      real: true,
      prefs: prefs,
      commands: commands,
    );
    await tester.pumpWidget(window(_Setup(app: app, checks: checks)));
    await tester.pump();
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

  /// The next look of the live checks, and what it found.
  Future<void> nextLook(WidgetTester tester, bool Function() done) async {
    await tester.pump(poll);
    await until(tester, done);
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
  }

  CheckState check(WidgetTester tester, String key) => tester.widget<SetupCheck>(find.byKey(ValueKey(key))).state;
  bool shows(String text) => find.text(text).evaluate().isNotEmpty;
  bool startEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const ValueKey('setup-start-server'))).onPressed != null;

  testWidgets('each choice opens its branch, Back goes up one screen, and the place is kept', (tester) async {
    final app = await pumpSetup(tester);
    expect(shows('On this computer'), isTrue);
    // How your data is protected, folded until asked.
    expect(shows('Encrypted from end to end'), isFalse);
    await tester.tap(find.text('How your data is protected'));
    await tester.pump();
    expect(shows('Encrypted from end to end'), isTrue);
    await tap(tester, 'setup-own-server');
    expect(shows('Do you already have a PocketTerm server?'), isTrue);
    await tap(tester, 'setup-have-server');
    expect(find.byKey(const ValueKey('setup-link')), findsOneWidget);
    await tap(tester, 'setup-back');
    await tap(tester, 'setup-new-server');
    await tester.enterText(find.byKey(const ValueKey('setup-address')), '203.0.113.7');
    await tester.pump();

    // Leaving and coming back (the window rebuilt, the app relaunched) opens the same screen, address kept.
    await tester.pumpWidget(window(_Setup(app: app, checks: checks, key: UniqueKey())));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('setup-address'))).controller!.text, '203.0.113.7');
    await tap(tester, 'setup-back');
    expect(shows('Do you already have a PocketTerm server?'), isTrue);
    await tap(tester, 'setup-back');
    await tap(tester, 'setup-this-computer');
    await tester.pumpWidget(window(_Setup(app: app, checks: checks, key: UniqueKey())));
    await tester.pump();
    expect(find.byKey(const ValueKey('check-installed')), findsOneWidget);
    expect(app.setupStep, 'thisComputer');
  });

  group('On this computer', () {
    testWidgets('the checklist follows Tailscale, one action at a time, then Start signs this computer in', (
      tester,
    ) async {
      fake.installed = false;
      final app = await pumpSetup(tester, prefs: {'setup_step': 'thisComputer'});
      await until(tester, () => check(tester, 'check-installed') != CheckState.looking);
      expect(check(tester, 'check-installed'), CheckState.now);
      expect(shows('Install Tailscale'), isTrue);
      expect(shows('Open Tailscale'), isFalse);
      expect(startEnabled(tester), isFalse);
      // The phone needs it too, from the start.
      expect(find.byKey(const ValueKey('setup-phone-tailscale')), findsOneWidget);

      // Installed, but its service isn't running.
      fake
        ..installed = true
        ..daemon = false;
      await nextLook(tester, () => check(tester, 'check-installed') == CheckState.done);
      expect(check(tester, 'check-running'), CheckState.now);
      expect(shows('Install Tailscale'), isFalse);
      expect(shows('Open Tailscale'), isTrue);
      expect(check(tester, 'check-signed-in'), CheckState.later);

      fake
        ..daemon = true
        ..backendState = 'NeedsLogin';
      await nextLook(tester, () => check(tester, 'check-running') == CheckState.done);
      expect(check(tester, 'check-signed-in'), CheckState.now);
      await tester.tap(find.text('Open Tailscale to sign in'));
      await until(tester, () => fake.calls.contains('-a Tailscale'));
      expect(fake.calls, contains('-a Tailscale'));

      // Signed in, HTTPS off for the tailnet: the page `tailscale serve` names turns it on.
      fake
        ..backendState = 'Running'
        ..https = false;
      await nextLook(tester, () => check(tester, 'check-signed-in') == CheckState.done);
      expect(check(tester, 'check-https'), CheckState.now);
      expect(startEnabled(tester), isFalse);
      await tap(tester, 'setup-turn-on-https');
      await until(tester, () => opened.isNotEmpty);
      expect(opened, [FakeTailscale.enableLink]);
      expect(fake.running.single.killed, isTrue);

      fake.https = true;
      await nextLook(tester, () => check(tester, 'check-https') == CheckState.done);
      expect(startEnabled(tester), isTrue);
      await tap(tester, 'setup-start-server');
      await until(tester, () => app.user != null);
      expect(app.hostsServer, isTrue);
      expect(find.byKey(signedIn), findsOneWidget);
      await finish(tester, app);
    });

    testWidgets('with Homebrew, Install Tailscale shows its command and runs it only after Run', (tester) async {
      fake.installed = false;
      final brew = FakeCommands(brew: '/opt/homebrew/bin/brew')
        ..result = (code: 1, output: '==> Installing tailscale-app\nError: Failure while executing installer\n');
      await pumpSetup(tester, prefs: {'setup_step': 'thisComputer'}, commands: brew.commands);
      await until(tester, () => check(tester, 'check-installed') == CheckState.now);
      expect(find.text('Download instead'), findsOneWidget);

      Future<void> confirm({required bool run}) async {
        await tester.tap(find.byKey(const ValueKey('command-tailscale-app')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          tester.widget<SelectableText>(find.byKey(const ValueKey('command-shown'))).data,
          'brew install --cask tailscale-app',
        );
        await tester.tap(run ? find.byKey(const ValueKey('command-run')) : find.text('Cancel'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      await confirm(run: false);
      expect(brew.calls, isEmpty);

      await confirm(run: true);
      expect(brew.calls, ['/opt/homebrew/bin/brew install --cask tailscale-app']);
      // The installer's sudo asks through macOS's own password dialog.
      final askpass = brew.envs.single['SUDO_ASKPASS']!;
      addTearDown(() => File(askpass).parent.deleteSync(recursive: true));
      expect(File(askpass).readAsStringSync(), contains('display dialog'));
      expect(find.textContaining('Error: Failure while executing installer'), findsOneWidget);

      // Try again, and it works: the checklist moves on to starting Tailscale.
      brew.result = (code: 0, output: '');
      fake
        ..installed = true
        ..daemon = false;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('command-run')));
      await tester.pump();
      await until(tester, () => check(tester, 'check-installed') == CheckState.done);
      expect(brew.calls, hasLength(2));
      expect(check(tester, 'check-running'), CheckState.now);
      File(brew.envs.last['SUDO_ASKPASS']!).parent.deleteSync(recursive: true);
    });
  });

  group('On my own server, I have one', () {
    Future<FakeApp> paste(WidgetTester tester, String link) async {
      final app = await pumpSetup(tester, prefs: {'setup_step': 'haveServer'});
      await tester.enterText(find.byKey(const ValueKey('setup-link')), link);
      await tester.pump();
      return app;
    }

    Future<void> connect(WidgetTester tester) async {
      await tap(tester, 'setup-connect');
      final button = find.byKey(const ValueKey('setup-connect'));
      await until(tester, () => button.evaluate().isEmpty || tester.widget<FilledButton>(button).onPressed != null);
    }

    String error(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('setup-error'))).data!;

    testWidgets('its setup link is checked as it is pasted, and signs this computer in', (tester) async {
      final app = await paste(tester, '${setupLink()}');
      await until(tester, () => shows('127.0.0.1 answers'));
      expect(shows('127.0.0.1 answers'), isTrue);
      await connect(tester);
      expect(app.user!.device.role, DeviceRole.desktop);
      expect(app.hostsServer, isFalse);
      expect(find.byKey(signedIn), findsOneWidget);
      await finish(tester, app);
    });

    testWidgets('a replaced setup link stays on the form, saying why, with nothing kept', (tester) async {
      final old = setupLink();
      PocketTermServer.setupLinkFor(Directory('${dir.path}/vps'), server.url, replace: true);
      final app = await paste(tester, '$old');
      await connect(tester);
      expect(app.user, isNull);
      expect(app.backend, isNull);
      expect(error(tester), contains('the server has a newer one'));
    });

    testWidgets('other text, a phone’s link and a server that doesn’t answer each say what’s wrong', (tester) async {
      final app = await paste(tester, 'https://pt.example.com');
      expect(error(tester), startsWith('That isn’t a setup link'));

      await tester.enterText(
        find.byKey(const ValueKey('setup-link')),
        'pocketterm://setup?url=${Uri.encodeQueryComponent('${server.url}')}&code=K7QM-3XRT',
      );
      await tester.pump();
      expect(error(tester), startsWith('That link signs in a phone'));
      await connect(tester);
      expect(error(tester), startsWith('That link signs in a phone'));

      // Nothing listens there any more.
      final gone = setupLink();
      await tester.runAsync(server.stop);
      await tester.enterText(find.byKey(const ValueKey('setup-link')), '$gone');
      await tester.pump();
      expect(find.byKey(const ValueKey('setup-error')), findsNothing);
      await until(tester, () => find.byKey(const ValueKey('setup-error')).evaluate().isNotEmpty);
      expect(error(tester), contains('reach 127.0.0.1'));
      await connect(tester);
      expect(error(tester), contains('reach 127.0.0.1'));
      expect(app.backend, isNull);
    });
  });

  group('On my own server, not yet', () {
    testWidgets('commands follow the address, and the checks turn green as the server comes up', (tester) async {
      final app = await pumpSetup(tester, prefs: {'setup_step': 'newServer'});
      await tester.enterText(find.byKey(const ValueKey('setup-address')), '2001:db8::7');
      await tester.pump();
      expect(find.byKey(const ValueKey('setup-address-error')), findsOneWidget);
      expect(find.byKey(const ValueKey('setup-command-0')), findsNothing);

      await tester.enterText(find.byKey(const ValueKey('setup-address')), '203.0.113.7');
      await until(tester, () => checks.asked.isNotEmpty);
      expect(checks.asked, ['203-0-113-7.sslip.io']);
      expect(
        tester.widget<CopyCommand>(find.byKey(const ValueKey('setup-command-2'))).command,
        'cd ~/pocketterm && echo "DOMAIN=203-0-113-7.sslip.io" > .env && sudo docker compose up -d',
      );
      expect(
        tester.widget<CopyCommand>(find.byKey(const ValueKey('setup-command-1'))).command,
        endsWith(composeUrl('0.3.0')),
      );
      expect(check(tester, 'check-dns'), CheckState.now);
      expect(check(tester, 'check-https'), CheckState.later);
      expect(find.byKey(const ValueKey('setup-link')), findsNothing);

      checks.resolvesNow = true;
      await nextLook(tester, () => check(tester, 'check-dns') == CheckState.done);
      expect(check(tester, 'check-https'), CheckState.now);
      expect(check(tester, 'check-health'), CheckState.later);

      // Caddy has its certificate; the server behind it answers its health.
      checks.httpsNow = true;
      await nextLook(tester, () => check(tester, 'check-health') == CheckState.done);
      expect(check(tester, 'check-https'), CheckState.done);
      expect(check(tester, 'check-health'), CheckState.done);

      // Healthy: the paste box, and the link setup-link printed signs in.
      await tester.enterText(find.byKey(const ValueKey('setup-link')), '${setupLink()}');
      await tester.pump();
      await tap(tester, 'setup-connect');
      await until(tester, () => app.user != null);
      expect(find.byKey(signedIn), findsOneWidget);
      await finish(tester, app);
    });
  });

  group('server address', () {
    test('an IPv4 address becomes its sslip.io name; a domain stays as it is', () {
      expect(ServerAddress.parse(' 203.0.113.7 ').domain, '203-0-113-7.sslip.io');
      expect(ServerAddress.parse('https://51.75.10.2/').domain, '51-75-10-2.sslip.io');
      expect(ServerAddress.parse('PocketTerm.Example.com').domain, 'pocketterm.example.com');
      expect(ServerAddress.parse('https://pt.example.com/v1').domain, 'pt.example.com');
    });

    test('IPv6, private addresses, ports and other text are refused, saying why', () {
      for (final (typed, why) in [
        ('2001:db8::7', 'IPv4'),
        ('[2001:db8::7]', 'IPv4'),
        ('192.168.1.20', 'private'),
        ('10.0.0.5', 'private'),
        ('100.101.102.103', 'private'),
        ('127.0.0.1', 'private'),
        ('203.0.113.7:443', 'port'),
        ('pt.example.com:8443', 'port'),
        ('my server', 'isn’t an IP address'),
        ('localhost', 'isn’t an IP address'),
        ('', 'Enter'),
      ]) {
        final a = ServerAddress.parse(typed);
        expect(a.domain, isNull, reason: typed);
        expect(a.error, contains(why), reason: typed);
      }
    });

    test('the commands install Docker, fetch the compose file of this release, start it, print the link', () {
      expect(vpsCommands('pt.example.com', '0.3.0').map((c) => c.command), [
        'curl -fsSL https://get.docker.com | sudo sh',
        'mkdir -p ~/pocketterm && cd ~/pocketterm && curl -fsSLO ${composeUrl('0.3.0')}',
        'cd ~/pocketterm && echo "DOMAIN=pt.example.com" > .env && sudo docker compose up -d',
        'cd ~/pocketterm && sudo docker compose exec server pocketterm-server setup-link',
      ]);
      final compose = Uri.parse(composeUrl('0.3.0'));
      expect(compose.host, 'raw.githubusercontent.com');
      expect(compose.path, '/danyzmaj-apps/pocketterm/v0.3.0/apps/pocketterm-server/docker-compose.yml');
    });
  });
}

/// The setup until this computer is signed in, as the main window has it.
class _Setup extends StatelessWidget {
  const _Setup({required this.app, required this.checks, super.key});
  final FakeApp app;
  final ServerChecks checks;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (_, _) =>
        app.user == null ? SetupPage(app: app, poll: poll, checks: checks) : const Text('Signed in', key: signedIn),
  );
}
