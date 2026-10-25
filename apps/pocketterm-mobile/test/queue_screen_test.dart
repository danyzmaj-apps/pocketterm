import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/queue_screen.dart';

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
    dir = Directory.systemTemp.createTempSync('pocketterm_queue_screen');
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
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(C.t),
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                TextButton(onPressed: () => openQueue(context, remote, _session), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// What was asked of the computer, without its bookkeeping.
  List<Map<String, dynamic>> asked() => [
    for (final r in runs)
      {
        for (final e in r.entries)
          if (e.key != 'id') e.key: e.value,
      },
  ];

  void ran(Map<String, dynamic> run, {String? error, String? queued}) =>
      remote.handle('ran', {'id': run['id'], 'error': ?error, 'queued': ?queued});

  Finder row(String id) => find.byKey(ValueKey('queue-item-$id'));

  Future<void> menu(WidgetTester tester, String id, String action) async {
    await tester.tap(find.byKey(ValueKey('queue-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  Future<List<String>> offered(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('queue-menu-$id')));
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
  List<String> order(WidgetTester tester, List<String> ids) =>
      [...ids]..sort((a, b) => top(tester, a).compareTo(top(tester, b)));

  testWidgets('opens over the screen with every prompt whole, numbered, and closes', (tester) async {
    final long = List.filled(40, 'and then the next part of it').join(' ');
    state(
      queue: [
        ...three,
        {'id': 'q4', 't': long},
      ],
    );
    await open(tester);
    expect(find.byKey(const ValueKey('queue-title')), findsOneWidget);
    expect(find.text('The session'), findsOneWidget);
    expect(find.text('Queued · 4'), findsOneWidget);
    expect(find.text('Working'), findsOneWidget);
    expect(order(tester, ['q3', 'q1', 'q4', 'q2']), ['q1', 'q2', 'q3', 'q4']);
    expect(find.descendant(of: row('q3'), matching: find.text('3')), findsOneWidget);
    expect(find.descendant(of: row('q2'), matching: find.text('⊕ 2 images · notes.md')), findsOneWidget);

    // A long one shows its start until opened.
    final text = find.byKey(const ValueKey('queue-text-q4'));
    final shut = tester.getSize(text).height;
    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();
    expect(tester.getSize(text).height, greaterThan(shut));
    expect(find.text('Show less'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('queue-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queue-title')), findsNothing);
  });

  testWidgets('says whether the agent works, the queue is paused or all is idle; Pause and Resume', (tester) async {
    state(queue: three, busy: false, paused: true);
    await open(tester);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Nothing goes until you resume.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('queue-screen-resume')));
    await tester.pump(Duration.zero);
    expect(asked().single, {'op': 'queue', 'session': _session, 'do': 'resume'});
    ran(runs.last);

    state(queue: three, busy: false);
    await tester.pump(Duration.zero);
    expect(find.text('Idle'), findsOneWidget);
    state(queue: three);
    await tester.pump(Duration.zero);
    expect(find.text('Working'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('queue-screen-pause')));
    await tester.pump(Duration.zero);
    expect(asked().last, {'op': 'queue', 'session': _session, 'do': 'pause'});
    ran(runs.last);
  });

  testWidgets('a drag by the handle, or the whole row held, moves it there at once', (tester) async {
    await open(tester);
    final handle = find.descendant(of: row('q1'), matching: find.byIcon(Icons.drag_handle));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    final move = asked().single;
    expect(move, containsPair('do', 'move'));
    expect(move, containsPair('item', 'q1'));
    final to = move['to'] as int;
    expect(to, greaterThan(0));
    expect(order(tester, ['q1', 'q2', 'q3']), ['q2', 'q3']..insert(to, 'q1'));
    ran(runs.last);

    // Held, the whole row drags.
    runs.clear();
    final held = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('queue-text-q3'))));
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 20; i++) {
      await held.moveBy(const Offset(0, -15));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await held.up();
    await tester.pumpAndSettle();
    expect(asked().single, containsPair('item', 'q3'));
    expect(asked().single['to'], lessThan(2));
    ran(runs.last);
  });

  testWidgets('a tap edits it in place: Cancel keeps it, Save changes it', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('queue-text-q1')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('queue-edit-field'));
    expect(tester.widget<TextField>(field).controller!.text, 'update the docs');
    await tester.enterText(field, 'something else');
    await tester.tap(find.byKey(const ValueKey('queue-edit-cancel')));
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(find.text('update the docs'), findsOneWidget);
    expect(runs, isEmpty);

    await tester.tap(find.byKey(const ValueKey('queue-text-q1')));
    await tester.pumpAndSettle();
    await tester.enterText(field, '  ');
    await tester.pump(Duration.zero);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('queue-edit-save'))).onPressed, isNull);
    await tester.enterText(field, 'update the docs and the changelog');
    await tester.pump(Duration.zero);
    await tester.tap(find.byKey(const ValueKey('queue-edit-save')));
    await tester.pumpAndSettle();
    expect(asked().single, {
      'op': 'queue',
      'session': _session,
      'do': 'edit',
      'item': 'q1',
      'text': 'update the docs and the changelog',
    });
    expect(find.text('update the docs and the changelog'), findsOneWidget, reason: 'shown before the computer says');

    // Refused: the old text again, with why.
    ran(runs.last, error: 'That prompt has gone to the agent already.');
    await tester.pumpAndSettle();
    expect(find.text('update the docs'), findsOneWidget);
    expect(find.text('That prompt has gone to the agent already.'), findsOneWidget);
  });

  testWidgets('Move to top and Move to bottom, offered where they move it', (tester) async {
    await open(tester);
    expect(await offered(tester, 'q1'), isNot(contains('Move to top')));
    expect(await offered(tester, 'q3'), isNot(contains('Move to bottom')));
    await menu(tester, 'q3', 'Move to top');
    expect(asked().single, {'op': 'queue', 'session': _session, 'do': 'move', 'item': 'q3', 'to': 0});
    expect(order(tester, ['q1', 'q2', 'q3']), ['q3', 'q1', 'q2']);
    ran(runs.last);

    await menu(tester, 'q3', 'Move to bottom');
    expect(asked().last, {'op': 'queue', 'session': _session, 'do': 'move', 'item': 'q3', 'to': 2});
    expect(order(tester, ['q1', 'q2', 'q3']), ['q1', 'q2', 'q3']);
    ran(runs.last);
  });

  testWidgets('Delete goes at once with Undo, which queues it again in its place', (tester) async {
    await open(tester);
    await menu(tester, 'q3', 'Delete');
    expect(asked().single, {'op': 'queue', 'session': _session, 'do': 'remove', 'item': 'q3'});
    expect(row('q3'), findsNothing);
    ran(runs.last);
    state(queue: three.take(2).toList());
    await tester.pump(Duration.zero);
    expect(find.text('Sent'), findsNothing, reason: 'deleted, not sent');

    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.pump(Duration.zero);
    expect(asked().last, {
      'op': 'prompt',
      'session': _session,
      'text': 'then ship it',
      'images': <String>[],
      'deliver': 'followUp',
    });
    ran(runs.last, queued: 'q9');
    await tester.pump(Duration.zero);
    expect(asked().last, {'op': 'queue', 'session': _session, 'do': 'move', 'item': 'q9', 'to': 2});
    ran(runs.last);
  });

  testWidgets('one with images or files asks first, since it could not come back; a swipe too', (tester) async {
    await open(tester);
    await menu(tester, 'q2', 'Delete');
    expect(find.text('Delete this prompt?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(runs, isEmpty);
    expect(row('q2'), findsOneWidget);

    await tester.fling(row('q2'), const Offset(-600, 0), 2000);
    await tester.pumpAndSettle();
    expect(find.text('Delete this prompt?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.pump(Duration.zero);
    expect(asked().single, {'op': 'queue', 'session': _session, 'do': 'remove', 'item': 'q2'});
    expect(row('q2'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    ran(runs.last);
  });

  testWidgets('Clear all asks, then deletes every one', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('queue-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Clear the queue?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Clear all').last);
    await tester.pumpAndSettle();
    expect(asked(), [
      for (final id in ['q1', 'q2', 'q3']) {'op': 'queue', 'session': _session, 'do': 'remove', 'item': id},
    ]);
    [...runs].forEach(ran);
    state();
    await tester.pumpAndSettle();
    expect(find.text('Nothing queued'), findsOneWidget);
    expect(find.text('Sent'), findsNothing);
  });

  testWidgets('Duplicate queues a copy after it; only of one with nothing but text', (tester) async {
    await open(tester);
    expect(await offered(tester, 'q2'), isNot(contains('Duplicate')));
    await menu(tester, 'q1', 'Duplicate');
    expect(asked().single, containsPair('text', 'update the docs'));
    expect(asked().single, containsPair('deliver', 'followUp'));
    ran(runs.last, queued: 'q9');
    await tester.pump(Duration.zero);
    expect(asked().last, {'op': 'queue', 'session': _session, 'do': 'move', 'item': 'q9', 'to': 1});
    ran(runs.last);
  });

  testWidgets('a prompt added at the bottom goes to the end of the queue, only while the agent works', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('queue-add-field')), 'and tag the release');
    await tester.pump(Duration.zero);
    await tester.tap(find.byKey(const ValueKey('queue-add')));
    await tester.pump(Duration.zero);
    expect(asked().single, {
      'op': 'prompt',
      'session': _session,
      'text': 'and tag the release',
      'images': <String>[],
      'deliver': 'followUp',
    });
    ran(runs.last, queued: 'q4');
    await tester.pump(Duration.zero);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('queue-add-field'))).controller!.text, isEmpty);

    // A command would go to the agent at once.
    await tester.enterText(find.byKey(const ValueKey('queue-add-field')), '/model');
    await tester.pump(Duration.zero);
    await tester.tap(find.byKey(const ValueKey('queue-add')));
    await tester.pump(Duration.zero);
    expect(runs, hasLength(1));
    expect(find.textContaining('Commands can’t wait in the queue'), findsOneWidget);

    state(queue: three, busy: false, paused: true);
    await tester.pump(Duration.zero);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('queue-add-field'))).enabled, isFalse);
  });

  testWidgets('follows the computer: the one that went shows as Sent, then leaves; empty once drained', (tester) async {
    await open(tester);
    state(queue: three.skip(1).toList());
    await tester.pump(Duration.zero);
    expect(row('q1'), findsNothing);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Queued · 2'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('Sent'), findsNothing);

    // One added on the computer shows too.
    state(
      queue: [
        ...three.skip(1),
        {'id': 'q5', 't': 'one more'},
      ],
    );
    await tester.pump(Duration.zero);
    expect(row('q5'), findsOneWidget);

    state();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Nothing queued'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-title')), findsOneWidget, reason: 'stays open');
  });

  testWidgets('offline it only shows, and says so', (tester) async {
    remote
      ..attach()
      ..detach();
    expect(remote.online, isFalse);
    await open(tester);
    expect(find.text('Offline: you can look, but not change it.'), findsOneWidget);
    expect(tester.widget<PopupMenuButton<String>>(find.byKey(const ValueKey('queue-menu-q1'))).enabled, isFalse);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('queue-clear'))).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('queue-screen-pause'))).onPressed, isNull);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('queue-add-field'))).enabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('queue-text-q1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('queue-edit-field')), findsNothing);
  });

  testWidgets('Send now for an agent that steers, not for Claude Code', (tester) async {
    await open(tester);
    expect(await offered(tester, 'q1'), contains('Send now'));
    await menu(tester, 'q1', 'Send now');
    expect(asked().single, {'op': 'queue', 'session': _session, 'do': 'send', 'item': 'q1'});
    ran(runs.last);
    state(queue: three.skip(1).toList());
    await tester.pump(Duration.zero);
    expect(find.text('Sent'), findsOneWidget);

    state(queue: three, agent: 'claude');
    await tester.pumpAndSettle();
    expect(await offered(tester, 'q2'), isNot(contains('Send now')));
  });
}
