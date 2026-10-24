import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/ansi.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/live_activity.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_channel.dart';
import 'package:pocketterm_core/timing.dart';
import 'package:uuid/uuid.dart';

// The phone side of the terminal protocol (lib/live.dart): the Mac's coding
// sessions and terminal windows, what the phone watches, and a disk cache so
// the Terminal tab shows the last known state before the Mac answers.

enum TerminalLink {
  /// Joining the topic.
  connecting,

  /// The server can't be reached (offline, Tailscale off, the server down):
  /// trying again.
  unreachable,

  /// Joined; no answer from the Mac yet.
  waiting,

  /// The Mac answers.
  online,

  /// The Mac stopped answering, or never did.
  offline,
}

/// A terminal window's text as the phone has it: version [v] of its [lines]
/// (ANSI), and how many lines have scrolled off the top since the phone
/// first saw it ([base]), so a view can keep its place while it scrolls.
class TermScreen {
  const TermScreen(this.v, this.lines, this.base);
  final int v;
  final List<String> lines;
  final int base;
}

/// What goes out on the topic; tests pass their own.
typedef TerminalSend = void Function(String event, Map<String, dynamic> payload);

/// Where images and files go on their way to the computer (the server's
/// blobs, sealed); tests pass their own.
typedef ImageUpload = Future<void> Function(String path, Uint8List sealed);

/// A file a prompt takes along, as it is: its name and type go inside the
/// sealed request, its bytes sealed in a blob.
typedef PromptFile = ({String name, String mime, Uint8List bytes});

class _Watch {
  _Watch({this.session, this.window});
  final String? session;
  final String? window;
}

/// The phone side for one computer ([desktopId]): its coding sessions
/// (structured, per [LiveView]) and terminal windows (as screens). The
/// channel and the hellos run between [attach] and [detach]: while the app is
/// in front. Everything goes sealed with that computer's [key] (lib/e2e.dart).
/// Its disk cache is `terminal/<desktopId>` in the given support directory.
/// `send` and `upload`, when handed in (tests and the phone's demo, which
/// answer locally), replace the channel and the image upload.
class TerminalRemote extends ChangeNotifier {
  TerminalRemote(
    this._server,
    Directory supportDir, {
    required this.desktopId,
    required this.key,
    TerminalSend? send,
    ImageUpload? upload,
    String? from,
  }) : _cacheDir = Directory('${supportDir.path}/terminal/$desktopId'),
       _transmit = send,
       _uploadImage = upload,
       from = from ?? const Uuid().v4() {
    _load();
  }

  final Server _server;
  final Directory _cacheDir;
  final TerminalSend? _transmit;
  final ImageUpload? _uploadImage;

  /// The computer this talks to (lib/desktops.dart).
  final String desktopId;

  /// That computer's channel key, from its QR code.
  final ChannelKey key;

  /// What the phone calls that computer (its name in the list), for "asking
  /// MacBook Pro…"; null while not known.
  String? get desktopName => _desktopName;
  String? _desktopName;
  set desktopName(String? name) {
    if (name == _desktopName) return;
    _desktopName = name;
    notifyListeners();
  }

  /// When that computer last told the server it's there (the computers
  /// list's seen_at, every minute while PocketTerm runs there with
  /// Terminal from phone on); null while not known. Not answering and not
  /// seen for a while, it's asleep or off rather than just quiet.
  DateTime? get desktopSeenAt => _desktopSeenAt;
  DateTime? _desktopSeenAt;
  set desktopSeenAt(DateTime? at) {
    if (at == _desktopSeenAt) return;
    _desktopSeenAt = at;
    notifyListeners();
  }

  /// This phone, to the Mac.
  final String from;

  static const _helloEvery = Duration(seconds: 4);
  static const _silent = Duration(seconds: 10);

  /// A sync unanswered this long is taken as lost.
  static const _syncWait = Duration(seconds: 8);

  /// A watched session behind the state's seq this long, without live ops
  /// catching it up, syncs.
  static const _behindWait = Duration(seconds: 3);
  static const _writeEvery = Duration(seconds: 2);
  static const _keepFor = Duration(days: 14);

