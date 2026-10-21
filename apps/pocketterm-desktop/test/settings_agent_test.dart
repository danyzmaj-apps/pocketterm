// Paths joined with `/`, shown with `~`.
@Tags(['posix'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/main_window.dart';

import 'app_fakes.dart';

void main() {
  late String home;
  late FakeApp app;

  setUp(() => home = Directory.systemTemp.createTempSync('pocketterm-settings').path);
  tearDown(() => Directory(home).deleteSync(recursive: true));

  /// Settings over nothing, its integrations in [home], with no `claude` on
  /// this computer unless [claude] is one.
  Future<void> pumpSettings(WidgetTester tester, {FakeClaude? claude}) async {
    tester.view
      ..physicalSize = const Size(1000, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    app = await FakeApp.create(
      integrations: Integrations(
        home: home,
        run: claude?.run ?? (_, _) async => ProcessResult(0, 1, '', ''),
        claudePaths: [?claude?.path],
        ompPaths: const [],
      ),
    );
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

  /// Gives real file work (copies, temporary directories) real time, until
  /// [text] shows.
  Future<void> settle(WidgetTester tester, String text) async {
    for (var i = 0; i < 200 && find.textContaining(text).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> openTab(WidgetTester tester, String tab) async {
    await tester.tap(find.byKey(ValueKey('settings-tab-$tab')));
    await tester.pumpAndSettle();
  }

  Finder inCard(Agent agent, Finder f) =>
      find.descendant(of: find.byKey(ValueKey('settings-agent-${agent.name}')), matching: f);

  testWidgets('omp is the default, and its extensions install from its card', (tester) async {
    Directory('$home/.omp').createSync();
    await pumpSettings(tester);
    await openTab(tester, 'agents');
    expect(app.codingAgent, Agent.omp);
    expect(inCard(Agent.omp, find.text('Default')), findsOneWidget);
    expect(inCard(Agent.omp, find.text('PocketTerm isn’t installed here yet')), findsOneWidget);
    expect(inCard(Agent.claude, find.text('Not found on this computer')), findsOneWidget);
    expect(inCard(Agent.claude, find.text('Make default')), findsNothing, reason: 'not on this computer');

    await tester.tap(inCard(Agent.omp, find.text('Install')));
    await settle(tester, 'restart');
    expect(find.text('Installed · restart your omp sessions to load it (${Agent.omp.resume})'), findsOneWidget);
    expect(File('$home/.omp/agent/extensions/pocketterm-live.ts').existsSync(), isTrue);
  });

  testWidgets('Make default makes the other agent the one new sessions start', (tester) async {
    Directory('$home/.omp').createSync();
    final claude = FakeClaude('$home/bin/claude');
    File(claude.path).createSync(recursive: true);
    await pumpSettings(tester, claude: claude);
    await openTab(tester, 'agents');
    expect(inCard(Agent.omp, find.text('Make default')), findsNothing);

    await tester.tap(inCard(Agent.claude, find.text('Make default')));
    await tester.pumpAndSettle();
    expect(app.codingAgent, Agent.claude);
    expect(inCard(Agent.claude, find.text('Default')), findsOneWidget);
    expect(inCard(Agent.claude, find.text('Make default')), findsNothing);
    expect(inCard(Agent.omp, find.text('Default')), findsNothing);
    expect(inCard(Agent.omp, find.text('Make default')), findsOneWidget);
  });

  testWidgets('Claude Code with mods off says how to turn them on, also right after updating', (tester) async {
    final claude = FakeClaude('$home/bin/claude')
      ..list = [
        {
          'id': 'pocketterm@pocketterm',
          'enabled': true,
          'readFromFolder': '$home/.config/pocketterm/claude-plugin/plugins/pocketterm',
        },
      ]
      ..modsOff = true;
    File(claude.path).createSync(recursive: true);
    await pumpSettings(tester, claude: claude);
    await openTab(tester, 'agents');
    // Installed, not the bundled copy yet.
    await settle(tester, 'out of date');
    expect(inCard(Agent.claude, find.text('PocketTerm here is out of date')), findsOneWidget);

    // Updating can't turn mods on.
    await tester.tap(inCard(Agent.claude, find.text('Update')));
    await settle(tester, 'Installed ·');
    const hint = 'run claude /login, start claude once, then type /reload-plugins in your Claude Code sessions';
    expect(find.text('Installed · Claude Code has mods turned off for now: $hint'), findsOneWidget);

    // Shown again, the window looks again.
    claude.modsOff = false;
    await tester.runAsync(() async {
      await app.openMain();
      await app.checkAgents();
    });
    await tester.pump();
    expect(inCard(Agent.claude, find.text('PocketTerm installed, up to date')), findsOneWidget);
  });
}
