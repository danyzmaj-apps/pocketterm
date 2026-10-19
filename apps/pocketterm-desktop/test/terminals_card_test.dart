import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_desktop/onboarding/terminals_card.dart';

/// A Mac whose terminals say [now].
class _Mac extends Terminals {
  _Mac(this.now)
    : super(home: '/nonexistent-pocketterm', recency: () async => const [], snapshot: () async => Procs(const []));
  List<TermStatus> now;

  @override
  Future<List<TermStatus>> statuses() async => now;
}

void main() {
  Future<void> pump(WidgetTester tester, Terminals t) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MacTerminalsCard(terminals: t, poll: const Duration(milliseconds: 100)),
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
      const TermStatus('iterm', 'iTerm2', TermState.missing),
      const TermStatus('terminal', 'Terminal', TermState.setup, note: 'allow', fix: TermFix.automation),
    ]);
    await pump(tester, mac);

    expect(find.byKey(const ValueKey('wizard-terminal-kitty')), findsOneWidget);
    expect(find.byKey(const ValueKey('wizard-terminal-terminal')), findsOneWidget);
    expect(find.byKey(const ValueKey('wizard-terminal-iterm')), findsNothing, reason: 'not installed');
    expect(find.text('Set up'), findsOneWidget);
    expect(find.text('Allow…'), findsOneWidget);
    expect(find.text('brew install tmux'), findsOneWidget);

    // Permission given and tmux installed meanwhile: the card catches up.
    mac.now = [
      const TermStatus('kitty', 'kitty', TermState.ready),
      const TermStatus('tmux', 'tmux', TermState.ready),
      const TermStatus('terminal', 'Terminal', TermState.limited, note: 'whole lines'),
    ];
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(find.text('Allow…'), findsNothing);
    expect(find.text('brew install tmux'), findsNothing);
    expect(find.byKey(const ValueKey('wizard-terminal-tmux')), findsOneWidget);
  });
}
