import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketterm_core/ghostty_config.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/commands.dart';
import 'package:pocketterm_desktop/onboarding/commands_view.dart';
import 'package:pocketterm_desktop/terminal_fixes.dart';
import 'package:pocketterm_desktop/wezterm_setup.dart';

/// The setup checklist's terminals on a Mac (lib/onboarding/get_ready.dart):
/// the terminals found on it, each with its one-click fix where it needs one
/// (kitty's config, Automation), tmux when it's missing (installed with
/// Homebrew once the person confirms, or its line to type), and Ghostty's
/// new windows in tmux. Nothing to pick: new sessions open in the terminal
/// used last, as Settings' Auto does. Looks again every few seconds, so a
/// permission given in System Settings shows; [onStatuses] hears each look.
class MacTerminalsCard extends StatefulWidget {
  const MacTerminalsCard({
    required this.terminals,
    this.commands,
    this.poll = const Duration(seconds: 3),
    this.onStatuses,
    super.key,
  });
  final Terminals terminals;

  /// What installs tmux with Homebrew; without it, only its line to type.
  final Commands? commands;
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

  /// Ghostty's config (new windows in tmux), where Ghostty can be.
  late final GhosttyConfig? _ghosttyConfig = widget.terminals.ghostty == null
      ? null
      : GhosttyConfig.standard(home: widget.terminals.home);
  GhosttyCommand? _ghosttyCommand;
  String? _ghosttyError;

  static const tmuxCommand = 'brew install tmux';

  /// What tmux is and why Ghostty needs it.
  static const tmuxWhy =
      'tmux runs terminal sessions inside a window and lets other apps read and type into them. Ghostty doesn’t '
      'let other apps do that, so sessions in Ghostty run in tmux to give your phone full control.';

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
      _ghosttyCommand = _ghosttyConfig?.read();
      for (final t in s) {
        if (_fixed[t.id] case (final fix, _) when fix != t.fix) _fixed.remove(t.id);
      }
    });
    widget.onStatuses?.call(s);
  }

  /// New Ghostty windows open in tmux from now on.
  Future<void> _ghosttyTmux() async {
    final tmux = widget.terminals.tmux?.executable;
    if (tmux == null) return;
    try {
      _ghosttyConfig!.add(tmux);
      _ghosttyError = null;
    } on Object catch (e) {
      _ghosttyError = e is TerminalException ? e.message : '$e';
    }
    await _look();
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
          const SizedBox(height: 14),
          const Text('Recommended: tmux', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text(tmuxWhy, style: TextStyle(color: C.dim, height: 1.45, fontSize: 12.5)),
          const SizedBox(height: 8),
          if (widget.commands case final c? when c.brew != null) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: ConfirmedCommand(
                commands: c,
                label: 'Install tmux',
                argv: const ['brew', 'install', 'tmux'],
                what: 'Homebrew downloads and installs tmux, a free terminal tool. It takes a minute or two.',
                onDone: () => unawaited(_look()),
              ),
            ),
            const SizedBox(height: 8),
            const Text('Or type it in a terminal:', style: TextStyle(fontSize: 11.5, color: C.dim)),
            const SizedBox(height: 6),
          ],
          const CopyCommand(tmuxCommand),
        ] else if (tmux != null)
          _row(tmux),
        ..._ghosttyInTmux(found, tmux),
      ],
    );
  }

  /// Ghostty with tmux here: its new windows in tmux, one click, saying
  /// first what it changes.
  List<Widget> _ghosttyInTmux(List<TermStatus> found, TermStatus? tmux) {
    final command = _ghosttyCommand;
    if (command == null || tmux == null || tmux.state == TermState.missing) return const [];
    if (!found.any((s) => s.id == 'ghostty')) return const [];
    Widget note(String text) => Text(text, style: const TextStyle(color: C.dim, height: 1.45, fontSize: 12.5));
    return [
      const SizedBox(height: 14),
      switch (command.state) {
        GhosttyCommandState.ours => const Row(
          key: ValueKey('ghostty-tmux-on'),
          children: [
            Icon(Icons.check_circle, size: 18, color: C.ok),
            SizedBox(width: 10),
            Expanded(child: Text('New Ghostty windows open in tmux')),
          ],
        ),
        GhosttyCommandState.theirs => note(
          'Your Ghostty config already sets command = ${command.command}, so PocketTerm leaves it alone. Add tmux '
          'to that command yourself for full control.',
        ),
        GhosttyCommandState.none => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            note(
              'Ghostty doesn’t let other apps read or type into its windows; in tmux, your phone gets full '
              'control. PocketTerm adds two lines to Ghostty’s config, so each new Ghostty window opens in tmux. '
              'Settings → Terminals takes them out again.',
            ),
            OutlinedButton(
              key: const ValueKey('ghostty-tmux'),
              onPressed: () => unawaited(_ghosttyTmux()),
              child: const Text('Start new windows in tmux'),
            ),
            if (_ghosttyError case final e?) Text(e, style: const TextStyle(fontSize: 12, color: Color(0xFFFCA5A5))),
          ],
        ),
      },
    ];
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
              const CopyCommand(WezTermSetup.wingetCommand),
            ],
          ),
  );
}
