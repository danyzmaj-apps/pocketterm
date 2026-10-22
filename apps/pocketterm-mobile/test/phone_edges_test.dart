import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/push_consent.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screenshots/fakes.dart';

void main() {
  late Directory dir;
  late List<MethodCall> calls;

  /// What the phone answers notificationsAllowed.
  late bool allowed;

  /// What the native side keeps as the server: an app from before kept a
  /// Supabase project's key with it.
  late Map<String, String>? backend;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_edges');
    calls = [];
    allowed = true;
    backend = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('pocketterm/native'), (call) async {
        calls.add(call);
        return switch (call.method) {
          'notificationsAllowed' => allowed,
          'getBackend' => backend,
          'liveActivities' => [
            {'key': 'mac00001/kitty-1/1'},
          ],
          _ => null,
        };
      })
      ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
      ..setMockStreamHandler(
        const EventChannel('com.llfbandit.app_links/events'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Iterable<String> native(String method) => calls.where((c) => c.method == method).map((c) => c.method);

  group('updating from PocketTerm 0.1 (Supabase)', () {
    Future<SharedPreferences> prefs() {
      SharedPreferences.setMockInitialValues({
        'sb-abcd-auth-token': '{"access_token":"x"}',
        'pocketterm_desktops': '[]',
        'pocketterm_desktop': 'mac00001',
        'pocketterm_push_token': 'apns-token',
        'pocketterm_terminal_sort': 'recent',
        CoachController.seenKey: ['queue'],
      });
      return SharedPreferences.getInstance();
    }

    test(
      "forgets the old app's project, sign-in, keys, cache and followed sessions; keeps the phone's choices",
      () async {
        backend = {'url': 'https://abcd.supabase.co', 'key': 'sb_publishable_x'};
        final p = await prefs();
        await MobileSession(p, 'iPhone').forgetOldApp();
        expect(calls.firstWhere((c) => c.method == 'setBackend').arguments, {'url': null});
        expect(calls.firstWhere((c) => c.method == 'setDeviceToken').arguments, {'value': null});
        expect(native('removeAllChannelKeys'), hasLength(1));
        expect(calls.where((c) => c.method == 'endActivity').map((c) => (c.arguments as Map)['key']), [
          'mac00001/kitty-1/1',
        ]);
        expect(p.getKeys(), {'pocketterm_terminal_sort', CoachController.seenKey});
      },
    );

    test("leaves a phone that's on a PocketTerm server alone", () async {
      backend = {'url': 'https://pt.example.com'};
      final p = await prefs();
      await MobileSession(p, 'iPhone').forgetOldApp();
      expect(calls.map((c) => c.method), ['getBackend']);
      expect(p.getKeys(), hasLength(6));
    });
  });

  Future<(FakeSession, TerminalRemote)> pumpApp(WidgetTester tester, {Desktops? desktops}) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final session = await FakeSession.create(push: true);
    final remote =
        TerminalRemote(session.server, dir, desktopId: 'mac00001', key: testKey, from: 'phone', send: (_, _) {})
          ..handle('state', {
            'windows': <Object>[],
            'sessions': [
              {'key': 'kitty-1/1', 'id': 's1', 'title': 'Mac work', 'cwd': '/Users/me/app', 'epoch': 'e', 'seq': 0},
            ],
          });
    final list =
        desktops ??
        (Desktops(offlineServer())..apply([
          {'id': 'mac00001', 'name': 'MacBook Pro', 'platform': 'macos', 'seen_at': DateTime.now().toIso8601String()},
        ]));
    await tester.pumpWidget(MobileApp(session: session, desktops: list, remoteFor: (_, _) => remote));
    await tester.pump();
    return (session, remote);
  }

  testWidgets('notifications turned off in Settings after saying yes: the account says so and opens Settings', (
    tester,
  ) async {
    allowed = false;
    final (session, remote) = await pumpApp(tester);
    await session.checkNotifications();
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text(pushBlocked), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('push-settings')));
    expect(calls.lastWhere((c) => c.method == 'openSettings').arguments, {'notifications': true});

    // Allowed again in Settings, then back to the app.
    allowed = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(pushBlocked), findsNothing);
    expect(find.byKey(const ValueKey('push-settings')), findsNothing);
    remote.flush();
  });

  testWidgets('a sign-in that ends with a session open goes back to setup, with nothing left over it', (tester) async {
    final (session, remote) = await pumpApp(tester);
    await tester.tap(find.text('Mac work'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionPage), findsOneWidget);

    session.endSignIn();
    await tester.pumpAndSettle();
    expect(find.byType(SessionPage), findsNothing);
    expect(find.text('Welcome to PocketTerm'), findsOneWidget);
    expect(tester.takeException(), isNull);
    remote.flush();
  });

  testWidgets("a server the phone can't reach says so instead of looking for computers forever", (tester) async {
    final list = Desktops(_Unreachable());
    await list.refresh();
    final (_, remote) = await pumpApp(tester, desktops: list);
    expect(find.textContaining("Can't reach my-mac.tail1234.ts.net"), findsOneWidget);
    expect(find.textContaining('open Tailscale'), findsOneWidget);
    expect(find.text('Looking for your computers…'), findsNothing);
    remote.flush();
  });
}

/// A server on a tailnet this phone isn't on (Tailscale off here).
class _Unreachable extends PocketTermServerClient {
  _Unreachable() : super(const Backend(url: 'https://my-mac.tail1234.ts.net'), tokens: MemoryDeviceTokens());

  @override
  Future<List<Map<String, dynamic>>> desktops() async => throw ServerException(0, 'offline', backend.unreachable);
}
