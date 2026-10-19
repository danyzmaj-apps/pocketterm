import 'dart:io';

import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';

/// A Mac terminal's one-click fix ([TermStatus.fix]), as Settings and the
/// setup wizard offer it: kitty's lines added to kitty.conf, or System
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
