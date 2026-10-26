import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/onboarding/commands_view.dart';

/// Asks before something is installed on this computer: [title], why it's
/// needed ([why]), what it changes ([what], with [command] shown as typed
/// when there is one) and how to take it out again ([undo]). True once the
/// person pressed [action]; nothing is installed without it.
Future<bool> confirmInstall(
  BuildContext context, {
  required String title,
  required String why,
  required String what,
  String? command,
  String? undo,
  String action = 'Install',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      key: const ValueKey('confirm-install'),
      backgroundColor: C.bar,
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Text(why, style: TextStyle(color: C.text, height: 1.45)),
            Text(what, style: TextStyle(color: C.dim, height: 1.45)),
            if (command != null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: C.win,
                  borderRadius: C.round(6),
                  border: Border.all(color: C.line2, width: C.border),
                ),
                child: SelectableText(command, style: commandStyle),
              ),
            if (undo != null) Text(undo, style: TextStyle(fontSize: 12, color: C.dim2, height: 1.4)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: const Text('Not now')),
        FilledButton(
          key: const ValueKey('confirm-install-go'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// [confirmInstall] for PocketTerm going into [agent] ([update]: replacing
/// an older copy there), with where [integrations] puts it shown below
/// [home] as `~`.
Future<bool> confirmAgentInstall(
  BuildContext context,
  Agent agent,
  Integrations integrations, {
  required String home,
  bool update = false,
}) {
  final name = Integrations.name(agent);
  String tilde(String dir) => p.isWithin(home, dir) ? '~/${p.relative(dir, from: home).replaceAll(r'\', '/')}' : dir;
  final verb = update ? 'Update' : 'Install';
  return confirmInstall(
    context,
    title: '$verb PocketTerm in $name?',
    action: verb,
    why: update
        ? 'The copy of PocketTerm in $name is older than this app. Updating it keeps your phone working with '
              'your $name sessions.'
        : 'So your phone sees your $name sessions as conversations, not just their screen: read the replies, '
              'answer questions and approvals, and get a notification when a run finishes. Without it, $name '
              'windows show on your phone only as a screen.',
    what: switch (agent) {
      Agent.omp =>
        '${update ? 'Replaces' : 'Copies'} PocketTerm\u2019s omp extension (pocketterm-live.ts) '
            '${update ? 'in' : 'into'} ${tilde(integrations.ompDir)}. Open omp sessions load it once you restart '
            'them with ${agent.resume}.',
      Agent.claude =>
        '${update ? 'Replaces' : 'Copies'} PocketTerm\u2019s Claude Code plugin '
            '${update ? 'in' : 'to'} ${tilde(integrations.claudeDir)} and has Claude Code '
            '${update ? 'update' : 'install'} it. Open Claude Code sessions load it when you type '
            '${agent.pickUp}.',
    },
    command: switch (agent) {
      Agent.omp => null,
      Agent.claude =>
        update
            ? 'claude plugin marketplace update pocketterm\nclaude plugin update pocketterm@pocketterm'
            : 'claude plugin marketplace add ${tilde(integrations.claudeDir)}\n'
                  'claude plugin install pocketterm@pocketterm',
    },
    undo: switch (agent) {
      Agent.omp => 'To take it out later, delete pocketterm-live.ts from that folder.',
      Agent.claude => 'To take it out later, run claude plugin uninstall pocketterm@pocketterm.',
    },
  );
}
