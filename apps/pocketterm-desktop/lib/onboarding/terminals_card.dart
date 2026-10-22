import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/terminal_fixes.dart';
import 'package:pocketterm_desktop/wezterm_setup.dart';

/// The setup checklist's terminals on a Mac (lib/onboarding/get_ready.dart):
/// the terminals found on it, each with its one-click fix where it needs one
/// (kitty's config, Automation), and tmux's install line when it's missing.
/// Nothing to pick: new sessions open in the terminal used last, as
/// Settings' Auto does. Looks again every few seconds, so a permission given
/// in System Settings shows; [onStatuses] hears each look.
class MacTerminalsCard extends StatefulWidget {
  const MacTerminalsCard({required this.terminals, this.poll = const Duration(seconds: 3), this.onStatuses, super.key});
  final Terminals terminals;
  final Duration poll;
  final ValueChanged<List<TermStatus>>? onStatuses;

  @override
  State<MacTerminalsCard> createState() => _MacTerminalsCardState();
}

class _MacTerminalsCardState extends State<MacTerminalsCard> {
  List<TermStatus>? _statuses;

  /// What a fix told the person, by terminal, with the fix it was for: shown
  /// until a status no longer carries that fix (permission given, kitty.conf
  /// set), then the live status speaks.
  final _fixed = <String, (TermFix?, String)>{};
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
    if (!mounted) return;
    setState(() {
      _statuses = s;
      for (final t in s) {
        if (_fixed[t.id] case (final fix, _) when fix != t.fix) _fixed.remove(t.id);
      }
    });
    widget.onStatuses?.call(s);
  }

  Future<void> _fix(TermStatus s) async {
    final note = await fixTerminal(widget.terminals, s);
    if (!mounted) return;
    setState(() => _fixed[s.id] = (s.fix, note));
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
    return Column(
      key: const ValueKey('mac-terminals'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          found.isEmpty && all != null
              ? 'No terminal app found. PocketTerm works with kitty, Ghostty and WezTerm.'
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
            'Recommended: tmux. With it, sessions in Ghostty get full control from your phone.',
            style: TextStyle(color: C.dim, height: 1.45, fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          const CopyLine(tmuxCommand),
        ] else if (tmux != null)
          _row(tmux),
      ],
    );
  }

  Widget _row(TermStatus s) {
    final ok = s.state == TermState.ready || s.state == TermState.idle;
    final note = _fixed[s.id]?.$2 ?? (s.state == TermState.setup ? s.note : (ok ? 'Ready' : s.note));
    return Padding(
      key: ValueKey('terminal-${s.id}'),
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
              key: ValueKey('terminal-fix-${s.id}'),
              onPressed: () => unawaited(_fix(s)),
              child: Text(s.fix == TermFix.kittyConfig ? 'Set up' : 'Allow…'),
            ),
        ],
      ),
    );
  }
}

/// Windows: WezTerm, checked off when it's on the PC, else one button to
/// install it (its own installer, visible) and the winget line for those
/// who'd rather type it.
class WezTermCard extends StatelessWidget {
  const WezTermCard({required this.setup, super.key});
  final WezTermSetup setup;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: setup,
    builder: (context, _) => setup.installed
        ? const Row(
            key: ValueKey('wezterm-installed'),
            children: [
              Icon(Icons.check_circle, size: 18, color: C.ok),
              SizedBox(width: 10),
              Expanded(child: Text('WezTerm is installed: your phone can reach its windows.')),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'On Windows, PocketTerm works through WezTerm, a free terminal app. Sessions you start from '
                'your phone open in it, and its windows show on your phone. Windows Terminal and PowerShell '
                "windows don't.",
                style: TextStyle(color: C.dim, height: 1.45, fontSize: 13),
              ),
              const SizedBox(height: 12),
              FilledButton.tonal(
                key: const ValueKey('wezterm-install'),
                onPressed: setup.state == WezTermSetupState.missing ? () => unawaited(setup.install()) : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(switch (setup.state) {
                    WezTermSetupState.downloading => 'Downloading WezTerm…',
                    WezTermSetupState.installing => 'Finish in WezTerm\u2019s installer',
                    _ => 'Install WezTerm',
                  }),
                ),
              ),
              if (setup.state == WezTermSetupState.downloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: setup.progress, minHeight: 3),
              ],
              if (setup.note case final n? when setup.state != WezTermSetupState.downloading) ...[
                const SizedBox(height: 8),
                Text(
                  n,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: setup.error != null ? const Color(0xFFFCA5A5) : C.dim,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text('Or type this in PowerShell', style: TextStyle(fontSize: 11.5, color: C.dim)),
              const SizedBox(height: 6),
              const CopyLine(WezTermSetup.wingetCommand),
            ],
          ),
  );
}

/// A command to type, with a copy button.
class CopyLine extends StatelessWidget {
  const CopyLine(this.value, {super.key});
  final String value;

  @override
  Widget build(BuildContext context) => Container(
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
