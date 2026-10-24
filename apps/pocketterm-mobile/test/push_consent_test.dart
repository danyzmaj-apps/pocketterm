import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/push_consent.dart';

import 'screenshots/fakes.dart';

void main() {
  late Directory dir;
  late List<MethodCall> calls;

  /// What the phone answers registerPush: its token, or null (not allowed).
  late String? pushToken;

  /// The phone never answers registerPush (no network, APNs silent).
  late bool pushHangs;

  /// What the phone says of its notification permission.
  late bool allowed;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_push');
    calls = [];
    pushToken = 'apns-token';
    pushHangs = false;
    allowed = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('pocketterm/native'), (call) async {
        calls.add(call);
        return switch (call.method) {
          'registerPush' when pushHangs => Completer<Object?>().future,
          'registerPush' => pushToken == null ? null : {'token': pushToken},
          'notificationsAllowed' => allowed,
          'liveActivities' => [
            {'key': 'mac00001/kitty-1/1', 'token': 'activity-token'},
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

  Future<(FakeSession, TerminalRemote)> pumpApp(WidgetTester tester, {bool? push}) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final session = await FakeSession.create(push: push);
    final remote =
        TerminalRemote(session.server, dir, desktopId: 'mac00001', key: testKey, from: 'phone', send: (_, _) {})
          ..handle('state', {
            'windows': <Object>[],
            'sessions': [
              {'key': 'kitty-1/1', 'id': 's1', 'title': 'Mac work', 'cwd': '/Users/me/app', 'epoch': 'e', 'seq': 0},
            ],
          });
    final desktops = Desktops(offlineServer())
      ..apply([
        {'id': 'mac00001', 'name': 'MacBook Pro', 'platform': 'macos', 'seen_at': DateTime.now().toIso8601String()},
      ]);
    await tester.pumpWidget(MobileApp(session: session, desktops: desktops, remoteFor: (_, _) => remote));
    await tester.pump();
    return (session, remote);
  }

  /// Opens the session, says whether it offers Follow, and goes back.
  Future<bool> offersFollow(WidgetTester tester) async {
    await tester.tap(find.text('Mac work'));
    await tester.pumpAndSettle();
    final shown = find.byKey(const ValueKey('follow-lock-screen')).evaluate().isNotEmpty;
    await tester.pageBack();
    await tester.pumpAndSettle();
    return shown;
  }

  Future<void> toggleInAccount(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('push-toggle')));
    await tester.pumpAndSettle();
  }

  testWidgets('the first sign-in asks before anything registers; Not now registers nothing', (tester) async {
    final (session, remote) = await pumpApp(tester);
    expect(find.byType(PushConsentPage), findsOneWidget);
    expect(find.textContaining('push.danyzmaj.com'), findsOneWidget);
    expect(native('registerPush'), isEmpty, reason: 'no permission prompt before the person says yes');
    expect(session.server.pushes, isEmpty);

    await tester.tap(find.byKey(const ValueKey('push-not-now')));
    await tester.pumpAndSettle();
    expect(find.byType(PushConsentPage), findsNothing);
    expect(find.text('Mac work'), findsOneWidget);
    expect(native('registerPush'), isEmpty);
    expect(session.server.pushes, isEmpty);
    expect(session.pushEnabled, isFalse);
    expect(await offersFollow(tester), isFalse, reason: 'following a session needs push');
    remote.flush();
  });

  testWidgets('Turn on registers this phone’s token with its server, and Follow shows', (tester) async {
    final (session, remote) = await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('push-accept')));
    await tester.pumpAndSettle();
    expect(native('registerPush'), hasLength(1));
    expect(session.server.pushes.firstWhere((p) => p.$1 == 'register').$2, {
      'token': 'apns-token',
      'label': 'iPhone',
      'platform': 'ios',
    });
    expect(session.pushEnabled, isTrue);
    expect(find.text('Mac work'), findsOneWidget);
    expect(await offersFollow(tester), isTrue);
    remote.flush();
  });

  testWidgets('a phone that refuses notifications stays off and says where to allow them', (tester) async {
    pushToken = null;
    allowed = false;
    final (session, remote) = await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('push-accept')));
    await tester.pumpAndSettle();
    expect(session.pushEnabled, isFalse);
    expect(session.server.pushes, isEmpty);
    expect(find.text(pushNotAllowed), findsOneWidget);
    remote.flush();
  });

  testWidgets('allowed, but no push address from Apple or Google: says so, not that Settings is off', (tester) async {
    pushToken = null;
    final (session, remote) = await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('push-accept')));
    await tester.pumpAndSettle();
    expect(session.pushEnabled, isFalse);
    expect(find.text(pushNoToken), findsOneWidget);
    expect(find.text(pushNotAllowed), findsNothing);
    remote.flush();
  });

  testWidgets('turning notifications off unregisters, ends followed sessions and hides Follow; on registers again', (
    tester,
  ) async {
    final (session, remote) = await pumpApp(tester, push: true);
    expect(find.byType(PushConsentPage), findsNothing, reason: 'asked once per server');
    expect(await offersFollow(tester), isTrue);

    await toggleInAccount(tester);
    expect(session.pushEnabled, isFalse);
    expect(session.server.pushes.map((p) => p.$1), contains('unregister'));
    expect(calls.where((c) => c.method == 'endActivity').map((c) => (c.arguments as Map)['key']), [
      'mac00001/kitty-1/1',
    ]);
    Navigator.of(tester.element(find.byKey(const ValueKey('push-toggle')))).pop();
    await tester.pumpAndSettle();
    expect(await offersFollow(tester), isFalse);

    session.server.pushes.clear();
    await toggleInAccount(tester);
    expect(session.pushEnabled, isTrue);
    expect(session.server.pushes.map((p) => p.$1), contains('register'));
    remote.flush();
  });

  testWidgets('a phone that never hands over its token neither traps the consent page nor waits forever', (
    tester,
  ) async {
    pushHangs = true;
    final (session, remote) = await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('push-accept')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('push-not-now')));
    await tester.pumpAndSettle();
    expect(find.byType(PushConsentPage), findsNothing, reason: 'Not now gets out while Turn on still waits');
    expect(session.pushEnabled, isFalse);

    await tester.pump(MobileSession.pushTokenWait);
    await tester.pumpAndSettle();
    expect(session.pushEnabled, isFalse, reason: 'the late Turn on does not override Not now');
    expect(session.server.pushes, isEmpty);

    await toggleInAccount(tester);
    expect(session.pushEnabled, isFalse, reason: 'still waiting on the phone');
    await tester.pump(MobileSession.pushTokenWait);
    await tester.pumpAndSettle();
    expect(session.pushEnabled, isFalse, reason: 'no token within the wait: off, and the switch is free again');
    remote.flush();
  });

  testWidgets('a server that misses the token says so, and gets it when the app comes back', (tester) async {
    final (session, remote) = await pumpApp(tester);
    session.server.offline = true;
    await tester.tap(find.byKey(const ValueKey('push-accept')));
    await tester.pumpAndSettle();
    expect(session.pushEnabled, isTrue);
    expect(session.pushUnsent, isTrue);
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(find.text(pushNotSent), findsOneWidget);

    session.server.offline = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(session.server.pushes.map((p) => p.$1), ['register']);
    expect(session.pushUnsent, isFalse);
    expect(find.text(pushNotSent), findsNothing);
    remote.flush();
  });
}
