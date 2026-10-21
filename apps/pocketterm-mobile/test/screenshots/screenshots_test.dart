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
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fakes.dart';
import 'fonts.dart';

final _out = Directory('../../docs/images');
final _ios = TargetPlatformVariant.only(TargetPlatform.iOS);
final _android = TargetPlatformVariant.only(TargetPlatform.android);

const _home = '/Users/demo';
const _garden = '$_home/Dev/garden-api';
const _site = '$_home/Dev/pocketterm-site';
const _seeds = '$_home/Dev/seed-catalog';

/// The computer's state: three coding sessions (finished, needing you, working)
/// and three plain terminal windows.
Map<String, dynamic> _state() {
  final now = DateTime.now();
  int ago(int minutes) => now.subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;
  return {
    'windows': [
      {'key': 'kitty-1/3', 'title': 'omp', 'cwd': _garden, 'program': 'omp', 'app': 'kitty'},
      {'key': 'iterm-2', 'title': 'claude', 'cwd': _site, 'program': 'claude', 'app': 'iterm'},
      {'key': 'tmux-%4', 'title': 'omp', 'cwd': _seeds, 'program': 'omp', 'app': 'tmux', 'via': 'Ghostty'},
      {'key': 'kitty-1/1', 'title': 'zsh', 'cwd': _garden, 'program': 'zsh', 'app': 'kitty', 'focused': true},
      {'key': 'tmux-%2', 'title': 'nvim README.md', 'cwd': _site, 'program': 'nvim', 'app': 'tmux', 'via': 'Ghostty'},
      {'key': 'iterm-1', 'title': 'htop', 'cwd': _home, 'program': 'htop', 'app': 'iterm'},
    ],
    'sessions': [
      {
        'key': 'kitty-1/3',
        'id': 's1',
        'agent': 'omp',
        'window': 'kitty-1/3',
        'title': 'Add a soil moisture endpoint',
        'cwd': _garden,
        'model': 'claude-sonnet-4.5',
        'ctx': 23,
        'preview': 'Done: GET /plants/:id/moisture, with tests.',
        'at': ago(4),
        'epoch': 'e1',
        'seq': 7,
      },
      {
        'key': 'iterm-2',
        'id': 's2',
        'agent': 'claude',
        'window': 'iterm-2',
        'title': 'Fix the pricing table on small screens',
        'cwd': _site,
        'model': 'opus',
        'ask': {'kind': 'approval', 'id': 'a1', 'tool': 'Bash', 'summary': 'npm run build'},
        'preview': 'Wants to run npm run build',
        'at': ago(1),
        'epoch': 'e1',
        'seq': 12,
      },
      {
        'key': 'tmux-%4',
        'id': 's3',
        'agent': 'omp',
        'window': 'tmux-%4',
        'title': 'Rate-limit the plant search',
        'cwd': _seeds,
        'busy': true,
        'preview': 'Running the integration tests…',
        'at': ago(0),
        'epoch': 'e1',
        'seq': 30,
      },
    ],
    'projects': [_garden, _site, _seeds],
    'home': _home,
    'agent': 'omp',
    'opensIn': 'kitty',
  };
}

