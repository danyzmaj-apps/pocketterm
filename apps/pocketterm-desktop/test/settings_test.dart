// Paths joined with `/`, shown with `~`.
@Tags(['posix'])
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/ghostty_config.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/main_window.dart';

import 'app_fakes.dart';

/// A Mac in [home] with kitty and WezTerm (WezTerm not running).
class _Mac extends Terminals {
  _Mac(String home)
    : super(
        home: home,
        kitty: Kitty(socketDir: home, home: home),
        wezterm: WezTerm(executable: '$home/wezterm', socketDir: home),
        recency: () async => const [],
        snapshot: () async => Procs(const []),
      );

  @override
  Future<List<TermStatus>> statuses() async => [
    TermStatus(kitty!.id, kitty!.label, TermState.ready),
    TermStatus(wezterm!.id, wezterm!.label, TermState.idle),
  ];

  @override
  Future<List<TermWindow>> windows() async => const [];
}

/// A Mac in [home] with Ghostty, and tmux when [tmux] is installed.
class _GhosttyMac extends Terminals {
  _GhosttyMac(String home, {required bool tmux})
    : super(
        home: home,
        tmux: Tmux(executable: tmux ? '/bin/sh' : '$home/no-tmux', socketDirs: const []),
        ghostty: Ghostty(appPath: '$home/Ghostty.app'),
        recency: () async => const [],
        snapshot: () async => Procs(const []),
      );

  @override
  Future<List<TermStatus>> statuses() async => [
    TermStatus(tmux!.id, tmux!.label, tmux!.installed ? TermState.ready : TermState.missing),
    TermStatus(ghostty!.id, ghostty!.label, TermState.ready),
  ];

  @override
  Future<List<TermWindow>> windows() async => const [];
}

/// A Mac with kitty, kept in [home], which says [now].
class _KittyMac extends Terminals {
  _KittyMac(String home, this.now)
    : super(
        home: home,
        kitty: Kitty(socketDir: home, home: home),
        recency: () async => const [],
        snapshot: () async => Procs(const []),
      );
  List<TermStatus> now;

  @override
  Future<List<TermStatus>> statuses() async => now;

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

  testWidgets("a phone whose clock is too far off this computer's is named, under Phone", (tester) async {
    await pumpSettings(tester);
    await app.setProjectRoots(['$home/Dev']);
    app.phoneClockOff = const Duration(minutes: -9, seconds: -50);
    await app.setProjectRoots(['$home/Dev', '$home/Work']);
    await tester.pumpAndSettle();
    expect(dot('phone'), findsOneWidget);
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(find.textContaining('10 minutes behind this computer’s'), findsOneWidget);

    app.phoneClockOff = null;
    await app.setProjectRoots(['$home/Dev']);
    await tester.pumpAndSettle();
    expect(find.textContaining('behind this computer’s'), findsNothing);
  });

