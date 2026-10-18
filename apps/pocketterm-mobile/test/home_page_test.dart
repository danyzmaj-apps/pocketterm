import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screenshots/fakes.dart';

void main() {
  late Directory dir;
  late Map<String, TerminalRemote> made;
  late String? tapped;
  final client = SupabaseClient(
    'http://localhost:1',
    'anon',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

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
  TerminalRemote remoteFor(String desktopId, String title) =>
      TerminalRemote(client, 'u1', dir, desktopId: desktopId, from: 'phone', send: (_, _) {})..handle('state', {
        'windows': <Object>[],
        'sessions': [
          {'key': 'kitty-1/1', 'id': 's1', 'title': title, 'cwd': '/Users/me/app', 'epoch': 'e', 'seq': 0},
        ],
      });

  Future<Desktops> pumpHome(WidgetTester tester) async {
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
        session: await FakeSession.create(),
        desktops: desktops,
        remoteFor: (id) => made[id] = remoteFor(id, id == 'mac00001' ? 'Mac work' : 'PC work'),
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
}