  late final TerminalChannel _ch = TerminalChannel(
    _server,
    desktopId,
    {
      for (final event in const ['state', 'items', 'live', 'screen', 'ran']) event: (p) => _receive(event, p),
    },
    key: key,
    name: 'terminal remote',
    onJoined: ({required joined}) {
      // Ops may have gone by while away.
      if (joined) _watched();
      notifyListeners();
    },
    onUnreachable: notifyListeners,
  );
  Timer? _timer;

  /// Debug timing ([timing]): a state came since [attach]; sessions caught up since then.
  bool _stateSinceAttach = false;
  final _caughtUp = <String>{};

  /// The server this goes through, as [TerminalLink.unreachable] tells it.
  Backend get backend => _server.backend;

  DateTime _openedAt = DateTime.now();
  DateTime? _heard;
  int _users = 0;

  List<TermWindow> windows = const [];
  List<LiveSummary> sessions = const [];
  List<String> projects = const [];

  /// The Mac's Project folders, where a new project can be made; null from
  /// a Mac that predates them (and can't make one).
  List<String>? roots;

  /// The Mac's home folder, shown as ~.
  String home = '';

  /// What a new session starts on the Mac (its setting).
  Agent agent = Agent.omp;

  /// Where PocketTerm stands in each coding agent found on the computer;
  /// empty from a computer that doesn't say.
  Map<Agent, AgentIntegration> agents = const {};

  /// Where a session the phone starts opens ("kitty", "Ghostty (in tmux)");
  /// null from a Mac that doesn't say.
  String? opensIn;

  /// The Mac's terminals (installed ones, and tmux) and how each stands;
  /// empty from a Mac that doesn't say.
  List<TermStatus> terminals = const [];

  /// What the Mac can't do with its terminals, as it says it (none reachable,
  /// one not set up …).
  String? error;

  /// Phone: the sessions followed (Live Activities, Android notifications); set by the app (null
  /// in tests and wherever there are none).
  LiveActivities? activities;

  /// When the Mac last sent its state; [fromCache]: that was before this
  /// launch, read from disk.
  DateTime? stateAt;
  bool fromCache = false;

  final _views = <String, LiveView>{};

  /// Sessions with no cache file, so [view] doesn't look again.
  final _uncached = <String>{};

  /// Sessions with a sync out: when it went.
  final _syncing = <String, DateTime>{};

  /// Live ops that came while a sync was out, applied after it.
  final _held = <String, List<(String, List<LiveOp>)>>{};

  /// Watched sessions the state says are ahead: since when.
  final _behind = <String, DateTime>{};

  final _screens = <String, TermScreen>{};

  /// Each watched window's colors, as its terminal draws it.
  final colors = <String, TermColors>{};

  final _watches = <_Watch>[];
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _writes = <String, Timer>{};

  TerminalLink get link {
    // A transport handed in (tests) is always there.
    if (_transmit == null && !_ch.joined) return _ch.unreachable ? TerminalLink.unreachable : TerminalLink.connecting;
    final now = DateTime.now();
    final heard = _heard;
    if (heard != null && now.difference(heard) < _silent) return TerminalLink.online;
    if (heard == null && now.difference(_openedAt) < _silent) return TerminalLink.waiting;
    return TerminalLink.offline;
  }

  bool get online => link == TerminalLink.online;

  /// How far the computer's clock is off this phone's while it's too far for
  /// anything from it to be taken (more than 5 minutes: both should set the
  /// time automatically); null otherwise. Then the computer reads as
  /// offline, though it's there.
  Duration? get clockOff => _transmit == null ? _ch.clockOff : null;

  TermWindow? window(String key) => windows.where((w) => w.key == key).firstOrNull;
  LiveSummary? session(String key) => sessions.where((s) => s.key == key).firstOrNull;
  TermScreen? screen(String window) => _screens[window];

  /// The session's transcript as far as the phone has it: in memory, else
  /// from the disk cache; null if neither has it.
  LiveView? view(String key) {
    final v = _views[key];
    if (v != null || _uncached.contains(key)) return v;
    try {
      final f = _sessionFile(key);
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        return _views[key] = LiveView.fromJson(j);
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: terminal cache: $e');
    }
    _uncached.add(key);
    return null;
  }