  testWidgets('New sessions open in: Auto or a terminal app found here', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('settings-tab-terminals')));
    await tester.pumpAndSettle();
    expect(app.terminalApp, 'auto');
    expect(find.text('Auto: the terminal app you used last'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-terminal-app')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WezTerm').last);
    await tester.pumpAndSettle();
    expect(app.terminalApp, 'wezterm');
    expect(find.text('Always WezTerm'), findsOneWidget);
  });

  testWidgets("Place them: a tab in the project's window unless a new window is chosen", (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.byKey(const ValueKey('settings-tab-terminals')));
    await tester.pumpAndSettle();
    expect(app.placement, Placement.projectWindow);

    await tester.tap(find.byKey(const ValueKey('settings-placement')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New window').last);
    await tester.pumpAndSettle();
    expect(app.placement, Placement.newWindow);
    expect(find.text('A new window for every session.'), findsOneWidget);
  });

  testWidgets("kitty's Set up stays after it fails, and its note gives way once kitty's status moves on", (
    tester,
  ) async {
    // A file where kitty's config folder goes: kitty.conf can't be written.
    File('$home/.config').createSync();
    const needs = TermStatus('kitty', 'kitty', TermState.setup, note: 'not let in', fix: TermFix.kittyConfig);
    final mac = _KittyMac(home, [needs]);
    await pumpSettings(tester, terminals: mac);
    await tester.tap(find.byKey(const ValueKey('settings-tab-terminals')));
    await tester.pumpAndSettle();
    final setUp = find.byKey(const ValueKey('settings-fix-kitty'));
    expect(setUp, findsOneWidget);

    await tester.runAsync(() => tester.tap(setUp));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't change kitty.conf"), findsOneWidget);
    expect(setUp, findsOneWidget, reason: 'a failed fix can be tried again');
    expect(dot('terminals'), findsOneWidget);

    // Tried again once kitty.conf can be written: done, and the note goes once kitty no longer needs the fix.
    File('$home/.config').deleteSync();
    await tester.runAsync(() => tester.tap(setUp));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(File('$home/.config/kitty/kitty.conf').existsSync(), isTrue);
    expect(find.textContaining('Added to kitty.conf'), findsOneWidget);
    expect(setUp, findsNothing);

    mac.now = [const TermStatus('kitty', 'kitty', TermState.setup, note: 'Restart kitty')];
    app.mainShown.value++;
    await tester.pumpAndSettle();
    expect(find.textContaining('kitty.conf'), findsNothing);
    expect(find.textContaining('Restart kitty'), findsOneWidget);
  });

  group('Ghostty: start new windows in tmux', () {
    Finder button() => find.byKey(const ValueKey('settings-ghostty-tmux'));
    String config() => '$home/.config/ghostty/config.ghostty';

    Future<void> openTerminals(WidgetTester tester, {required bool tmux}) async {
      await pumpSettings(tester, terminals: _GhosttyMac(home, tmux: tmux));
      await tester.tap(find.byKey(const ValueKey('settings-tab-terminals')));
      await tester.pumpAndSettle();
    }

    testWidgets('offered only with tmux installed', (tester) async {
      await openTerminals(tester, tmux: false);
      expect(find.byKey(const ValueKey('settings-terminal-ghostty')), findsOneWidget);
      expect(button(), findsNothing);
    });

    testWidgets('adds its lines, then Remove puts the config back as it was', (tester) async {
      File(config())
        ..createSync(recursive: true)
        ..writeAsStringSync('font-size = 14\n');
      await openTerminals(tester, tmux: true);
      expect(find.text('Start new windows in tmux'), findsOneWidget);

      await tester.tap(button());
      await tester.pumpAndSettle();
      expect(File(config()).readAsStringSync(), contains('command = /bin/sh new-session'));
      expect(find.textContaining('Open new Ghostty windows to get full control.'), findsOneWidget);

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(File(config()).readAsStringSync(), 'font-size = 14\n');
      expect(find.text('Start new windows in tmux'), findsOneWidget);
    });

    testWidgets("a command of the person's own is explained and left alone", (tester) async {
      File(config())
        ..createSync(recursive: true)
        ..writeAsStringSync('command=/bin/zsh -l\n');
      await openTerminals(tester, tmux: true);
      expect(find.textContaining('already sets command = /bin/zsh -l'), findsOneWidget);
      expect(button(), findsNothing);
      expect(File(config()).readAsStringSync(), 'command=/bin/zsh -l\n');
    });

    testWidgets("an earlier PocketTerm's line is brought up to date when Settings looks, and the card says so", (
      tester,
    ) async {
      const old = r'command = /bin/sh new-session \; set-option destroy-unattached on';
      const before = 'font-size = 14\n${GhosttyConfig.marker}\n$old\ntheme = dark\n';
      File(config())
        ..createSync(recursive: true)
        ..writeAsStringSync(before);
      await openTerminals(tester, tmux: true);
      expect(File(config()).readAsStringSync(), before.replaceFirst(old, GhosttyConfig.line('/bin/sh')));
      expect(find.textContaining('with a title PocketTerm can match'), findsOneWidget);
    });
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
