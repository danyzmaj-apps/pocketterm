import 'dart:io';

import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';

/// A Mac terminal's one-click fix ([TermStatus.fix]), as Settings and the
/// setup checklist offer it: kitty's lines added to kitty.conf, or System
/// Settings opened where Automation is allowed. Returns what to tell the
/// person next. WezTerm's install (Windows) is `WezTermSetup`'s.
Future<String> fixTerminal(Terminals terminals, TermStatus s) async {
  switch (s.fix) {
    case TermFix.kittyConfig:
      try {
        await terminals.kitty?.configure();
        return 'Added to kitty.conf (the old one is kitty.conf.pocketterm-backup). '
            'Quit and reopen kitty to let PocketTerm in.';
      } on Object catch (e) {
        return "Couldn't change kitty.conf: $e";
      }
    case TermFix.automation:
      await Process.run('/usr/bin/open', [
        'x-apple.systempreferences:com.apple.preference.security?Privacy_Automation',
      ]);
      return 'Turn on ${s.label} under PocketTerm, then come back here.';
    case TermFix.install || null:
      return '';
  }
}

/// The terminals the phone can't reach until the person acts: one that
/// needs setup or a permission, WezTerm not installed on Windows.
List<TermStatus> terminalsNeedingSetup(List<TermStatus> statuses) => [
  for (final s in statuses)
    if (s.state == TermState.setup || (s.fix == TermFix.install && s.state == TermState.missing)) s,
];

/// No terminal app the phone could use is installed (tmux alone isn't one);
/// WezTerm to install on Windows counts, [terminalsNeedingSetup] has it.
bool noTerminalApp(List<TermStatus> statuses) =>
    !statuses.any((s) => s.id != 'tmux' && (s.state != TermState.missing || s.fix == TermFix.install));