  /// The session the phone shows, if it shows one.
  String? get watchedSession => _watches.lastOrNull?.session;

  /// The window whose screen the phone shows, if it shows one.
  String? get watchedWindow => _watches.lastOrNull?.window;

  /// Pages call these on init and the returned function on dispose; the
  /// newest one open is what the Mac hears about (one at a time), and
  /// closing it goes back to the one under it.
  VoidCallback watchSession(String key) => _watch(_Watch(session: key));
  VoidCallback watchWindow(String key) => _watch(_Watch(window: key));

  VoidCallback _watch(_Watch w) {
    _watches.add(w);
    _watched();
    return () {
      final top = identical(_watches.lastOrNull, w);
      _watches.remove(w);
      if (top) _watched();
    };
  }

  /// Tells the Mac what's watched now and catches up with it.
  void _watched() {
    hello();
    final s = watchedSession;
    if (s != null) _sync(s, force: true);
    final w = watchedWindow;
    if (w != null) _post('sync', {'from': from, 'window': w});
  }

  /// The app calls this when it comes to the front and [detach] when it
  /// leaves.
  void attach() {
    if (_users++ > 0) return;
    timing('attach');
    _stateSinceAttach = false;
    _caughtUp.clear();
    _openedAt = DateTime.now();
    if (_transmit != null) return;
    _ch.open();
    _timer = Timer.periodic(_helloEvery, (_) {
      hello();
      // A session left behind with no state to come still catches up.
      _checkBehind(DateTime.now());
      // The link can turn offline without a message.
      notifyListeners();
    });
  }

  void detach() {
    if (_users == 0 || --_users > 0) return;
    _timer?.cancel();
    _timer = null;
    _heard = null;
    _syncing.clear();
    _held.clear();
    _behind.clear();
    if (_transmit == null) unawaited(_ch.close());
    flush();
  }

  /// Retry: a new connection at once (lib/terminal_channel.dart), and the
  /// computer asked again, given its 10 seconds to answer before it reads as
  /// not answering. Only while attached.
  void reconnect() {
    if (_users == 0) return;
    _openedAt = DateTime.now();
    _heard = null;
    if (_transmit == null) {
      _ch.reconnect();
    } else {
      hello();
    }
    notifyListeners();
  }

  void hello() => _post('hello', {'from': from, 'session': ?watchedSession, 'window': ?watchedWindow});

  void _receive(String event, Map<String, dynamic> p) {
    try {
      handle(event, p);
    } on Object catch (e) {
      debugPrint('PocketTerm: terminal remote: bad $event: $e');
    }
  }

  /// One message from the Mac; also handed in directly by tests and the
  /// phone's demo, which answer locally.
  void handle(String event, Map<String, dynamic> p) {
    switch (event) {
      case 'state':
        _onState(p);
      case 'items':
        _onItems(p);
      case 'live':
        _onLive(p);
      case 'screen':
        _onScreen(p);
      case 'ran':
        _pending.remove(p['id'])?.complete(p);
    }
  }

  Future<void> _send(String event, Map<String, dynamic> payload) async {
    final t = _transmit;
    if (t != null) {
      t(event, payload);
    } else {
      await _ch.send(event, payload);
    }
  }

  void _post(String event, Map<String, dynamic> payload) =>
      unawaited(_send(event, payload).then((_) {}, onError: (Object e) => debugPrint('PocketTerm: terminal: $e')));

  /// Asks the Mac for what [key]'s view misses. Unforced, it waits for a
  /// sync already out.
  void _sync(String key, {bool force = false}) {
    final now = DateTime.now();
    final out = _syncing[key];
    if (!force && out != null && now.difference(out) < _syncWait) return;
    _syncing[key] = now;
    _held.remove(key);
    final v = view(key);
    _post('sync', {'from': from, 'session': key, 'epoch': ?v?.epoch, 'since': v?.seq ?? 0});
  }

  bool _syncOut(String key) {
    final out = _syncing[key];
    return out != null && DateTime.now().difference(out) < _syncWait;
  }

