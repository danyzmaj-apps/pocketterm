import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_desktop/live_hub.dart';

// The computer's orchestrator: an omp session PocketTerm starts in its own folder (beside cli.json,
// [LiveHub.orchestratorDir]) that the PocketTerm extension gives tools to see and steer the other sessions
// (integrations/omp/pocketterm-live.ts). Its calls come to the hub as `call` frames; this is what they answer.

/// The file in the orchestrator folder omp appends to its system prompt (`omp --append-system-prompt ORCHESTRATOR.md`).
const orchestratorPromptFile = 'ORCHESTRATOR.md';

/// What the orchestrator is told, beyond omp's own system prompt.
const orchestratorInstructions = '''
You are the PocketTerm orchestrator on this computer. The person talks to you from their phone, often in short typed or spoken messages, to find out about and steer the other coding sessions running here.

- Use pocketterm_sessions to see what is running, and pocketterm_read to look inside a session before saying anything about it. Never guess what a session is doing.
- Answer briefly, for a phone screen: the answer first, sessions named by project and title, not by key.
- Use pocketterm_prompt only when the person asks you to tell a session something or clearly agrees to it; when the wording isn't obvious, say what you will send. Use deliver "followUp" unless they want the session's current run redirected now.
- Use pocketterm_stop only when the person asks you to stop a session.
- You run in an empty folder. Don't edit files or run commands to answer questions about sessions: their transcripts are the source of truth.
''';

/// Whether a session in [cwd] is the orchestrator: [cwd] is [dir] (symlinks resolved; Windows ignores case).
bool isOrchestratorDir(String cwd, String? dir) {
  if (dir == null || cwd.isEmpty) return false;
  String real(String x) {
    try {
      return Directory(x).resolveSymbolicLinksSync();
    } on FileSystemException {
      return p.normalize(x);
    }
  }

  return p.equals(real(cwd), real(dir));
}

/// Makes [dir] and (re)writes its [orchestratorPromptFile] with [orchestratorInstructions].
Future<void> prepareOrchestratorDir(String dir) async {
  await Directory(dir).create(recursive: true);
  await File(p.join(dir, orchestratorPromptFile)).writeAsString(orchestratorInstructions);
}

/// How a call's answer names [s]: `<project> "<title>" (<key>)`.
String namedSession(LiveHub hub, LiveSession s) => '${_project(hub, s)} "${_title(s)}" (${s.key})';

String _project(LiveHub hub, LiveSession s) {
  final name = hub.projectName(s);
  return name.isNotEmpty ? name : (s.cwd.isNotEmpty ? s.cwd : '(no folder)');
}

String _title(LiveSession s) => s.title.isEmpty ? '(untitled)' : s.title;

String _state(LiveSession s) => switch (s) {
  LiveSession(ask: _?) => 'waiting for an answer',
  LiveSession(busy: true) => 'working',
  LiveSession(failed: true) => 'last run failed',
  _ => 'idle',
};

String _ago(DateTime at, DateTime now) {
  final d = now.difference(at);
  if (d.inMinutes < 1) return '${d.inSeconds.clamp(0, 59)}s ago';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

/// [s] cut to [max] characters, ending with `…` when cut.
String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

/// The `sessions` call's text: every session but the orchestrators.
String sessionsText(LiveHub hub, DateTime now) {
  int rank(LiveSession s) => s.ask != null ? 0 : (s.busy ? 1 : 2);
  final sessions = hub.sessions.where((s) => !s.orchestrator).toList()
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : b.at.compareTo(a.at);
    });
  if (sessions.isEmpty) return 'No other coding sessions are running on this computer.';
  final out = StringBuffer('${sessions.length} coding session${sessions.length == 1 ? '' : 's'} on this computer:');
  for (final s in sessions) {
    final summary = s.summary;
    final parts = [
      s.key,
      _project(hub, s),
      '"${_title(s)}"',
      [s.agent.label, if (s.model.isNotEmpty) s.model].join(' '),
      _state(s),
      if (s.ctx != null) 'ctx ${s.ctx}%',
      if (s.cost != null) '\$${s.cost!.toStringAsFixed(2)}',
      if (summary.queue.isNotEmpty) '${summary.queue.length} queued${summary.paused ? ', paused' : ''}',
      'active ${_ago(s.at, now)}',
    ];
    out.write('\n- ${parts.join(' | ')}');
    if (s.ask != null) out.write('\n  waiting on: ${s.ask!.text}');
    if (s.preview.isNotEmpty) out.write('\n  last answer: ${s.preview}');
  }
  return out.toString();
}

/// The most a `read` answer takes, in characters.
const _maxRead = 40000;

/// The `read` call's text: [s]'s newest [last] items (1..200).
String transcriptText(LiveHub hub, LiveSession s, {required int last}) {
  final header =
      'Session ${s.key} — ${_project(hub, s)} · "${_title(s)}" · '
      '${[s.agent.label, if (s.model.isNotEmpty) s.model].join(' ')} · ${_state(s)}';
  final items = s.log.items;
  final newest = items.sublist(items.length - last.clamp(1, 200).clamp(0, items.length));
  final blocks = <String>[];
  var size = 0;
  for (final i in newest.reversed) {
    final b = _block(i);
    if (size + b.length + 2 > _maxRead) break;
    size += b.length + 2;
    blocks.add(b);
  }
  final summary = s.summary;
  return [
    header,
    if (blocks.length < items.length || s.log.older) '(earlier items left out)',
    ...blocks.reversed,
    if (s.ask != null) 'Waiting on: ${s.ask!.text}',
    if (summary.queue.isNotEmpty) ...[
      'Queued prompts${summary.paused ? ' (paused)' : ''}:',
      for (final (n, q) in summary.queue.indexed) '${n + 1}. ${_clip(q.text, 300)}',
    ],
  ].join('\n\n');
}

String _block(LiveItem i) => switch (i.kind) {
  ItemKind.user => '[user] ${_clip(i.text, 2000)}${i.images > 0 ? ' (+${i.images} images)' : ''}',
  ItemKind.assistant => '[assistant] ${_clip(i.text, 6000)}',
  ItemKind.tool => [
    '[tool ${i.tool} ${i.status.name}] ${_clip((i.title.isNotEmpty ? i.title : i.args).replaceAll(RegExp(r'\s+'), ' ').trim(), 200)}',
    if (i.output.isNotEmpty) _tail(i.output),
  ].join('\n'),
  ItemKind.notice => '[notice] ${_clip(i.text, 500)}',
};

/// A tool's output as `read` shows it: its last 12 lines, at most their last 1200 characters, indented.
String _tail(String output) {
  final lines = output.trimRight().split('\n');
  var text = lines.sublist(lines.length > 12 ? lines.length - 12 : 0).join('\n');
  if (text.length > 1200) text = '…${text.substring(text.length - 1200)}';
  return text.split('\n').map((l) => '  $l').join('\n');
}
