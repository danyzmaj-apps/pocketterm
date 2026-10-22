import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/ghostty_config.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_desktop/commands.dart';
import 'package:pocketterm_desktop/onboarding/commands_view.dart';
import 'package:pocketterm_desktop/onboarding/terminals_card.dart';

import 'app_fakes.dart';

/// A Mac whose terminals say [now].
class _Mac extends Terminals {
  _Mac(this.now, {super.home = '/nonexistent-pocketterm', super.tmux, super.ghostty})
    : super(recency: () async => const [], snapshot: () async => Procs(const []));
  List<TermStatus> now;

  @override
  Future<List<TermStatus>> statuses() async => now;
}

void main() {
  /// [t]'s card; it looks again every [poll] (an hour: only when a fix or an install asks it to).
  Future<void> pump(
    WidgetTester tester,
    Terminals t, {
    Commands? commands,
    Duration poll = const Duration(milliseconds: 100),
  }) async {
    tester.view
      ..physicalSize = const Size(800, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MacTerminalsCard(terminals: t, commands: commands, poll: poll),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('lists only the terminals found, with their fixes, and recommends tmux while it is missing', (
    tester,
  ) async {
    final mac = _Mac([
      const TermStatus('kitty', 'kitty', TermState.setup, note: 'not let in', fix: TermFix.kittyConfig),
      const TermStatus('tmux', 'tmux', TermState.missing),
      const TermStatus('wezterm', 'WezTerm', TermState.missing),
      const TermStatus('ghostty', 'Ghostty', TermState.setup, note: 'allow', fix: TermFix.automation),
    ]);
    await pump(tester, mac);

    expect(find.byKey(const ValueKey('terminal-kitty')), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-ghostty')), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-wezterm')), findsNothing, reason: 'not installed');
    expect(find.text('Set up'), findsOneWidget);
    expect(find.text('Allow…'), findsOneWidget);
    expect(find.byKey(const ValueKey('tmux-get-homebrew')), findsOneWidget);

    // Permission given and tmux installed meanwhile: the card catches up.
    mac.now = [
      const TermStatus('kitty', 'kitty', TermState.ready),
      const TermStatus('tmux', 'tmux', TermState.ready),
      const TermStatus('ghostty', 'Ghostty', TermState.limited, note: 'no screen'),
    ];
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.text('Allow…'), findsNothing);
    expect(find.byKey(const ValueKey('tmux-get-homebrew')), findsNothing);
    expect(find.byKey(const ValueKey('terminal-tmux')), findsOneWidget);
  });

  testWidgets("a fix's note stays while the terminal still needs that fix, then gives way to its status", (
    tester,
  ) async {
    final mac = _Mac([
      const TermStatus('kitty', 'kitty', TermState.setup, note: 'not let in', fix: TermFix.kittyConfig),
    ]);
    await pump(tester, mac);

    // The fix's note replaces the status's while kitty still needs the fix.
    await tester.runAsync(() => tester.tap(find.text('Set up')));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.text('not let in'), findsNothing);
    expect(find.textContaining('kitty.conf'), findsOneWidget);

    mac.now = [const TermStatus('kitty', 'kitty', TermState.setup, note: 'Restart kitty')];
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.textContaining('kitty.conf'), findsNothing);
    expect(find.text('Restart kitty'), findsOneWidget);
  });

  testWidgets('with Homebrew, tmux installs from the card: the command shown first, run only on Run', (tester) async {
    final brew = FakeCommands(brew: '/opt/homebrew/bin/brew')..result = (code: 1, output: 'Error: no network\n');
    final mac = _Mac([
      const TermStatus('ghostty', 'Ghostty', TermState.limited, note: 'no screen'),
      const TermStatus('tmux', 'tmux', TermState.missing),
    ]);
    await pump(tester, mac, commands: brew.commands, poll: const Duration(hours: 1));
    expect(find.textContaining('Ghostty doesn’t let other apps'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('command-tmux')));
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('command-shown'))).data, 'brew install tmux');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(brew.calls, isEmpty);

    // Run: it fails, and says what the command said.
    await tester.tap(find.byKey(const ValueKey('command-tmux')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('command-run')));
    await tester.pumpAndSettle();
    expect(brew.calls, ['/opt/homebrew/bin/brew install tmux']);
    expect(brew.envs.single['PATH'], startsWith('/opt/homebrew/bin:'));
    expect(find.textContaining('Error: no network'), findsOneWidget);

    // Try again: it works, and the card looks again and finds tmux.
    brew.result = (code: 0, output: '');
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    mac.now = [
      const TermStatus('ghostty', 'Ghostty', TermState.limited, note: 'no screen'),
      const TermStatus('tmux', 'tmux', TermState.ready),
    ];
    await tester.tap(find.byKey(const ValueKey('command-run')));
    await tester.pumpAndSettle();
    expect(brew.calls, hasLength(2));
    expect(find.byKey(const ValueKey('terminal-tmux')), findsOneWidget);
  });

  testWidgets('without Homebrew, where to get it, and Install tmux once it is there', (tester) async {
    final opened = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        if (call.method == 'launch') opened.add((call.arguments as Map)['url'] as String);
        return true;
      },
    );
    final mac = FakeCommands();
    await pump(tester, _Mac([const TermStatus('tmux', 'tmux', TermState.missing)]), commands: mac.commands);
    expect(find.byKey(const ValueKey('command-tmux')), findsNothing);
    expect(find.text('brew install tmux'), findsNothing, reason: 'no brew to type it in');
    await tester.tap(find.byKey(const ValueKey('tmux-get-homebrew')));
    await tester.pump();
    expect(opened, ['https://brew.sh']);

    // Homebrew installed meanwhile: the card's next look offers tmux.
    mac.brew = '/opt/homebrew/bin/brew';
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.byKey(const ValueKey('command-tmux')), findsOneWidget);
    expect(find.byKey(const ValueKey('tmux-get-homebrew')), findsNothing);
  });

  testWidgets('with MacPorts and no Homebrew, MacPorts’ line to type', (tester) async {
    await pump(
      tester,
      _Mac([const TermStatus('tmux', 'tmux', TermState.missing)]),
      commands: FakeCommands(macPorts: '/opt/local/bin/port').commands,
      poll: const Duration(hours: 1),
    );
    expect(tester.widget<CopyCommand>(find.byKey(const ValueKey('tmux-macports'))).command, 'sudo port install tmux');
    expect(find.byKey(const ValueKey('command-tmux')), findsNothing);
    expect(find.byKey(const ValueKey('tmux-get-homebrew')), findsNothing);
  });

  testWidgets('Ghostty with tmux: new windows in tmux in one click, said first, done after', (tester) async {
    final home = Directory.systemTemp.createTempSync('pocketterm-ghostty').path;
    addTearDown(() => Directory(home).deleteSync(recursive: true));
    final mac = _Mac(
      [
        const TermStatus('ghostty', 'Ghostty', TermState.limited, note: 'no screen'),
        const TermStatus('tmux', 'tmux', TermState.ready),
      ],
      home: home,
      tmux: Tmux(executable: '/opt/homebrew/bin/tmux', socketDirs: const []),
      ghostty: Ghostty(appPath: '$home/Ghostty.app'),
    );
    await pump(tester, mac, poll: const Duration(hours: 1));
    expect(find.text(ghosttyTmuxWhy), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ghostty-tmux')));
    await tester.pump();
    await tester.pump();
    expect(GhosttyConfig.standard(home: home).read().state, GhosttyCommandState.ours);
    expect(find.byKey(const ValueKey('ghostty-tmux-on')), findsOneWidget);
    expect(find.byKey(const ValueKey('ghostty-tmux')), findsNothing);
  });
}
