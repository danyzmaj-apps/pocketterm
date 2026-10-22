import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_desktop/prompt_files.dart';

/// One extension's connection, whatever carries it (lib/local_api.dart): a
/// WebSocket (omp) or HTTP long polls (Claude Code).
abstract interface class LiveLink {
  /// A JSON frame to the extension.
  void send(String frame);

  Future<void> close();
}

/// A WebSocket as a [LiveLink].
class SocketLink implements LiveLink {
  SocketLink(this._ws);
  final WebSocket _ws;

  @override
  void send(String frame) => _ws.add(frame);

  @override
  Future<void> close() => _ws.close();
}

/// Where a session runs (Terminals.locate): from the `term` its extension
/// reports, else (Ghostty) by its folder, its title as its [agent] shows it
/// in the window's, and the windows [claimed] by other sessions.
typedef Locate = Future<String?> Function(
  Map<String, dynamic>? term, {
  String cwd,
  String title,
  Agent agent,
  Set<String> claimed,
});

/// One coding session, as its agent's extension reports it (integrations/:
/// omp's pocketterm-live.ts, the Claude Code plugin).
class LiveSession {
  LiveSession._(this._link, this.key, this.log);

  final LiveLink _link;

  /// The terminal window it runs in (lib/terminal.dart's keys:
  /// `kitty-<pid>/<id>`, `tmux:default/3` …), or `pid:<pid>`; a window
  /// found after it said hello ([LiveHub.relink]) is [window] only.
  final String key;
  LiveLog log;
  Agent agent = Agent.omp;
  String? window;

  /// What its extension said of its terminal, to find [window] again.
  Map<String, dynamic>? _term;
  String id = '';
  String title = '';
  String cwd = '';
  String model = '';
  bool busy = false;
  LiveAsk? ask;
  int? ctx;
  String preview = '';
  List<LiveCommand> commands = const [];
  DateTime at = DateTime.now();

  int _req = 0;
  final _pending = <int, Completer<Map<String, dynamic>>>{};

  LiveSummary get summary => LiveSummary(
    key: key,
    id: id,
    agent: agent,
    window: window,
    title: title,
    cwd: cwd,
    model: model,
    busy: busy,
    ask: ask,
    ctx: ctx,
    preview: preview,
    at: at,
    epoch: log.epoch,
    seq: log.seq,
    older: log.older,
    commands: commands,
  );

  Future<Map<String, dynamic>> _request(String type, Map<String, dynamic> payload, Duration timeout) async {
    final req = ++_req;
    final done = _pending[req] = Completer();
    _link.send(jsonEncode({'t': type, 'req': req, ...payload}));
    try {
      final reply = await done.future.timeout(timeout);
      final error = reply['error'] as String?;
      if (error != null) throw LiveException(error);
      return reply;
    } on TimeoutException {
      throw LiveException('${agent.label} did not answer.');
    } finally {
      _pending.remove(req);
    }
  }

  void _fail() {
    for (final c in _pending.values) {
      c.completeError(LiveException('The ${agent.label} session ended.'));
    }
    _pending.clear();
  }
}

class LiveException implements Exception {
  const LiveException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Something worth a notification.
sealed class LiveEvent {
  const LiveEvent(this.session);
  final LiveSession session;
}

/// The agent stopped and isn't about to go on by itself.
class LiveFinished extends LiveEvent {
  const LiveFinished(super.session, this.summary);
  final String summary;
}

/// The agent asks a question, wants a tool approved, or has a plan for review.
class LiveAsked extends LiveEvent {
  const LiveAsked(super.session, this.ask);
  final LiveAsk ask;
}

/// The coding sessions on this computer: their extensions connect to the local
/// API (lib/local_api.dart) and keep it up to date; the terminal bridge
/// passes them on to the phone.
class LiveHub {
  /// [locate]: where a session runs (Terminals.locate); [windowOfTerm] by
  /// default. [files]: where files sent with prompts go.
  LiveHub({Locate? locate, PromptFiles? files}) : _locate = locate ?? _byTerm, _files = files ?? PromptFiles() {
    unawaited(_files.prune());
  }

