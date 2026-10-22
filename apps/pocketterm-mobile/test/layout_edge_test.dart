import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/demo/demo.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/push_consent.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:pocketterm_mobile/setup_page.dart';
import 'package:pocketterm_mobile/switch_view.dart';
import 'package:pocketterm_mobile/terminal_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screenshots/fakes.dart';

/// 200 characters and no space to break at: a title, folder or computer name nothing can wrap.
final String _long = List.filled(20, 'Abcdefghij').join();

/// A screen the app runs on: its logical size, text size, direction and platform.
typedef _Screen = ({String name, Size size, double text, bool rtl, TargetPlatform platform});

const _screens = <_Screen>[
  (name: 'iPhone SE', size: Size(320, 568), text: 1, rtl: false, platform: TargetPlatform.iOS),
  (name: '320dp Android', size: Size(320, 640), text: 1, rtl: false, platform: TargetPlatform.android),
  (name: 'text at 200%', size: Size(375, 667), text: 2, rtl: false, platform: TargetPlatform.iOS),
  (name: 'landscape', size: Size(667, 375), text: 1, rtl: false, platform: TargetPlatform.iOS),
  (name: 'iPad split 320', size: Size(320, 1024), text: 1, rtl: false, platform: TargetPlatform.iOS),
  (name: 'iPad split 507', size: Size(507, 1024), text: 1, rtl: false, platform: TargetPlatform.iOS),
  (name: 'iPad split 678', size: Size(678, 1024), text: 1, rtl: false, platform: TargetPlatform.iOS),
  (name: 'right to left', size: Size(375, 667), text: 1, rtl: true, platform: TargetPlatform.android),
];

/// A phone signed in to a server named [name] (or not, for setup and the demo), holding a key for every computer
/// but the [locked] ones.
class _Phone extends MobileSession {
  _Phone._(SharedPreferences prefs, this.name, this._signedIn) : super(prefs, 'iPhone');
  final String name;
  final bool _signedIn;
  final locked = <String>{};

  static Future<_Phone> create({String name = 'ana.example.com', bool signedIn = true, bool tips = false}) async {
    SharedPreferences.setMockInitialValues({
      CoachController.seenKey: [
        if (!tips)
          for (final t in Tip.values) t.id,
      ],
      'pocketterm_push_on_server': true,
    });
    return _Phone._(await SharedPreferences.getInstance(), name, signedIn);
  }

  @override
  final PushRecorder server = PushRecorder();

  @override
  Backend? get backend => null;

  @override
  ChannelKey? computerKey(String desktopId) => locked.contains(desktopId) ? null : testKey;

  @override
  Account? get user => _signedIn
      ? const Account(
          id: 'server',
          device: Device(id: 'phone', role: DeviceRole.phone, label: 'iPhone', platform: 'ios'),
        )
      : null;

  @override
  String get userName => name;
}

