// Paths joined with `/`, shown with `~`.
@Tags(['posix'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/iterm.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_desktop/main_window.dart';

import 'app_fakes.dart';

/// A Mac in [home] with kitty and iTerm2 (iTerm2 not running).
class _Mac extends Terminals {
  _Mac(String home)
    : super(
        home: home,
        kitty: Kitty(socketDir: home, home: home),
        iterm: ITerm(appPath: '$home/iTerm.app'),
        recency: () async => const [],
        snapshot: () async => Procs(const []),
      );

  @override
  Future<List<TermStatus>> statuses() async => [
    TermStatus(kitty!.id, kitty!.label, TermState.ready),
    TermStatus(iterm!.id, iterm!.label, TermState.idle),
  ];

  @override
  Future<List<TermWindow>> windows() async => const [];
}

void main() {
  late String home;
  late FakeApp app;

  setUp(() => home = Directory.systemTemp.createTempSync('pocketterm-settings').resolveSymbolicLinksSync());
  tearDown(() => Directory(home).deleteSync(recursive: true));

  Future<void> pumpSettings(WidgetTester tester, {Terminals? terminals}) async {
    tester.view
      ..physicalSize = const Size(1000, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    app = await FakeApp.create(terminals: terminals ?? _Mac(home), integrations: FakeApp.noAgents(home));
    await tester.pumpWidget(
      window(
        ListenableBuilder(
          listenable: app,
          builder: (_, _) => Stack(children: [SettingsPage(app: app)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder dot(String tab) => find.byKey(ValueKey('settings-tab-dot-$tab'));

  testWidgets('a dot marks the tab whose items need attention, and goes once they are done', (tester) async {
    await pumpSettings(tester);
    // No coding agent and no project folders; a phone has signed in.
    app.phoneUsedCode = true;
    await app.checkPhone();
    await tester.pumpAndSettle();
    expect(find.text('2 things need attention'), findsOneWidget);
    expect(dot('agents'), findsOneWidget);
    expect(dot('phone'), findsOneWidget);
    expect(dot('terminals'), findsNothing);
    expect(dot('account'), findsNothing);

    await app.setProjectRoots(['$home/Dev']);
    await tester.pumpAndSettle();
    expect(find.text('1 thing needs attention'), findsOneWidget);
    expect(dot('phone'), findsNothing);
    expect(dot('agents'), findsOneWidget);
  });

  testWidgets('Show lists what needs attention with its button', (tester) async {
    await pumpSettings(tester);
    expect(find.textContaining('No coding agent found:'), findsNothing);
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No coding agent found:'), findsOneWidget);

    app.host.folders = ['$home/Dev'];
    final add = find.descendant(of: find.byKey(const ValueKey('settings-status')), matching: find.text('Add folder…'));
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(app.projectRoots, ['$home/Dev']);
  });

  testWidgets('New sessions open in: Auto or a terminal app found here', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('settings-tab-terminals')));
    await tester.pumpAndSettle();
    expect(app.terminalApp, 'auto');
    expect(find.text('Auto: the terminal app you used last'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-terminal-app')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('iTerm2').last);
    await tester.pumpAndSettle();
    expect(app.terminalApp, 'iterm');
    expect(find.text('Always iTerm2'), findsOneWidget);
  });

  testWidgets('project folders: added ones show with ~, their ✕ drops them', (tester) async {
    await pumpSettings(tester);
    expect(find.text('None yet · your phone can still open any path you type'), findsOneWidget);
    await app.setProjectRoots(['$home/Code', '/opt/src', home]);
    await tester.pumpAndSettle();
    expect(find.text('~/Code'), findsOneWidget);
    expect(find.text('/opt/src'), findsOneWidget);
    expect(find.text('~'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('settings-folder-$home/Code')));
    await tester.pumpAndSettle();
    expect(app.projectRoots, ['/opt/src', home]);
    expect(find.text('~/Code'), findsNothing);
  });
}
