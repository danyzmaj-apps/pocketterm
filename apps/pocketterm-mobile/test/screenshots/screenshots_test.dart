// The phone screenshots in the docs: the real screens on made-up data, as an iPhone (393×852 at 2×) and, for the
// Android look, an Android phone of the same size.
// Run from apps/pocketterm-mobile: `fvm flutter test --tags screenshots --run-skipped` (dart_test.yaml skips them otherwise).
// They land in the repo's docs/images/phone-*.png.
@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/demo/demo.dart';
import 'package:pocketterm_mobile/mobile.dart';

import 'fakes.dart';
import 'fonts.dart';

final _out = Directory('../../docs/images');
final _ios = TargetPlatformVariant.only(TargetPlatform.iOS);
final _android = TargetPlatformVariant.only(TargetPlatform.android);

/// The finished session's transcript, as the computer sends it to this phone.
Map<String, dynamic> _items() {
  final items = demoTranscripts()['kitty-1/3']!;
  return {
    'to': 'phone',
    'session': 'kitty-1/3',
    'epoch': 'e1',
    'seq': items.length,
    'reset': true,
    'last': true,
    'older': false,
    'items': [for (final i in items) i.toJson()],
  };
}

void main() {
  late String? missingFont;
  late Directory cache;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    missingFont = await loadRealFonts();
    _out.createSync(recursive: true);
  });

  setUp(() {
    cache = Directory.systemTemp.createTempSync('pocketterm_shots');
    // Pushes, keep-awake: nothing on the native side to answer.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('pocketterm/native'), (_) async => null)
      ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
      ..setMockStreamHandler(
        const EventChannel('com.llfbandit.app_links/events'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      );
  });

  tearDown(() => cache.deleteSync(recursive: true));

  /// The phone's screen: 393×852 points at 2×, with the notch's and home
  /// indicator's safe areas.
  void phone(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(786, 1704)
      ..devicePixelRatio = 2
      ..padding = const FakeViewPadding(top: 118, bottom: 68)
      ..viewPadding = const FakeViewPadding(top: 118, bottom: 68);
    addTearDown(tester.view.reset);
    // Soft shadows, as on the phone (tests draw them as black outlines).
    debugDisableShadows = false;
  }

  final shot = GlobalKey();

  Future<void> save(WidgetTester tester, String name) async {
    final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${_out.path}/$name').writeAsBytesSync(png!.buffer.asUint8List());
      image.dispose();
    });
    debugDisableShadows = true;
  }

  /// The app, signed in (else on its setup page), its Terminal list fed by [terminal].
  /// [tips]: its first-use tips not seen yet. [locked]: its computer's code not scanned yet.
  Future<void> app(
    WidgetTester tester, {
    required TerminalRemote terminal,
    bool signedIn = true,
    bool tips = false,
    bool locked = false,
    bool? push = false,
  }) async {
    phone(tester);
    final session = await FakeSession.create(signedIn: signedIn, tips: tips, push: push);
    if (locked) session.locked.add('abcd1234');
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: MobileApp(
          session: session,
          desktops: Desktops(
            offlineServer(),
            cached: [Desktop(id: 'abcd1234', name: 'MacBook Pro', platform: 'macos', seenAt: DateTime.now())],
            saved: 'abcd1234',
          ),
          remoteFor: (_, _) => terminal,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The computer, answering: its state and the finished session's transcript.
  TerminalRemote remote() =>
      TerminalRemote(
          // Never used: the remote talks through `send`.
          offlineServer(),
          cache,
          desktopId: 'abcd1234',
          key: testKey,
          from: 'phone',
          send: (_, _) {},
        )
        ..handle('state', demoState())
        ..handle('items', _items());

  bool skipped() {
    if (missingFont case final missing?) markTestSkipped('No $missing to draw with.');
    return missingFont != null;
  }

  testWidgets('terminal', variant: _ios, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r);
    await save(tester, 'phone-terminal.png');
    r.flush();
  });

  testWidgets('terminal on Android', variant: _android, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r);
    await save(tester, 'phone-terminal-android.png');
    r.flush();
  });

  testWidgets('a computer whose code the phone has not scanned', variant: _ios, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r, locked: true);
    await save(tester, 'phone-locked.png');
    r.flush();
  });

  testWidgets('terminal, a row swiped open', variant: _ios, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r);
    await tester.drag(find.byKey(const ValueKey('swipe-tmux-%4')), const Offset(-200, 0));
    // It slides back from past open to just open.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await save(tester, 'phone-swipe.png');
    r.flush();
  });

  /// The computer, with omp at work in the window that shows only its screen.
  TerminalRemote screenOnly() {
    late final TerminalRemote r;
    return r =
        TerminalRemote(
            offlineServer(),
            cache,
            desktopId: 'abcd1234',
            key: testKey,
            from: 'phone',
            send: (event, p) {
              if (event == 'run' && p['op'] == 'probe') {
                unawaited(Future(() => r.handle('ran', {'id': p['id'], 'busy': true})));
              }
            },
          )
          ..handle('state', demoState())
          ..handle('screen', {'window': demoScreenOnly, 'v': 1, 'lines': demoScreen(demoScreenOnly)});
  }

  testWidgets('switch a screen-only session', variant: _ios, (tester) async {
    if (skipped()) return;
    const window = demoScreenOnly;
    final r = screenOnly();
    await app(tester, terminal: r);
    final row = find.byKey(const ValueKey('term-$window'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('switch-open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await save(tester, 'phone-switch.png');
    r.flush();
  });

  /// Long enough for a page to settle and its first tip to show.
  Future<void> tipShows(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('tip: a screen-only session', variant: _ios, (tester) async {
    if (skipped()) return;
    const window = demoScreenOnly;
    final r = screenOnly();
    await app(tester, terminal: r, tips: true);
    await tester.ensureVisible(find.byKey(const ValueKey('term-$window')));
    await tipShows(tester);
    await save(tester, 'phone-tip-switch-open.png');
    r.flush();
  });

  testWidgets('tip: switch to conversation', variant: _ios, (tester) async {
    if (skipped()) return;
    const window = demoScreenOnly;
    final r = screenOnly();
    await app(tester, terminal: r, tips: true);
    await tester.ensureVisible(find.byKey(const ValueKey('term-$window')));
    await tipShows(tester);
    await tester.tap(find.byKey(const ValueKey('term-$window')));
    await tipShows(tester);
    await save(tester, 'phone-tip-switch-button.png');
    r.flush();
  });

  testWidgets('session', variant: _ios, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r);
    await tester.tap(find.text('Add a soil moisture endpoint'));
    await tester.pumpAndSettle();
    // The test run's card open, its output showing.
    await tester.tap(find.text('npm test -- moisture'));
    await tester.pumpAndSettle();
    await save(tester, 'phone-session.png');
    r.flush();
  });

  testWidgets('setup', variant: _ios, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r, signedIn: false);
    await save(tester, 'phone-setup.png');
    r.flush();
  });

  testWidgets('account', variant: _ios, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r, push: true);
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await save(tester, 'phone-account.png');
    r.flush();
  });

  testWidgets('notifications, asked after the first sign-in', variant: _ios, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r, push: null);
    await save(tester, 'phone-notifications.png');
    r.flush();
  });

  testWidgets('demo', variant: _ios, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r, signedIn: false);
    await tester.ensureVisible(find.byKey(const ValueKey('try-demo')));
    await tester.tap(find.byKey(const ValueKey('try-demo')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await save(tester, 'phone-demo.png');
    // Its computer stops answering.
    await tester.tap(find.byKey(const ValueKey('exit-demo')));
    await tester.pump();
    await tester.pump();
    r.flush();
  });
}
