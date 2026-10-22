import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/terminal_view.dart';

import 'screenshots/fakes.dart';

void main() {
  late Directory dir;
  late List<(String, Map<String, dynamic>)> sent;
  late TerminalRemote remote;

  /// What the sheet pops, once [pumpSheet] opened it.
  late Future<({String window, bool agent})?> popped;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_new_session');
    sent = [];
    remote = TerminalRemote(
      offlineServer(),
      dir,
      desktopId: 'abcd1234',
      key: ChannelKey(List.filled(32, 9)),
      from: 'phone',
      send: (event, payload) => sent.add((event, payload)),
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// The computer online with [roots] as its Project folders; null: a computer that
  /// predates them.
  void macState(List<String>? roots) => remote.handle('state', {
    'windows': <Object>[],
    'sessions': <Object>[],
    'projects': <Object>[],
    'roots': ?roots,
    'home': '/Users/me',
  });

  /// The `run` the phone sent last, after the turn of the event loop it goes out on.
  Future<Map<String, dynamic>> lastRun(WidgetTester tester) async {
    await tester.pump(Duration.zero);
    return sent.lastWhere((s) => s.$1 == 'run').$2;
  }

  Future<void> openNewProject(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('new-project')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('project-name')), name);
    await tester.pump();
  }

  /// The sheet opened over a page.
  Future<void> pumpSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => popped = showModalBottomSheet<({String window, bool agent})>(
                context: context,
                isScrollControlled: true,
                builder: (_) => NewSessionSheet(remote: remote),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('no project folders: New project… is off and the sheet says where to add one, once', (tester) async {
    macState(const []);
    await pumpSheet(tester);
    final tile = tester.widget<ListTile>(find.byKey(const ValueKey('new-project')));
    expect(tile.enabled, isFalse);
    expect(tile.subtitle, isNull);
    expect(find.byKey(const ValueKey('no-roots')), findsOneWidget);
    // The state's cache write, not waited for.
    remote.flush();
  });

  testWidgets('a computer without Project folders: no New project…, and no hint about a setting it lacks', (
    tester,
  ) async {
    macState(null);
    await pumpSheet(tester);
    expect(find.byKey(const ValueKey('new-project')), findsNothing);
    expect(find.byKey(const ValueKey('no-roots')), findsNothing);
    remote.flush();
  });

  testWidgets('New project… makes the folder under the picked root, kept when the list changes', (tester) async {
    macState(const ['/Users/me/Code', '/Users/me/Work']);
    await pumpSheet(tester);
    expect(find.byKey(const ValueKey('no-roots')), findsNothing);
    await openNewProject(tester, 'demo');
    expect(find.text('New project'), findsOneWidget);
    await tester.tap(find.text('~/Work'));
    await tester.pump();
    // The computer adds a folder in front of the picked one meanwhile.
    macState(const ['/Users/me/New', '/Users/me/Code', '/Users/me/Work']);
    await tester.pump();
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '~/Work')).selected, isTrue);

    await tester.tap(find.text('Create and open'));
    final run = await lastRun(tester);
    expect(
      run,
      allOf(
        containsPair('op', 'create'),
        containsPair('root', '/Users/me/Work'),
        containsPair('name', 'demo'),
        containsPair('agent', true),
      ),
    );
    // No going back while it's under way.
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Back')).onPressed, isNull);

    remote.handle('ran', {'id': run['id'], 'window': 'kitty-1/9'});
    await tester.pumpAndSettle();
    expect(await popped, (window: 'kitty-1/9', agent: true));
    remote.flush();
  });

  testWidgets("the computer's refusal shows, and the form stays to try again", (tester) async {
    macState(const ['/Users/me/Code']);
    await pumpSheet(tester);
    await openNewProject(tester, 'demo');
    await tester.tap(find.text('Create and open'));
    final run = await lastRun(tester);
    remote.handle('ran', {'id': run['id'], 'error': 'There is already something named demo there.'});
    await tester.pumpAndSettle();

    expect(find.text('There is already something named demo there.'), findsOneWidget);
    expect(find.byKey(const ValueKey('project-name')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Back')).onPressed, isNotNull);
    remote.flush();
  });

  testWidgets('a shell just started opens as coming, not closed, until the computer lists it', (tester) async {
    remote.handle('state', {
      'windows': <Object>[],
      'sessions': <Object>[],
      'projects': ['/Users/me/a'],
      'home': '/Users/me',
    });
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                TextButton(onPressed: () => unawaited(openNewSession(context, remote)), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('start-agent')));
    await tester.pump();
    await tester.tap(find.text('~/a'));
    final run = await lastRun(tester);
    expect(run, allOf(containsPair('op', 'launch'), containsPair('agent', false)));
    remote.handle('ran', {'id': run['id'], 'window': 'kitty-1/9'});
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TerminalPage), findsOneWidget);
    expect(find.text('This window has closed.'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    Map<String, dynamic> listed(List<Object> windows) => {
      'windows': windows,
      'sessions': <Object>[],
      'projects': ['/Users/me/a'],
      'home': '/Users/me',
    };
    remote.handle(
      'state',
      listed([
        {'key': 'kitty-1/9', 'title': 'zsh', 'cwd': '/Users/me/a', 'program': 'zsh', 'app': 'kitty'},
      ]),
    );
    await tester.pump();
    expect(find.text('This window has closed.'), findsNothing);
    remote.handle('state', listed([]));
    await tester.pump();
    expect(find.text('This window has closed.'), findsOneWidget, reason: 'listed once, then gone: closed');
    remote.flush();
  });
}