  static Future<String?> _byTerm(
    Map<String, dynamic>? term, {
    String cwd = '',
    String title = '',
    Agent agent = Agent.omp,
    Set<String> claimed = const {},
  }) async => windowOfTerm(term);

  final Locate _locate;
  final PromptFiles _files;
  final _byKey = <String, LiveSession>{};

  /// Transcript changes, per session.
  Stream<(LiveSession, List<LiveOp>)> get ops => _ops.stream;
  final _ops = StreamController<(LiveSession, List<LiveOp>)>.broadcast(sync: true);

  /// A session came, went, or its summary changed.
  Stream<void> get changes => _changes.stream;
  final _changes = StreamController<void>.broadcast(sync: true);

  Stream<LiveEvent> get events => _events.stream;
  final _events = StreamController<LiveEvent>.broadcast();

  Iterable<LiveSession> get sessions => _byKey.values;
  LiveSession? operator [](String key) => _byKey[key];

  /// What notifications call [s]'s project: its folder's name, with the one
  /// above it when another session's folder has the same name (two
  /// checkouts called `api`); empty when its folder isn't known.
  String projectName(LiveSession s) {
    List<String> parts(String cwd) => cwd.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    final mine = parts(s.cwd);
    if (mine.isEmpty) return s.cwd == '/' ? '/' : '';
    final clash = _byKey.values.any((o) => !identical(o, s) && o.cwd != s.cwd && parts(o.cwd).lastOrNull == mine.last);
    return clash && mine.length > 1 ? '${mine[mine.length - 2]}/${mine.last}' : mine.last;
  }

