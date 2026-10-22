import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/session_view.dart';

import 'screenshots/fakes.dart';

void main() {
  late Directory dir;
  late Map<String, TerminalRemote> made;
  late String? tapped;
  final client = offlineServer();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_home');
    made = {};
    tapped = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(
        const MethodChannel('pocketterm/native'),
        (call) async => call.method == 'takeTappedSession' ? tapped : null,
      )
      ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
      ..setMockStreamHandler(
        const EventChannel('com.llfbandit.app_links/events'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// The remotes' cache writes, done before the test ends.
  void flush() {
    for (final r in made.values) {
      r.flush();
    }
  }

  /// A computer answering with one session, titled [title].
  TerminalRemote remoteFor(String desktopId, String title, ChannelKey key) =>
      TerminalRemote(client, dir, desktopId: desktopId, key: key, from: 'phone', send: (_, _) {})..handle('state', {
        'windows': <Object>[],
        'sessions': [
          {'key': 'kitty-1/1', 'id': 's1', 'title': title, 'cwd': '/Users/me/app', 'epoch': 'e', 'seq': 0},
        ],
      });

  Future<Desktops> pumpHome(WidgetTester tester, {FakeSession? session}) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final desktops = Desktops(client)
      ..apply([
        {'id': 'mac00001', 'name': 'MacBook Pro', 'platform': 'macos', 'seen_at': DateTime.now().toIso8601String()},
        {
          'id': 'win00001',
          'name': 'Gaming PC',
          'platform': 'windows',
          'seen_at': DateTime.now().subtract(const Duration(hours: 2)).toUtc().toIso8601String(),
        },
      ]);
    await tester.pumpWidget(
      MobileApp(
        session: session ?? await FakeSession.create(),
        desktops: desktops,
        remoteFor: (id, key) => made[id] = remoteFor(id, id == 'mac00001' ? 'Mac work' : 'PC work', key),
      ),
    );
    await tester.pump();
    return desktops;
  }

  testWidgets("the title picks the computer, and the list shows that one's sessions", (tester) async {
    await pumpHome(tester);
    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('Mac work'), findsOneWidget);

    await tester.tap(find.text('MacBook Pro'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.laptop_mac), findsOneWidget);
    expect(find.byIcon(Icons.desktop_windows), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Seen 2 h ago'), findsOneWidget);

    await tester.tap(find.text('Gaming PC'));
    await tester.pumpAndSettle();
    expect(made.keys, ['mac00001', 'win00001']);
    expect(find.text('Gaming PC'), findsOneWidget);
    expect(find.text('PC work'), findsOneWidget);
    expect(find.text('Mac work'), findsNothing);
    flush();
  });

  // The avatar's letter isn't read with the button: a server at 127.0.0.1 made it "1, Account".
  testWidgets('the account button reads as Account', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHome(tester);
    final button = tester.getSemantics(find.byTooltip('Account'));
    expect((button.tooltip, button.label), ('Account', ''));
    semantics.dispose();
    flush();
  });

  testWidgets("a computer whose code wasn't scanned stays locked until it is; a link not scanned brings no key", (
    tester,
  ) async {
    final setKeys = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('pocketterm/native'), (
      call,
    ) async {
      if (call.method == 'setChannelKey') setKeys.add(call.arguments);
      return null;
    });
    const server = Backend(url: 'https://pt.example.com');
    final session = await FakeSession.create()
      ..connected = server
      ..locked.add('win00001');
    final desktops = await pumpHome(tester, session: session);

    desktops.select('win00001');
    await tester.pumpAndSettle();
    expect(find.text('Scan this computer’s code to connect'), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-locked-computer')), findsOneWidget);
    expect(made.keys, ['mac00001'], reason: 'nothing joins a locked computer');
    expect(find.byTooltip('New session'), findsNothing);

    await tester.tap(find.text('Gaming PC'));
    await tester.pumpAndSettle();
    expect(find.text('Locked: scan its code'), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-computer')), findsOneWidget);
    Navigator.of(tester.element(find.text('Locked: scan its code'))).pop();
    await tester.pumpAndSettle();

    // What the scanner hands over, signed in: the computer's code, with its key.
    final key = ChannelKey.generate();
    await session.connectLink(
      server.linkWithCode('ABCD-1234', computer: (desktop: 'win00001', key: key)),
      scanned: true,
    );
    await tester.pumpAndSettle();
    expect(session.user, isNotNull, reason: 'still the same account');
    expect(setKeys, [
      {'desktop': 'win00001', 'key': key.toBase64()},
    ]);
    expect(made['win00001']?.key, key);
    expect(find.text('PC work'), findsOneWidget);
    expect(find.text('Scan this computer’s code to connect'), findsNothing);

    // Anyone can send a link: one opened from outside, or pasted, doesn't swap the key.
    await session.connectLink(
      server.linkWithCode('ABCD-1234', computer: (desktop: 'win00001', key: ChannelKey.generate())),
    );
    expect(session.computerKey('win00001'), key);
    expect(setKeys, hasLength(1));
    flush();
  });

  testWidgets('a tapped push opens its session on its computer; one that names no computer opens nothing', (
    tester,
  ) async {
    await pumpHome(tester);
    Future<void> openTerminal() async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'pocketterm/native',
        const StandardMethodCodec().encodeMethodCall(const MethodCall('openTerminal')),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    tapped = 'kitty-1/1';
    await openTerminal();
    expect(find.byType(SessionPage), findsNothing);

    tapped = 'win00001/kitty-1/1';
    await openTerminal();
    final page = tester.widget<SessionPage>(find.byType(SessionPage));
    expect((page.remote.desktopId, page.sessionKey), ('win00001', 'kitty-1/1'));
    expect(find.text('PC work'), findsWidgets);
    flush();
  });

  testWidgets('no computer: it says how to get one reporting, and there is no + to start a session', (tester) async {
    await tester.pumpWidget(
      MobileApp(
        session: await FakeSession.create(),
        desktops: Desktops(client)..apply(const []),
        remoteFor: (_, _) => fail('no computer to reach'),
      ),
    );
    await tester.pump();
    expect(find.textContaining('turn on Terminal from phone'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byTooltip('New session'), findsNothing);
  });
}