/// The finished session's transcript, as the computer sends it to this phone.
Map<String, dynamic> _items() {
  var order = 0;
  Map<String, dynamic> item(
    ItemKind kind, {
    String text = '',
    String tool = '',
    String title = '',
    String args = '',
    String output = '',
  }) {
    order++;
    return LiveItem(
      id: 'it$order',
      kind: kind,
      text: text,
      tool: tool,
      title: title,
      args: args,
      output: output,
      status: ToolStatus.ok,
      order: order,
      seq: order,
    ).toJson();
  }

  return {
    'to': 'phone',
    'session': 'kitty-1/3',
    'epoch': 'e1',
    'seq': 7,
    'reset': true,
    'last': true,
    'older': false,
    'items': [
      item(
        ItemKind.user,
        text:
            'Add GET /plants/:id/moisture: the last 24 hours of soil readings, newest first. '
            'Reuse the sensor repo, and add tests.',
      ),
      item(ItemKind.assistant, text: 'Let me look at how the readings are stored first.'),
      item(ItemKind.tool, tool: 'read', title: 'src/sensors/repo.ts'),
      item(ItemKind.tool, tool: 'read', title: 'src/routes/plants.ts'),
      item(ItemKind.tool, tool: 'edit', title: 'src/routes/plants.ts'),
      item(
        ItemKind.tool,
        tool: 'bash',
        title: 'npm test -- moisture',
        output:
            ' PASS  test/moisture.test.ts\n'
            '  ✓ last 24 h, newest first (18 ms)\n'
            '  ✓ 404 for an unknown plant (4 ms)\n'
            '\n'
            'Tests:  2 passed, 2 total',
      ),
      item(
        ItemKind.assistant,
        text:
            'Done. `GET /plants/:id/moisture` now returns the last 24 h of readings:\n\n'
            '- `SensorRepo.readingsSince()` runs the query, on the `(plant_id, taken_at)` index\n'
            '- an unknown plant gets a **404**\n'
            '- `test/moisture.test.ts` covers both\n\n'
            'Want a `?hours=` parameter as well?',
      ),
    ],
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
  }) async {
    phone(tester);
    final session = await FakeSession.create(signedIn: signedIn, tips: tips);
    if (locked) session.locked.add('abcd1234');
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: MobileApp(
          session: session,
          desktops: Desktops(
            SupabaseClient('http://localhost:1', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)),
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
          SupabaseClient('http://localhost:1', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)),
          'user',
          cache,
          desktopId: 'abcd1234',
          key: testKey,
          from: 'phone',
          send: (_, _) {},
        )
        ..handle('state', _state())
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

  /// The computer with one more omp window, which shows only its screen and can switch; omp is at work in it.
  TerminalRemote screenOnly(String window) {
    final state = _state();
    late final TerminalRemote r;
    return r =
        TerminalRemote(
            SupabaseClient('http://localhost:1', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)),
            'user',
            cache,
            desktopId: 'abcd1234',
            key: testKey,
            from: 'phone',
            // omp is at work in it.
            send: (event, p) {
              if (event == 'run' && p['op'] == 'probe') {
                unawaited(Future(() => r.handle('ran', {'id': p['id'], 'busy': true})));
              }
            },
          )
          ..handle('state', {
            ...state,
            'windows': [
              ...state['windows'] as List,
              {'key': window, 'title': 'omp', 'cwd': _seeds, 'program': 'omp', 'app': 'kitty'},
            ],
            'agents': {'omp': 'installed', 'claude': 'installed'},
          })
          ..handle('screen', {
            'window': window,
            'v': 1,
            'lines': [
              ' Import the 2026 seed list from suppliers.csv',
              '',
              ' I will read the CSV, match each row to a catalog entry and',
              ' add the new varieties with their sowing months.',
              '',
              ' ╭──────────────────────────────────────────────╮',
              r' │ $ python scripts/import_seeds.py suppliers.csv │',
              ' ├─── Output ───────────────────────────────────┤',
              ' │ 412 rows read                                │',
              ' │ 388 matched, 24 new                          │',
              ' ╰──────────────────────────────────────────────╯',
              '',
              ' ⠼ 41s > Opus > seed-catalog',
              '╰─',
            ],
          });
  }

  testWidgets('switch a screen-only session', variant: _ios, (tester) async {
    if (skipped()) return;
    const window = 'kitty-1/7';
    final r = screenOnly(window);
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
    const window = 'kitty-1/7';
    final r = screenOnly(window);
    await app(tester, terminal: r, tips: true);
    await tester.ensureVisible(find.byKey(const ValueKey('term-$window')));
    await tipShows(tester);
    await save(tester, 'phone-tip-switch-open.png');
    r.flush();
  });

  testWidgets('tip: switch to conversation', variant: _ios, (tester) async {
    if (skipped()) return;
    const window = 'kitty-1/7';
    final r = screenOnly(window);
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
    await app(tester, terminal: r);
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await save(tester, 'phone-account.png');
    r.flush();
  });
}
