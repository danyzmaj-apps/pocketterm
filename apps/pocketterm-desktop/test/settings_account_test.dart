import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_desktop/hosting/built_in_server.dart';
import 'package:pocketterm_desktop/main_window.dart';

import 'app_fakes.dart';

void main() {
  late Directory dir;

  setUp(() {
    // The built-in server on 127.0.0.1.
    HttpOverrides.global = null;
    dir = Directory.systemTemp.createTempSync('pocketterm-account');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> pumpAccount(WidgetTester tester, FakeApp app) async {
    tester.view
      ..physicalSize = const Size(900, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      window(
        ListenableBuilder(
          listenable: app,
          builder: (_, _) => app.user == null ? const Text('Signed out') : SettingsPage(app: app),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('settings-tab-account')));
    await tester.pump();
  }

  /// Lets real I/O and the window take turns until [done] holds, 5 seconds at most.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 250 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pump();
  }

  testWidgets('on a server elsewhere: its address and who is signed in, nothing to erase', (tester) async {
    final app = await FakeApp.create(integrations: FakeApp.noAgents(dir.path))
      ..devices = const [
        Device(id: 'd1', role: DeviceRole.desktop, label: 'Mac', platform: 'macos'),
        Device(id: 'p1', role: DeviceRole.phone, label: 'iPhone', platform: 'ios'),
        Device(id: 'p2', role: DeviceRole.phone, label: 'Pixel', platform: 'android'),
      ];
    await pumpAccount(tester, app);
    await tester.pumpAndSettle();
    expect(find.text('pt.example.com · 1 computer, 2 phones'), findsOneWidget);
    expect(find.textContaining('Erase'), findsNothing);
    expect(find.byKey(const ValueKey('settings-add-computer')), findsNothing);

    // How your data is protected, again, as the first-run setup showed it.
    await tester.tap(find.byKey(const ValueKey('settings-data-protection')));
    await tester.pumpAndSettle();
    expect(find.text('Encrypted from end to end'), findsOneWidget);
    expect(find.text('Lock Screen updates (iPhone)'), findsOneWidget);
  });

  testWidgets('a lost phone is signed out of the server from its row, asked first', (tester) async {
    final app = await FakeApp.create(integrations: FakeApp.noAgents(dir.path))
      ..devices = const [
        Device(id: 'd1', role: DeviceRole.desktop, label: 'Mac', platform: 'macos'),
        Device(id: 'p1', role: DeviceRole.phone, label: 'iPhone', platform: 'ios'),
        Device(id: 'p2', role: DeviceRole.phone, label: 'Pixel', platform: 'android'),
      ];
    await pumpAccount(tester, app);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-phone-p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-phone-p2')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-phone-d1')), findsNothing, reason: 'computers have no row');

    final signOut = find.byKey(const ValueKey('settings-phone-sign-out-p1'));
    await tester.tap(signOut);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.revoked, isEmpty);

    await tester.tap(signOut);
    await tester.pumpAndSettle();
    expect(find.text('Sign out iPhone?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Sign out').last);
    await tester.pumpAndSettle();
    expect(app.revoked, ['p1']);
    expect(find.byKey(const ValueKey('settings-phone-p1')), findsNothing);
    expect(find.text('pt.example.com · 1 computer, 1 phone'), findsOneWidget);
  });

  testWidgets('a computer that runs the server: HTTPS to turn on, then Add a computer, Erase, and Sign out stops it', (
    tester,
  ) async {
    final fake = FakeTailscale(installed: true, https: false);
    final app = await FakeApp.create(
      tailscale: fake.tailscale,
      serverDir: dir,
      real: true,
      integrations: FakeApp.noAgents(dir.path),
    );
    await tester.runAsync(app.startHosting);
    await tester.runAsync(() => app.hosting!.refresh());
    await pumpAccount(tester, app);
    await until(tester, () => find.textContaining('1 computer, 0 phones').evaluate().isNotEmpty);

    expect(app.hosting!.state, HostState.httpsOff);
    expect(find.byKey(const ValueKey('hosting-enable-https')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-add-computer')), findsNothing);
    expect(find.textContaining('Erase'), findsWidgets);

    // HTTPS turned on in the admin console.
    fake.https = true;
    await tester.tap(find.text('Check again'));
    await until(tester, () => app.hosting!.state == HostState.ready);
    expect(find.textContaining('https://mac.tail1234.ts.net'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-add-computer')));
    await tester.pumpAndSettle();
    final link = Uri.parse(tester.widget<SelectableText>(find.byKey(const ValueKey('add-computer-link'))).data!);
    expect(Backend.fromLink(link)!.url, 'https://mac.tail1234.ts.net');
    expect(Backend.setupToken(link), isNotNull);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    final port = app.hosting!.port;
    await tester.tap(find.byKey(const ValueKey('settings-sign-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
    await until(tester, () => app.backend == null);
    expect(app.hosting, isNull);
    expect(fake.calls.last, 'serve --https=443 off');
    final refused = await tester.runAsync(() async {
      try {
        (await Socket.connect(InternetAddress.loopbackIPv4, port)).destroy();
        return false;
      } on SocketException {
        return true;
      }
    });
    expect(refused, isTrue);
  });
}
