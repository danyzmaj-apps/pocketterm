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
import 'package:pocketterm_desktop/orchestrator.dart';
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

  /// Its last run ended in an error ([LiveSummary.failed]); a new run clears it.
  bool failed = false;
  LiveAsk? ask;
  int? ctx;

  /// What the session has cost so far, in US dollars ([LiveSummary.cost]).
  double? cost;
  String preview = '';
  List<LiveCommand> commands = const [];
  DateTime at = DateTime.now();

  /// Prompts waiting for a run to end, next first ([LiveHub.prompt]); [paused] holds them.
  final _queue = <_Queued>[];
  bool paused = false;

  /// Its folder is the orchestrator folder ([LiveHub.orchestratorDir]): it may make calls.
  bool orchestrator = false;

  /// The queue's next prompt went to the agent, which hasn't said yet that it started; [_handoff] gives up on that.
  bool _handing = false;
  Timer? _handoff;

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
    cost: cost,
    preview: preview,
    at: at,
    epoch: log.epoch,
    seq: log.seq,
    older: log.older,
    commands: commands,
    queue: [for (final q in _queue) q.summary],
    paused: paused,
    failed: failed,
    orchestrator: orchestrator,
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

/// A prompt in a session's queue, as it will go to the agent.
class _Queued {
  _Queued(this.id, this.text, {required this.images, required this.imageFiles, required this.docs});

  final String id;

  /// What the person typed; [docs] are named after it as `@path` when it goes.
  String text;

  /// For an agent that steers (omp): the images themselves; else saved on this computer for it to read.
  final List<Map<String, String>> images;
  final List<String> imageFiles;

  /// The files sent with it, saved on this computer ([PromptFiles]).
  final List<String> docs;

  bool get empty => text.trim().isEmpty && images.isEmpty && imageFiles.isEmpty && docs.isEmpty;

