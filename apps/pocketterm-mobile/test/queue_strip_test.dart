import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/session_view.dart';

import 'screenshots/fakes.dart';

const _session = 'kitty-1/2';

void main() {
  late Directory dir;
  late TerminalRemote remote;
  late List<Map<String, dynamic>> runs;

  /// The computer's state: the session, at work unless not [busy], with [queue] waiting in it.
  void state({
    List<Map<String, dynamic>> queue = const [],
    String agent = 'omp',
    bool busy = true,
    bool paused = false,
  }) => remote.handle('state', {
    'windows': [
      {'key': _session, 'title': agent, 'cwd': '/Users/me/a', 'program': agent, 'app': 'kitty'},
    ],
    'sessions': [
      {
        'key': _session,
        'id': 's2',
        'agent': agent,
        'window': _session,
        'title': 'The session',
        'cwd': '/Users/me/a',
        'busy': busy,
        'at': DateTime.now().millisecondsSinceEpoch,
        if (queue.isNotEmpty) 'queue': queue,
        if (paused) 'paused': true,
      },
    ],
    'home': '/Users/me',
    'agent': agent,
  });

  final three = [
    {'id': 'q1', 't': 'update the docs'},
    {
      'id': 'q2',
      't': 'look at these',
      'im': 2,
      'f': ['notes.md'],
    },
    {'id': 'q3', 't': 'then ship it'},
  ];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_queue_strip');
    runs = [];
    remote = TerminalRemote(
      offlineServer(),
      dir,
      desktopId: 'abcd1234',
      key: ChannelKey(List.filled(32, 9)),
      from: 'phone',
      send: (event, payload) {
        if (event == 'run') runs.add(payload);
      },
    );
    state(queue: three);
  });
  tearDown(() {
    remote.flush();
    dir.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
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
        home: SessionPage(remote: remote, sessionKey: _session),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The queue changes sent, without the computer's bookkeeping.
  List<Map<String, dynamic>> changes() => [
    for (final r in runs)
      if (r['op'] == 'queue')
        {
          for (final e in r.entries)
            if (e.key != 'id') e.key: e.value,
        },
  ];

  Map<String, dynamic> lastChange() => runs.lastWhere((r) => r['op'] == 'queue');

  void ran(Map<String, dynamic> run, {String? error}) => remote.handle('ran', {'id': run['id'], 'error': ?error});

  Finder row(String id) => find.byKey(ValueKey('queued-$id'));

  Future<void> menu(WidgetTester tester, String id, String action) async {
    await tester.tap(find.byKey(ValueKey('queued-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Menu entries offered for [id]'s row, then closes the menu.
  Future<List<String>> offered(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('queued-menu-$id')));
    await tester.pumpAndSettle();
    final entries = [
      for (final e in tester.widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>)))
        (e.child! as Text).data!,
    ];
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    return entries;
  }

  double top(WidgetTester tester, String id) => tester.getTopLeft(row(id)).dy;

  testWidgets('the queue shows above the composer, next first, with what goes along', (tester) async {
    await open(tester);
    expect(find.text('Queued · 3'), findsOneWidget);
    expect(top(tester, 'q1'), lessThan(top(tester, 'q2')));
    expect(top(tester, 'q2'), lessThan(top(tester, 'q3')));
    expect(find.descendant(of: row('q2'), matching: find.text('⊕ 2 images · notes.md')), findsOneWidget);
    expect(
      tester.getTopLeft(row('q3')).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('session-input'))).dy),
    );

    // Folded, only the header shows.
    await tester.tap(find.byKey(const ValueKey('queue-fold')));
    await tester.pump();
    expect(row('q1'), findsNothing);
    expect(find.text('Queued · 3'), findsOneWidget);
  });

  testWidgets('its header opens the whole queue over the screen', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('queue-open-header')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queue-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-item-q3')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('queue-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queue-title')), findsNothing);
    expect(row('q3'), findsOneWidget);
  });

  testWidgets('no strip while nothing waits', (tester) async {
    state();
    await open(tester);
    expect(find.textContaining('Queued'), findsNothing);
    expect(find.byKey(const ValueKey('queue-pause')), findsNothing);
  });

  testWidgets('Delete takes it out at once; back with why when the computer refuses', (tester) async {
    await open(tester);
    await menu(tester, 'q2', 'Delete');
    expect(changes().single, {'op': 'queue', 'session': _session, 'do': 'remove', 'item': 'q2'});
    expect(row('q2'), findsNothing);
    expect(find.text('Queued · 2'), findsOneWidget);

    ran(lastChange(), error: 'That prompt already went.');
    await tester.pump(const Duration(milliseconds: 500));
    expect(row('q2'), findsOneWidget);
    expect(find.text('That prompt already went.'), findsOneWidget);

    await menu(tester, 'q2', 'Delete');
    ran(lastChange());
    await tester.pump();
    expect(row('q2'), findsNothing, reason: 'gone until the computer says so');
    state(queue: [three[0], three[2]]);
    await tester.pump(const Duration(milliseconds: 500));
    expect(row('q2'), findsNothing);
    expect(find.text('Queued · 2'), findsOneWidget);
  });

  testWidgets('a swipe deletes it too', (tester) async {
    await open(tester);
    await tester.fling(row('q3'), const Offset(-600, 0), 2000);
    await tester.pumpAndSettle();
    await tester.pump(Duration.zero);
    expect(changes().single, {'op': 'queue', 'session': _session, 'do': 'remove', 'item': 'q3'});
    expect(row('q3'), findsNothing);
    ran(lastChange());
  });

  testWidgets('dragging one moves it there at once, and asks the computer to', (tester) async {
    await open(tester);
    final handle = find.descendant(of: row('q1'), matching: find.byIcon(Icons.drag_handle));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(Duration.zero);

    final move = changes().single;
    expect(move, containsPair('do', 'move'));
    expect(move, containsPair('item', 'q1'));
    final to = move['to'] as int;
    expect(to, greaterThan(0));
    final order = ['q2', 'q3']..insert(to, 'q1');
    final tops = [for (final id in order) top(tester, id)];
    expect(tops, orderedEquals([...tops]..sort()), reason: 'shown in the new order before the computer answers');

    ran(lastChange());
    // A state from before the move doesn't undo it.
    state(queue: three);
    await tester.pump(const Duration(milliseconds: 500));
    final again = [for (final id in order) top(tester, id)];
    expect(again, orderedEquals([...again]..sort()));
  });

  testWidgets('a move the computer refuses goes back, with why', (tester) async {
    await open(tester);
    final handle = find.descendant(of: row('q3'), matching: find.byIcon(Icons.drag_handle));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, -15));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(Duration.zero);
    expect(changes().single, containsPair('item', 'q3'));

    ran(lastChange(), error: 'That prompt already went.');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('That prompt already went.'), findsOneWidget);
    expect(top(tester, 'q2'), lessThan(top(tester, 'q3')));
  });

  testWidgets('a paused queue says so, and Resume lets it go on', (tester) async {
    state(queue: [three[0]], busy: false, paused: true);
    await open(tester);
    expect(find.text('Queue paused · 1'), findsOneWidget);
    expect(find.text('Nothing goes until you resume.'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-pause')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('queue-resume')));
    await tester.pump(Duration.zero);
    expect(changes().single, {'op': 'queue', 'session': _session, 'do': 'resume'});
    ran(lastChange());

    state(queue: [three[0]]);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Queued · 1'), findsOneWidget);
    expect(find.text('Nothing goes until you resume.'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('queue-pause')));
    await tester.pump(Duration.zero);
    expect(changes().last, containsPair('do', 'pause'));
    ran(lastChange());
  });

  testWidgets('Send now is offered to an agent that steers, not to Claude Code', (tester) async {
    await open(tester);
    expect(await offered(tester, 'q1'), ['Edit', 'Send now', 'Delete']);
    await menu(tester, 'q1', 'Send now');
    expect(changes().single, {'op': 'queue', 'session': _session, 'do': 'send', 'item': 'q1'});
    expect(row('q1'), findsNothing);
    ran(lastChange());

    state(queue: three, agent: 'claude');
    await tester.pump(const Duration(milliseconds: 500));
    expect(await offered(tester, 'q2'), ['Edit', 'Delete']);
  });

  testWidgets('Edit changes its text; one cut short has no Edit', (tester) async {
    state(
      queue: [
        three[0],
        {'id': 'q9', 't': 'a very long prompt', 'c': true},
      ],
    );
    await open(tester);
    expect(await offered(tester, 'q9'), ['Send now', 'Delete']);

    await menu(tester, 'q1', 'Edit');
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('queued-edit-field'));
    expect(tester.widget<TextField>(field).controller!.text, 'update the docs');

    await tester.enterText(field, '   ');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byKey(const ValueKey('queued-edit-save'))).onPressed,
      isNull,
      reason: 'nothing to send',
    );

    await tester.enterText(field, 'update the docs and the changelog');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('queued-edit-save')));
    await tester.pumpAndSettle();
    expect(changes().single, {
      'op': 'queue',
      'session': _session,
      'do': 'edit',
      'item': 'q1',
      'text': 'update the docs and the changelog',
    });
    ran(lastChange());
  });

  testWidgets('offline, nothing in it can be changed', (tester) async {
    state(queue: three);
    // Nothing heard from the computer any more.
    remote
      ..attach()
      ..detach();
    expect(remote.online, isFalse);
    await open(tester);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('queue-pause'))).onPressed, isNull);
    expect(tester.widget<PopupMenuButton<String>>(find.byKey(const ValueKey('queued-menu-q1'))).enabled, isFalse);
  });
}
