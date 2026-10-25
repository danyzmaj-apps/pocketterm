import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
        {
          'id': 'mac00001',
          'name': 'MacBook Pro',
          'platform': 'macos',
          'seen_at': DateTime.now().toUtc().toIso8601String(),
        },
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

  // E2E (iOS, test server): a tap the app got half a second late came as a long press, which showed the
  // Account tooltip and opened nothing. On iPhone, where no button has a tooltip, a held press still presses.
  testWidgets('on iPhone a press held past a long press still opens the account sheet', (tester) async {
    await pumpHome(tester);
    final press = await tester.startGesture(tester.getCenter(find.byTooltip('Account')));
    await tester.pump(const Duration(milliseconds: 700));
    await press.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('show-tips')), findsOneWidget);
    flush();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  // E2E (Android): the list's note went while the computer picker was up, and a tap aimed by the accessibility
  // tree (as a screen reader or Maestro aims) landed on the project heading below the row.
  testWidgets('rows say where they are after the list moved under the computer picker', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHome(tester);
    final remote = made['mac00001']!;
    void state({String? error}) => remote.handle('state', {
      'windows': <Object>[],
      'sessions': [
        {'key': 'kitty-1/1', 'id': 's1', 'title': 'Mac work', 'cwd': '/Users/me/app', 'epoch': 'e', 'seq': 0},
      ],
      'error': ?error,
    });
    state(error: 'kitty is busy');
    await tester.pumpAndSettle();
    expect(find.text('kitty is busy'), findsOneWidget);

    await tester.tap(find.text('MacBook Pro'));
    await tester.pumpAndSettle();
    state();
    await tester.pumpAndSettle();
    await tester.tap(find.text('MacBook Pro').last);
    await tester.pumpAndSettle();
    expect(find.text('kitty is busy'), findsNothing);

    final row = find.text('Mac work');
    final node = tester.getSemantics(row);
    var rect = node.rect;
    for (SemanticsNode? n = node; n != null; n = n.parent) {
      if (n.transform case final t?) rect = MatrixUtils.transformRect(t, rect);
    }
    final onScreen = tester.getCenter(row) * tester.view.devicePixelRatio;
    expect(rect.contains(onScreen), isTrue, reason: 'row at $onScreen, its semantics at $rect');
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

  // E2E: the phone paired with one computer landed on another, seen later.
  testWidgets('scanning a computer shows it, even when another was seen since; also its key already known', (
    tester,
  ) async {
    const server = Backend(url: 'https://pt.example.com');
    final session = await FakeSession.create()
      ..connected = server
      // Not scanned yet: the code's key is the first this phone holds for it.
      ..locked.add('win00001');
    final desktops = await pumpHome(tester, session: session);
    expect(desktops.selected?.id, 'mac00001');

    final key = ChannelKey.generate();
    await session.connectLink(
      server.linkWithCode('ABCD-1234', computer: (desktop: 'win00001', key: key)),
      scanned: true,
    );
    await tester.pumpAndSettle();
    expect(desktops.selected?.id, 'win00001');
    expect(find.text('PC work'), findsOneWidget);

    flush();
    desktops.select('mac00001');
    await tester.pumpAndSettle();
    flush();
    await session.connectLink(
      server.linkWithCode('ABCD-1234', computer: (desktop: 'win00001', key: key)),
      scanned: true,
    );
    await tester.pumpAndSettle();
    expect(desktops.selected?.id, 'win00001');
    flush();
  });

  testWidgets("a link this signed-in phone can't use says why where the person is", (tester) async {
    const server = Backend(url: 'https://pt.example.com');
    final session = await FakeSession.create()
      ..connected = server;
    await pumpHome(tester, session: session);

    const elsewhere = Backend(url: 'https://other.example.com');
    await session.connectLink(
      elsewhere.linkWithCode('ABCD-1234', computer: (desktop: 'zzzz9999', key: ChannelKey.generate())),
      scanned: true,
    );
    await tester.pump();
    expect(find.textContaining('That code is for a computer on other.example.com'), findsOneWidget);
    expect(session.authError, isNull, reason: 'nothing waits for the setup page');
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

  group('a tapped followed session (its link) or push', () {
    /// What happens to Studio's (abcd1234) remote when it's made; it answers only when the test says.
    late void Function(TerminalRemote remote) onMade;

    Future<FakeSession> pumpTwo(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final session = await FakeSession.create();
      final now = DateTime.now().toUtc().toIso8601String();
      await tester.pumpWidget(
        MobileApp(
          session: session,
          desktops: Desktops(client)
            ..apply([
              {'id': 'mac00001', 'name': 'MacBook Pro', 'platform': 'macos', 'seen_at': now},
              {'id': 'abcd1234', 'name': 'Studio', 'platform': 'macos', 'seen_at': now},
            ]),
          remoteFor: (id, key) {
            if (id == 'mac00001') return made[id] = remoteFor(id, 'Mac work', key);
            final r = made[id] = TerminalRemote(client, dir, desktopId: id, key: key, from: 'phone', send: (_, _) {});
            onMade(r);
            return r;
          },
        ),
      );
      await tester.pump();
      return session;
    }

    void state(TerminalRemote r, {required bool withSession}) => r.handle('state', {
      'windows': <Object>[],
      'sessions': [
        if (withSession)
          {'key': 'kitty-1/2', 'id': 's2', 'title': 'Studio work', 'cwd': '/Users/me/app', 'epoch': 'e', 'seq': 0},
      ],
    });

    SessionPage? page(WidgetTester tester) => tester.widgetList<SessionPage>(find.byType(SessionPage)).firstOrNull;

    /// The page's push, under a note whose spinner never settles.
    Future<void> opened(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('opens at once on its computer, the computer switched, and fills in when the computer answers', (
      tester,
    ) async {
      onMade = (_) {};
      final session = await pumpTwo(tester);
      // As a Live Activity's tap sends it (ios/Shared/SessionActivity.swift): the routed key's / as it is.
      session.onOtherLink(Uri.parse('pocketterm://session?key=abcd1234/kitty-1/2'));
      await opened(tester);
      expect((page(tester)?.remote.desktopId, page(tester)?.sessionKey), ('abcd1234', 'kitty-1/2'));
      expect(find.textContaining('Asking Studio…'), findsOneWidget, reason: 'open before the computer answered');

      state(made['abcd1234']!, withSession: true);
      await tester.pumpAndSettle();
      expect(find.text('Studio work'), findsWidgets);
      await tester.pump(HomePage.routedWait + const Duration(seconds: 1));
      state(made['abcd1234']!, withSession: true);
      await tester.pumpAndSettle();
      expect(page(tester), isNotNull, reason: 'it came: nothing gives up on it later');
      expect(find.byType(SnackBar), findsNothing);
      flush();
    });

    testWidgets('one that launched the app, before there was a home page, opens once there is', (tester) async {
      onMade = (r) => state(r, withSession: true);
      final session = await FakeSession.create();
      session.onOtherLink(Uri.parse('pocketterm://session?key=abcd1234/kitty-1/2'));
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MobileApp(
          session: session,
          desktops: Desktops(client)
            ..apply([
              {
                'id': 'abcd1234',
                'name': 'Studio',
                'platform': 'macos',
                'seen_at': DateTime.now().toUtc().toIso8601String(),
              },
            ]),
          remoteFor: (id, key) {
            final r = made[id] = TerminalRemote(client, dir, desktopId: id, key: key, from: 'phone', send: (_, _) {});
            onMade(r);
            return r;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect((page(tester)?.remote.desktopId, page(tester)?.sessionKey), ('abcd1234', 'kitty-1/2'));
      expect(find.text('Studio work'), findsWidgets);
      flush();
    });

    testWidgets("gives up after 20 s when the computer doesn't answer: back on its list, with why", (tester) async {
      onMade = (_) {};
      final session = await pumpTwo(tester);
      session.onOtherLink(Uri.parse('pocketterm://session?key=abcd1234/kitty-1/2'));
      await opened(tester);
      expect(page(tester), isNotNull);

      await tester.pump(HomePage.routedWait);
      await opened(tester);
      expect(page(tester), isNull);
      expect(find.textContaining("Studio didn't answer in time"), findsOneWidget);
      expect(find.text('Studio'), findsOneWidget, reason: "that computer's list, not the one shown before");

      // Answering later, it opens nothing by itself.
      state(made['abcd1234']!, withSession: true);
      await tester.pumpAndSettle();
      expect(page(tester), isNull);
      flush();
    });

    testWidgets('a session the computer no longer has goes at once, saying so', (tester) async {
      onMade = (_) {};
      final session = await pumpTwo(tester);
      session.onOtherLink(Uri.parse('pocketterm://session?key=abcd1234/kitty-1/2'));
      await opened(tester);
      state(made['abcd1234']!, withSession: false);
      await tester.pumpAndSettle();
      expect(page(tester), isNull);
      expect(find.textContaining('That session isn’t on Studio anymore'), findsOneWidget);
      flush();
    });
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