  void _applyState(Map<String, dynamic> p) {
    windows = [for (final w in p['windows'] as List? ?? const []) TermWindow.fromJson((w as Map).cast())];
    sessions = [for (final s in p['sessions'] as List? ?? const []) LiveSummary.fromJson((s as Map).cast())];
    projects = (p['projects'] as List?)?.cast<String>() ?? projects;
    roots = (p['roots'] as List?)?.cast<String>();
    home = p['home'] as String? ?? home;
    agent = Agent.parse(p['agent']);
    agents = AgentIntegration.parseAll(p['agents']);
    opensIn = p['opensIn'] as String?;
    terminals = [for (final t in p['terminals'] as List? ?? const []) TermStatus.fromJson((t as Map).cast())];
  }

  void _onState(Map<String, dynamic> p) {
    if (kDebugMode && !_stateSinceAttach) {
      _stateSinceAttach = true;
      timing('first state');
    }
    final now = _heard = stateAt = DateTime.now();
    fromCache = false;
    _applyState(p);
    error = p['error'] as String?;
    _checkBehind(now);
    _dirty(_stateKey);
    notifyListeners();
  }

  /// Syncs the watched session when the state says the Mac has more than
  /// live ops brought (a new epoch, or a seq ahead for [_behindWait]).
  void _checkBehind(DateTime now) {
    final watched = watchedSession;
    final s = watched == null ? null : session(watched);
    if (s == null) return;
    final v = view(s.key);
    if (v == null || (s.epoch.isNotEmpty && s.epoch != v.epoch)) {
      _sync(s.key);
    } else if (s.seq > v.seq) {
      final since = _behind[s.key] ??= now;
      if (now.difference(since) >= _behindWait) {
        _behind.remove(s.key);
        _sync(s.key);
      }
    } else {
      _behind.remove(s.key);
    }
  }

  void _onItems(Map<String, dynamic> p) {
    if (p['to'] != from) return;
    _heard = DateTime.now();
    final key = p['session'] as String;
    final epoch = p['epoch'] as String;
    final last = p['last'] == true;
    final v = (view(key) ?? (_views[key] = LiveView(epoch: epoch)))
      ..catchUp(
        epoch: epoch,
        seq: p['seq'] as int,
        reset: p['reset'] == true,
        items: [for (final i in p['items'] as List? ?? const []) LiveItem.fromJson((i as Map).cast())],
        last: last,
        older: p['older'] as bool?,
      );
    if (last && v.epoch == epoch) {
      if (kDebugMode && key == watchedSession && _caughtUp.add(key)) timing('caught up');
      _syncing.remove(key);
      _behind.remove(key);
      for (final (e, ops) in _held.remove(key) ?? const <(String, List<LiveOp>)>[]) {
        if (!v.apply(e, ops)) {
          _sync(key);
          break;
        }
      }
    }
    _dirty(key);
    notifyListeners();
  }

  void _onLive(Map<String, dynamic> p) {
    _heard = DateTime.now();
    final key = p['session'] as String;
    final epoch = p['epoch'] as String;
    final ops = [for (final o in p['ops'] as List? ?? const []) LiveOp.fromJson((o as Map).cast())];
    final watched = key == watchedSession;
    if (watched && _syncOut(key)) {
      (_held[key] ??= []).add((epoch, ops));
      return;
    }
    // Other phones' sessions too, when this one has them at hand.
    final v = _views[key] ?? (watched ? view(key) : null);
    if (v == null) {
      if (watched) _sync(key);
      return;
    }
    if (!v.apply(epoch, ops) && watched) _sync(key);
    _dirty(key);
    notifyListeners();
  }

