import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:pocketterm_mobile/state_border.dart';
import 'package:pocketterm_mobile/swipe_action.dart';
import 'package:pocketterm_mobile/switch_view.dart';
import 'package:pocketterm_mobile/terminal_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screenshots/fakes.dart';

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
      offlineServer(),
      dir,
      desktopId: 'abcd1234',
      key: ChannelKey(List.filled(32, 9)),
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
  void macState({String idleId = 's2'}) {
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
          'id': idleId,
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

  Future<void> pumpList(
    WidgetTester tester, {
    Key? key,
    String? computer,
    ThemeData? theme,
    String? profileFilter,
    ValueChanged<String?>? onProfileFilter,
  }) async {
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
        theme: theme,
        home: Scaffold(
          body: TerminalList(
            key: key,
            remote: remote,
            folded: _Phone(prefs).collapsedProjects,
            onFolded: _Phone(prefs).setCollapsedProjects,
            sort: _Phone(prefs).projectSort,
            onSort: _Phone(prefs).setProjectSort,
            looks: _Phone(prefs).tileLooks('mac00001'),
            onLooks: (l) => _Phone(prefs).setTileLooks('mac00001', l),
            computer: computer,
            profileFilter: profileFilter,
            onProfileFilter: onProfileFilter,
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
      [
        for (final a
            in tester
                .widget<SwipeAction>(find.ancestor(of: session('pid:9'), matching: find.byType(SwipeAction)))
                .actions)
          a.label,
      ],
      ['Rename', 'Color'],
      reason: 'a session without a window has nothing to close, but can still be renamed and coloured',
    );

    // Somewhere unknown has nowhere to start a session.
    await menu(tester, '');
    expect(find.byKey(const ValueKey('project-menu-new')), findsNothing);
    expect(find.byKey(const ValueKey('project-menu-fold')), findsOneWidget);
    remote.flush();
  });

  testWidgets("a row reads like the agent's status bar: state, model, context and cost, a bar filled to the context", (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> state({int ctx = 49}) => {
      'windows': [
        {'key': 'kitty-1/3', 'title': 'omp', 'cwd': _b, 'program': 'omp', 'app': 'kitty'},
      ],
      'sessions': [
        {
          'key': 'kitty-1/3',
          'id': 's3',
          'agent': 'omp',
          'window': 'kitty-1/3',
          'title': 'Working one',
          'cwd': _b,
          'busy': true,
          'model': 'Opus 5.5',
          'ctx': ctx,
          'cost': 43.34,
          'preview': 'The last answer, no longer shown',
          'at': now,
        },
        {'key': 'pid:9', 'id': 's9', 'agent': 'omp', 'title': 'Nothing known', 'cwd': _a, 'at': now - 600000},
      ],
      'projects': [_a, _b],
      'home': '/Users/me',
      'agent': 'omp',
      'opensIn': 'kitty',
    };
    remote.handle('state', state());
    await pumpList(tester);
    await tester.pump(const Duration(seconds: 1));

    final row = session('kitty-1/3');
    expect(find.descendant(of: row, matching: find.text(r'Working… · Opus 5.5 · 49% · $43.34')), findsOneWidget);
    expect(find.textContaining('no longer shown'), findsNothing);
    FractionallySizedBox fill() => tester.widget(
      find.descendant(of: find.byKey(const ValueKey('ctx-kitty-1/3')), matching: find.byType(FractionallySizedBox)),
    );
    ColoredBox bar() =>
        tester.widget(find.descendant(of: find.byType(FractionallySizedBox), matching: find.byType(ColoredBox)));
    expect(fill().widthFactor, closeTo(.49, .001));
    expect(bar().color, C.accent);
    // Nothing known: just how long ago, and no bar.
    expect(find.descendant(of: session('pid:9'), matching: find.text('10 min ago')), findsOneWidget);
    expect(find.byKey(const ValueKey('ctx-pid:9')), findsNothing);

    // A fuller context fills the bar further and turns it red.
    remote.handle('state', state(ctx: 95));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.descendant(of: row, matching: find.text(r'Working… · Opus 5.5 · 95% · $43.34')), findsOneWidget);
    expect(fill().widthFactor, closeTo(.95, .001));
    expect(bar().color, C.error);
    remote.flush();
  });

  testWidgets('a run that ends unseen lights its row as done; one that ends while its conversation is open does not', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> state({required bool busy}) => {
      'windows': const <Object>[],
      'sessions': [
        for (final key in ['pid:41', 'pid:42'])
          {'key': key, 'id': key, 'agent': 'omp', 'title': key, 'cwd': _a, 'busy': busy, 'at': now},
      ],
      'home': '/Users/me',
      'agent': 'omp',
    };
    TileState border(String key) => tester
        .widget<StateBorder>(find.descendant(of: find.byKey(ValueKey('in-$key')), matching: find.byType(StateBorder)))
        .state;

    remote.handle('state', state(busy: true));
    await pumpList(tester);
    await tester.pump(const Duration(seconds: 1));
    // pid:42's conversation is open (over the list) as its run ends.
    final unwatch = remote.watchSession('pid:42');
    remote.handle('state', state(busy: false));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    unwatch();
    remote.handle('state', state(busy: false));
    await tester.pump();
    expect(border('pid:41'), TileState.done);
    expect(border('pid:42'), TileState.idle, reason: 'its answer was on screen as it came');
    remote.flush();
  });

  test("cost reads like omp's status line; a long model id is cut to fit", () {
    expect([money(43.344), money(0.01), money(0.004)], [r'$43.34', r'$0.01', r'<$0.01']);
    expect(shortModel('claude-opus-4-5-20251101'), 'opus-4-5');
    expect(shortModel('Claude Opus 4.5'), 'Opus 4.5');
    expect(shortModel('accounts/fireworks/models/qwen3-coder-480b'), 'accounts/fireworks/mo…');
  });

  testWidgets('by recent activity, projects keep their place until the list is refreshed, and the choice is kept', (
    tester,
  ) async {
    macState();
    await pumpList(tester);
    // One tap switches the order, no menu.
    await tester.tap(find.byKey(const ValueKey('project-sort')));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<ProjectSort>), findsNothing);
    expect(find.text('Recent activity'), findsOneWidget);
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

  testWidgets('the sort pill is as big for accessibility as on screen, not the whole row', (tester) async {
    final semantics = tester.ensureSemantics();
    macState();
    await pumpList(tester);
    final pill = find.byKey(const ValueKey('project-sort'));
    final node = tester.getSemantics(pill);
    expect(node.label, contains('Name'));
    expect(node.tooltip, 'Sort projects');
    // Not the whole row: VoiceOver's frame and a tap at its middle (as UI
    // automation does) land on the pill itself.
    expect(node.rect.width, closeTo(tester.getSize(pill).width, 1));
    expect(node.rect.height, closeTo(tester.getSize(pill).height, 1));
    remote.flush();
    semantics.dispose();
  });

  group('omp profiles', () {
    /// A personal session in a, a default one in b; [profiles]: the computer's omp profiles.
    void profileState({List<String>? profiles, String personal = 'personal'}) => remote.handle('state', {
      'windows': <Object>[],
      'sessions': [
        {
          'key': 'kitty-1/2',
          'id': 's2',
          'agent': 'omp',
          'profile': personal,
          'title': 'Mine',
          'cwd': _a,
          'model': 'claude-sonnet-4-5',
        },
        {'key': 'kitty-1/3', 'id': 's3', 'agent': 'omp', 'title': 'Work', 'cwd': _b},
      ],
      'projects': [_a, _b],
      'home': '/Users/me',
      'agent': 'omp',
      'profiles': ?profiles,
    });

    testWidgets("a profile's sessions say so, and the filter shows only the one picked", (tester) async {
      profileState(profiles: ['personal']);
      final kept = <String?>[];
      await pumpList(tester, onProfileFilter: kept.add);
      expect(
        find.descendant(of: session('kitty-1/2'), matching: find.textContaining('personal ·', findRichText: true)),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('profile-filter')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('profile-filter')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('profile-filter-personal')));
      await tester.pumpAndSettle();
      expect(kept, ['personal']);
      expect(session('kitty-1/2'), findsOneWidget);
      expect(session('kitty-1/3'), findsNothing);
      remote.flush();
    });

    testWidgets('a filter none of the sessions match says so, and Show all brings them back', (tester) async {
      profileState(profiles: ['personal'], personal: '');
      final kept = <String?>[];
      await pumpList(tester, profileFilter: 'personal', onProfileFilter: kept.add);
      expect(find.byKey(const ValueKey('profile-filter-empty')), findsOneWidget);
      expect(session('kitty-1/2'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('profile-filter-show-all')));
      await tester.pumpAndSettle();
      expect(kept, [null]);
      expect(find.byKey(const ValueKey('profile-filter-empty')), findsNothing);
      expect(session('kitty-1/2'), findsOneWidget);
      expect(session('kitty-1/3'), findsOneWidget);
      remote.flush();
    });

    testWidgets('a computer with only the default profile: no filter, and a kept one is ignored', (tester) async {
      profileState(personal: '');
      await pumpList(tester, profileFilter: 'personal');
      expect(find.byKey(const ValueKey('profile-filter')), findsNothing);
      expect(session('kitty-1/2'), findsOneWidget);
      expect(session('kitty-1/3'), findsOneWidget);
      remote.flush();
    });
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

  testWidgets("a project's menu folds all the others, keeping other computers' folds, then unfolds them all", (
    tester,
  ) async {
    // Folded on another computer of the account.
    await _Phone(prefs).setCollapsedProjects({'/Users/me/elsewhere'});
    macState();
    await pumpList(tester);

    await menu(tester, _b);
    await tester.tap(find.byKey(const ValueKey('project-menu-fold-others')));
    await tester.pumpAndSettle();
    expect(session('kitty-1/3'), findsOneWidget);
    expect(session('kitty-1/2'), findsNothing);
    expect(session('kitty-1/1'), findsNothing);
    expect(prefs.getStringList('pocketterm_terminal_folded')!.toSet(), {
      _a,
      _z,
      '/Users/me/c',
      '',
      '/Users/me/elsewhere',
    });

    await menu(tester, _b);
    await tester.tap(find.byKey(const ValueKey('project-menu-unfold-all')));
    await tester.pumpAndSettle();
    expect(session('kitty-1/2'), findsOneWidget);
    expect(session('kitty-1/1'), findsOneWidget);
    expect(prefs.getStringList('pocketterm_terminal_folded'), isEmpty);
    remote.flush();
  });

  /// Not to settle: a close going spins, and settling would outwait its
  /// answer and an open row's 5 s.
  Future<void> slide(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Finder action(String key) => find.byKey(ValueKey('swipe-action-$key'));

  Finder spinning(String key) => find.descendant(of: action(key), matching: find.byType(CircularProgressIndicator));

  /// Drags row [key] sideways ([dx] < 0: left), wherever it is slid to.
  Future<void> swipe(WidgetTester tester, String key, {double dx = -300}) async {
    await tester.drag(find.byKey(ValueKey('swipe-$key')), Offset(dx, 0));
    await slide(tester);
  }

  testWidgets('swiping a row left shows End session behind it; one tap ends it, once, spinning until answered', (
    tester,
  ) async {
    macState();
    await pumpList(tester);

    await swipe(tester, 'kitty-1/3');
    expect(find.byType(AlertDialog), findsNothing);
    expect(session('kitty-1/3'), findsOneWidget, reason: 'the row stays, slid aside');
    expect(find.descendant(of: action('kitty-1/3'), matching: find.text('End session')), findsOneWidget);
    expect(runs('close'), isEmpty, reason: 'opening it ends nothing');

    await tester.tap(action('kitty-1/3'));
    await tester.pump(Duration.zero);
    final closeB = runs('close').single;
    expect(closeB, containsPair('window', 'kitty-1/3'));
    expect(spinning('kitty-1/3'), findsOneWidget);

    // Until the computer answers, it can't go again, nor be swiped shut.
    await tester.tap(action('kitty-1/3'));
    await swipe(tester, 'kitty-1/3', dx: 300);
    expect(runs('close'), hasLength(1));
    expect(spinning('kitty-1/3'), findsOneWidget);

    // Another row's close doesn't change that.
    await swipe(tester, 'kitty-1/2');
    await tester.tap(action('kitty-1/2'));
    await tester.pump(Duration.zero);
    final closeA = runs('close').last;
    expect(closeA, containsPair('window', 'kitty-1/2'));
    expect(spinning('kitty-1/3'), findsOneWidget);

    remote.handle('ran', {'id': closeA['id']});
    await slide(tester);
    expect(action('kitty-1/2'), findsNothing, reason: 'answered, the row slides back');
    expect(spinning('kitty-1/3'), findsOneWidget, reason: "a's answer isn't b's");
    remote.handle('ran', {'id': closeB['id'], 'error': 'No such window.'});
    await slide(tester);
    expect(action('kitty-1/3'), findsNothing);
    expect(session('kitty-1/3'), findsOneWidget);
    expect(runs('close'), hasLength(2));
    remote.flush();
  });

  testWidgets(
    'an open row shuts on a swipe right, a tap on it, another row opening, or 5 s untouched, ending nothing',
    (tester) async {
      macState();
      await pumpList(tester);

      await swipe(tester, 'kitty-1/3', dx: -20);
      expect(action('kitty-1/3'), findsNothing, reason: 'a nudge slides back');

      await swipe(tester, 'kitty-1/3');
      await swipe(tester, 'kitty-1/3', dx: 300);
      expect(action('kitty-1/3'), findsNothing);

      await swipe(tester, 'kitty-1/3');
      // Its visible start: the rest of it is slid under the actions.
      await tester.tapAt(Offset(40, tester.getCenter(session('kitty-1/3')).dy));
      await slide(tester);
      expect(action('kitty-1/3'), findsNothing);
      expect(find.byType(SessionPage), findsNothing, reason: 'the tap shuts it, not opens the session');

      await swipe(tester, 'kitty-1/3');
      await swipe(tester, 'kitty-1/2');
      expect(action('kitty-1/3'), findsNothing, reason: 'one row is open at a time');
      expect(action('kitty-1/2'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      await slide(tester);
      expect(action('kitty-1/2'), findsNothing);

      // A fling far left only opens it.
      await tester.fling(session('kitty-1/3'), const Offset(-800, 0), 4000);
      await slide(tester);
      expect(action('kitty-1/3'), findsOneWidget);

      // A plain window closes; it ends no session.
      await tester.ensureVisible(find.byKey(const ValueKey('term-kitty-1/4')));
      await slide(tester);
      await tester.drag(find.byKey(const ValueKey('term-kitty-1/4')), const Offset(-300, 0));
      await slide(tester);
      expect(find.descendant(of: action('kitty-1/4'), matching: find.text('Close window')), findsOneWidget);
      expect(runs('close'), isEmpty);
      remote.flush();
    },
  );

  testWidgets('a row is renamed and coloured from its swipe or a long press, kept, and put back', (tester) async {
    macState();
    await pumpList(tester);
    Finder title(String text) => find.descendant(of: session('kitty-1/3'), matching: find.text(text));
    Color? tint() => tester.widget<ListTile>(session('kitty-1/3')).tileColor;

    // The swipe shows Rename and Color before End session.
    await swipe(tester, 'kitty-1/3');
    expect(
      [for (final a in tester.widget<SwipeAction>(find.byKey(const ValueKey('swipe-kitty-1/3'))).actions) a.label],
      ['Rename', 'Color', 'End session'],
    );
    await tester.tap(find.byKey(const ValueKey('swipe-rename-kitty-1/3')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tile-rename-field')), 'Moisture API');
    await tester.tap(find.byKey(const ValueKey('tile-rename-save')));
    await tester.pumpAndSettle();
    expect(title('Moisture API'), findsOneWidget);
    expect(action('kitty-1/3'), findsNothing, reason: 'done, the row slides shut');

    // A long press offers the same three.
    await tester.longPress(session('kitty-1/3'));
    await tester.pumpAndSettle();
    for (final k in ['row-menu-rename', 'row-menu-color', 'row-menu-close']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('row-menu-color')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('tile-color-${tileColors[3].toARGB32().toRadixString(16)}')));
    await tester.pumpAndSettle();
    expect(tint()!.toARGB32() & 0xFFFFFF, tileColors[3].toARGB32() & 0xFFFFFF);

    // Kept: a new list (another visit) shows both.
    await pumpList(tester, key: const ValueKey('again'));
    await tester.pumpAndSettle();
    expect(title('Moisture API'), findsOneWidget);
    expect(tint(), isNotNull);

    // Put back: Reset brings the computer's name, No color the plain row.
    await tester.longPress(session('kitty-1/3'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('row-menu-rename')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tile-rename-reset')));
    await tester.pumpAndSettle();
    await tester.longPress(session('kitty-1/3'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('row-menu-color')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tile-color-none')));
    await tester.pumpAndSettle();
    expect(title('Moisture API'), findsNothing);
    expect(tint(), isNull);
    expect(prefs.getString('pocketterm_tile_looks'), '{}');
    remote.flush();
  });

  testWidgets("with the computer out of reach, neither a new session nor a row's End session can be used", (
    tester,
  ) async {
    macState();
    await pumpList(tester);
    await swipe(tester, 'kitty-1/3');
    expect(action('kitty-1/3'), findsOneWidget);

    // Nothing heard from the computer any more, and the list looks again (the
    // app's link check does, every few seconds).
    remote
      ..attach()
      ..detach();
    await pumpList(tester);
    await slide(tester);
    expect(remote.online, isFalse);
    expect(action('kitty-1/3'), findsNothing);
    await swipe(tester, 'kitty-1/3');
    expect(action('kitty-1/3'), findsNothing);
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
    expect(find.text('End this omp session on the computer?'), findsOneWidget);
    expect(find.text('Its window in ~/b closes with it.'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const ValueKey('close-cancel')), matching: find.text('Keep')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('close-confirm')), matching: find.text('End session')),
      findsOneWidget,
    );
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
    await tester.ensureVisible(find.byKey(const ValueKey('term-kitty-1/4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('term-kitty-1/4')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('close-window')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Close this window on the computer?'), findsOneWidget);
    expect(find.text('zsh in ~ stops with it.'), findsOneWidget);
    expect(find.text('Close window'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('close-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('zsh in ~ stops with it.'), findsNothing);
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

  /// The idle session a's window can only be [caps]; its session asks [ask].
  Future<void> asking(
    WidgetTester tester,
    Map<String, dynamic> ask, {
    String? window,
    List<String>? caps,
    ThemeData? theme,
  }) async {
    remote.handle('state', {
      'windows': [
        if (window != null) {'key': window, 'title': 'omp', 'cwd': _a, 'program': 'omp', 'app': 'kitty', 'caps': ?caps},
      ],
      'sessions': [
        {'key': window ?? 'pid:9', 'id': 's2', 'agent': 'omp', 'window': ?window, 'title': 'Asking', 'cwd': _a},
      ],
      'projects': [_a],
      'home': '/Users/me',
      'agent': 'omp',
      'opensIn': 'kitty',
    });
    await pumpList(tester, theme: theme);
    await tester.tap(session(window ?? 'pid:9'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    remote.handle('state', {
      'windows': [
        if (window != null) {'key': window, 'title': 'omp', 'cwd': _a, 'program': 'omp', 'app': 'kitty', 'caps': ?caps},
      ],
      'sessions': [
        {
          'key': window ?? 'pid:9',
          'id': 's2',
          'agent': 'omp',
          'window': ?window,
          'title': 'Asking',
          'cwd': _a,
          'ask': ask,
        },
      ],
      'projects': [_a],
      'home': '/Users/me',
      'agent': 'omp',
      'opensIn': 'kitty',
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group("a question's answers", () {
    const long =
        'Merge Corona to main, new worktree feat/session-tile-borders for the borders, and keep the old '
        'branch around until the release ships';

    /// Answer [o] of the question.
    Finder answer(int o) => find.byKey(ValueKey('ask-0-$o'));

    /// Its chip as drawn (inside its tap target).
    Finder chip(int o) => find.descendant(of: answer(o), matching: find.byType(Material)).first;

    /// The pill the chip draws.
    OutlinedBorder pill(WidgetTester tester, int o) => tester.widget<Material>(chip(o)).shape! as OutlinedBorder;

    for (final multi in [false, true]) {
      testWidgets('show a long one whole on more lines, in a pill that picks (${multi ? 'several' : 'one'})', (
        tester,
      ) async {
        await asking(
          tester,
          {
            'kind': 'questions',
            'id': 'q1',
            'questions': [
              {
                'id': 'next',
                'question': 'What next?',
                'options': ['Ship it', long],
                'multi': multi,
              },
            ],
          },
          window: 'kitty-1/2',
          theme: appTheme(C.t),
        );

        final text = find.descendant(of: answer(1), matching: find.text(long));
        final paragraph = tester.renderObject<RenderParagraph>(text);
        expect(paragraph.maxLines, isNull, reason: 'no line limit');
        expect(paragraph.softWrap, isTrue);
        expect(paragraph.getMaxIntrinsicWidth(double.infinity), greaterThan(paragraph.size.width), reason: 'wrapped');
        expect(
          paragraph.size.height,
          paragraph.getMinIntrinsicHeight(paragraph.size.width),
          reason: 'laid out as tall as all its lines',
        );
        final short = tester.getRect(chip(0));
        final tall = tester.getRect(chip(1));
        expect(tall.height, greaterThan(short.height + 2 * paragraph.text.style!.fontSize!), reason: 'more lines');
        expect(tall.expandToInclude(tester.getRect(text)), tall, reason: 'all inside the chip');
        // Soft themes' pills: a short answer's stadium; the long one keeps those corners rather than a blob's.
        expect(pill(tester, 0), isA<StadiumBorder>());
        final corners = pill(tester, 1) as RoundedRectangleBorder;
        expect((corners.borderRadius as BorderRadius).topLeft.x, moreOrLessEquals(short.height / 2, epsilon: .01));

        await tester.tap(text);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.widget<ChoiceChip>(find.descendant(of: answer(1), matching: find.byType(ChoiceChip))).selected,
          isTrue,
        );
        expect(tester.getRect(chip(1)).height, tall.height, reason: 'picking it reflows nothing');
        await tester.ensureVisible(find.byKey(const ValueKey('answer')));
        await tester.tap(find.byKey(const ValueKey('answer')));
        await tester.pump(Duration.zero);
        expect(runs('answer').single['answers'], [
          {
            'picks': [1],
          },
        ]);
        remote.handle('ran', {'id': runs('answer').single['id']});
        await tester.pump();
        remote.flush();
      });
    }
  });

  group("an ask PocketTerm can't answer from the phone", () {
    const menu = {
      'kind': 'menu',
      'id': 'm1',
      'title': 'Resume',
      'filter': true,
      'items': [
        {'label': 'Yesterday'},
      ],
    };

    testWidgets('a picker in a window that takes no keys offers its screen and can be put away', (tester) async {
      await asking(tester, menu, window: 'kitty-1/2', caps: ['read']);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.byKey(const ValueKey('menu-cancel')), findsNothing, reason: 'Esc needs keys');
      expect(find.byKey(const ValueKey('menu-search')), findsNothing, reason: 'typing too');
      expect(find.textContaining('Pick on the computer.'), findsOneWidget);
      await tester.tap(find.text('Yesterday'));
      await tester.pump();
      expect(runs('answer'), isEmpty, reason: 'a pick presses keys it has no way to press');

      await tester.tap(find.byKey(const ValueKey('menu-screen')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TerminalPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(TerminalPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(find.byKey(const ValueKey('menu-hide')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Yesterday'), findsNothing);
      remote.flush();
    });

    testWidgets('a plan with no options in a terminal PocketTerm can’t read says to answer it on the computer', (
      tester,
    ) async {
      await asking(tester, {'kind': 'plan', 'id': 'p1', 'title': 'Plan'});
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('plan-waiting'))).data,
        'Answer it on the computer: PocketTerm can’t read this terminal.',
      );
      expect(find.byKey(const ValueKey('plan-screen')), findsNothing);
      remote.flush();
    });
  });

  group('a slash command with no picker', () {
    /// Sends [command] in the idle session; the computer takes it.
    Future<void> sendCommand(WidgetTester tester, String command) async {
      macState();
      await pumpList(tester);
      await tester.tap(session('kitty-1/2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byKey(const ValueKey('session-input')), command);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('session-send')));
      await tester.pump(Duration.zero);
      remote.handle('ran', {'id': runs('prompt').single['id']});
      await tester.pump();
    }

    testWidgets('that renews the session (/new) keeps the conversation in front', (tester) async {
      await sendCommand(tester, '/new');
      macState(idleId: 's2-new');
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TerminalPage), findsNothing);
      expect(find.byType(SessionPage), findsOneWidget);
      remote.flush();
    });

    testWidgets("that doesn't renew it opens the window's screen", (tester) async {
      await sendCommand(tester, '/compact');
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TerminalPage), findsOneWidget);
      remote.flush();
    });
  });

  testWidgets('why an agent window shows only as a screen follows where PocketTerm stands in that agent', (
    tester,
  ) async {
    // [caps]: the window's terminal's; one that can't press keys and type isn't switched from the phone, so it
    // says why even where PocketTerm is installed.
    Future<String> advice(String? integration, {String? computer, String agent = 'omp', List<String>? caps}) async {
      remote.handle('state', {
        'windows': [
          {'key': 'kitty-1/8', 'title': agent, 'cwd': _a, 'program': agent, 'app': 'kitty', 'caps': ?caps},
        ],
        'sessions': <Object>[],
        'home': '/Users/me',
        'agent': 'omp',
        'agents': ?(integration == null ? null : {agent: integration}),
      });
      await pumpList(tester, key: ValueKey('$agent$integration$computer$caps'), computer: computer);
      return tester
          .widget<Text>(find.descendant(of: find.byKey(ValueKey('$agent-screens-only')), matching: find.byType(Text)))
          .data!;
    }

    expect(await advice('missing', computer: 'Studio'), contains('isn’t installed in omp on Studio'));
    expect(await advice('missing'), contains('on the computer.'));
    const lineOnly = ['read', 'line'];
    expect(await advice('installed', caps: lineOnly), contains('started before PocketTerm was installed in omp'));
    expect(await advice('installed', caps: lineOnly), contains(Agent.omp.resume));
    expect(await advice('outdated', computer: 'Studio'), contains('out of date on Studio'));
    expect(await advice(null), contains('It may be out of date'), reason: 'an older computer: the old advice');
    expect(await advice('bogus'), contains('It may be out of date'));

    // Claude Code reloads its plugins in place: nothing to restart.
    for (final integration in ['installed', 'outdated', 'missing', null]) {
      final text = await advice(integration, agent: 'claude', caps: lineOnly);
      expect(text, contains('/reload-plugins'), reason: '$integration');
      expect(text, isNot(contains(Agent.claude.resume)), reason: '$integration');
    }
    remote.flush();
  });

  group('switching a screen-only session to the conversation view', () {
    /// Two omp windows and a Claude one no session claims, a shell, and where PocketTerm stands in each agent.
    void screensOnly({String omp = 'installed', String claude = 'installed', List<Object> sessions = const []}) {
      Map<String, dynamic> window(String key, String program) => {
        'key': key,
        'title': program,
        'cwd': _a,
        'program': program,
        'app': 'kitty',
      };
      remote.handle('state', {
        'windows': [
          window('kitty-1/7', 'omp'),
          window('kitty-1/8', 'omp'),
          window('kitty-1/9', 'claude'),
          window('kitty-1/4', 'zsh'),
        ],
        'sessions': sessions,
        'home': '/Users/me',
        'agent': 'omp',
        'agents': {'omp': omp, 'claude': claude},
      });
    }

    String tip(WidgetTester tester) => tester
        .widget<Text>(find.descendant(of: find.byKey(const ValueKey('switch-tip')), matching: find.byType(Text)))
        .data!;

    Future<void> openScreen(WidgetTester tester, String window) async {
      await pumpList(tester);
      await tester.tap(find.byKey(ValueKey('term-$window')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TerminalPage), findsOneWidget);
    }

    /// Opens the switch sheet from the screen page's banner.
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('switch-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('agent rows are badged Screen only, under a tip to tap one where PocketTerm is installed', (
      tester,
    ) async {
      screensOnly();
      await pumpList(tester);
      for (final w in ['kitty-1/7', 'kitty-1/8', 'kitty-1/9']) {
        expect(find.byKey(ValueKey('screen-only-$w')), findsOneWidget, reason: w);
      }
      expect(find.byKey(const ValueKey('screen-only-kitty-1/4')), findsNothing, reason: 'a shell is no session');
      expect(tip(tester), '3 sessions show only their screen. Tap one to switch it to the conversation view.');
      expect(find.byKey(const ValueKey('omp-screens-only')), findsNothing);

      // Out of date in omp: switching wouldn't help there, so it says what would.
      screensOnly(omp: 'outdated');
      await tester.pump();
      expect(tip(tester), '1 session shows only its screen. Tap it to switch it to the conversation view.');
      expect(find.byKey(const ValueKey('omp-screens-only')), findsOneWidget);
      expect(find.byKey(const ValueKey('screen-only-kitty-1/7')), findsOneWidget);

      screensOnly(omp: 'missing', claude: 'off');
      await tester.pump();
      expect(find.byKey(const ValueKey('switch-tip')), findsNothing);
      expect(find.byKey(const ValueKey('claude-screens-only')), findsOneWidget);
      remote.flush();
    });

    testWidgets('the screen page offers the switch only where PocketTerm is installed in its agent', (tester) async {
      screensOnly(omp: 'outdated');
      await openScreen(tester, 'kitty-1/7');
      expect(find.byKey(const ValueKey('switch-open')), findsNothing);

      screensOnly();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('This omp session shows only its screen'), findsOneWidget);
      expect(find.text('Switch to conversation'), findsOneWidget);
      remote.flush();
    });

    /// The omp in [window] is at work: the sheet asks, warns and offers both restarts.
    Future<void> busySheet(WidgetTester tester, String window) async {
      screensOnly();
      await openScreen(tester, window);
      await openSheet(tester);
      expect(find.textContaining('picks the same conversation back up'), findsOneWidget);
      // Asking the computer first: no buttons yet.
      expect(find.byKey(const ValueKey('switch-probing')), findsOneWidget);
      expect(find.text('Restart and continue'), findsNothing);
      final probe = runs('probe').single;
      expect(probe, containsPair('window', window));
      remote.handle('ran', {'id': probe['id'], 'busy': true});
      await tester.pump();
      expect(find.byKey(const ValueKey('switch-busy')), findsOneWidget);
      expect(find.text('Restart and continue'), findsOneWidget);
      expect(find.text('Just restart'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);
      expect(find.text('Restart now'), findsNothing);
    }

    /// Taps [choice] in the sheet; the switch goes and omp reports from [window] (at work if [busy]), whose session
    /// page opens.
    Future<void> restart(WidgetTester tester, String window, String choice, {bool busy = false}) async {
      await tester.tap(find.text(choice));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final switched = runs('switch').single;
      expect(switched, allOf(containsPair('window', window), containsPair('agent', 'omp')));
      expect(find.text('Switching…'), findsOneWidget);
      remote.handle('ran', {'id': switched['id']});
      await tester.pump();
      expect(find.text('Switching…'), findsOneWidget, reason: 'until omp reports');
      expect(runs('prompt'), isEmpty);

      // omp reports from the window: its session's page takes the screen's place.
      screensOnly(
        sessions: [
          {'key': window, 'id': 's7', 'agent': 'omp', 'window': window, 'title': 'Back', 'cwd': _a, 'busy': busy},
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TerminalPage), findsNothing);
      expect(find.byType(SessionPage), findsOneWidget);
    }

    testWidgets('omp at work, Just restart: its session opens with Continue, which carries on once', (tester) async {
      await busySheet(tester, 'kitty-1/7');
      await restart(tester, 'kitty-1/7', 'Just restart');
      expect(runs('prompt'), isEmpty, reason: 'nothing goes on its own');

      await tester.tap(find.byKey(const ValueKey('continue')));
      await tester.pump();
      await tester.pump(Duration.zero);
      final prompt = runs('prompt').single;
      expect(prompt, allOf(containsPair('session', 'kitty-1/7'), containsPair('text', 'continue')));
      remote.handle('ran', {'id': prompt['id']});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('continue')), findsNothing);

      // Back: the list, not the screen.
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TerminalList), findsOneWidget);
      expect(find.byType(TerminalPage), findsNothing);
      remote.flush();
    });

    testWidgets('omp at work, Restart and continue: continue goes once its session reports at rest, no chip', (
      tester,
    ) async {
      await busySheet(tester, 'kitty-1/7');
      // It reports at work first: continue waits rather than going in the middle of it, or not at all.
      await restart(tester, 'kitty-1/7', 'Restart and continue', busy: true);
      expect(runs('prompt'), isEmpty);
      screensOnly(
        sessions: [
          {'key': 'kitty-1/7', 'id': 's7', 'agent': 'omp', 'window': 'kitty-1/7', 'title': 'Back', 'cwd': _a},
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final prompt = runs('prompt').single;
      expect(prompt, allOf(containsPair('session', 'kitty-1/7'), containsPair('text', 'continue')));
      expect(find.byKey(const ValueKey('continue')), findsNothing);
      remote.handle('ran', {'id': prompt['id']});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // More reports and rebuilds send nothing more.
      screensOnly(
        sessions: [
          {'key': 'kitty-1/7', 'id': 's7', 'agent': 'omp', 'window': 'kitty-1/7', 'title': 'Again', 'cwd': _a},
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(runs('prompt'), hasLength(1));
      expect(find.byKey(const ValueKey('continue')), findsNothing);
      remote.flush();
    });

    testWidgets('omp at work, Restart and continue: a prompt of their own first means no continue after it', (
      tester,
    ) async {
      await busySheet(tester, 'kitty-1/7');
      await restart(tester, 'kitty-1/7', 'Restart and continue', busy: true);
      await tester.enterText(find.byKey(const ValueKey('session-input')), 'fix the tests instead');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('session-send')));
      await tester.pump(Duration.zero);
      final prompt = runs('prompt').single;
      expect(prompt, containsPair('text', 'fix the tests instead'));
      remote.handle('ran', {'id': prompt['id']});
      await tester.pump();

      // At rest after their prompt: nothing more goes.
      screensOnly(
        sessions: [
          {'key': 'kitty-1/7', 'id': 's7', 'agent': 'omp', 'window': 'kitty-1/7', 'title': 'Back', 'cwd': _a},
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(runs('prompt'), hasLength(1));
      remote.flush();
    });

    testWidgets('omp at work, Restart and continue: when continue fails, the chip offers it', (tester) async {
      await busySheet(tester, 'kitty-1/7');
      await restart(tester, 'kitty-1/7', 'Restart and continue');
      final prompt = runs('prompt').single;
      remote.handle('ran', {'id': prompt['id'], 'error': 'It isn’t taking prompts.'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('continue')), findsOneWidget);
      expect(runs('prompt'), hasLength(1), reason: 'not again on its own');
      remote.flush();
    });

    testWidgets('omp at rest: no warning, and its session opens without Continue', (tester) async {
      screensOnly();
      await openScreen(tester, 'kitty-1/8');
      await openSheet(tester);
      remote.handle('ran', {'id': runs('probe').single['id'], 'busy': false});
      await tester.pump();
      expect(find.byKey(const ValueKey('switch-busy')), findsNothing);
      await tester.tap(find.text('Restart now'));
      await tester.pump();
      await tester.pump(Duration.zero);
      remote.handle('ran', {'id': runs('switch').single['id']});
      screensOnly(
        sessions: [
          {'key': 'kitty-1/8', 'id': 's8', 'agent': 'omp', 'window': 'kitty-1/8', 'title': 'Back', 'cwd': _a},
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SessionPage), findsOneWidget);
      expect(find.byKey(const ValueKey('continue')), findsNothing);
      remote.flush();
    });

    testWidgets('Claude Code: no asking, /reload-plugins; when it never reports, the screen says so and stays', (
      tester,
    ) async {
      screensOnly();
      await openScreen(tester, 'kitty-1/9');
      await openSheet(tester);
      expect(find.text('PocketTerm types /reload-plugins in it. Nothing restarts.'), findsOneWidget);
      expect(runs('probe'), isEmpty);
      await tester.tap(find.text('Switch'));
      await tester.pump();
      await tester.pump(Duration.zero);
      final switched = runs('switch').single;
      expect(switched, containsPair('agent', 'claude'));
      remote.handle('ran', {'id': switched['id']});
      await tester.pump();

      await tester.pump(switchWait);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('It didn’t come back as a conversation.'), findsOneWidget);
      expect(find.byType(TerminalPage), findsOneWidget);
      expect(find.byType(SessionPage), findsNothing);

      // Try again asks again.
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Switch'), findsOneWidget);
      remote.flush();
    });
  });
}
