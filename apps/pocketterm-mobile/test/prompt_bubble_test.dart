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

  /// The session's transcript as the computer has it.
  late List<Map<String, dynamic>> items;

  /// The computer sends the whole transcript, as on a catch-up.
  void catchUp() => remote.handle('items', {
    'to': 'phone',
    'session': _session,
    'epoch': 'e1',
    'seq': items.length,
    'reset': true,
    'last': true,
    'older': false,
    'items': items,
  });

  /// The agent shows the person's [text] in its transcript, as a live change.
  void echo(String text) {
    items.add({'id': 'u${items.length + 1}', 'k': 'user', 't': text, 'o': items.length + 1, 's': items.length + 1});
    remote.handle('live', {
      'session': _session,
      'epoch': 'e1',
      'ops': [
        {'s': items.length, 'item': items.last},
      ],
    });
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_prompt_bubble');
    runs = [];
    items = [
      {'id': 'u1', 'k': 'user', 't': 'hi', 'o': 1, 's': 1},
      {'id': 'a2', 'k': 'assistant', 't': 'Hello. What should we do?', 'o': 2, 's': 2},
    ];
    remote =
        TerminalRemote(
          offlineServer(),
          dir,
          desktopId: 'abcd1234',
          key: ChannelKey(List.filled(32, 9)),
          from: 'phone',
          send: (event, payload) {
            if (event == 'run') runs.add(payload);
          },
        )..handle('state', {
          'windows': [
            {'key': _session, 'title': 'omp', 'cwd': '/Users/me/a', 'program': 'omp', 'app': 'kitty'},
          ],
          'sessions': [
            {
              'key': _session,
              'id': 's2',
              'agent': 'omp',
              'window': _session,
              'title': 'The session',
              'cwd': '/Users/me/a',
              'at': DateTime.now().millisecondsSinceEpoch,
            },
          ],
          'home': '/Users/me',
          'agent': 'omp',
        });
    catchUp();
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
    // The computer answers the page's catch-up.
    catchUp();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('session-input')), text);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('session-send')));
    await tester.pump(Duration.zero);
  }

  /// A frame, then the one that keeps the bottom in view as it grew.
  Future<void> frames(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  List<Map<String, dynamic>> prompts() => [
    for (final r in runs)
      if (r['op'] == 'prompt') r,
  ];

  void ran(Map<String, dynamic> run, {String? error}) => remote.handle('ran', {'id': run['id'], 'error': ?error});

  final outgoing = find.byKey(const ValueKey('outgoing'));
  final sending = find.byKey(const ValueKey('outgoing-sending'));

  testWidgets('a prompt shows at once as the person’s message, sending until the computer takes it', (tester) async {
    await open(tester);
    await send(tester, 'fix the tests');

    expect(prompts().single, containsPair('text', 'fix the tests'));
    expect(find.descendant(of: outgoing, matching: find.text('fix the tests')), findsOneWidget);
    expect(find.descendant(of: outgoing, matching: find.text('Sending…')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('session-input'))).controller!.text,
      isEmpty,
      reason: 'the field is free for the next one',
    );
    // Below the transcript, the newest message.
    expect(tester.getTopLeft(outgoing).dy, greaterThan(tester.getTopLeft(find.text('Hello. What should we do?')).dy));

    ran(prompts().single);
    await tester.pump();
    expect(sending, findsNothing);
    expect(find.descendant(of: outgoing, matching: find.text('fix the tests')), findsOneWidget);
  });

  testWidgets('the agent’s copy takes its place, never both; before the computer answers or with more in it too', (
    tester,
  ) async {
    await open(tester);
    await send(tester, 'fix the tests');
    ran(prompts().single);
    await tester.pump();
    // A catch-up that doesn't have it yet keeps it.
    catchUp();
    await tester.pump();
    expect(outgoing, findsOneWidget);
    echo('fix the tests');
    await tester.pump();
    expect(outgoing, findsNothing);
    expect(find.text('fix the tests'), findsOneWidget);

    // omp can show it before the computer answers; the computer names a file it took along after its text.
    await send(tester, 'read   this');
    echo('read this @/tmp/pocketterm/notes.md');
    await tester.pump();
    expect(outgoing, findsNothing);
    ran(prompts().last);
    await tester.pump();
    expect(outgoing, findsNothing);
    expect(find.text('read this @/tmp/pocketterm/notes.md'), findsOneWidget);
  });

  testWidgets('one that did not go says why, and a tap sends it again, once', (tester) async {
    await open(tester);
    await send(tester, 'deploy it');
    ran(prompts().single, error: 'That session has ended.');
    await frames(tester);
    expect(find.descendant(of: outgoing, matching: find.text('Not sent. Tap to retry')), findsOneWidget);
    expect(find.descendant(of: outgoing, matching: find.text('That session has ended.')), findsOneWidget);
    expect(prompts(), hasLength(1), reason: 'not again on its own');

    await tester.tap(find.text('Not sent. Tap to retry'));
    await tester.pump(Duration.zero);
    expect(prompts(), hasLength(2));
    expect(prompts().last, containsPair('text', 'deploy it'));
    expect(sending, findsOneWidget);
    expect(find.text('Not sent. Tap to retry'), findsNothing);
    await tester.tap(find.text('deploy it'));
    await tester.pump(Duration.zero);
    expect(prompts(), hasLength(2), reason: 'nothing to retry while it goes');

    ran(prompts().last);
    await tester.pump();
    echo('deploy it');
    await tester.pump();
    expect(outgoing, findsNothing);
    expect(find.text('deploy it'), findsOneWidget);
  });
}
