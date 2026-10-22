import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_desktop/hosting/built_in_server.dart';
import 'package:pocketterm_desktop/hosting/tailscale.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_fakes.dart';

/// Whether anything answers on 127.0.0.1:[port].
Future<bool> listening(int port) async {
  try {
    (await Socket.connect(InternetAddress.loopbackIPv4, port)).destroy();
    return true;
  } on SocketException {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These talk to a real server on 127.0.0.1, which flutter_test's own HttpClient wouldn't reach.
  setUp(() => HttpOverrides.global = null);

  group('Tailscale CLI', () {
    test('found in the Mac app first, then on the PATH or in Homebrew; Windows has its own', () {
      bool only(Set<String> files, String path) => files.contains(path);
      expect(
        Tailscale.findCli(env: {'PATH': '/usr/bin'}, exists: (f) => only({Tailscale.macCli, '/usr/bin/tailscale'}, f)),
        Tailscale.macCli,
      );
      expect(
        Tailscale.findCli(env: {'PATH': '/usr/bin:/bin'}, exists: (f) => only({'/bin/tailscale'}, f), windows: false),
        '/bin/tailscale',
      );
      expect(
        Tailscale.findCli(env: {'PATH': '/usr/bin'}, exists: (f) => only({'/opt/homebrew/bin/tailscale'}, f)),
        '/opt/homebrew/bin/tailscale',
      );
      const programs = r'C:\Program Files';
      expect(
        Tailscale.findCli(
          env: {'PATH': r'C:\Windows', 'ProgramFiles': programs},
          exists: (f) => only({Tailscale.windowsCli(programs)}, f),
          windows: true,
        ),
        r'C:\Program Files\Tailscale\tailscale.exe',
      );
      // Program Files on another drive.
      expect(
        Tailscale.findCli(
          env: {'PATH': r'C:\Windows', 'ProgramFiles': r'D:\Program Files'},
          exists: (f) => only({r'D:\Program Files\Tailscale\tailscale.exe'}, f),
          windows: true,
        ),
        r'D:\Program Files\Tailscale\tailscale.exe',
      );
      expect(Tailscale.findCli(env: {'PATH': '/usr/bin'}, exists: (_) => false, windows: false), isNull);
    });

    test('not installed, its service not running, signed out, running', () async {
      final fake = FakeTailscale();
      expect((await fake.tailscale.status()).state, TailscaleState.missing);
      expect(fake.calls, isEmpty);

      fake
        ..installed = true
        ..daemon = false;
      expect((await fake.tailscale.status()).state, TailscaleState.stopped);

      fake
        ..daemon = true
        ..backendState = 'NeedsLogin';
      expect((await fake.tailscale.status()).state, TailscaleState.loggedOut);

      fake.backendState = 'Stopped';
      expect((await fake.tailscale.status()).state, TailscaleState.stopped);

      fake.backendState = 'Running';
      final running = await fake.tailscale.status();
      expect(running.state, TailscaleState.running);
      expect(running.dnsName, 'mac.tail1234.ts.net');
      expect(running.url, Uri.parse('https://mac.tail1234.ts.net'));
      expect(running.https, isTrue);

      fake.https = false;
      expect((await fake.tailscale.status()).https, isFalse);
    });

    test(
      'serve on a tailnet with HTTPS off answers with the page that turns it on, without waiting on the CLI',
      () async {
        final fake = FakeTailscale(installed: true, https: false);
        final result = await fake.tailscale.serve(47900).timeout(const Duration(seconds: 5));
        expect(result.ok, isFalse);
        expect(result.enableLink, Uri.parse(FakeTailscale.enableLink));
        expect(fake.running.single.killed, isTrue);
      },
    );

    test('serve publishes 127.0.0.1 at the port on HTTPS 443, in the background', () async {
      final fake = FakeTailscale(installed: true);
      expect((await fake.tailscale.serve(47901)).ok, isTrue);
      expect(fake.calls, ['serve status --json', 'serve --bg --https=443 http://127.0.0.1:47901']);
      await fake.tailscale.unserve(47901);
      expect(fake.calls.last, 'serve --https=443 off');
    });

    test('what else Serve publishes on 443 is told apart from the built-in server', () {
      String? at(Map<String, Object?> config, {Set<int> ours = const {47900}}) =>
          Tailscale.servedElsewhere(jsonEncode(config), ours);
      Map<String, Object?> web(Map<String, Object?> handlers) => {
        'TCP': {
          '443': {'HTTPS': true},
        },
        'Web': {
          'mac.tail1234.ts.net:443': {'Handlers': handlers},
        },
      };
      expect(at({}), isNull);
      expect(Tailscale.servedElsewhere('not json', const {47900}), isNull);
      // This app's, from this run or the one before, whose port moved.
      expect(
        at(
          web({
            '/': {'Proxy': 'http://127.0.0.1:47900'},
          }),
        ),
        isNull,
      );
      expect(
        at(
          web({
            '/': {'Proxy': 'http://127.0.0.1:47900'},
          }),
          ours: const {47901, 47900},
        ),
        isNull,
      );
      // Another PocketTerm's on this Mac (another user, another copy), though on a port of the same range.
      expect(
        at(
          web({
            '/': {'Proxy': 'http://127.0.0.1:47900'},
          }),
          ours: const {47901},
        ),
        'http://127.0.0.1:47900',
      );
      expect(
        at(
          web({
            '/': {'Proxy': 'http://127.0.0.1:47900'},
          }),
          ours: const {},
        ),
        'http://127.0.0.1:47900',
      );
      expect(
        at(
          web({
            '/': {'Proxy': 'http://127.0.0.1:3000'},
          }),
        ),
        'http://127.0.0.1:3000',
      );
      expect(
        at(
          web({
            '/': {'Proxy': 'http://127.0.0.1:47900'},
            '/grafana': {'Proxy': 'http://127.0.0.1:3000'},
          }),
        ),
        'http://127.0.0.1:3000 at /grafana',
      );
      expect(
        at({
          'TCP': {
            '443': {'TCPForward': '127.0.0.1:22'},
          },
        }),
        'a TCP forward to 127.0.0.1:22',
      );
      // Another port of the tailnet name is no business of this one.
      expect(
        at({
          'Web': {
            'mac.tail1234.ts.net:8443': {
              'Handlers': {
                '/': {'Proxy': 'http://127.0.0.1:3000'},
              },
            },
          },
        }),
        isNull,
      );
      // A `tailscale serve` running in a terminal (not --bg).
      expect(
        at({
          'Foreground': {
            'session1': web({
              '/': {'Path': '/Users/me/site'},
            }),
          },
        }),
        '/Users/me/site',
      );
    });

    test('serve leaves what else Serve publishes on 443 alone, and so does unserve', () async {
      final fake = FakeTailscale(installed: true)..serving('http://127.0.0.1:3000');
      final result = await fake.tailscale.serve(47900);
      expect(result.ok, isFalse);
      expect(result.taken, 'http://127.0.0.1:3000');
      expect(fake.calls.where((c) => c.startsWith('serve --')), isEmpty);

      await fake.tailscale.unserve(47900);
      expect(fake.calls, isNot(contains('serve --https=443 off')));
    });

    test("the open source build's operator rule says how to let PocketTerm in", () {
      expect(
        Tailscale.serveError('Access denied: serve config denied\nUse sudo or set operator\n'),
        contains('--operator'),
      );
      expect(Tailscale.serveError('first\nsomething broke\n\n'), 'something broke');
    });
  });

  group('the built-in server', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pocketterm-host'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<BuiltInServer> host(FakeTailscale fake) async {
      final server = BuiltInServer(
        dataDir: dir,
        tailscale: fake.tailscale,
        recheck: Duration.zero,
        recheckReady: Duration.zero,
      );
      addTearDown(server.stop);
      await server.start(port: 0);
      await server.refresh();
      return server;
    }

    test('without Tailscale it still runs on 127.0.0.1, with nothing to hand out', () async {
      final server = await host(FakeTailscale());
      expect(server.state, HostState.noTailscale);
      expect(await Backend(url: server.backend.url).check(), isNull);
      expect(server.publicUrl, isNull);
      expect(server.setupLink(), isNull);
    });

    test('signed out of Tailscale, it says so and serves nothing', () async {
      final fake = FakeTailscale(installed: true, backendState: 'NeedsLogin');
      final server = await host(fake);
      expect(server.state, HostState.loggedOut);
      expect(fake.calls.where((c) => c.startsWith('serve')), isEmpty);
    });

    test('HTTPS off: the page that turns it on; once on, Tailscale serves it at its ts.net name', () async {
      final fake = FakeTailscale(installed: true, https: false);
      final server = await host(fake);
      expect(server.state, HostState.httpsOff);
      expect(server.enableHttps, Uri.parse(FakeTailscale.enableLink));
      expect(server.publicUrl, isNull);

      fake.https = true;
      await server.refresh();
      expect(server.state, HostState.ready);
      expect(server.publicUrl, Uri.parse('https://mac.tail1234.ts.net'));
      expect(fake.calls.last, 'serve --bg --https=443 http://127.0.0.1:${server.port}');

      // Looking again doesn't serve again.
      final served = fake.calls.where((c) => c.startsWith('serve --bg')).length;
      await server.refresh();
      expect(fake.calls.where((c) => c.startsWith('serve --bg')).length, served);
    });

    test('stopping takes it off the tailnet and closes the port', () async {
      final fake = FakeTailscale(installed: true);
      final server = await host(fake);
      final port = server.port;
      expect(server.state, HostState.ready);
      await server.stop();
      expect(fake.calls.last, 'serve --https=443 off');
      expect(await listening(port), isFalse);
    });

    test('a taken port moves it to the next one', () async {
      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(taken.close);
      final server = BuiltInServer(dataDir: dir, tailscale: FakeTailscale().tailscale, recheck: Duration.zero);
      addTearDown(server.stop);
      await server.start(port: taken.port);
      expect(server.port, greaterThan(taken.port));
    });

    test('something else on 443 stays: the server says so and serves nothing, until it goes', () async {
      final fake = FakeTailscale(installed: true)..serving('http://127.0.0.1:3000');
      final server = await host(fake);
      expect(server.state, HostState.taken);
      expect(server.error, contains('http://127.0.0.1:3000'));
      expect(server.publicUrl, isNull);
      expect(server.setupLink(), isNull);

      fake.serveConfig = {};
      await server.refresh();
      expect(server.state, HostState.ready);
    });

    test('something else taking 443 later shows, and stopping leaves it there', () async {
      final fake = FakeTailscale(installed: true);
      final server = await host(fake);
      expect(server.state, HostState.ready);

      fake.serving('http://127.0.0.1:8080');
      await server.refresh();
      expect(server.state, HostState.taken);
      expect(server.publicUrl, isNull);
      await server.stop();
      expect(fake.serveConfig, isNotEmpty);
    });

    test("another PocketTerm's entry (another user, another copy) is taken on a first start, and stays", () async {
      final fake = FakeTailscale(installed: true)..serving('http://127.0.0.1:47900');
      final server = await host(fake);
      expect(server.state, HostState.taken);
      expect(server.error, contains('http://127.0.0.1:47900'));
      expect(fake.calls.where((c) => c.startsWith('serve --')), isEmpty);
      await server.stop();
      expect(fake.calls, isNot(contains('serve --https=443 off')));
      expect(jsonEncode(fake.serveConfig), contains('http://127.0.0.1:47900'));
    });

    test('its own entry from last time moves to the port it has now', () async {
      final fake = FakeTailscale(installed: true)..serving('http://127.0.0.1:47950');
      final server = BuiltInServer(dataDir: dir, tailscale: fake.tailscale, recheck: Duration.zero);
      addTearDown(server.stop);
      await server.start(port: 0, earlier: 47950);
      await server.refresh();
      expect(server.state, HostState.ready);
      expect(fake.calls.last, 'serve --bg --https=443 http://127.0.0.1:${server.port}');
    });

    test('Tailscale stopping later takes it off; back on, it serves again', () async {
      final fake = FakeTailscale(installed: true);
      final server = await host(fake);
      expect(server.state, HostState.ready);
      fake.backendState = 'Stopped';
      await server.refresh();
      expect(server.state, HostState.tailscaleOff);
      expect(server.publicUrl, isNull);
      fake.backendState = 'Running';
      await server.refresh();
      expect(server.state, HostState.ready);
    });

    test('a new Tailscale name moves it there and is remembered, also after a restart, until seen', () async {
      final fake = FakeTailscale(installed: true);
      final server = await host(fake);
      expect(server.renamedFrom, isNull);

      fake.dnsName = 'studio.tail1234.ts.net';
      await server.refresh();
      expect(server.publicUrl, Uri.parse('https://studio.tail1234.ts.net'));
      expect(Backend.fromLink(server.setupLink()!)!.url, 'https://studio.tail1234.ts.net');
      expect(server.renamedFrom, Uri.parse('https://mac.tail1234.ts.net'));

      // Renamed again: the phones still have the first one.
      fake.dnsName = 'office.tail1234.ts.net';
      await server.refresh();
      expect(server.renamedFrom, Uri.parse('https://mac.tail1234.ts.net'));

      await server.stop();
      final again = await host(fake);
      expect(again.renamedFrom, Uri.parse('https://mac.tail1234.ts.net'));

      // Back at the first name: the phones' address works again.
      fake.dnsName = 'mac.tail1234.ts.net';
      await again.refresh();
      expect(again.renamedFrom, isNull);

      fake.dnsName = 'studio.tail1234.ts.net';
      await again.refresh();
      expect(again.renamedFrom, isNotNull);
      again.renameSeen();
      expect(again.renamedFrom, isNull);
    });
  });

  group('This computer', () {
    late Directory dir;
    late FakeTailscale fake;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('pocketterm-host');
      fake = FakeTailscale(installed: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
        ..setMockStreamHandler(
          const EventChannel('com.llfbandit.app_links/events'),
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<FakeApp> app({Map<String, Object> prefs = const {}}) async {
      final app = await FakeApp.create(prefs: prefs, tailscale: fake.tailscale, serverDir: dir, real: true);
      addTearDown(() => app.hosting?.stop());
      return app;
    }

    test('starting the server signs this computer in to it, on 127.0.0.1', () async {
      final a = await app();
      await a.startHosting();
      expect(a.user, isNotNull);
      expect(a.user!.device.role, DeviceRole.desktop);
      expect(a.hostsServer, isTrue);
      expect(a.backend, a.hosting!.backend);
      expect(Uri.parse(a.backend!.url).host, '127.0.0.1');
    });

    test("a phone's code carries the ts.net address, and its code signs a phone in", () async {
      final a = await app();
      await a.startHosting();
      await a.hosting!.refresh();
      final link = await a.pairingLink();
      expect(Backend.fromLink(link)!.url, 'https://mac.tail1234.ts.net');
      expect(Backend.computerKey(link)!.desktop, a.desktopId(a.user!.id));
      // The phone reaches it through Tailscale; here, on 127.0.0.1.
      final phone = PocketTermServerClient(a.backend!, tokens: MemoryDeviceTokens());
      final account = await phone.redeemCode(Backend.pairingCode(link)!, label: 'iPhone', platform: 'ios');
      expect(account.id, a.user!.id);
      expect((await a.serverDevices()).map((d) => d.role), unorderedEquals([DeviceRole.desktop, DeviceRole.phone]));
    });

    test("until Tailscale serves it, there's no phone code to show", () async {
      fake.https = false;
      final a = await app();
      await a.startHosting();
      await a.hosting!.refresh();
      expect(a.hosting!.state, HostState.httpsOff);
      await expectLater(a.pairingLink(), throwsA(isA<PairingException>()));
    });

    test('Add a computer: its link signs another computer in to this server', () async {
      final a = await app();
      await a.startHosting();
      await a.hosting!.refresh();
      final link = a.computerSetupLink()!;
      expect(Backend.fromLink(link)!.url, 'https://mac.tail1234.ts.net');
      final other = PocketTermServerClient(a.backend!, tokens: MemoryDeviceTokens());
      final account = await other.redeemSetup(Backend.setupToken(link)!, label: 'Mac mini', platform: 'macos');
      expect(account.id, a.user!.id);
      expect(account.device.role, DeviceRole.desktop);
    });

    test('at launch it starts again and signs in by itself, also when its port was taken', () async {
      final first = await app();
      await first.startHosting();
      final port = first.hosting!.port;
      final prefs = (await SharedPreferences.getInstance()).getKeys();
      expect(prefs, containsAll(['hosting', 'hosting_port']));
      await first.hosting!.stop();

      final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      addTearDown(taken.close);
      final again = await FakeApp.create(
        prefs: {
          // Without Terminal from phone: no bridge to the terminals here.
          for (final k in prefs)
            if (k != 'terminal_bridge') k: (await SharedPreferences.getInstance()).get(k)!,
        },
        tailscale: fake.tailscale,
        serverDir: dir,
        real: true,
      );
      addTearDown(() => again.hosting?.stop());
      await again.start();
      expect(again.hosting!.port, isNot(port));
      expect(again.user, isNotNull);
      expect(again.user!.id, first.user!.id);
    });

    test('signing out stops the server, takes it off the tailnet and shows the setup again', () async {
      final a = await app();
      await a.startHosting();
      await a.hosting!.refresh();
      final port = a.hosting!.port;
      await a.signOut();
      expect(a.hosting, isNull);
      expect(a.backend, isNull);
      expect(a.user, isNull);
      expect(fake.calls, contains('serve --https=443 off'));
      expect(await listening(port), isFalse);
      expect((await SharedPreferences.getInstance()).getBool('hosting'), isFalse);
    });

    test(
      'a computer that runs the server starts it at launch; quitting takes it off the tailnet and stops it',
      () async {
        final a = await app(prefs: {'hosting': true});
        await a.start();
        expect(a.user, isNotNull);
        await a.hosting!.refresh();
        expect(a.hosting!.state, HostState.ready);
        final port = a.hosting!.port;
        await a.host.onEvent!('quitting');
        expect(fake.calls.last, 'serve --https=443 off');
        expect(await listening(port), isFalse);
      },
    );

    test('erasing signs every phone out and this computer back in', () async {
      final a = await app();
      await a.startHosting();
      await a.hosting!.refresh();
      final phone = PocketTermServerClient(a.backend!, tokens: MemoryDeviceTokens());
      await phone.redeemCode(Backend.pairingCode(await a.pairingLink())!, label: 'iPhone', platform: 'ios');
      final before = a.user!.device.id;

      await a.eraseServer();
      expect(a.user, isNotNull);
      expect(a.user!.device.id, isNot(before));
      await expectLater(phone.devices(), throwsA(isA<ServerException>().having((e) => e.status, 'status', 401)));
      expect((await a.serverDevices()).single.role, DeviceRole.desktop);
    });

    testWidgets('Tailscale switched off later: Settings says phones can’t reach the server, and opens Tailscale', (
      tester,
    ) async {
      tester.view
        ..physicalSize = const Size(1000, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = (await tester.runAsync(() async {
        final a = await app();
        await a.startHosting();
        await a.hosting!.refresh();
        return a;
      }))!;
      expect(a.hosting!.state, HostState.ready);
      await tester.pumpWidget(
        window(
          ListenableBuilder(
            listenable: a,
            builder: (_, _) => SettingsPage(app: a),
          ),
        ),
      );
      await tester.pump();
      final open = find.byKey(const ValueKey('attention-open-tailscale'));
      expect(open, findsNothing);

      fake.backendState = 'Stopped';
      await tester.runAsync(a.hosting!.refresh);
      await tester.pump();
      await tester.tap(find.text('Show'));
      await tester.pump();
      expect(find.textContaining('Tailscale isn’t running, so phones can’t reach'), findsOneWidget);
      await tester.tap(open);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(fake.calls, contains('-a Tailscale'));

      await tester.runAsync(() async => await a.hosting?.stop());
      a.server?.close();
      await tester.pumpWidget(const SizedBox());
    });
  });
}
