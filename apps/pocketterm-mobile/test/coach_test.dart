import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:pocketterm_mobile/terminal_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screenshots/fakes.dart';

const _a = '/Users/me/a';
const _b = '/Users/me/b';

void main() {
  late Directory dir;
  late List<(String, Map<String, dynamic>)> sent;
  late TerminalRemote remote;
  final client = offlineServer();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_coach');
    sent = [];
    remote = TerminalRemote(
      client,
      dir,
      desktopId: 'abcd1234',
      key: testKey,
      from: 'phone',
      send: (event, payload) => sent.add((event, payload)),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('pocketterm/native'), (_) async => null)
      ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
      ..setMockStreamHandler(
        const EventChannel('com.llfbandit.app_links/events'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  List<Map<String, dynamic>> runs(String op) => [
    for (final (event, p) in sent)
      if (event == 'run' && p['op'] == op) p,
  ];

  /// Two projects with a session each; with [screenOnly], also an omp window no session claims, which the phone
  /// can switch.
  void state({bool screenOnly = false, List<Map<String, dynamic>> more = const []}) {
    Map<String, dynamic> window(String key, String cwd) => {
      'key': key,
      'title': 'omp',
      'cwd': cwd,
      'program': 'omp',
      'app': 'kitty',
    };
    remote.handle('state', {
      'windows': [window('kitty-1/1', _a), window('kitty-1/2', _b), if (screenOnly) window('kitty-1/7', _a)],
      'sessions': [
        {'key': 'kitty-1/1', 'id': 's1', 'agent': 'omp', 'window': 'kitty-1/1', 'title': 'First', 'cwd': _a},
        {'key': 'kitty-1/2', 'id': 's2', 'agent': 'omp', 'window': 'kitty-1/2', 'title': 'Second', 'cwd': _b},
        ...more,
      ],
      'home': '/Users/me',
      'agent': 'omp',
      'agents': {'omp': 'installed'},
    });
  }

  /// The app, signed in, its tips not yet seen (unless [fresh] is false: the same phone's prefs as before); with
  /// [asked] false, the first-use question not answered yet. [push] null: the notifications question still to come.
  Future<void> app(WidgetTester tester, {bool fresh = true, bool asked = true, bool? push = false}) async {
    tester.view
      ..physicalSize = const Size(1179, 2556)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MobileApp(
        session: await FakeSession.create(tips: true, asked: asked, fresh: fresh, push: push),
        desktops: Desktops(
          client,
          cached: [Desktop(id: 'abcd1234', name: 'MacBook Pro', platform: 'macos', seenAt: DateTime.now())],
          saved: 'abcd1234',
        ),
        remoteFor: (_, _) => remote,
      ),
    );
  }

  /// Long enough for a page to settle and its next tip to show.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Finder tip(String id) => find.byKey(ValueKey('tip-$id'));

  /// Any tip: each has one Got it.
  final anyTip = find.byKey(const ValueKey('tip-got-it'));

  Future<void> gotIt(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('tip-got-it')));
    await settle(tester);
  }

  testWidgets('list tips show one at a time in order, each once, also on the next launch', (tester) async {
    state();
    await app(tester);
    await settle(tester);
    expect(tip('project-heading'), findsOneWidget);
    expect(anyTip, findsOneWidget);
    // Read out to a screen reader.
    expect(find.bySemanticsLabel('Tap to fold this project. Long-press for its menu.'), findsOneWidget);

    await gotIt(tester);
    expect(tip('project-heading'), findsNothing);
    expect(tip('swipe-row'), findsOneWidget);
    expect(anyTip, findsOneWidget);

    // Tapping the dimmed rest dismisses it too, and does nothing else.
    await tester.tapAt(const Offset(5, 400));
    await settle(tester);
    expect(tip('swipe-row'), findsNothing);
    expect(tip('new-session'), findsOneWidget);
    expect(find.byType(SessionPage), findsNothing);

    // The same phone, the app started again: the next one, not the ones seen.
    await tester.pumpWidget(const SizedBox());
    await app(tester, fresh: false);
    await settle(tester);
    expect(tip('project-heading'), findsNothing);
    expect(tip('swipe-row'), findsNothing);
    expect(tip('new-session'), findsOneWidget);
    await gotIt(tester);
    expect(anyTip, findsNothing);
    remote.flush();
  });

  testWidgets('Show tips again shows them again', (tester) async {
    state();
    await app(tester);
    await settle(tester);
    for (final id in ['project-heading', 'swipe-row', 'new-session']) {
      expect(tip(id), findsOneWidget, reason: id);
      await gotIt(tester);
    }
    expect(anyTip, findsNothing);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    expect(anyTip, findsNothing, reason: 'no tip over a sheet');
    await tester.tap(find.byKey(const ValueKey('show-tips')));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(tip('project-heading'), findsOneWidget);
    remote.flush();
  });

  final question = find.text('New here?');

  testWidgets('the first time on the list it asks first; Show me starts the tips, and it asks only once', (
    tester,
  ) async {
    state();
    await app(tester, asked: false);
    await settle(tester);
    expect(question, findsOneWidget);
    expect(find.text('Want a quick tour? A few tips point out what you can tap, one at a time.'), findsOneWidget);
    expect(anyTip, findsNothing, reason: 'no tip before the answer');

    await tester.tap(find.text('Show me'));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(question, findsNothing);
    expect(tip('project-heading'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await app(tester, fresh: false);
    await settle(tester);
    expect(question, findsNothing);
    expect(tip('project-heading'), findsOneWidget, reason: 'the tour goes on where it was');
    remote.flush();
  });

  testWidgets('No thanks: no tips now or after a restart, and Show tips again brings them without asking', (
    tester,
  ) async {
    state();
    await app(tester, asked: false);
    await settle(tester);
    await tester.tap(find.text('No thanks'));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(question, findsNothing);
    expect(anyTip, findsNothing);

    await tester.pumpWidget(const SizedBox());
    await app(tester, fresh: false);
    await settle(tester);
    expect(question, findsNothing);
    expect(anyTip, findsNothing);

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('show-tips')));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(question, findsNothing);
    expect(tip('project-heading'), findsOneWidget);
    remote.flush();
  });

  testWidgets('not over the notifications question: it asks once that one is answered', (tester) async {
    state();
    await app(tester, asked: false, push: null);
    await settle(tester);
    expect(find.byKey(const ValueKey('push-not-now')), findsOneWidget);
    expect(question, findsNothing);

    await tester.tap(find.byKey(const ValueKey('push-not-now')));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(question, findsOneWidget);
    expect(anyTip, findsNothing);
    remote.flush();
  });

  testWidgets('the switch tour: tapping the spotlit row opens it, then the banner, then the switched row', (
    tester,
  ) async {
    state(screenOnly: true);
    await app(tester);
    await settle(tester);
    // Before every list tip, though the projects come first on the list.
    expect(tip('switch-open'), findsOneWidget);
    expect(anyTip, findsOneWidget);

    // The row itself does what it does: its screen opens, and the tip is seen.
    await tester.tap(find.byKey(const ValueKey('term-kitty-1/7')));
    await tester.pump();
    expect(anyTip, findsNothing);
    await settle(tester);
    expect(find.byType(TerminalPage), findsOneWidget);
    expect(tip('switch-button'), findsOneWidget);
    expect(anyTip, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('switch-open')));
    await tester.pump();
    expect(anyTip, findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    remote.handle('ran', {'id': runs('probe').single['id'], 'busy': false});
    await tester.pump();
    await tester.tap(find.text('Restart now'));
    await tester.pump();
    await tester.pump(Duration.zero);
    remote.handle('ran', {'id': runs('switch').single['id']});
    state(
      screenOnly: true,
      more: [
        {'key': 'kitty-1/7', 'id': 's7', 'agent': 'omp', 'window': 'kitty-1/7', 'title': 'Switched', 'cwd': _a},
      ],
    );
    await settle(tester);
    expect(find.byType(SessionPage), findsOneWidget);
    // The conversation page's own first tip.
    expect(tip('slash'), findsOneWidget);
    await gotIt(tester);
    if (tip('open-screen').evaluate().isNotEmpty) await gotIt(tester);

    await tester.pageBack();
    await settle(tester);
    expect(find.byType(TerminalList), findsOneWidget);
    expect(tip('switch-done'), findsOneWidget);
    expect(tip('switch-open'), findsNothing);

    // Seen with the row: tapping it opens its session.
    await tester.tap(find.byKey(const ValueKey('session-kitty-1/7')));
    await tester.pump();
    expect(anyTip, findsNothing);
    await settle(tester);
    expect(find.byType(SessionPage), findsOneWidget);
    remote.flush();
  });

  // E2E debug builds start with every tip seen and the question answered, so the flows aren't held up; Show tips
  // again brings the tips back, also after the app restarts, as on any phone.
  test('tips seen from the start stay gone until Show tips again', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final first = CoachController(prefs, startSeen: true);
    expect(first.answered, isTrue);
    expect(Tip.values.where(first.seen), Tip.values);
    expect(Tip.values.where(CoachController(prefs, startSeen: true).seen), Tip.values);

    await first.reset();
    expect(Tip.values.where(first.seen), isEmpty);
    final relaunched = CoachController(prefs, startSeen: true);
    expect(Tip.values.where(relaunched.seen), isEmpty);
    await relaunched.markSeen(Tip.slash);
    expect(Tip.values.where(CoachController(prefs, startSeen: true).seen), [Tip.slash]);

    SharedPreferences.setMockInitialValues({});
    final store = CoachController(await SharedPreferences.getInstance());
    expect(store.answered, isFalse);
    expect(Tip.values.where(store.seen), isEmpty);
  });
}
