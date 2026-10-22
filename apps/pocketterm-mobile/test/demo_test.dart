import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_mobile/demo/demo.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/setup_page.dart';

import 'screenshots/fakes.dart';

/// Any connection anything opens is kept here, and fails.
class _NoNetwork extends HttpOverrides {
  final attempts = <Uri>[];

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..connectionFactory = (uri, _, _) {
          attempts.add(uri);
          throw const SocketException('No network in the demo');
        };
}

void main() {
  late _NoNetwork network;
  late List<MethodCall> calls;

  setUp(() {
    network = _NoNetwork();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('pocketterm/native'), (call) async {
        calls.add(call);
        return null;
      })
      ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
      ..setMockStreamHandler(
        const EventChannel('com.llfbandit.app_links/events'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
  });
  testWidgets('the demo shows a made-up computer in two projects, answers itself, and exits to setup, all offline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    // The test binding's own overrides answer 400 to anything: these record and refuse instead.
    await HttpOverrides.runWithHttpOverrides(() => _demo(tester), network);
    expect(network.attempts, isEmpty, reason: 'the demo never goes on the network');
    expect(calls.map((c) => c.method), isNot(contains('registerPush')));
    expect(calls.map((c) => c.method), isNot(contains('setChannelKey')));
  });
}

Future<void> _demo(WidgetTester tester) async {
  final session = await FakeSession.create(signedIn: false);
  await tester.pumpWidget(MobileApp(session: session));
  await tester.ensureVisible(find.byKey(const ValueKey('try-demo')));
  await tester.tap(find.byKey(const ValueKey('try-demo')));
  await settle(tester);

  expect(find.text('DEMO'), findsOneWidget);
  expect(find.text(demoDesktopName), findsOneWidget);
  expect(find.text('Add a soil moisture endpoint'), findsOneWidget);
  expect(find.text('Fix the pricing table on small screens'), findsOneWidget);
  expect(find.textContaining('garden-api'), findsWidgets);
  expect(find.textContaining('pocketterm-site'), findsWidgets);
  expect(find.text('Scan this computer’s code to connect'), findsNothing, reason: 'the demo computer is not locked');

  // A conversation, and an approval the demo carries on from.
  await tester.tap(find.text('Fix the pricing table on small screens'));
  await settle(tester);
  expect(find.textContaining('I want to build the site to check it'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('approve')));
  await settle(tester);
  expect(find.textContaining('Built in 6.2 s'), findsOneWidget);
  expect(find.byKey(const ValueKey('approve')), findsNothing);

  // A prompt gets the demo's own answer.
  await tester.enterText(find.byKey(const ValueKey('session-input')), 'Also check the footer');
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('session-send')));
  await settle(tester);
  expect(find.text('Also check the footer'), findsOneWidget);
  expect(find.textContaining("This is the demo: there's no computer behind it"), findsOneWidget);

  await tester.pageBack();
  await settle(tester);
  await tester.tap(find.byKey(const ValueKey('exit-demo')));
  await settle(tester);
  expect(find.byType(SetupPage), findsOneWidget);
  expect(session.demo, isNull);
  expect(find.text('DEMO'), findsNothing);
}

/// Lets the demo's answers (microtasks) and the pages settle.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pumpAndSettle();
}
