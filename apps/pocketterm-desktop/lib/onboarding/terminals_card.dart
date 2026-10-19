import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/terminal_fixes.dart';

/// The setup wizard's last step on a Mac: the terminals found on it, each
/// with its one-click fix where it needs one (kitty's config, Automation),
/// and tmux's install line when it's missing. Nothing to pick: new sessions
/// open in the terminal used last, as Settings' Auto does. Looks again
/// every few seconds, so a permission given in System Settings shows.
class MacTerminalsCard extends StatefulWidget {
  const MacTerminalsCard({required this.terminals, this.poll = const Duration(seconds: 3), super.key});
  final Terminals terminals;
  final Duration poll;

  @override
  State<MacTerminalsCard> createState() => _MacTerminalsCardState();
}

class _MacTerminalsCardState extends State<MacTerminalsCard> {
  List<TermStatus>? _statuses;
  final _fixed = <String, String>{};
  Timer? _timer;

  static const tmuxCommand = 'brew install tmux';

  @override
  void initState() {
    super.initState();
    unawaited(_look());
    _timer = Timer.periodic(widget.poll, (_) => unawaited(_look()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _look() async {
    final s = await widget.terminals.statuses();
    if (mounted) setState(() => _statuses = s);
  }

  Future<void> _fix(TermStatus s) async {
    final note = await fixTerminal(widget.terminals, s);
    if (!mounted) return;
    setState(() => _fixed[s.id] = note);
    await _look();
  }

  @override
  Widget build(BuildContext context) {
    final all = _statuses;
    final found = [
      for (final s in all ?? const <TermStatus>[])
        if (s.state != TermState.missing && s.id != 'tmux') s,
    ];
    final tmux = all?.where((s) => s.id == 'tmux').firstOrNull;
    return Container(
      key: const ValueKey('wizard-terminals'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: C.line2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Your terminals', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            found.isEmpty && all != null
                ? 'No terminal app found. PocketTerm works with kitty, iTerm2, WezTerm, Ghostty and macOS\u2019s Terminal.'
                : 'Sessions you start from your phone open in the one you used last (Settings can pin one).',
            style: const TextStyle(color: C.dim, height: 1.45, fontSize: 13),
          ),
          if (all == null)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          for (final s in found) _row(s),
          if (tmux != null && tmux.state == TermState.missing) ...[
            const SizedBox(height: 12),
            const Text(
              'Recommended: tmux. With it, sessions in Terminal and Ghostty get full control from your phone.',
              style: TextStyle(color: C.dim, height: 1.45, fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            _copy(tmuxCommand),
          ] else if (tmux != null)
            _row(tmux),
        ],
      ),
    );
  }

  Widget _row(TermStatus s) {
    final ok = s.state == TermState.ready || s.state == TermState.idle;
    final note = _fixed[s.id] ?? (s.state == TermState.setup ? s.note : (ok ? 'Ready' : s.note));
    return Padding(
      key: ValueKey('wizard-terminal-${s.id}'),
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : (s.state == TermState.setup ? Icons.error_outline : Icons.remove_circle_outline),
            size: 18,
            color: ok ? C.ok : (s.state == TermState.setup ? C.warn : C.dim),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.label),
                if (note.isNotEmpty) Text(note, style: const TextStyle(fontSize: 11.5, color: C.dim, height: 1.35)),
              ],
            ),
          ),
          if (s.fix case TermFix.kittyConfig || TermFix.automation
              when _fixed[s.id] == null || s.fix == TermFix.automation)
            TextButton(
              key: ValueKey('wizard-terminal-fix-${s.id}'),
              onPressed: () => unawaited(_fix(s)),
              child: Text(s.fix == TermFix.kittyConfig ? 'Set up' : 'Allow…'),
            ),
        ],
      ),
    );
  }

  Widget _copy(String value) => Container(
    padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
    decoration: BoxDecoration(
      color: C.win,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: C.line2),
    ),
    child: Row(
      children: [
        Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 13))),
        IconButton(
          tooltip: 'Copy',
          iconSize: 16,
          color: C.dim,
          icon: const Icon(Icons.copy_outlined),
          onPressed: () {
            unawaited(Clipboard.setData(ClipboardData(text: value)));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied')));
          },
        ),
      ],
    ),
  );
}