  /// Serves one extension, whose JSON [frames] come in order over [link],
  /// until they end. A frame this side can't read (an extension older or
  /// newer than the app, with fields missing or of another shape) is
  /// skipped; the session goes on.
  Future<void> accept(Stream<String> frames, LiveLink link) async {
    LiveSession? session;
    try {
      await for (final frame in frames) {
        try {
          final m = jsonDecode(frame);
          if (m is! Map<String, dynamic>) continue;
          if (m['t'] == 'hello') {
            session = await _hello(link, session, m);
          } else if (session != null && identical(_byKey[session.key], session)) {
            _handle(session, m);
          }
        } on Object catch (e) {
          debugPrint('PocketTerm: live session: a frame skipped: $e');
        }
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: live session: $e');
    } finally {
      if (session != null) {
        session._fail();
        if (identical(_byKey[session.key], session)) {
          _byKey.remove(session.key);
          _changes.add(null);
        }
      }
    }
  }

  /// The session's key is the window it runs in: where its `term` says
  /// (an older extension reports only kitty's, as `window`), else its pid.
  /// A `term` that names no window is trusted over `window`, which an
  /// extension also reads from KITTY_* variables leaked from a kitty that
  /// started the terminal (they'd name a window of that kitty). The same
  /// agent saying hello again stays where it is, under the same key.
  Future<LiveSession> _hello(LiveLink link, LiveSession? current, Map<String, dynamic> m) async {
    final s = (m['session'] as Map?)?.cast<String, dynamic>() ?? const {};
    final term = (m['term'] as Map?)?.cast<String, dynamic>();
    final agent = Agent.parse(m['agent']);
    final cwd = s['cwd'] as String? ?? '';
    final title = s['title'] as String? ?? '';
    String? window;
    try {
      window = await _locate(term, cwd: cwd, title: title, agent: agent, claimed: _claimed(current));
    } on Object catch (e) {
      debugPrint('PocketTerm: where a live session runs: $e');
    }
    if (term == null) window ??= m['window'] as String?;
    final same = current != null && identical(_byKey[current.key], current) ? current : null;
    window ??= same?.window;
    final key = same != null && same.window == window ? same.key : window ?? 'pid:${m['pid']}';
    final log = LiveLog([
      for (final i in m['items'] as List? ?? const [])
        if (i is Map && i['id'] is String) LiveItem.fromJson(i.cast()),
    ], older: m['older'] == true);
    final LiveSession session;
    if (current != null && current.key == key && identical(_byKey[key], current)) {
      // Another session in the same agent (/new, /resume, /clear): a new transcript.
      session = current..log = log;
    } else {
      if (current != null && identical(_byKey[current.key], current)) _byKey.remove(current.key);
      session = LiveSession._(link, key, log);
      // The same window's previous agent, if its connection hasn't closed yet.
      final old = _byKey[key];
      if (old != null && !identical(old._link, link)) unawaited(old._link.close());
      _byKey[key] = session;
    }
    session
      ..agent = agent
      ..window = window
      .._term = term
      ..id = s['id'] as String? ?? ''
      ..title = title
      ..cwd = cwd
      ..model = s['model'] as String? ?? ''
      ..busy = m['busy'] == true
      ..ctx = (m['ctx'] as num?)?.round()
      ..ask = null
      ..commands = liveCommands(m['commands'])
      ..preview = _preview(log.items.lastWhere((i) => i.kind == ItemKind.assistant, orElse: () => _none).text)
      ..at = DateTime.now();
    _changes.add(null);
    // A window claimed can leave another session the one window left.
    if (window != null) _relinkSoon();
    return session;
  }

  /// The windows the sessions other than [except] run in.
  Set<String> _claimed(LiveSession? except) => {
    for (final s in _byKey.values)
      if (!identical(s, except)) ?s.window,
  };

  bool _relinking = false;
  bool _relinkAgain = false;

  /// Looks again for the window of each session that has none, by what
  /// changed since its hello: a Ghostty window is told apart by its title
  /// (a session gets one after its first prompt) and by the windows other
  /// sessions run in. A window found becomes the session's
  /// [LiveSession.window]; its key stays the one the phone knows.
  Future<void> relink() async {
    if (_relinking) {
      _relinkAgain = true;
      return;
    }
    _relinking = true;
    try {
      var found = false;
      do {
        _relinkAgain = false;
        found = false;
        for (final s in [..._byKey.values]) {
          if (s.window != null || s._term == null) continue;
          String? window;
          try {
            window = await _locate(s._term, cwd: s.cwd, title: s.title, agent: s.agent, claimed: _claimed(s));
          } on Object catch (e) {
            debugPrint('PocketTerm: where a live session runs: $e');
          }
          // Gone, placed or beaten to it meanwhile.
          if (window == null || s.window != null || !identical(_byKey[s.key], s) || _claimed(s).contains(window)) {
            continue;
          }
          s.window = window;
          found = true;
          _changes.add(null);
        }
        // A window claimed can leave another session the one window left.
      } while (found || _relinkAgain);
    } finally {
      _relinking = false;
    }
  }

  void _relinkSoon() {
    if (_byKey.values.any((s) => s.window == null && s._term != null)) unawaited(relink());
  }

  static final _none = LiveItem(id: '', kind: ItemKind.notice);

  static String _preview(String text) {
    final line = text
        .split('\n')
        .map((l) => l.replaceAll(RegExp('[`*_#>]'), '').trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return line.length > 140 ? '${line.substring(0, 139)}…' : line;
  }

  void _handle(LiveSession s, Map<String, dynamic> m) {
    switch (m['t']) {
      case 'item':
        final item = LiveItem.fromJson((m['item'] as Map).cast());
        s.at = DateTime.now();
        _ops.add((s, [s.log.upsert(item)]));
        if (item.kind == ItemKind.assistant && item.text.isNotEmpty) {
          final preview = _preview(item.text);
          if (preview != s.preview) {
            s.preview = preview;
            _changes.add(null);
          }
        }
      case 'append':
        final op = s.log.append(m['id'] as String, m['text'] as String? ?? '');
        if (op != null) _ops.add((s, [op]));
      case 'busy':
        final busy = m['busy'] == true;
        s
          ..busy = busy
          ..at = DateTime.now();
        _changes.add(null);
        final summary = m['summary'] as String?;
        if (!busy && summary != null) _events.add(LiveFinished(s, summary));
      case 'ask':
        final ask = m['ask'] is Map ? LiveAsk.fromJson((m['ask'] as Map).cast()) : null;
        s.ask = ask;
        _changes.add(null);
        if (ask != null) _events.add(LiveAsked(s, ask));
      case 'meta':
        if (m['title'] is String && m['title'] != s.title) {
          s.title = m['title'] as String;
          if (s.window == null) _relinkSoon();
        }
        if (m['model'] is String) s.model = m['model'] as String;
        if (m.containsKey('ctx')) s.ctx = (m['ctx'] as num?)?.round();
        if (m['commands'] is List) s.commands = liveCommands(m['commands']);
        _changes.add(null);
      case 'reply':
        s._pending[m['req']]?.complete(m);
    }
  }

  LiveSession _session(String key) {
    final s = _byKey[key];
    if (s == null) throw const LiveException('That session has ended.');
    return s;
  }

  /// Replaces session [key]'s ask, while it's still [id] (null: while there
  /// is none), with what this computer read off its screen: a plan review's
  /// options, a picker a slash command opened, or null once it's gone. Not
  /// the agent asking, so no event. False when the session's ask has moved
  /// on.
  bool updateAsk(String key, String? id, LiveAsk? ask) {
    final s = _byKey[key];
    if (s == null || s.ask?.id != id) return false;
    s.ask = ask;
    _changes.add(null);
    return true;
  }

  /// Where images for an agent that reads them from disk (Claude Code) wait
  /// for it; the ones older than a day go when more come.
  static final _imageDir = Directory(p.join(Directory.systemTemp.path, 'pocketterm-images'));

  /// Sends [text] (and [images] and [files]) as the person's prompt. While
  /// omp works it steers the run, or waits for the run to end with
  /// [followUp]; Claude Code always waits, and gets the images as files.
  /// [files] are saved on this computer ([PromptFiles]) and named in the
  /// text as `@path`, as one would at the computer: omp reads them in when
  /// it isn't working, else the agent opens them; Claude Code's extension
  /// lets it read them without asking.
  Future<void> prompt(
    String key,
    String text, {
    List<({Uint8List bytes, String mimeType})> images = const [],
    List<PromptFile> files = const [],
    bool followUp = false,
  }) async {
    final s = _session(key);
    final steers = s.agent.steers;
    final saved = await _files.save(files);
    await s._request('prompt', {
      'text': withMentions(text, saved),
      'images': [
        if (steers)
          for (final i in images) {'data': base64Encode(i.bytes), 'mimeType': i.mimeType},
      ],
      if (!steers) 'files': await _saveImages(images),
      if (!steers && saved.isNotEmpty) 'docs': saved,
      'deliver': followUp || !steers ? 'followUp' : 'steer',
    }, const Duration(seconds: 15));
  }

  static Future<List<String>> _saveImages(List<({Uint8List bytes, String mimeType})> images) async {
    if (images.isEmpty) return const [];
    final dir = _imageDir;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      // Private to this user; Windows' per-user temp folder already is.
      if (!Platform.isWindows) await Process.run('chmod', ['700', dir.path]);
    }
    final dayAgo = DateTime.now().subtract(const Duration(days: 1));
    for (final f in dir.listSync().whereType<File>()) {
      if (f.statSync().modified.isBefore(dayAgo)) f.deleteSync();
    }
    final random = Random.secure();
    return [
      for (final i in images)
        (File(
          p.join(
            dir.path,
            '${List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join()}'
            '.${i.mimeType == 'image/jpeg' ? 'jpg' : 'png'}',
          ),
        )..writeAsBytesSync(i.bytes)).path,
    ];
  }

  /// Esc: stops what the agent is doing.
  Future<void> abort(String key) => _session(key)._request('abort', const {}, const Duration(seconds: 5));

  /// Fetches the items before the oldest one the hub has; they go out as ops.
  Future<void> older(String key, {int limit = 150}) async {
    final s = _session(key);
    if (!s.log.older) return;
    final log = s.log;
    final reply = await s._request('older', {'limit': limit}, const Duration(seconds: 10));
    // Another session started meanwhile: these belong to the old one.
    if (!identical(s.log, log)) return;
    final items = [for (final i in reply['items'] as List? ?? const []) LiveItem.fromJson((i as Map).cast())];
    final ops = log.addOlder(items, more: reply['older'] == true);
    if (ops.isNotEmpty) _ops.add((s, ops));
    _changes.add(null);
  }
}
