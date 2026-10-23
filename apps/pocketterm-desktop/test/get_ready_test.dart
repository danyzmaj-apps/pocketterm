// Paths joined with `/`, shown with `~`; the Mac's terminals card.
@Tags(['posix'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:pocketterm_desktop/onboarding/get_ready.dart';

import 'app_fakes.dart';

/// A computer in [home] with no terminal app, whose terminals show [shown].
class _Computer extends Terminals {
  _Computer(String home) : super(home: home, recency: () async => const [], snapshot: () async => Procs(const []));
  List<TermWindow> shown = const [];

  @override
  Future<List<TermWindow>> windows() async => shown;
}

/// A coding agent's extension connection that goes nowhere.
class _Link implements LiveLink {
  @override
  void send(String frame) {}

  @override
  Future<void> close() async {}
}

void main() {
  late String home;
  late FakeApp app;

  setUp(() => home = Directory.systemTemp.createTempSync('pocketterm-get-ready').resolveSymbolicLinksSync());
  tearDown(() => Directory(home).deleteSync(recursive: true));

  /// [page] over an app whose home is [home], with `claude` there if
  /// [claude] is one.
  Future<_Computer> pump(WidgetTester tester, Widget Function(FakeApp app) page, {FakeClaude? claude}) async {
    tester.view
      ..physicalSize = const Size(1000, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final computer = _Computer(home);
    app = await FakeApp.create(
      terminals: computer,
      integrations: Integrations(
        home: home,
        run: claude?.run ?? (_, _) async => ProcessResult(0, 1, '', ''),
        claudePaths: [?claude?.path],
        ompPaths: const [],
      ),
    );
    await tester.pumpWidget(window(ListenableBuilder(listenable: app, builder: (_, _) => page(app))));
    return computer;
  }

  /// Gives real file work (copies, temporary directories) real time, until
  /// [done] holds.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(done(), isTrue);
  }

  bool shows(String text) => find.textContaining(text).evaluate().isNotEmpty;

  testWidgets('PocketTerm goes into every agent found, and a failure says why and offers Retry', (tester) async {
    // omp has run here; Claude Code is installed, and installing its plugin fails.
    Directory('$home/.omp').createSync();
    final claude = FakeClaude('$home/bin/claude')..fail = 'plugin install pocketterm@pocketterm --json';
    File(claude.path).createSync(recursive: true);
    await pump(tester, (app) => GetReadyPage(app: app), claude: claude);

    await settle(tester, () => shows('PocketTerm is installed in omp') && shows("Couldn't install PocketTerm in"));
    expect(File('$home/.omp/agent/extensions/pocketterm-live.ts').existsSync(), isTrue);
    expect(claude.calls, contains('plugin install pocketterm@pocketterm --json'));
    expect(find.textContaining('Claude Code not found'), findsNothing, reason: 'both agents are here');

    // Fixed meanwhile: Retry installs it, and Claude Code lists it from then on.
    claude
      ..fail = null
      ..list = [
        {
          'id': 'pocketterm@pocketterm',
          'enabled': true,
          'readFromFolder': '$home/.config/pocketterm/claude-plugin/plugins/pocketterm',
        },
      ];
    await tester.tap(find.text('Retry'));
    await settle(tester, () => shows('PocketTerm is installed in Claude Code'));
    expect(find.textContaining("Couldn't install PocketTerm in"), findsNothing);
  });

  testWidgets('an agent that isn’t here is left for later; none at all needs one installed', (tester) async {
    Directory('$home/.omp').createSync();
    await pump(tester, (app) => GetReadyPage(app: app));
    await settle(tester, () => shows('PocketTerm is installed in omp'));
    expect(find.textContaining('Claude Code not found'), findsOneWidget);

    Directory('$home/.omp').deleteSync(recursive: true);
    await app.checkAgents();
    await tester.pump();
    expect(find.textContaining('No coding agent found'), findsOneWidget);
  });

  testWidgets('sessions opened before PocketTerm are listed with what picks it up, until they report', (tester) async {
    Directory('$home/.omp').createSync();
    final computer = await pump(tester, (app) => GetReadyPage(app: app, poll: const Duration(milliseconds: 100)));
    computer.shown = [
      TermWindow(key: 'kitty-1/4', title: 'omp', tab: '', cwd: '$home/Dev/garden', program: 'omp'),
      TermWindow(key: 'kitty-1/5', title: 'zsh', tab: '', cwd: home, program: 'zsh'),
      TermWindow(key: 'kitty-1/6', title: 'claude', tab: '', cwd: '$home/Dev/shop', program: 'claude'),
    ];
    await settle(tester, () => shows('PocketTerm is installed in omp'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.text('Sessions that were already open'), findsOneWidget);
    expect(find.byKey(const ValueKey('get-ready-unreported-kitty-1/4')), findsOneWidget);
    expect(find.byKey(const ValueKey('get-ready-unreported-kitty-1/5')), findsNothing, reason: 'a shell');
    Finder command(String key, String text) =>
        find.descendant(of: find.byKey(ValueKey('get-ready-unreported-$key')), matching: find.text(text));
    expect(command('kitty-1/4', Agent.omp.resume), findsOneWidget);
    expect(command('kitty-1/6', '/reload-plugins'), findsOneWidget);
    expect(find.textContaining('omp in ~/Dev/garden'), findsOneWidget);
    expect(find.textContaining('Claude Code in ~/Dev/shop'), findsOneWidget);
    expect(find.textContaining('Claude Code: type /reload-plugins in it. Nothing restarts.'), findsOneWidget);
    expect(find.text('Skip'), findsNothing, reason: 'Done is the only way out');

    // The copy button puts what to type on the clipboard: plain spaces, no joiners.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    final copy = find.descendant(
      of: find.byKey(const ValueKey('get-ready-unreported-kitty-1/4')),
      matching: find.byTooltip('Copy'),
    );
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pump();
    expect(copied, 'omp -c');
    expect(find.byTooltip('Copied'), findsOneWidget);

    // Restarted with omp -c: its session reports from that window.
    final frames = StreamController<String>();
    addTearDown(frames.close);
    unawaited(app.live.accept(frames.stream, _Link()));
    frames.add(
      '{"t":"hello","v":1,"pid":7,"agent":"omp","busy":false,"items":[],"window":"kitty-1/4",'
      '"session":{"id":"s7","title":"Garden","cwd":"$home/Dev/garden","model":"m"}}',
    );
    await settle(tester, () => find.byKey(const ValueKey('get-ready-unreported-kitty-1/4')).evaluate().isEmpty);
  });

  testWidgets('project folders: a usual one found here is added in one click', (tester) async {
    Directory('$home/Dev').createSync();
    Directory('$home/Music').createSync();
    await pump(tester, (app) => GetReadyPage(app: app));
    await tester.pump();
    expect(find.text('~/Music'), findsNothing);

    await tester.ensureVisible(find.byKey(ValueKey('get-ready-folder-$home/Dev')));
    await tester.tap(find.byKey(ValueKey('get-ready-folder-$home/Dev')));
    await tester.pump();
    expect(app.projectRoots, ['$home/Dev']);
    expect(find.byKey(ValueKey('get-ready-folder-$home/Dev')), findsNothing, reason: 'added, so no longer offered');
  });

  testWidgets('the phone step shows a code until a phone has signed in', (tester) async {
    await pump(tester, (app) => GetReadyPage(app: app, poll: const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump();
    expect(app.pairingLinks, 1);
    expect(find.textContaining('A phone is signed in'), findsNothing);

    app.phoneUsedCode = true;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.textContaining('A phone is signed in'), findsOneWidget);
  });

  testWidgets('looking goes on while the window shows, however long it has been', (tester) async {
    await pump(
      tester,
      (app) => GetReadyPage(app: app, poll: const Duration(milliseconds: 100), lookHidden: Duration.zero),
    );
    await tester.runAsync(app.start);
    await tester.pump(const Duration(seconds: 1));
    app.phoneUsedCode = true;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.textContaining('A phone is signed in'), findsOneWidget, reason: 'still looking while shown');
  });

  testWidgets('hidden, it stops looking; shown again, it looks', (tester) async {
    await pump(
      tester,
      (app) => GetReadyPage(app: app, poll: const Duration(milliseconds: 100), lookHidden: Duration.zero),
    );
    await tester.runAsync(app.start);
    await app.host.onEvent!('mainClosed');
    await tester.pump(const Duration(milliseconds: 10));
    app.phoneUsedCode = true;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.textContaining('A phone is signed in'), findsNothing);

    await app.host.onEvent!('openMain');
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('A phone is signed in'), findsOneWidget);
  });

  testWidgets('through Tailscale, the phone step says the phone needs Tailscale too; on a VPS it doesn’t', (
    tester,
  ) async {
    final note = find.byKey(const ValueKey('get-ready-phone-tailscale'));
    await pump(tester, (app) => GetReadyPage(app: app, poll: const Duration(hours: 1)));
    await tester.pump();
    expect(note, findsNothing);

    await pump(tester, (app) {
      app.fakeBackend = const Backend(url: 'https://ana-mac.tail4b2c.ts.net');
      return GetReadyPage(app: app, poll: const Duration(hours: 1));
    });
    await tester.pump();
    expect(note, findsOneWidget);
  });

  testWidgets('Settings counts what needs attention, and its buttons fix it', (tester) async {
    // omp without PocketTerm, no terminal app, no phone, no project folders.
    Directory('$home/.omp').createSync();
    await pump(tester, (app) => SettingsPage(app: app));
    await settle(tester, () => shows('things need attention'));
    expect(find.text('4 things need attention'), findsOneWidget);
    await tester.tap(find.text('Show'));
    await tester.pump();
    Finder inStatus(String text) =>
        find.descendant(of: find.byKey(const ValueKey('settings-status')), matching: find.text(text));

    app.host.folders = ['$home/Dev'];
    await tester.tap(inStatus('Add folder…'));
    await tester.pump();
    expect(find.text('3 things need attention'), findsOneWidget);

    app.phoneUsedCode = true;
    await app.checkPhone();
    await tester.pump();
    expect(find.text('2 things need attention'), findsOneWidget);

    await tester.tap(inStatus('Install'));
    await settle(tester, () => shows('1 thing needs attention'));
    expect(File('$home/.omp/agent/extensions/pocketterm-live.ts').existsSync(), isTrue);
  });

  test('Windows: GitHub Desktop’s folder is found where OneDrive moved Documents too', () {
    final there = {r'C:\Users\ana\source\repos', r'C:\Users\ana\OneDrive - Contoso\Documents\GitHub'};
    expect(
      windowsProjectFolders(r'C:\Users\ana', {
        'OneDriveCommercial': r'C:\Users\ana\OneDrive - Contoso',
        'OneDrive': r'C:\Users\ana\OneDrive - Contoso',
      }, there.contains),
      unorderedEquals(there),
    );
  });
}