  void _onScreen(Map<String, dynamic> p) {
    _heard = DateTime.now();
    final window = p['window'] as String;
    final v = p['v'] as int;
    final c = p['colors'] as Map?;
    if (c != null) colors[window] = TermColors.fromJson(c.cast());
    final old = _screens[window];
    final lines = (p['lines'] as List?)?.cast<String>();
    final diff = p['diff'] is Map ? ScreenDiff.fromJson((p['diff'] as Map).cast()) : null;
    if (lines != null) {
      // How far it scrolled, if it did.
      final drop = old == null ? 0 : ScreenDiff.between(old.lines, lines)?.drop ?? 0;
      _screens[window] = TermScreen(v, lines, (old?.base ?? 0) + drop);
    } else if (diff != null) {
      final next = old != null && old.v == v - 1 ? diff.apply(old.lines) : null;
      if (next != null) {
        _screens[window] = TermScreen(v, next, old!.base + diff.drop);
      } else if (window == watchedWindow) {
        _post('sync', {'from': from, 'window': window});
      }
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ ops

  /// How long a request waits for the computer's answer (a prompt with
  /// images three times as long).
  @visibleForTesting
  Duration answerWait = const Duration(seconds: 10);

  /// [request]'s answer from the Mac, sending included within [wait]
  /// ([answerWait] by default), under [id] (a new one by default). With
  /// [onLate], an answer that comes after [wait] (the Mac did it after all)
  /// still goes there, for a while.
  Future<Map<String, dynamic>> _run(
    Map<String, dynamic> request, {
    Duration? wait,
    String? id,
    void Function(Map<String, dynamic> reply)? onLate,
  }) async {
    if (!online) throw const TerminalException('The computer is not answering.');
    final runId = id ?? const Uuid().v4();
    final done = _pending[runId] = Completer();
    final Map<String, dynamic> reply;
    var later = false;
    try {
      reply = await Future(() async {
        await _send('run', {'id': runId, ...request});
        return await done.future;
      }).timeout(wait ?? answerWait);
    } on TimeoutException {
      if (onLate != null) {
        later = true;
        unawaited(
          done.future
              .timeout(_lateFor)
              .then<void>(onLate, onError: (Object _) {})
              .whenComplete(() => _pending.remove(runId)),
        );
      }
      throw const _NoAnswer();
    } finally {
      if (!later) _pending.remove(runId);
    }
    final error = reply['error'] as String?;
    if (error != null) throw TerminalException(error);
    return reply;
  }

  /// How long an answer that came too late is still taken.
  static const _lateFor = Duration(minutes: 2);

  /// Types [text] into [window], then Enter.
  Future<void> send(String window, String text) => _run({'op': 'send', 'window': window, 'text': text});

  /// One of [phoneKeys], where the window's terminal can press keys.
  Future<void> press(String window, String key) => _run({'op': 'key', 'window': window, 'key': key});

  /// Closes [window] on the Mac, with what runs in it.
  Future<void> close(String window) => _run({'op': 'close', 'window': window});

  /// Whether the agent in [window] looks at work: its screen changed over two seconds on the computer.
  Future<bool> probe(String window) async => (await _run({'op': 'probe', 'window': window}))['busy'] == true;

  /// Switches [agent] in [window], which shows only as a screen, to reporting its session: omp quits and
  /// starts again on the same conversation, Claude Code reloads its plugins. The session shows up in
  /// [sessions] once the agent reports.
  Future<void> switchToConversation(String window, Agent agent) =>
      _run({'op': 'switch', 'window': window, 'agent': agent.name}, wait: answerWait * 2);

  /// A new terminal window in [cwd] (where [opensIn] says), running the Mac's coding [agent] if
  /// [startAgent]; its window key.
  Future<String> launch(String cwd, {required bool startAgent}) =>
      _open({'op': 'launch', 'cwd': cwd, 'agent': startAgent});

  /// A new folder [name] under [root] (one of [roots]) on the Mac, with a
  /// window in it as [launch]; its window key.
  Future<String> create(String root, String name, {required bool startAgent}) =>
      _open({'op': 'create', 'root': root, 'name': name, 'agent': startAgent});

  /// Runs [request], which opens a window; its key. Starting a terminal app
  /// can take a while; a window that opens after the phone stopped waiting
  /// is still taken as new ([_fresh]).
  Future<String> _open(Map<String, dynamic> request) async {
    final reply = await _run(
      request,
      wait: answerWait * 2,
      onLate: (r) {
        if (r['window'] case final String window) _fresh(window);
      },
    );
    final window = reply['window'] as String;
    _fresh(window);
    return window;
  }

  /// A window just opened under [window]'s key. A key can come back (tmux
  /// numbers panes from %0 again once its server restarts, Terminal reuses
  /// ttys): what the phone kept for it is an ended session's, and goes.
  void _fresh(String window) {
    _views.remove(window);
    _writes.remove(window)?.cancel();
    try {
      final f = _sessionFile(window);
      if (f.existsSync()) f.deleteSync();
    } on Object catch (e) {
      debugPrint('PocketTerm: terminal cache: $e');
    }
  }

  /// The last prompt the computer didn't answer (the app went to the
  /// background, the network dropped): what it was and the id it went
  /// under. The same prompt sent again soon goes under the same id, which
  /// the computer answers without running it twice if it got it the first
  /// time (TerminalBridge in apps/pocketterm-desktop).
  ({String what, String id, DateTime at})? _unanswered;
  static const _sameFor = Duration(minutes: 2);

  /// Prompts [session] with [text], [images] (image files: PNG, JPEG) and
  /// [files] (any file, as it is). Their bytes pass through the server
  /// sealed with [key]; a file's name and type go inside the sealed request.
  /// While omp works the prompt steers it, or waits for the turn to end if
  /// [followUp]; Claude Code always waits. One that waits goes to the
  /// session's queue on the computer: the id it waits under there
  /// ([LiveSummary.queue]), else null.
  Future<String?> prompt(
    String session,
    String text, {
    List<Uint8List> images = const [],
    List<PromptFile> files = const [],
    bool followUp = false,
  }) async {
    if (!online) throw const TerminalException('The computer is not answering.');
    final what = sha1
        .convert(
          utf8.encode(
            jsonEncode([
              session,
              text,
              followUp,
              for (final i in images) '${sha1.convert(i)}',
              for (final f in files) [f.name, f.mime, '${sha1.convert(f.bytes)}'],
            ]),
          ),
        )
        .toString();
    final now = DateTime.now();
    final again = switch (_unanswered) {
      final u? when u.what == what && now.difference(u.at) < _sameFor => u,
      _ => null,
    };
    final id = again?.id ?? const Uuid().v4();
    final upload = _uploadImage ?? _server.putBlob;
    final paths = <String>[];
    final sent = <Map<String, String>>[];
    void forget() {
      for (final path in [...paths, for (final f in sent) f['path']!]) {
        unawaited(_server.deleteBlob(path).then((_) {}, onError: (Object e) => debugPrint('$e')));
      }
    }

    Future<String> sealed(Uint8List bytes) async {
      final path = _server.newBlobPath();
      await upload(path, await sealBytes(key, bytes, imageAad(path)));
      return path;
    }

    try {
      for (final bytes in images) {
        paths.add(await sealed(bytes));
      }
      for (final f in files) {
        sent.add({'path': await sealed(f.bytes), 'name': f.name, 'mime': f.mime});
      }
    } on Object catch (e) {
      forget();
      throw TerminalException("The ${paths.length < images.length ? 'image' : 'file'} didn't upload: $e");
    }
    final bytes = [...images, for (final f in files) f.bytes].fold(0, (n, b) => n + b.length);
    try {
      final reply = await _run(
        {
          'op': 'prompt',
          'session': session,
          'text': text,
          'images': paths,
          if (sent.isNotEmpty) 'files': sent,
          'deliver': followUp ? 'followUp' : 'steer',
        },
        // The computer downloads them first: a second more for each MB.
        wait: bytes == 0 ? answerWait : answerWait * 3 + Duration(seconds: bytes >> 20),
        id: id,
      );
      _unanswered = null;
      // The computer had it already, with the images and files sent the first time.
      if (reply['repeat'] == true) forget();
      return reply['queued'] as String?;
    } on TerminalException catch (e) {
      _unanswered = e is _NoAnswer ? (what: what, id: id, at: again?.at ?? now) : null;
      // The Mac deletes them once used; unanswered, nobody would.
      forget();
      rethrow;
    }
  }

  /// Esc: stops what the agent is doing.
  Future<void> abort(String session) => _run({'op': 'abort', 'session': session});

  /// Changes [session]'s queue on the computer ([LiveSummary.queue]): [item]'s text to [text].
  Future<void> editQueued(String session, String item, String text) =>
      _queue(session, 'edit', {'item': item, 'text': text});

  /// Takes [item] out of [session]'s queue: it never goes.
  Future<void> removeQueued(String session, String item) => _queue(session, 'remove', {'item': item});

  /// Moves [item] to place [to] (0: next) in [session]'s queue.
  Future<void> moveQueued(String session, String item, int to) => _queue(session, 'move', {'item': item, 'to': to});

  /// Sends [item] now, out of [session]'s queue: it steers the run (omp).
  Future<void> sendQueuedNow(String session, String item) => _queue(session, 'send', {'item': item});

  /// Holds [session]'s queue, or lets it go on ([paused] false): the next prompt goes when the run ends, or now if
  /// it has ended.
  Future<void> pauseQueue(String session, {required bool paused}) => _queue(session, paused ? 'pause' : 'resume');

  Future<void> _queue(String session, String what, [Map<String, Object?> args = const {}]) =>
      _run({'op': 'queue', 'session': session, 'do': what, ...args});

  /// Answers [ask]: [answers] (one per question), or [approve] an approval.
  Future<void> answer(String session, LiveAsk ask, {List<LiveAnswer> answers = const [], bool approve = false}) =>
      _run({
        'op': 'answer',
        'session': session,
        'ask': ask.id,
        if (ask.isApproval) 'approve': approve else 'answers': [for (final a in answers) a.toJson()],
      });

  /// Fetches items before the oldest the Mac has; they arrive as live ops.
  Future<void> older(String session) => _run({'op': 'older', 'session': session});

  // ---------------------------------------------------------------- cache

  /// [_writes]' key for state.json (session keys are never empty).
  static const _stateKey = '';

  File get _stateFile => File('${_cacheDir.path}/state.json');
  Directory get _sessionDir => Directory('${_cacheDir.path}/sessions');
  File _sessionFile(String key) => File('${_sessionDir.path}/${sha1.convert(utf8.encode(key))}.json');

  void _load() {
    try {
      final f = _stateFile;
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        _applyState(j);
        stateAt = j['at'] is int ? DateTime.fromMillisecondsSinceEpoch(j['at'] as int) : null;
        fromCache = true;
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: terminal cache: $e');
    }
    try {
      final dir = _sessionDir;
      if (!dir.existsSync()) return;
      final now = DateTime.now();
      for (final f in dir.listSync().whereType<File>()) {
        if (now.difference(f.statSync().modified) > _keepFor) f.deleteSync();
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: terminal cache: $e');
    }
  }

  /// Writes [key]'s file (a session, or [_stateKey]) soon, at most every
  /// [_writeEvery].
  void _dirty(String key) => _writes[key] ??= Timer(_writeEvery, () {
    _writes.remove(key);
    _write(key);
  });

  /// Writes every file waiting to be.
  void flush() {
    for (final key in _writes.keys.toList()) {
      _writes.remove(key)!.cancel();
      _write(key);
    }
  }

  void _write(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final File file;
    final Map<String, dynamic> json;
    if (key == _stateKey) {
      file = _stateFile;
      json = {
        'windows': [for (final w in windows) w.toJson()],
        'sessions': [for (final s in sessions) s.toJson()],
        'projects': projects,
        'roots': ?roots,
        'home': home,
        'agent': agent.name,
        'agents': AgentIntegration.toJsonAll(agents),
        'opensIn': ?opensIn,
        'terminals': [for (final t in terminals) t.toJson()],
        'at': stateAt?.millisecondsSinceEpoch ?? now,
      };
    } else {
      final v = _views[key];
      if (v == null) return;
      file = _sessionFile(key);
      json = {'key': key, 'at': now, ...v.toJson()};
    }
    try {
      file.parent.createSync(recursive: true);
      // Whole or not at all, should the app be killed mid-write.
      File('${file.path}.tmp')
        ..writeAsStringSync(jsonEncode(json))
        ..renameSync(file.path);
    } on Object catch (e) {
      debugPrint('PocketTerm: terminal cache: $e');
    }
  }

  @override
  void dispose() {
    _users = 1;
    detach();
    for (final p in _pending.values) {
      if (!p.isCompleted) p.completeError(const TerminalException('Closed.'));
    }
    super.dispose();
  }
}

/// No answer from the computer in time: it may have done it all the same.
class _NoAnswer extends TerminalException {
  const _NoAnswer() : super('The computer did not answer.');
}