void main() {
  late Directory dir;
  late List<TerminalRemote> remotes;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_layout');
    remotes = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('pocketterm/native'), (_) async => null)
      ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
      ..setMockStreamHandler(
        const EventChannel('com.llfbandit.app_links/events'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      )
      // The cache folder never comes: the selected computer stays "Reaching".
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) => Completer<Object?>().future,
      );
  });
  tearDown(() {
    for (final r in remotes) {
      r.flush();
    }
    dir.deleteSync(recursive: true);
  });

  /// [home] on [screen], laid out as the app does it.
  Future<void> pump(WidgetTester tester, _Screen screen, Widget home, {MobileSession? session}) async {
    tester.view
      ..physicalSize = screen.size * 3
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = screen.platform;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        builder: (context, child) {
          Widget app = Directionality(textDirection: screen.rtl ? TextDirection.rtl : TextDirection.ltr, child: child!);
          if (session != null) app = Coach(controller: session.tips, child: app);
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(screen.text)),
            child: app,
          );
        },
        home: home,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The tree gone and the remotes' timers run out; the platform back to the test's.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    debugDefaultTargetPlatformOverride = null;
  }

  /// Nothing overflowed and nothing threw.
  void clean(WidgetTester tester, String what) {
    expect(tester.takeException(), isNull, reason: what);
  }

  /// Every tap target is labelled, and big enough on the screen's platform.
  Future<void> accessible(WidgetTester tester, _Screen screen) async {
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(
      tester,
      meetsGuideline(screen.platform == TargetPlatform.iOS ? iOSTapTargetGuideline : androidTapTargetGuideline),
    );
  }

  /// A computer whose project folder, session titles and window titles are all [_long], plus the demo's.
  Map<String, dynamic> longState() {
    final state = demoState();
    final cwd = '/Users/me/$_long';
    final now = DateTime.now().millisecondsSinceEpoch;
    return {
      ...state,
      'windows': [
        ...state['windows'] as List,
        {'key': 'kitty-9/1', 'title': _long, 'cwd': cwd, 'program': 'omp', 'app': 'kitty'},
        {'key': 'kitty-9/2', 'title': _long, 'cwd': cwd, 'program': _long, 'app': 'kitty'},
      ],
      'sessions': [
        ...state['sessions'] as List,
        {
          'key': 'kitty-9/1',
          'id': 's91',
          'agent': 'omp',
          'window': 'kitty-9/1',
          'title': _long,
          'cwd': cwd,
          'preview': _long,
          'ask': {'kind': 'approval', 'id': 'a9', 'tool': 'Bash', 'summary': _long},
          'at': now,
          'epoch': 'e1',
          'seq': 1,
        },
      ],
      'projects': [...state['projects'] as List, cwd],
    };
  }

  /// A computer answering its list with [state] and each session's conversation with the demo's, plus a [_long] line.
  TerminalRemote computer(String id, Map<String, dynamic> state) {
    late final TerminalRemote remote;
    remote = TerminalRemote(
      offlineServer(),
      dir,
      desktopId: id,
      key: testKey,
      from: 'phone',
      send: (event, p) => scheduleMicrotask(() {
        if (event == 'run' && p['op'] == 'probe') remote.handle('ran', {'id': p['id'], 'busy': true});
        if (event == 'sync' && p['window'] is String) {
          remote.handle('screen', {
            'window': p['window'],
            'v': 1,
            'lines': [...demoScreen(p['window'] as String), _long],
          });
        }
        if (event == 'sync' && p['session'] is String) {
          final items = [...?demoTranscripts()[p['session']]];
          remote.handle('items', {
            'to': 'phone',
            'session': p['session'],
            'epoch': 'e1',
            'seq': items.length,
            'reset': true,
            'last': true,
            'older': false,
            'items': [for (final i in items) i.toJson()],
          });
        }
      }),
    )..handle('state', state);
    remotes.add(remote);
    return remote;
  }

  Desktops desktops(int count, {String? name}) => Desktops(offlineServer())
    ..apply([
      for (var i = 0; i < count; i++)
        {
          'id': 'mac${i.toString().padLeft(5, '0')}',
          'name': i == 0 ? (name ?? _long) : '$_long $i',
          'platform': i.isEven ? 'macos' : 'windows',
          'seen_at': DateTime.now().subtract(Duration(hours: i)).toUtc().toIso8601String(),
        },
    ]);

  Future<_Phone> home(
    WidgetTester tester,
    _Screen screen, {
    Desktops? list,
    Map<String, dynamic>? state,
    bool noRemote = false,
    String name = 'ana.example.com',
    bool tips = false,
    void Function(_Phone)? prepare,
  }) async {
    final session = await _Phone.create(name: name, tips: tips);
    prepare?.call(session);
    await pump(
      tester,
      screen,
      HomePage(
        session: session,
        userId: 'server',
        desktops: list ?? desktops(1),
        remoteFor: noRemote ? null : (id, _) => computer(id, state ?? longState()),
      ),
      session: session,
    );
    return session;
  }

  /// The page title's name, which picks the computer.
  final title = find.descendant(of: find.byType(PageTitle), matching: find.byType(Text)).first;

  /// The Terminal list's scrolling.
  final list = find.descendant(of: find.byType(TerminalList), matching: find.byType(Scrollable)).first;

  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  for (final screen in _screens) {
    group(screen.name, () {
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      testWidgets('setup', (tester) async {
        final session = await _Phone.create(signedIn: false);
        await pump(
          tester,
          screen,
          Scaffold(
            body: SafeArea(
              child: SetupPage(session: session, onDemo: () {}),
            ),
          ),
        );
        clean(tester, 'setup');
        await accessible(tester, screen);
        await finish(tester);
      });

      testWidgets('notifications', (tester) async {
        await pump(tester, screen, PushConsentPage(session: await _Phone.create()));
        clean(tester, 'notifications');
        await accessible(tester, screen);
        await finish(tester);
      });

      testWidgets('home: long names and titles, then the account sheet', (tester) async {
        await home(tester, screen, name: _long);
        clean(tester, 'home');
        await accessible(tester, screen);

        await tester.tap(find.byTooltip('Account'));
        await settleSheet(tester);
        expect(find.byKey(const ValueKey('push-toggle')), findsOneWidget);
        clean(tester, 'account sheet');
        await accessible(tester, screen);
        await finish(tester);
      });

      testWidgets('home: the computer picker with one computer and with 40', (tester) async {
        await home(tester, screen);
        await tester.tap(title);
        await settleSheet(tester);
        expect(find.byKey(const ValueKey('desktop-mac00000')), findsOneWidget);
        clean(tester, 'one computer');
        await accessible(tester, screen);
        Navigator.of(tester.element(find.byKey(const ValueKey('scan-computer')))).pop();
        await settleSheet(tester);

        await tester.pumpWidget(const SizedBox());
        await home(tester, screen, list: desktops(40));
        await tester.tap(title);
        await settleSheet(tester);
        expect(find.byKey(const ValueKey('desktop-mac00000')), findsOneWidget);
        clean(tester, '40 computers');
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('scan-computer')),
          200,
          scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first,
        );
        await accessible(tester, screen);
        await finish(tester);
      });

      testWidgets('home: no computers, looking, reaching, locked, no sessions', (tester) async {
        await home(tester, screen, list: desktops(0));
        clean(tester, 'no computers');
        await tester.tap(title);
        await settleSheet(tester);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('scan-computer')),
          200,
          scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first,
        );
        clean(tester, 'picker with no computers');

        await tester.pumpWidget(const SizedBox());
        await home(tester, screen, list: Desktops(offlineServer()), noRemote: true);
        clean(tester, 'looking for computers');

        await tester.pumpWidget(const SizedBox());
        await home(tester, screen, noRemote: true);
        clean(tester, 'reaching');

        await tester.pumpWidget(const SizedBox());
        await home(tester, screen, prepare: (s) => s.locked.add('mac00000'));
        expect(find.byKey(const ValueKey('scan-locked-computer')), findsOneWidget);
        clean(tester, 'locked');
        await accessible(tester, screen);

        await tester.pumpWidget(const SizedBox());
        await home(tester, screen, state: {'windows': <Object>[], 'sessions': <Object>[], 'home': '/Users/me'});
        clean(tester, 'no sessions');
        await accessible(tester, screen);
        await finish(tester);
      });

      testWidgets('first-use tips', (tester) async {
        await home(tester, screen, tips: true);
        await tester.pump(const Duration(seconds: 2));
        clean(tester, 'tips');
        await finish(tester);
      });

      testWidgets('a session with the keyboard up', (tester) async {
        await home(tester, screen);
        await tester.tap(find.byKey(const ValueKey('session-kitty-9/1')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(SessionPage), findsOneWidget);
        expect(find.byKey(const ValueKey('approve')), findsOneWidget, reason: 'its question shows');
        clean(tester, 'session');
        await accessible(tester, screen);

        tester.view.viewInsets = FakeViewPadding(bottom: screen.size.height * .45 * 3);
        await tester.showKeyboard(find.byKey(const ValueKey('session-input')));
        await tester.enterText(find.byKey(const ValueKey('session-input')), '$_long\n$_long');
        await tester.pump(const Duration(milliseconds: 500));
        clean(tester, 'session, keyboard up');
        for (final label in ['Send', 'Attach images or files']) {
          expect(find.byTooltip(label), findsOneWidget, reason: label);
        }
        await finish(tester);
      });

      testWidgets("a window's screen with the keyboard up", (tester) async {
        await home(tester, screen);
        final row = find.byKey(const ValueKey('term-kitty-9/2'));
        await tester.scrollUntilVisible(row, 200, scrollable: list);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(row);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(TerminalPage), findsOneWidget);
        clean(tester, 'screen');
        await accessible(tester, screen);

        tester.view.viewInsets = FakeViewPadding(bottom: screen.size.height * .45 * 3);
        await tester.showKeyboard(find.byType(TextField));
        await tester.enterText(find.byType(TextField), '$_long\n$_long');
        await tester.pump(const Duration(milliseconds: 500));
        clean(tester, 'screen, keyboard up');
        await finish(tester);
      });

      testWidgets('a screen-only session, offered to switch', (tester) async {
        await home(tester, screen);
        final row = find.byKey(const ValueKey('term-$demoScreenOnly'));
        await tester.scrollUntilVisible(row, 200, scrollable: list);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(row);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        clean(tester, 'screen-only window');
        await tester.tap(find.byKey(const ValueKey('switch-open')));
        await settleSheet(tester);
        expect(find.byType(SwitchSheet), findsOneWidget);
        clean(tester, 'switch sheet');
        await accessible(tester, screen);
        await finish(tester);
      });

      testWidgets('a row swiped open', (tester) async {
        await home(tester, screen);
        await tester.drag(find.byKey(const ValueKey('swipe-kitty-9/1')), Offset(screen.rtl ? 300 : -300, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        clean(tester, 'swiped row');
        expect(find.byKey(const ValueKey('swipe-action-kitty-9/1')), findsOneWidget);
        await finish(tester);
      });

      testWidgets('a new session', (tester) async {
        await home(
          tester,
          screen,
          state: {
            ...longState(),
            'roots': ['/Users/me/$_long', '/Users/me/Code'],
          },
        );
        await tester.tap(find.byTooltip('New session'));
        await settleSheet(tester);
        expect(find.byType(NewSessionSheet), findsOneWidget);
        clean(tester, 'new session sheet');
        await accessible(tester, screen);
        await finish(tester);
      });

      testWidgets('the demo', (tester) async {
        final session = await _Phone.create(signedIn: false);
        session.enterDemo();
        final demo = session.demo!;
        await pump(
          tester,
          screen,
          HomePage(session: session, userId: demoDesktopId, desktops: demo.desktops, remoteFor: (_, _) => demo.remote),
          session: session,
        );
        clean(tester, 'demo');
        await accessible(tester, screen);
        session.exitDemo();
        await finish(tester);
      });
    });
  }
}
