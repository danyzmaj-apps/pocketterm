import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/commands.dart';

/// A command as typed in a terminal.
const commandStyle = TextStyle(
  fontSize: 11.5,
  fontFamily: 'Menlo',
  fontFamilyFallback: ['Consolas', 'monospace'],
  height: 1.45,
);

/// A command to type, with a button that copies it (and says so: the
/// window has no snackbar).
class CopyCommand extends StatefulWidget {
  const CopyCommand(this.command, {super.key});
  final String command;

  @override
  State<CopyCommand> createState() => _CopyCommandState();
}

class _CopyCommandState extends State<CopyCommand> {
  bool _copied = false;

  @override
  void didUpdateWidget(CopyCommand old) {
    super.didUpdateWidget(old);
    if (old.command != widget.command) _copied = false;
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.only(left: 10),
    decoration: BoxDecoration(
      color: C.win,
      borderRadius: C.round(6),
      border: Border.all(color: C.line2, width: C.border),
    ),
    child: Row(
      children: [
        Expanded(child: SelectableText(widget.command, style: commandStyle)),
        IconButton(
          tooltip: _copied ? 'Copied' : 'Copy',
          iconSize: 14,
          visualDensity: VisualDensity.compact,
          color: _copied ? C.ok : C.dim,
          icon: Icon(_copied ? Icons.check : Icons.copy_outlined),
          onPressed: () {
            unawaited(Clipboard.setData(ClipboardData(text: widget.command)));
            setState(() => _copied = true);
          },
        ),
      ],
    ),
  );
}

enum _Run { idle, running, done, failed }

/// A button that runs [argv] for the person, after they read what it does
/// ([what]) and the command itself, and confirmed it: never on its own.
/// While it runs, it says so; then done, or what went wrong and Try again.
class ConfirmedCommand extends StatefulWidget {
  const ConfirmedCommand({
    required this.commands,
    required this.label,
    required this.argv,
    required this.what,
    this.password,
    this.onDone,
    super.key,
  });
  final Commands commands;

  /// The button's words: what it gets done ("Install tmux").
  final String label;
  final List<String> argv;

  /// What running it does, a sentence or two, shown before it runs.
  final String what;

  /// Why macOS may ask for the password, for a command that may need it.
  final String? password;

  /// It went through.
  final VoidCallback? onDone;

  @override
  State<ConfirmedCommand> createState() => _ConfirmedCommandState();
}

class _ConfirmedCommandState extends State<ConfirmedCommand> {
  _Run _state = _Run.idle;
  String _failure = '';

  String get _command => widget.argv.join(' ');

  Future<void> _confirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: C.bar,
        title: Text(widget.label),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(widget.what, style: TextStyle(color: C.dim, height: 1.45)),
              Text('PocketTerm will run:', style: TextStyle(fontSize: 12.5, color: C.dim)),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: C.win,
                  borderRadius: C.round(6),
                  border: Border.all(color: C.line2, width: C.border),
                ),
                child: SelectableText(_command, key: const ValueKey('command-shown'), style: commandStyle),
              ),
              if (widget.password != null)
                Text(
                  'macOS asks for your Mac password during the install.',
                  style: TextStyle(fontSize: 12, color: C.dim2),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('command-run'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Run'),
          ),
        ],
      ),
    );
    if (ok ?? false) await _runIt();
  }

  Future<void> _runIt() async {
    setState(() => _state = _Run.running);
    CommandResult result;
    try {
      result = await widget.commands.run(widget.argv, password: widget.password);
    } on Object catch (e) {
      result = (code: null, output: '$e');
    }
    if (!mounted) return;
    final ok = result.code == 0;
    setState(() {
      _state = ok ? _Run.done : _Run.failed;
      final lines = result.output.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
      final last = lines.skip(lines.length > 3 ? lines.length - 3 : 0).join('\n');
      _failure = last.isEmpty ? 'It stopped with code ${result.code}.' : last;
    });
    if (ok) widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) => switch (_state) {
    _Run.idle => _button(widget.label),
    _Run.running => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 8),
        Flexible(
          child: Text('Running $_command…', style: TextStyle(fontSize: 12, color: C.dim)),
        ),
      ],
    ),
    _Run.done => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check, size: 14, color: C.ok),
        const SizedBox(width: 6),
        Text(
          'Done',
          key: const ValueKey('command-done'),
          style: TextStyle(fontSize: 12, color: C.dim),
        ),
      ],
    ),
    _Run.failed => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Text(
          'That didn’t work:\n$_failure',
          key: const ValueKey('command-failed'),
          style: TextStyle(fontSize: 12, color: C.error, height: 1.4),
        ),
        _button('Try again'),
      ],
    ),
  };

  Widget _button(String label) => OutlinedButton(
    key: ValueKey('command-${widget.argv.last}'),
    onPressed: () => unawaited(_confirm()),
    style: OutlinedButton.styleFrom(
      foregroundColor: C.text,
      side: BorderSide(color: C.line2, width: C.border),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      visualDensity: VisualDensity.compact,
    ),
    child: Text(label, style: const TextStyle(fontSize: 12.5)),
  );
}
