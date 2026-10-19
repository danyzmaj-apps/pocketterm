import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:pocketterm_mobile/terminal_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Phone extends MobileSession {
  _Phone(SharedPreferences prefs) : super(prefs, 'iPhone');
}

const _a = '/Users/me/a';
const _b = '/Users/me/b';
const _z = '/Users/me/z';

void main() {
  late Directory dir;
  late List<(String, Map<String, dynamic>)> sent;
  late TerminalRemote remote;
  late SharedPreferences prefs;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pocketterm_terminal_list');
    sent = [];
    remote = TerminalRemote(
      SupabaseClient('http://localhost:1', 'anon'),
      'u1',
      dir,
      desktopId: 'abcd1234',
      from: 'phone',
      send: (event, payload) => sent.add((event, payload)),
    );
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// Project z: one session needing you, listed last, and a newer idle one;
  /// a: one idle; b: one working; c: one in a terminal PocketTerm doesn't drive
  /// (IntelliJ's: no window). Plus a shell. By name: a, b, c, z; by
  /// activity: b, z, a, c.
  void macState() {
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> window(String key, String cwd, String program) => {
      'key': key,
      'title': program,
      'cwd': cwd,
      'program': program,
      'app': 'kitty',
    };
    remote.handle('state', {
      'windows': [
        window('kitty-1/1', _z, 'omp'),
        window('kitty-1/2', _a, 'omp'),
        window('kitty-1/3', _b, 'omp'),
        window('kitty-1/4', '/Users/me', 'zsh'),
        window('kitty-1/5', _z, 'omp'),
      ],
      'sessions': [
        {
          'key': 'kitty-1/2',
          'id': 's2',
          'agent': 'omp',
          'window': 'kitty-1/2',
          'title': 'Idle one',
          'cwd': _a,
          'at': now - 600000,
        },
        {
          'key': 'kitty-1/3',
          'id': 's3',
          'agent': 'omp',
          'window': 'kitty-1/3',
          'title': 'Working one',
          'cwd': _b,
          'busy': true,
          'at': now,
        },
        {'key': 'pid:9', 'id': 's9', 'agent': 'omp', 'title': 'In IntelliJ', 'cwd': '/Users/me/c', 'at': now - 900000},
        {'key': 'pid:8', 'id': 's8', 'agent': 'omp', 'title': '', 'cwd': '', 'at': now - 1000000},
        {
          'key': 'kitty-1/5',
          'id': 's5',
          'agent': 'omp',
          'window': 'kitty-1/5',
          'title': 'Newer idle',
          'cwd': _z,
          'at': now - 60000,
        },
        {
          'key': 'kitty-1/1',
          'id': 's1',
          'agent': 'omp',
          'window': 'kitty-1/1',
          'title': 'Asking one',
          'cwd': _z,
          'ask': {'kind': 'approval', 'id': 'q1', 'tool': 'Bash', 'summary': 'ls'},
          'at': now - 1200000,
        },
      ],
      'projects': [_a, _b],
      'home': '/Users/me',
      'agent': 'omp',
      'opensIn': 'kitty',
    });
  }

  Future<void> pumpList(WidgetTester tester, {Key? key}) async {
    // An iPhone's screen, so the whole list is laid out.
    tester.view
      ..physicalSize = const Size(1179, 2556)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('pocketterm/native'),
      (_) async => null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalList(
            key: key,
            remote: remote,
            folded: _Phone(prefs).collapsedProjects,
            onFolded: _Phone(prefs).setCollapsedProjects,
            sort: _Phone(prefs).projectSort,
            onSort: _Phone(prefs).setProjectSort,
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> runs(String op) => [
    for (final (event, p) in sent)
      if (event == 'run' && p['op'] == op) p,
  ];

  Finder session(String key) => find.byKey(ValueKey('session-$key'));

  /// A project heading, as read.
  String heading(WidgetTester tester, String cwd) => tester
      .widget<Text>(find.descendant(of: find.byKey(ValueKey('project-$cwd')), matching: find.byType(Text)).first)
      .data!;

  double top(WidgetTester tester, String cwd) => tester.getTopLeft(find.byKey(ValueKey('project-$cwd'))).dy;

  /// Long-presses project [cwd]'s heading: its menu. Not to settle: a
  /// spinner (a session starting, the link checking) never does.
  Future<void> menu(WidgetTester tester, String cwd) async {
    await tester.longPress(find.text(heading(tester, cwd)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('projects go by name, sessions in the order the computer saw them, whatever needs you', (tester) async {
    macState();
    await pumpList(tester);

    expect(top(tester, _a), lessThan(top(tester, _b)));
    expect(top(tester, _b), lessThan(top(tester, '/Users/me/c')));
    expect(top(tester, '/Users/me/c'), lessThan(top(tester, _z)), reason: 'z needing you does not lift it');
    expect(top(tester, _z), lessThan(top(tester, '')), reason: 'somewhere unknown comes last');
    expect(heading(tester, _z), 'Z');
    expect(heading(tester, ''), 'SOMEWHERE');
    expect(find.textContaining('~/'), findsNothing, reason: 'the heading names the project once, without its path');
    expect(find.byIcon(Icons.add), findsNothing, reason: 'no + on the headings');
    expect(find.byIcon(Icons.expand_more), findsNothing, reason: 'no fold arrows on the headings');
    // In z's group: the computer's order, the asking one not lifted.
    expect(tester.getTopLeft(session('kitty-1/5')).dy, lessThan(tester.getTopLeft(session('kitty-1/1')).dy));
    expect(find.descendant(of: session('pid:8'), matching: find.text('omp')), findsOneWidget);
    expect(find.text('OTHER WINDOWS'), findsOneWidget);
    expect(find.byKey(const ValueKey('term-kitty-1/4')), findsOneWidget);
    expect(
      find.ancestor(of: session('pid:9'), matching: find.byType(Dismissible)),
      findsNothing,
      reason: 'a session without a window has nothing to close',
    );

    // Somewhere unknown has nowhere to start a session.
    await menu(tester, '');
    expect(find.byKey(const ValueKey('project-menu-new')), findsNothing);
    expect(find.byKey(const ValueKey('project-menu-fold')), findsOneWidget);
    remote.flush();
  });

  testWidgets('by recent activity, projects keep their place until the list is refreshed, and the choice is kept', (
    tester,
  ) async {
    macState();
    await pumpList(tester);
    await tester.tap(find.byKey(const ValueKey('project-sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recent activity').last);
    await tester.pumpAndSettle();
    expect(prefs.getString('pocketterm_terminal_sort'), 'activity');

    expect(top(tester, _b), lessThan(top(tester, _z)));
    expect(top(tester, _z), lessThan(top(tester, _a)));
    expect(top(tester, _a), lessThan(top(tester, '/Users/me/c')));

    // a gets busy now: it stays where it is while the list is up.
    final state = remote.sessions.map((s) => s.toJson()).toList();
    final a = state.indexWhere((s) => s['cwd'] == _a);
    state[a] = {...state[a], 'busy': true, 'at': DateTime.now().millisecondsSinceEpoch + 1000};
    remote.handle('state', {
      'windows': [for (final w in remote.windows) w.toJson()],
      'sessions': state,
      'home': '/Users/me',
      'agent': 'omp',
    });
    await tester.pump();
    expect(top(tester, _b), lessThan(top(tester, _a)), reason: 'no reshuffle while looking');

    // Pulled to refresh: ranked afresh.
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(top(tester, _a), lessThan(top(tester, _b)));

    await pumpList(tester, key: const ValueKey('again'));
    expect(find.text('Recent activity'), findsOneWidget, reason: 'the sort is kept');
    remote.flush();
  });

  testWidgets('a long folder name gets the row; its menu starts the agent there', (tester) async {
    const long = '/Users/me/IdeaProjects/customer-integration-service-frontend-and-more';
    remote.handle('state', {
      'windows': [
        {'key': 'kitty-1/7', 'title': 'omp', 'cwd': long, 'program': 'omp', 'app': 'kitty'},
      ],
      'sessions': [
        {'key': 'kitty-1/7', 'id': 's7', 'agent': 'omp', 'window': 'kitty-1/7', 'title': 'Long', 'cwd': long},
      ],
      'home': '/Users/me',
      'agent': 'omp',
    });
    await pumpList(tester);

    expect(tester.takeException(), isNull, reason: 'no overflow');
    expect(
      tester.getSize(find.text(long.split('/').last.toUpperCase())).width,
      greaterThan(250),
      reason: 'the name gets most of the row',
    );
    await menu(tester, long);
    expect(find.text('~/IdeaProjects/customer-integration-service-frontend-and-more'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('project-menu-new')));
    await tester.pump(Duration.zero);
    final launch = runs('launch').single;
    expect(launch, containsPair('cwd', long));
    remote.handle('ran', {'id': launch['id'], 'error': 'No such folder.'});
    await tester.pump();
    remote.flush();
  });

  testWidgets("a project's menu starts the agent there and opens its session, the heading spinning meanwhile", (
    tester,
  ) async {
    macState();
    await pumpList(tester);

    await menu(tester, _b);
    expect(find.text('New omp session here'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('project-menu-new')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final launch = runs('launch').single;
    expect(launch, containsPair('cwd', _b));
    expect(launch, containsPair('agent', true));
    expect(find.byKey(const ValueKey('project-launching-$_b')), findsOneWidget);
    expect(session('kitty-1/3'), findsOneWidget, reason: 'starting one does not fold the project');

    remote.handle('ran', {'id': launch['id'], 'window': 'kitty-1/9'});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SessionPage), findsOneWidget);
    expect(tester.widget<SessionPage>(find.byType(SessionPage)).sessionKey, 'kitty-1/9');
    remote.flush();
  });

  testWidgets('a folded project shows one summary row that still says what needs you, and stays folded next time', (
    tester,
  ) async {
    macState();
    await pumpList(tester);

    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(session('kitty-1/2'), findsNothing);
    expect(find.byKey(const ValueKey('project-summary-$_a')), findsOneWidget);
    expect(session('kitty-1/3'), findsOneWidget);
    expect(prefs.getStringList('pocketterm_terminal_folded'), [_a]);

    await pumpList(tester, key: const ValueKey('again'));
    expect(session('kitty-1/2'), findsNothing);

    // Tapping the summary opens it again.
    await tester.tap(find.byKey(const ValueKey('project-summary-$_a')));
    await tester.pump();
    expect(session('kitty-1/2'), findsOneWidget);
    expect(prefs.getStringList('pocketterm_terminal_folded'), isEmpty);

    await tester.tap(find.text('Z'));
    await tester.pump();
    expect(find.text('2 sessions · 1 needs you'), findsOneWidget);
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(find.text('1 session · 1 working'), findsOneWidget);
    remote.flush();
  });

  testWidgets("a project's menu folds all the others, then unfolds them all", (tester) async {
    macState();
    await pumpList(tester);

    await menu(tester, _b);
    await tester.tap(find.byKey(const ValueKey('project-menu-fold-others')));
    await tester.pumpAndSettle();
    expect(session('kitty-1/3'), findsOneWidget);
    expect(session('kitty-1/2'), findsNothing);
    expect(session('kitty-1/1'), findsNothing);
    expect(prefs.getStringList('pocketterm_terminal_folded')!.toSet(), {_a, _z, '/Users/me/c', ''});

    await menu(tester, _b);
    await tester.tap(find.byKey(const ValueKey('project-menu-unfold-all')));
    await tester.pumpAndSettle();
    expect(session('kitty-1/2'), findsOneWidget);
    expect(session('kitty-1/1'), findsOneWidget);
    expect(prefs.getStringList('pocketterm_terminal_folded'), isEmpty);
    remote.flush();
  });

  testWidgets('swiping a row asks in its place, not in a dialog; Cancel or waiting leaves the window open', (
    tester,
  ) async {
    macState();
    await pumpList(tester);
    // Not to settle: a close going spins, and settling would outwait its
    // answer and the question's 5 s.
    Future<void> swipe(String key) async {
      await tester.drag(session(key), const Offset(-600, 0));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Finder sent(String window) => find.descendant(
      of: find.byKey(ValueKey('confirm-close-$window')),
      matching: find.byKey(const ValueKey('close-sent')),
    );

    await swipe('kitty-1/3');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Close this window on the computer?'), findsOneWidget);
    expect(find.text('The omp session in ~/b ends with it.'), findsOneWidget);
    expect(session('kitty-1/3'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('close-cancel')));
    await tester.pump();
    expect(session('kitty-1/3'), findsOneWidget);

    await swipe('kitty-1/3');
    await tester.pump(const Duration(seconds: 6));
    expect(session('kitty-1/3'), findsOneWidget, reason: 'the question goes on its own');
    expect(runs('close'), isEmpty);

    await swipe('kitty-1/3');
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pump(Duration.zero);
    final closeB = runs('close').single;
    expect(closeB, containsPair('window', 'kitty-1/3'));
    // Until the computer answers, it shows the close going, with nothing to ask
    // or send again; another row's close doesn't change that.
    expect(sent('kitty-1/3'), findsOneWidget);
    expect(find.byKey(const ValueKey('close-confirm')), findsNothing);
    await swipe('kitty-1/2');
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pump(Duration.zero);
    final closeA = runs('close').last;
    expect(closeA, containsPair('window', 'kitty-1/2'));
    expect(sent('kitty-1/3'), findsOneWidget);

    remote.handle('ran', {'id': closeA['id']});
    await tester.pump();
    expect(session('kitty-1/2'), findsOneWidget);
    expect(sent('kitty-1/3'), findsOneWidget, reason: "a's answer isn't b's");
    remote.handle('ran', {'id': closeB['id']});
    await tester.pump();
    expect(session('kitty-1/3'), findsOneWidget);
    expect(runs('close'), hasLength(2));
    remote.flush();
  });

  testWidgets("with the computer out of reach, neither a new session nor a row's question can be used", (tester) async {
    macState();
    await pumpList(tester);
    await tester.drag(session('kitty-1/3'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('close-confirm')), findsOneWidget);

    // Nothing heard from the computer any more, and the list looks again (the
    // app's link check does, every few seconds).
    remote
      ..attach()
      ..detach();
    await pumpList(tester);
    expect(remote.online, isFalse);
    expect(find.byKey(const ValueKey('close-confirm')), findsNothing);
    expect(session('kitty-1/3'), findsOneWidget);
    await menu(tester, _b);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('project-menu-new'))).enabled, isFalse);
    remote.flush();
  });

  testWidgets("the session page's close button asks above the composer, then closes and goes back", (tester) async {
    macState();
    await pumpList(tester);
    await tester.tap(session('kitty-1/3'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const ValueKey('close-window')));
    // The question grows in above the composer.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Close this window on the computer?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pump(Duration.zero);
    final close = runs('close').single;
    expect(close, containsPair('window', 'kitty-1/3'));
    // Until the computer answers: the close shows going, and can't go again.
    expect(find.byKey(const ValueKey('close-sent')), findsOneWidget);
    expect(find.byKey(const ValueKey('close-confirm')), findsNothing);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('close-window'))).onPressed, isNull);
    remote.handle('ran', {'id': close['id']});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SessionPage), findsNothing);
    remote.flush();
  });

  testWidgets("a window's screen asks the same before closing, then goes back", (tester) async {
    macState();
    await pumpList(tester);
    await tester.tap(find.byKey(const ValueKey('term-kitty-1/4')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('close-window')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('zsh in ~ ends with it.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('close-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('zsh in ~ ends with it.'), findsNothing);
    expect(runs('close'), isEmpty);

    await tester.tap(find.byKey(const ValueKey('close-window')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pump(Duration.zero);
    final close = runs('close').single;
    expect(close, containsPair('window', 'kitty-1/4'));
    remote.handle('ran', {'id': close['id']});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalPage), findsNothing);
    remote.flush();
  });

  testWidgets("a slash command for a session in a terminal PocketTerm can't type into isn't sent as chat", (
    tester,
  ) async {
    macState();
    await pumpList(tester);
    await tester.tap(session('pid:9'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.enterText(find.byKey(const ValueKey('session-input')), '/new');
    await tester.pump();
    expect(find.byKey(const ValueKey('commands-need-window')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('session-send')));
    await tester.pump();

    expect(runs('prompt'), isEmpty);
    expect(find.textContaining('Run them on the computer.'), findsWidgets);
    expect(find.text('/new'), findsOneWidget, reason: 'what was typed stays');
    remote.flush();
  });
}