  LiveQueued get summary => LiveQueued(
    id: id,
    text: text,
    images: images.length + imageFiles.length,
    files: [for (final d in docs) p.basename(d)],
  );
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
  /// default. [files]: where files sent with prompts go; [images]: where
  /// images for an agent that reads them from disk go. The ones older than
  /// a day go now, and when more come.
  LiveHub({Locate? locate, PromptFiles? files, Directory? images})
    : _locate = locate ?? _byTerm,
      _files = files ?? PromptFiles(),
      _imageDir = images ?? Directory(p.join(Directory.systemTemp.path, 'pocketterm-images')) {
    unawaited(_files.prune());
    _pruneImages();
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

  /// PocketTerm's orchestrator folder, next to cli.json; set by LocalApi. Null: no orchestrator.
  String? orchestratorDir;

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
        session
          .._fail()
          .._handoff?.cancel();
        if (identical(_byKey[session.key], session)) {
          _byKey.remove(session.key);
          _keepQueue(session);
          _changes.add(null);
        }
      }
    }
  }

  /// Sessions gone with prompts in their queue, by key: the same agent saying hello again in the same window soon
  /// (restarted, reconnected) takes them over.
  final _orphans = <String, (LiveSession, Timer)>{};
  static const _orphanFor = Duration(minutes: 10);

  void _keepQueue(LiveSession s) {
    if (s._queue.isEmpty && !s._handing) return;
    _orphans.remove(s.key)?.$2.cancel();
    _orphans[s.key] = (s, Timer(_orphanFor, () => _orphans.remove(s.key)));
  }

  /// [to] takes over [from]'s queue, when they're the same agent.
  static void _takeQueue(LiveSession to, LiveSession? from) {
    if (from == null || identical(from, to) || from.agent != to.agent || from._queue.isEmpty) return;
    to._queue.addAll(from._queue);
    to.paused = from.paused;
    from._queue.clear();
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
      final moved = current != null && identical(_byKey[current.key], current) ? current : null;
      if (moved != null) _byKey.remove(moved.key);
      session = LiveSession._(link, key, log)..agent = agent;
      // The same window's previous agent, if its connection hasn't closed yet.
      final old = _byKey[key];
      if (old != null && !identical(old._link, link)) unawaited(old._link.close());
      _byKey[key] = session;
      final orphan = _orphans.remove(key);
      orphan?.$2.cancel();
      _takeQueue(session, moved);
      _takeQueue(session, old);
      _takeQueue(session, orphan?.$1);
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
      ..failed = false
      .._handing = false
      ..ctx = (m['ctx'] as num?)?.round()
      ..cost = (m['cost'] as num?)?.toDouble()
      ..ask = null
      ..commands = liveCommands(m['commands'])
      ..preview = _preview(log.items.lastWhere((i) => i.kind == ItemKind.assistant, orElse: () => _none).text)
      ..at = DateTime.now()
      ..orchestrator = isOrchestratorDir(cwd, orchestratorDir);
    session._handoff?.cancel();
    _changes.add(null);
    _drain(session);
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
          .._handing = false
          .._handoff?.cancel()
          ..busy = busy
          ..failed = !busy && m['failed'] == true
          ..at = DateTime.now();
        // Stopped (Stop from the phone, Esc at the computer): what waits stays until Resume.
        if (!busy && m['stopped'] == true && s._queue.isNotEmpty) s.paused = true;
        // The queue's next prompt goes now: the agent goes on, so nothing finished.
        if (_drainable(s)) return _drain(s);
        _changes.add(null);
        final summary = m['summary'] as String?;
        if (!busy && summary != null) _events.add(LiveFinished(s, summary));
      case 'ask':
        final ask = m['ask'] is Map ? LiveAsk.fromJson((m['ask'] as Map).cast()) : null;
        s.ask = ask;
        _changes.add(null);
        if (ask != null) _events.add(LiveAsked(s, ask));
        _drain(s);
      case 'meta':
        if (m['title'] is String && m['title'] != s.title) {
          s.title = m['title'] as String;
          if (s.window == null) _relinkSoon();
        }
        if (m['model'] is String) s.model = m['model'] as String;
        if (m.containsKey('ctx')) s.ctx = (m['ctx'] as num?)?.round();
        if (m.containsKey('cost')) s.cost = (m['cost'] as num?)?.toDouble();
        if (m['commands'] is List) s.commands = liveCommands(m['commands']);
        _changes.add(null);
      case 'reply':
        s._pending[m['req']]?.complete(m);
      case 'call':
        unawaited(_call(s, m));
    }
  }

  LiveSession _session(String key) {
    final s = _byKey[key];
    if (s == null) throw const LiveException('That session has ended.');
    return s;
  }

  /// Answers a call of the orchestrator's tools ([LiveSession.orchestrator] only): a `result` with the text for its
  /// model, or the error.
  Future<void> _call(LiveSession s, Map<String, dynamic> m) async {
    final id = m['id'];
    String? text;
    String? error;
    try {
      if (!s.orchestrator) throw const LiveException('Only the PocketTerm orchestrator can do that.');
      switch (m['op']) {
        case 'sessions':
          text = sessionsText(this, DateTime.now());
        case 'read':
          text = transcriptText(this, _target(m), last: (m['last'] as num?)?.toInt() ?? 30);
        case 'prompt':
          final words = (m['text'] as String? ?? '').trim();
          if (words.isEmpty) throw const LiveException('Nothing to send.');
          if (words.startsWith('/')) throw const LiveException("Slash commands can't be sent from the orchestrator.");
          final t = _target(m);
          final queued = await prompt(t.key, words, followUp: m['deliver'] != 'steer');
          text = queued == null
              ? 'Sent to ${namedSession(this, t)}.'
              : 'Queued in ${namedSession(this, t)}: it goes when its current run ends.';
        case 'stop':
          final t = _target(m);
          await abort(t.key);
          final n = t._queue.length;
          text =
              'Stopped ${namedSession(this, t)}.'
              '${n == 0 ? '' : ' Its $n queued prompt${n == 1 ? '' : 's'} wait${n == 1 ? 's' : ''} until the person resumes them.'}';
        default:
          throw const LiveException('Unknown call.');
      }
    } on LiveException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = '$e';
    }
    if (!identical(_byKey[s.key], s)) return;
    s._link.send(jsonEncode({'t': 'result', 'id': id, 'text': ?text, 'error': ?error}));
  }

  /// The session a call names: not gone, not the orchestrator itself.
  LiveSession _target(Map<String, dynamic> m) {
    final t = _session(m['session'] as String? ?? '');
    if (t.orchestrator) throw const LiveException('That is the orchestrator itself.');
    return t;
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
    _drain(s);
    return true;
  }

  /// Where images for an agent that reads them from disk (Claude Code) wait
  /// for it (`pocketterm-images` in the temp folder by default).
  final Directory _imageDir;

  /// Sends [text] (and [images] and [files]) as the person's prompt. While
  /// omp works it steers the run, or waits for the run to end with
  /// [followUp]; Claude Code always waits, and gets the images as files.
  /// [files] are saved on this computer ([PromptFiles]) and named in the
  /// text as `@path`, as one would at the computer: omp reads them in when
  /// it isn't working, else the agent opens them; Claude Code's extension
  /// lets it read them without asking.
  ///
  /// One that waits goes to the session's queue, under [id] (a new one by
  /// default), which it returns; it goes to the agent when a run ends, next
  /// in line. Null when it went to the agent now.
  Future<String?> prompt(
    String key,
    String text, {
    List<({Uint8List bytes, String mimeType})> images = const [],
    List<PromptFile> files = const [],
    bool followUp = false,
    String? id,
  }) async {
    final steers = _session(key).agent.steers;
    final saved = await _files.save(files);
    final q = _Queued(
      id ?? _newId(),
      text,
      images: [
        if (steers)
          for (final i in images) {'data': base64Encode(i.bytes), 'mimeType': i.mimeType},
      ],
      imageFiles: steers ? const [] : await _saveImages(images),
      docs: saved,
    );
    // As it is now: it may have started or ended a run, or said hello again, meanwhile.
    final s = _session(key);
    if ((followUp || !steers) && (s.busy || s.ask != null)) {
      _room(s, q.text.length, another: true);
      s._queue.add(q);
      _changes.add(null);
      return q.id;
    }
    await _send(s, q, deliver: followUp || !steers ? 'followUp' : 'steer');
    return null;
  }

  /// At most this many prompts wait in a session's queue, with at most [maxQueuedText] characters of text together:
  /// the phones get every one whole with each state.
  static const maxQueued = 20;
  static const maxQueuedText = 32000;

  /// Throws unless [s]'s queue has room for [chars] more characters, and [another] prompt.
  static void _room(LiveSession s, int chars, {bool another = false}) {
    if (another && s._queue.length >= maxQueued) {
      throw const LiveException('The queue is full: $maxQueued prompts wait already.');
    }
    if (s._queue.fold(0, (n, q) => n + q.text.length) + chars > maxQueuedText) {
      throw const LiveException('That is more text than the queue holds: send it when the run ends.');
    }
  }

  static final _random = Random.secure();
  static String _newId() => List.generate(16, (_) => _random.nextInt(36).toRadixString(36)).join();

  Future<void> _send(LiveSession s, _Queued q, {required String deliver}) => s._request('prompt', {
    'text': withMentions(q.text, q.docs),
    'images': q.images,
    if (!s.agent.steers) 'files': q.imageFiles,
    if (!s.agent.steers && q.docs.isNotEmpty) 'docs': q.docs,
    'deliver': deliver,
  }, const Duration(seconds: 15));

  /// Whether [s]'s queue's next prompt can go: the agent is at rest and asks nothing, nothing holds the queue.
  bool _drainable(LiveSession s) =>
      s._queue.isNotEmpty && !s.paused && !s.busy && s.ask == null && !s._handing && identical(_byKey[s.key], s);

  /// How long the agent may take to say it started on a prompt from the queue before it's taken to be at rest.
  static const handoffWait = Duration(seconds: 10);

  /// Hands [s]'s queue's next prompt to the agent, if it can go ([_drainable]). The session shows as working from
  /// here on, so it never looks done in between. One that doesn't go returns to the front, and the queue pauses.
  void _drain(LiveSession s) {
    if (!_drainable(s)) return;
    final q = s._queue.removeAt(0);
    s
      .._handing = true
      ..busy = true
      ..failed = false
      ..at = DateTime.now();
    if (s._queue.isEmpty) s.paused = false;
    _changes.add(null);
    unawaited(_handOff(s, q));
  }

  Future<void> _handOff(LiveSession s, _Queued q) async {
    try {
      await _send(s, q, deliver: 'followUp');
    } on Object catch (e) {
      debugPrint('PocketTerm: a queued prompt did not go: $e');
      s._queue.insert(0, q);
      s.paused = true;
      if (s._handing) {
        s
          .._handing = false
          ..busy = false;
      }
      _changes.add(null);
      return;
    }
    if (!s._handing) return;
    s._handoff?.cancel();
    s._handoff = Timer(handoffWait, () {
      if (!s._handing) return;
      s
        .._handing = false
        ..busy = false;
      if (_drainable(s)) return _drain(s);
      _changes.add(null);
    });
  }

  _Queued _queued(LiveSession s, String id) =>
      s._queue.where((q) => q.id == id).firstOrNull ??
      (throw const LiveException('That prompt has gone to the agent already.'));

  /// Replaces the text of prompt [id] in session [key]'s queue.
  void editQueued(String key, String id, String text) {
    final s = _session(key);
    final q = _queued(s, id);
    final was = q.text;
    q.text = text;
    if (q.empty) {
      q.text = was;
      throw const LiveException('A prompt needs some text, an image or a file.');
    }
    q.text = was;
    _room(s, text.length - was.length);
    q.text = text;
    _changes.add(null);
  }

  /// Takes prompt [id] out of session [key]'s queue: it never goes.
  void removeQueued(String key, String id) {
    final s = _session(key);
    s._queue.remove(_queued(s, id));
    if (s._queue.isEmpty) s.paused = false;
    _changes.add(null);
  }

  /// Moves prompt [id] to place [to] (0: next) in session [key]'s queue.
  void moveQueued(String key, String id, int to) {
    final s = _session(key);
    final q = _queued(s, id);
    s._queue
      ..remove(q)
      ..insert(to.clamp(0, s._queue.length - 1), q);
    _changes.add(null);
  }

  /// Sends prompt [id] out of session [key]'s queue now: it steers the run. omp only; Claude Code can't take a
  /// prompt while it works. One that doesn't go goes back where it was.
  Future<void> sendQueuedNow(String key, String id) async {
    final s = _session(key);
    if (!s.agent.steers) throw LiveException("${s.agent.label} can't take a prompt while it works.");
    final q = _queued(s, id);
    final at = s._queue.indexOf(q);
    s._queue.removeAt(at);
    if (s._queue.isEmpty) s.paused = false;
    _changes.add(null);
    try {
      await _send(s, q, deliver: 'steer');
    } on Object {
      s._queue.insert(min(at, s._queue.length), q);
      _changes.add(null);
      rethrow;
    }
  }

  /// Holds session [key]'s queue, or lets it go on: its next prompt goes now if the agent is at rest.
  void pauseQueue(String key, {required bool paused}) {
    final s = _session(key);
    s.paused = paused && s._queue.isNotEmpty;
    _changes.add(null);
    _drain(s);
  }

  Future<List<String>> _saveImages(List<({Uint8List bytes, String mimeType})> images) async {
    if (images.isEmpty) return const [];
    final dir = _imageDir;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      // Private to this user; Windows' per-user temp folder already is.
      if (!Platform.isWindows) await Process.run('/bin/chmod', ['700', dir.path]);
    }
    _pruneImages();
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

  /// Deletes the images older than [PromptFiles.keep].
  void _pruneImages() {
    if (!_imageDir.existsSync()) return;
    final before = DateTime.now().subtract(PromptFiles.keep);
    for (final f in _imageDir.listSync().whereType<File>()) {
      try {
        if (f.statSync().modified.isBefore(before)) f.deleteSync();
      } on FileSystemException catch (e) {
        debugPrint('PocketTerm: image cleanup: $e');
      }
    }
  }

  /// Esc: stops what the agent is doing. What waits in its queue stays there until Resume.
  Future<void> abort(String key) {
    final s = _session(key);
    if (s._queue.isNotEmpty && !s.paused) {
      s.paused = true;
      _changes.add(null);
    }
    return s._request('abort', const {}, const Duration(seconds: 5));
  }

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
