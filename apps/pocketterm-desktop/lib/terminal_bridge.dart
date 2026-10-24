import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/live_activity.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_channel.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_desktop/desktop_host.dart';
import 'package:pocketterm_desktop/live_hub.dart';

/// The desktop side of Terminal from the phone (protocol: packages/pocketterm_core/lib/live.dart): the
/// coding sessions [LiveHub] knows and the terminals' windows
/// (packages/pocketterm_core/lib/terminals.dart) go out on this computer's
/// topic on the server (its id), sealed with its channel
/// key (packages/pocketterm_core/lib/e2e.dart); what the phone asks for is
/// done here, where the window's terminal can do it. The terminals are
/// polled only while a phone has said hello lately.
class TerminalBridge {
  TerminalBridge(
    this._server,
    this._desktopId,
    this._key,
    this._terms,
    this._hub,
    this._host,
    this._agent,
    this._app,
    this._roots, {
    this._agents,
    this._onPhone,
  });

  final Server _server;

  /// This computer, among the user's (lib/controller.dart).
  final String _desktopId;

  /// This computer's channel key (lib/channel_keys.dart).
  final ChannelKey _key;
  final Terminals _terms;
  final LiveHub _hub;

  /// Keeps this computer awake while the bridge runs.
  final DesktopHost _host;

  /// The agent a new session from the phone starts (this computer's setting).
  final Agent Function() _agent;

  /// The terminal app it opens in: an app's id or `auto` (this computer's setting).
  final String Function() _app;

  /// This computer's Project folders setting.
  final List<String> Function() _roots;

  /// Where PocketTerm stands in each coding agent found here (this computer's
  /// checks, which keep themselves fresh); none told if null.
  final Future<Map<Agent, AgentIntegration>> Function()? _agents;
  Map<Agent, AgentIntegration>? _agentsNow;

  /// A phone said hello: one is signed in to this account.
  final VoidCallback? _onPhone;

  /// A phone that hasn't said hello for this long has left.
  static const _gone = Duration(seconds: 12);

  /// How often a watched window's screen is read; the window list every
  /// third time.
  static const _tickEvery = Duration(milliseconds: 700);

  /// Live ops wait this long to go out together.
  static const _batch = Duration(milliseconds: 150);

  /// The server closes a socket on a frame over 256 KiB, and sealed and in base64 a message grows by a third (see
  /// chunkJson in live.dart): a full screen is cut to this much JSON, a state to [_maxStateJson].
  static const _maxScreenJson = 60000;
  static const _maxStateJson = 150000;

  late final TerminalChannel _ch = TerminalChannel(
    _server,
    _desktopId,
    {'hello': _onHello, 'sync': _onSync, 'run': (m) => unawaited(_onRun(m))},
    key: _key,
    name: 'terminal bridge',
  );
  Timer? _tick;
  int _ticks = 0;
  bool _polling = false;
  final _subs = <StreamSubscription<Object?>>[];

  /// Each listening phone (its `from`): what it shows, when it last said hello.
  final _phones = <String, ({String? session, String? window, DateTime seen})>{};

  List<TermWindow> _windows = const [];
  String? _termError;
  List<String>? _projects;
  DateTime? _projectsAt;
  List<String> _projectsRoots = const [];

  /// The installed terminals and how they stand, and where a new session
  /// opens (its label), as of [_statusesAt].
  List<TermStatus> _statuses = const [];
  String? _opensIn;
  DateTime? _statusesAt;

  /// The last state sent: without the sessions' seq and time, which change
  /// with every live op, and with them.
  String? _sentState;
  String? _sentClock;
  DateTime _sentAt = DateTime(0);
  Timer? _stateSoon;

  /// A state that differs only in seq and time (live ops already carry those)
  /// goes out at most this often; phones use it to notice lost ops.
  static const _clockEvery = Duration(seconds: 4);

  /// Per watched window: the version and lines the phones have.
  final _screens = <String, ({int v, List<String> lines})>{};
  final _fullScreen = <String>{};

  /// Ops waiting for the next batch, per session key.
  final _pendingOps = <String, ({String epoch, List<LiveOp> ops})>{};
  Timer? _flush;

  /// Asks (their ids) whose screen is being followed: plan reviews, and
  /// Claude Code's approvals, which its plugin can't see answered.
  final _followed = <String>{};
  bool _stopped = false;

  /// How often a followed ask's screen is read: often while it opens, then
  /// now and then to follow its cursor and notice it go.
  static const _askSoon = Duration(milliseconds: 500);
  static const _askOpening = 6;
  static const _askEvery = Duration(seconds: 3);

  /// Sessions whose screen is followed for pickers (/resume, /model …) after
  /// a slash command from the phone, and the pickers' ids so far.
  final _menus = <String, _MenuWatch>{};
  int _menuIds = 0;

  /// A picker's screen is read this often for [_menuOpening] after the
  /// command or an answer, then [_menuEvery], until nothing changed for
  /// [_menuIdle].
  static const _menuSoon = Duration(milliseconds: 400);
  static const _menuOpening = Duration(seconds: 3);
  static const _menuEvery = Duration(milliseconds: 1500);
  static const _menuIdle = Duration(minutes: 2);

  /// Each session's Live Activity state as last seen (packages/pocketterm_core/lib/live_activity.dart)
  /// and as last pushed; a change goes out once it has held for
  /// [_activityWait], so a quick busy flicker between turns stays home.
  final _activitySeen = <String, ActivityStatus>{};
  final _activitySent = <String, ActivityStatus>{};
  final _activitySoon = <String, Timer>{};
  static const _activityWait = Duration(seconds: 2);

  /// Phones show this session now (said so within [_gone]).
  bool watching(String sessionKey) => _phones.values.any((p) => p.session == sessionKey);

  /// How far a phone's clock is off this computer's while it's too far for
  /// anything from it to be taken (more than 5 minutes); null otherwise.
  Duration? get clockOff => _ch.clockOff;

  Future<void> start() async {
    _stopped = false;
    _ch.open();
    _subs
      ..add(_hub.ops.listen(_onOps))
      ..add(
        _hub.changes.listen((_) {
          _stateChanged();
          _activitiesChanged();
        }),
      )
      ..add(
        _hub.events.listen((e) {
          if (e is LiveAsked && (e.ask.isPlan || (e.ask.isApproval && e.session.agent == Agent.claude))) {
            unawaited(_followAsk(e.session.key, e.ask.id));
          }
        }),
      );
    // Away from the computer, an idle sleep would end the bridge; the lid
    // still sleeps it.
    await _host.setKeepAwake(on: true);
  }

  Future<void> stop() async {
    _stopped = true;
    for (final w in _menus.values) {
      w.wake();
    }
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _tick?.cancel();
    _tick = null;
    _flush?.cancel();
    _stateSoon?.cancel();
    for (final t in _activitySoon.values) {
      t.cancel();
    }
    _activitySoon.clear();
    await _host.setKeepAwake(on: false);
    _phones.clear();
    await _ch.close();
  }

  void _send(String event, Map<String, dynamic> payload) => unawaited(
    _ch.send(event, payload).then((_) {}, onError: (Object e) => debugPrint('PocketTerm: terminal bridge: $e')),
  );

  // ------------------------------------------------------------ phones

  void _onHello(Map<String, dynamic> p) {
    final from = p['from'] as String?;
    if (from == null) return;
    final window = p['window'] as String?;
    final before = _phones[from];
    _phones[from] = (session: p['session'] as String?, window: window, seen: DateTime.now());
    if (before == null) _onPhone?.call();
    // Every hello gets the state: it's how the phone knows the computer is there.
    _sentState = null;
    if (window != null && before?.window != window) _fullScreen.add(window);
    _tick ??= Timer.periodic(_tickEvery, (_) => unawaited(_poll()));
    unawaited(_poll(windows: true));
  }

  void _onSync(Map<String, dynamic> p) {
    final from = p['from'] as String?;
    if (from == null) return;
    final window = p['window'] as String?;
    if (window != null) {
      _fullScreen.add(window);
      unawaited(_poll());
      return;
    }
    final key = p['session'] as String?;
    final s = key == null ? null : _hub[key];
    if (s == null) return;
    // Pending ops would arrive after this answer, which covers them already.
    _flushNow();
    final log = s.log;
    final since = p['since'] as int? ?? 0;
    final reset = p['epoch'] != log.epoch || since > log.seq || since <= 0;
    final items = reset ? log.items : log.since(since);
    final chunks = chunkJson([for (final i in items) i.toJson()]);
    for (final (n, chunk) in chunks.indexed) {
      _send('items', {
        'to': from,
        'session': key,
        'epoch': log.epoch,
        'seq': log.seq,
        'reset': reset,
        'items': chunk,
        'last': n == chunks.length - 1,
        'older': log.older,
      });
    }
  }

  // ------------------------------------------------------------ live sessions

  void _onOps((LiveSession, List<LiveOp>) change) {
    final (s, ops) = change;
    if (!watching(s.key)) return;
    final pending = _pendingOps[s.key];
    if (pending != null && pending.epoch == s.log.epoch) {
      pending.ops.addAll(ops);
    } else {
      if (pending != null) _flushNow();
      _pendingOps[s.key] = (epoch: s.log.epoch, ops: [...ops]);
    }
    _flush ??= Timer(_batch, _flushNow);
  }

  void _flushNow() {
    _flush?.cancel();
    _flush = null;
    for (final MapEntry(:key, :value) in _pendingOps.entries) {
      for (final chunk in chunkJson([for (final op in value.ops) op.toJson()])) {
        _send('live', {'session': key, 'epoch': value.epoch, 'ops': chunk});
      }
    }
    _pendingOps.clear();
  }

  void _stateChanged() {
    if (_phones.isEmpty) return;
    _stateSoon ??= Timer(const Duration(milliseconds: 200), () {
      _stateSoon = null;
      _sendState();
    });
  }

  // ------------------------------------------------------------ Live Activities

  /// A session started or stopped working, asks or stopped asking, or went:
  /// the phones following it hear about it through the server (POST
  /// /v1/push/activity, [activityPush]), which does nothing for a session no
  /// phone follows. A session seen for the first time pushes nothing: no
  /// phone can follow it yet.
  void _activitiesChanged() {
    for (final s in _hub.sessions) {
      final status = activityStatus(busy: s.busy, ask: s.ask);
      final seen = _activitySeen[s.key];
      _activitySeen[s.key] = status;
      if (seen == null) {
        _activitySent[s.key] ??= status;
      } else if (seen != status) {
        _activitySoon[s.key]?.cancel();
        _activitySoon[s.key] = Timer(_activityWait, () => _pushActivity(s.key));
      }
    }
    for (final key in _activitySeen.keys.where((k) => _hub[k] == null).toList()) {
      if (_activitySeen[key]!.state == ActivityState.ended) continue;
      _activitySeen[key] = (state: ActivityState.ended, kind: null);
      _activitySoon[key]?.cancel();
      _activitySoon[key] = Timer(_activityWait, () => _pushActivity(key));
    }
  }

  void _pushActivity(String key) {
    _activitySoon.remove(key);
    final status = _activitySeen[key];
    if (status == null || status == _activitySent[key]) return;
    _activitySent[key] = status;
    if (status.state == ActivityState.ended) {
      _activitySeen.remove(key);
      _activitySent.remove(key);
    }
    unawaited(
      activityPush(_key, _desktopId, key, status)
          .then((body) => _server.push('activity', body))
          .then((_) {}, onError: (Object e) => debugPrint('PocketTerm: Live Activity push: $e')),
    );
  }

  /// What goes to POST /v1/push/activity for coding session [key] now at
  /// [status]: its routed key (for the server to find the phones following
  /// it; it never reaches the relay), state and kind in the clear for
  /// iPhones' Live Activities (Apple can't open anything sealed), and the
  /// same sealed with this computer's [channelKey] as `enc`, the only thing
  /// Android phones get, with this computer's push tag to find the key by.
  @visibleForTesting
  static Future<Map<String, Object?>> activityPush(
    ChannelKey channelKey,
    String desktopId,
    String key,
    ActivityStatus status,
  ) async {
    final session = routedKey(desktopId, key);
    final state = activityJson(status);
    return {
      'session': session,
      ...state,
      'tag': await pushTag(channelKey),
      'enc': await sealActivity(channelKey, desktopId, {
        'session': session,
        ...state,
        'since': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      }),
    };
  }

  void _sendState() {
    final state = fitState(
      {
        'windows': [for (final w in _windows) w.toJson()],
        'sessions': [for (final s in _hub.sessions) s.summary.toJson()],
        'projects': _projects,
        'roots': _roots(),
        'home': _terms.home,
        'agent': _agent().name,
        'opensIn': ?_opensIn,
        'terminals': [for (final s in phoneTerminals(_statuses)) s.toJson()],
        'error': ?_termError,
        if (_agentsNow case final a?) 'agents': AgentIntegration.toJsonAll(a),
      },
      watched: {for (final p in _phones.values) ?p.session},
    );
    final sessions = (state['sessions'] as List).cast<Map<String, dynamic>>();
    final key = jsonEncode({
      ...state,
      'sessions': [
        for (final s in sessions) {...s, 'seq': null, 'at': null},
      ],
    });
    final clock = jsonEncode([for (final s in sessions) (s['seq'], s['at']).toString()]);
    final now = DateTime.now();
    if (key == _sentState && (clock == _sentClock || now.difference(_sentAt) < _clockEvery)) return;
    _sentState = key;
    _sentClock = clock;
    _sentAt = now;
    _send('state', state);
  }

  /// [state] cut to at most [maxBytes] of JSON, least needed first: the slash commands of the sessions no phone
  /// shows ([watched]: the ones phones show), the queued prompts of those sessions to their start, the repositories
  /// in the Project folders that don't fit, every command's description, every session's commands, every queued
  /// prompt to its start, then windows from the end of the list. Many coding sessions (each with its agent's whole
  /// list of commands) or a Project folder with thousands of repositories would otherwise make a state the server
  /// can't take.
  @visibleForTesting
  static Map<String, dynamic> fitState(
    Map<String, dynamic> state, {
    required Set<String> watched,
    int maxBytes = _maxStateJson,
  }) {
    int size(Object? json) => utf8.encode(jsonEncode(json)).length;
    final text = jsonEncode(state);
    // UTF-8 takes at most three bytes per UTF-16 unit: most states are measured without encoding them.
    if (text.length * 3 <= maxBytes) return state;
    var total = utf8.encode(text).length;
    if (total <= maxBytes) return state;
    final out = {...state};
    void cmds(Object? Function(Map<String, dynamic> session, List<Object?> cmds) keep) {
      out['sessions'] = [
        for (final s in (out['sessions'] as List).cast<Map<String, dynamic>>())
          if (s['cmds'] case final List<Object?> c)
            {
              for (final e in s.entries)
                if (e.key != 'cmds') e.key: e.value,
              'cmds': ?keep(s, c),
            }
          else
            s,
      ];
      total = size(out);
    }

    cmds((s, c) => watched.contains(s['key']) ? c : null);
    // A queued prompt cut to its start: the phone shows it, but doesn't offer to edit it.
    void queues(bool Function(Map<String, dynamic> session) which) {
      if (total <= maxBytes) return;
      out['sessions'] = [
        for (final s in (out['sessions'] as List).cast<Map<String, dynamic>>())
          if (s['queue'] case final List<Object?> queue when which(s))
            {
              ...s,
              'queue': [
                for (final q in queue.cast<Map<String, dynamic>>())
                  if (q['t'] case final String t when t.length > _queuedStart)
                    {...q, 't': '${t.substring(0, _queuedStart)}…', 'c': true}
                  else
                    q,
              ],
            }
          else
            s,
      ];
      total = size(out);
    }

    queues((s) => !watched.contains(s['key']));
    if (out['projects'] case final List<Object?> projects when total > maxBytes) {
      var room = maxBytes - (total - size(projects));
      out['projects'] = [
        for (final p in projects)
          if ((room -= size(p) + 1) >= 0) p,
      ];
      total = size(out);
    }
    if (total > maxBytes) {
      cmds(
        (s, c) => [
          for (final cmd in c)
            if (cmd is List && cmd.isNotEmpty) [cmd.first],
        ],
      );
    }
    if (total > maxBytes) cmds((s, c) => null);
    queues((s) => true);
    if (total > maxBytes) {
      final windows = (out['windows'] as List).toList();
      while (total > maxBytes && windows.isNotEmpty) {
        total -= size(windows.removeLast()) + 1;
      }
      out['windows'] = windows;
    }
    return out;
  }

  /// How much of a queued prompt's text a state too big for it keeps.
  static const _queuedStart = 200;

  bool _askingAgents = false;

  /// Where the agents stand, in the background (it may run `claude`); a
  /// change goes out with the next state.
  void _askAgents() {
    final ask = _agents;
    if (ask == null || _askingAgents) return;
    _askingAgents = true;
    unawaited(
      ask()
          .then((a) {
            if (_stopped || mapEquals(a, _agentsNow)) return;
            _agentsNow = a;
            _stateChanged();
          }, onError: (Object e) => debugPrint('PocketTerm: coding agents: $e'))
          .whenComplete(() => _askingAgents = false),
    );
  }

  // ------------------------------------------------------------ terminals

  /// How often Settings-like statuses are read again while phones listen.
  static const _statusEvery = Duration(seconds: 30);

  Future<void> _poll({bool windows = false}) async {
    if (_polling) return;
    _polling = true;
    try {
      final now = DateTime.now();
      _phones.removeWhere((_, v) => now.difference(v.seen) > _gone);
      if (_phones.isEmpty) {
        _tick?.cancel();
        _tick = null;
        _screens.clear();
        return;
      }
      if (windows || _ticks++ % 3 == 0) {
        _windows = await _terms.windows();
        _relink();
        if (windows || _statusesAt == null || now.difference(_statusesAt!) > _statusEvery) {
          _statusesAt = now;
          _statuses = await _terms.statuses();
          _opensIn = _terms.describe(await _terms.opensIn(_app()));
        }
        _termError = terminalsError(_statuses, nothingShown: _windows.isEmpty && _hub.sessions.isEmpty);
        _askAgents();
        final roots = _roots();
        if (_projectsAt == null ||
            !listEquals(roots, _projectsRoots) ||
            now.difference(_projectsAt!) > const Duration(minutes: 5)) {
          _projectsAt = now;
          _projectsRoots = roots;
          unawaited(
            _terms.projects(roots).then((p) {
              // A scan of folders since changed (a slow one, of ~ say) is stale.
              if (!listEquals(roots, _projectsRoots)) return;
              _projects = p;
              _stateChanged();
            }),
          );
        }
      }
      _sendState();
      final watched = {for (final v in _phones.values) ?v.window};
      _screens.removeWhere((k, _) => !watched.contains(k));
      for (final w in watched) {
        final shown = _windows.where((x) => x.key == w).firstOrNull;
        if (shown == null || !shown.can(TermCap.read)) continue;
        try {
          await _sendScreen(w);
        } on TerminalException catch (e) {
          debugPrint('PocketTerm: terminal screen $w: $e');
        }
      }
    } finally {
      _polling = false;
    }
  }

  /// What the windows (and the sessions' windows) were at the last relink.
  String? _relinkedFor;

  /// Sessions without a window look for one again once the windows change
  /// (a Ghostty window's title follows its session's).
  void _relink() {
    if (_hub.sessions.every((s) => s.window != null)) return;
    final now = [
      for (final w in _windows) '${w.key}\t${w.title}\t${w.cwd}',
      for (final s in _hub.sessions) ?s.window,
    ].join('\n');
    if (now == _relinkedFor) return;
    _relinkedFor = now;
    unawaited(_hub.relink());
  }

  Future<void> _sendScreen(String window) async {
    final lines = fitLines(await _terms.lines(window, history: true), _maxScreenJson);
    final before = _screens[window];
    final full = before == null || _fullScreen.remove(window);
    if (!full && listEquals(before.lines, lines)) return;
    final v = (before?.v ?? 0) + 1;
    _screens[window] = (v: v, lines: lines);
    final diff = full ? null : ScreenDiff.between(before.lines, lines);
    if (diff != null) {
      _send('screen', {'window': window, 'v': v, 'diff': diff.toJson()});
      return;
    }
    _send('screen', {
      'window': window,
      'v': v,
      'lines': lines,
      if (before == null) 'colors': ?await _terms.colors(window),
    });
  }

  /// The newest of [lines] that take at most [maxBytes] as JSON (one line at least, itself cut to fit): what a
  /// screen sends whole. Its diffs are made between these too, so they're never larger.
  @visibleForTesting
  static List<String> fitLines(List<String> lines, int maxBytes) {
    var size = 2;
    var from = lines.length;
    while (from > 0) {
      final next = size + jsonBytes(lines[from - 1]) + 3;
      if (next > maxBytes) break;
      size = next;
      from--;
    }
    if (from == lines.length && lines.isNotEmpty) {
      // One line longer than all of it: its start, which is what a terminal shows of it.
      final last = lines.last;
      var end = last.length;
      while (end > 0 && jsonBytes(last.substring(0, end)) + 5 > maxBytes) {
        end = end * 3 ~/ 4;
      }
      return [last.substring(0, end)];
    }
    return from == 0 ? lines : lines.sublist(from);
  }

  // ------------------------------------------------------------ requests

  /// The phones' requests of the last minutes, by id.
  final _runs = RunLog();

  Future<void> _onRun(Map<String, dynamic> p) async {
    final id = p['id'] as String?;
    if (id == null || !_runs.start(id, (ran) => _send('ran', ran))) return;
    String? error;
    String? window;
    bool? busy;
    String? queued;
    try {
      switch (p['op']) {
        case 'send':
          await _terms.send(p['window'] as String, p['text'] as String? ?? '', enter: p['enter'] != false);
        case 'key':
          final pressed = p['window'] as String;
          await _terms.press(pressed, p['key'] as String);
          // Esc on a picker, say: see it go soon.
          for (final s in _hub.sessions) {
            if (s.window == pressed) _menus[s.key]?.arm();
          }
        case 'close':
          await _terms.close(p['window'] as String);
        case 'probe':
          busy = await screenChanges(_terms, p['window'] as String);
        case 'switch':
          final at = p['window'] as String;
          final agent = Agent.values.asNameMap()[p['agent']];
          if (agent == null) throw const TerminalException('Unknown coding agent.');
          // As the windows are now: it may have closed since the phone's list.
          final shown = (await _terms.windows()).where((w) => w.key == at).firstOrNull;
          if (shown == null) throw const TerminalException('That window has closed.');
          await switchToConversation(_terms, at, agent, tty: shown.tty);
        case 'launch':
          // An older phone says `omp` for "start the coding agent".
          final start = p['agent'] == true || p['omp'] == true;
          final host = await _terms.opensIn(_app());
          window = await _terms.launch(p['cwd'] as String, host: host, agent: start ? _agent() : null);
        case 'create':
          window = await _terms.launchNewProject(
            p['root'] as String,
            p['name'] as String? ?? '',
            roots: _roots(),
            host: await _terms.opensIn(_app()),
            agent: p['agent'] == true ? _agent() : null,
          );
        case 'prompt':
          queued = await _prompt(p);
        case 'queue':
          await _queue(p);
        case 'abort':
          await _hub.abort(p['session'] as String);
        case 'answer':
          await _answer(p);
        case 'older':
          await _hub.older(p['session'] as String);
        default:
          error = 'Unknown request.';
      }
    } on TerminalException catch (e) {
      error = e.message;
    } on LiveException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = 'The computer could not do that: $e';
    }
    final ran = {'id': id, 'error': ?error, 'window': ?window, 'busy': ?busy, 'queued': ?queued};
    _runs.done(id, ran);
    _send('ran', ran);
    unawaited(_poll(windows: const {'launch', 'create', 'close', 'switch'}.contains(p['op'])));
  }

  /// The phone's prompt, with its images and files fetched from Storage
  /// (and deleted): the id it waits under in the session's queue, if it waits there.
  Future<String?> _prompt(Map<String, dynamic> p) async {
    // The agent's own commands (/resume, /model …) are read by its editor,
    // not the model: type them into its window like the person would, and
    // follow the pickers they open.
    final text = (p['text'] as String? ?? '').trim();
    final key = p['session'] as String;
    final window = _hub[key]?.window;
    final paths = (p['images'] as List? ?? const []).cast<String>();
    final files = [
      for (final f in p['files'] as List? ?? const [])
        if (f case {'path': final String path, 'name': final String name})
          (path: path, name: name, mime: f['mime'] is String ? f['mime'] as String : '')
        else
          throw const LiveException('Bad file.'),
    ];
    final blobs = [...paths, for (final f in files) f.path];
    if (text.startsWith('/') && blobs.isEmpty) {
      // Sent as a prompt instead, the agent would take it for chat.
      if (cantCommand(_terms, window) case final why?) throw LiveException(why);
      await _terms.send(window!, text, enter: true);
      unawaited(_followMenus(key));
      return null;
    }
    for (final path in blobs) {
      if (!Server.isBlobPath(path)) throw const LiveException('Bad image or file path.');
    }
    try {
      final images = [for (final path in paths) await image(await openBlob(_key, path, await _server.getBlob(path)))];
      final opened = [
        for (final f in files)
          (name: f.name, mime: f.mime, bytes: await openBlob(_key, f.path, await _server.getBlob(f.path))),
      ];
      return await _hub.prompt(
        p['session'] as String,
        p['text'] as String? ?? '',
        images: images,
        files: opened,
        followUp: p['deliver'] == 'followUp',
        id: p['id'] as String?,
      );
    } finally {
      // The server drops one once it's downloaded; one that didn't come down goes too.
      for (final path in blobs) {
        unawaited(
          _server.deleteBlob(path).then((_) {}, onError: (Object e) => debugPrint('PocketTerm: blob cleanup: $e')),
        );
      }
    }
  }

  /// The phone's change to a session's queue (LiveHub).
  Future<void> _queue(Map<String, dynamic> p) async {
    final key = p['session'] as String;
    final item = p['item'] as String? ?? '';
    switch (p['do']) {
      case 'edit':
        _hub.editQueued(key, item, p['text'] as String? ?? '');
      case 'remove':
        _hub.removeQueued(key, item);
      case 'move':
        _hub.moveQueued(key, item, (p['to'] as num?)?.toInt() ?? 0);
      case 'send':
        await _hub.sendQueuedNow(key, item);
      case 'pause':
        _hub.pauseQueue(key, paused: true);
      case 'resume':
        _hub.pauseQueue(key, paused: false);
      default:
        throw const LiveException('Unknown change to the queue.');
    }
  }

  /// A phone's image or file as stored at [path], opened with [key] (the
  /// phone sealed it for that path: packages/pocketterm_core/lib/terminal_remote.dart).
  @visibleForTesting
  static Future<Uint8List> openBlob(ChannelKey key, String path, Uint8List sealed) async =>
      await openBytes(key, sealed, imageAad(path)) ??
      (throw const LiveException("The image or file didn't open: it wasn't sealed with this computer's key."));

  /// PNG and JPEG go as they are; on a Mac anything else (HEIC from Photos)
  /// becomes PNG first, which every model reads. Elsewhere (no `sips`) only
  /// PNG and JPEG do; the phone sends JPEG anyway.
  @visibleForTesting
  static Future<({Uint8List bytes, String mimeType})> image(Uint8List bytes, {bool? macos}) async {
    bool starts(List<int> magic) =>
        bytes.length > magic.length && Iterable<int>.generate(magic.length).every((i) => bytes[i] == magic[i]);
    if (starts(const [0x89, 0x50, 0x4E, 0x47])) return (bytes: bytes, mimeType: 'image/png');
    if (starts(const [0xFF, 0xD8, 0xFF])) return (bytes: bytes, mimeType: 'image/jpeg');
    if (!(macos ?? Platform.isMacOS)) throw const LiveException('This computer reads PNG and JPEG images only.');
    final dir = await Directory.systemTemp.createTemp('pocketterm-image');
    try {
      final input = File('${dir.path}/in')..writeAsBytesSync(bytes);
      final png = '${dir.path}/out.png';
      final conv = await Process.run('/usr/bin/sips', ['-s', 'format', 'png', input.path, '--out', png]);
      if (conv.exitCode != 0) throw const LiveException("The computer couldn't read that image.");
      return (bytes: await File(png).readAsBytes(), mimeType: 'image/png');
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// Follows on its screen an ask whose end the agent's extension can't
  /// see: a plan review (dismissed with Esc at the computer), or Claude Code's
  /// approval (its plugin hears only once the tool has run). A plan's
  /// options are published once it has rendered, and again when its cursor
  /// moves. An ask gone from the screen twice running goes from the hub too.
  Future<void> _followAsk(String key, String id) async {
    if (!_followed.add(id)) return;
    try {
      var misses = 0;
      for (var n = 0; !_stopped; n++) {
        final opening = n < _askOpening;
        await Future<void>.delayed(opening ? _askSoon : _askEvery);
        final s = _hub[key];
        final ask = s?.ask;
        final window = s?.window;
        if (s == null || ask == null || ask.id != id || window == null || !_terms.can(window, TermCap.read)) return;
        final String screen;
        try {
          screen = await _terms.plainScreen(window);
        } on TerminalException catch (e) {
          debugPrint('PocketTerm: ask on screen $window: $e');
          if (opening) continue;
          return;
        }
        final review = ask.isPlan ? parsePlanReview(screen, agent: s.agent) : null;
        if (review != null) {
          misses = 0;
          if (!listEquals(review.options, ask.options) || review.current != ask.selected) {
            _hub.updateAsk(
              key,
              id,
              LiveAsk.plan(id, title: ask.title, options: review.options, selected: review.current),
            );
          }
        } else if (askOnScreen(ask, screen, agent: s.agent)) {
          misses = 0;
        } else if (!opening && ++misses >= 2) {
          _hub.updateAsk(key, id, null);
          return;
        }
      }
    } finally {
      _followed.remove(id);
    }
  }

  /// Picks the plan review option [p] names, once the screen still lists it
  /// there. Claude Code's rows go by their number. omp's cursor moves from
  /// where it is now (someone may have moved it at the computer) down or up to
  /// it, and Enter goes once the screen shows the cursor there: ↓/↑ skip an
  /// option omp has disabled, which plain text doesn't show, and a cursor
  /// that won't land on the option means omp won't take it.
  Future<void> _answerPlan(String window, LiveAsk ask, Agent agent, Map<String, dynamic> p) async {
    final answers = [for (final a in p['answers'] as List? ?? const []) LiveAnswer.fromJson((a as Map).cast())];
    final pick = answers.length == 1 && answers.single.picks.length == 1 ? answers.single.picks.single : -1;
    if (pick < 0) throw const LiveException('Pick one option.');
    for (var tries = 0; tries < 4; tries++) {
      final review = parsePlanReview(await _terms.plainScreen(window), agent: agent);
      if (review == null) {
        throw const LiveException(
          "The plan review isn't ready on the computer's screen. Open the screen to answer it there.",
        );
      }
      if (pick >= review.options.length || (pick < ask.options.length && review.options[pick] != ask.options[pick])) {
        throw const LiveException('The plan review on the computer has changed. Open the screen to answer it there.');
      }
      if (agent == Agent.claude) {
        await _terms.pressKeys(window, [claudeRowKey(pick)]);
        return;
      }
      if (review.current == pick) {
        await _terms.pressKeys(window, const ['enter']);
        return;
      }
      await _terms.pressKeys(window, menuKeys(review.current, pick, enter: false));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw const LiveException("omp won't move to that option. Open the screen to answer it there.");
  }

  /// Follows session [key]'s screen for the pickers a slash command opens
  /// (/resume, /model, /tree …) and publishes each as a menu ask: its rows,
  /// cursor and search as they change, a new ask for each new picker (one
  /// can open another), none once it has gone two reads running. Read often
  /// for a while after the command or an answer, then less; it stops when
  /// no picker is up after that while, or nothing changed for [_menuIdle].
  /// The agent's own asks come first: a picker never replaces one. Again for a
  /// session already followed just reads sooner.
  Future<void> _followMenus(String key) async {
    final known = _menus[key];
    if (known != null) {
      known.arm();
      return;
    }
    final w = _menus[key] = _MenuWatch();
    String? published;
    try {
      var misses = 0;
      while (!_stopped) {
        var now = DateTime.now();
        if (now.difference(w.changed) > _menuIdle) break;
        final opening = now.difference(w.armed) < _menuOpening;
        if (published == null && !opening) break;
        await w.sleep(opening ? _menuSoon : _menuEvery);
        final s = _hub[key];
        final window = s?.window;
        if (s == null || window == null || _stopped || !_terms.can(window, TermCap.read)) break;
        final current = s.ask;
        // The agent asks something itself, or the picker's ask went (a new session's hello).
        if (current != null && current.id != published) break;
        if (current == null && published != null) published = null;
        final String screen;
        try {
          screen = await _terms.plainScreen(window);
        } on TerminalException catch (e) {
          debugPrint('PocketTerm: picker $window: $e');
          break;
        }
        now = DateTime.now();
        final menu = parseMenu(screen);
        if (menu == null) {
          if (published != null && ++misses >= 2) {
            _hub.updateAsk(key, published, null);
            published = null;
            w.query = '';
          }
          continue;
        }
        misses = 0;
        final same = current != null && current.title == menu.title;
        final ask = LiveAsk.menu(
          same ? current.id : 'menu-${++_menuIds}',
          title: menu.title,
          items: menu.items,
          selected: menu.current,
          filter: menu.filter,
        );
        if (same && jsonEncode(ask.toJson()) == jsonEncode(current.toJson())) continue;
        if (!_hub.updateAsk(key, published, ask)) break;
        if (!same) w.query = '';
        published = ask.id;
        w.changed = now;
      }
    } finally {
      if (identical(_menus[key], w)) _menus.remove(key);
      if (published != null) _hub.updateAsk(key, published, null);
    }
  }

  /// Answers a picker: a pick moves its cursor from where it is now to the
  /// row (once that row still reads the same) and presses Enter; typed text
  /// becomes its search, by typing what's new and erasing only what was
  /// typed from the phone before (Backspace on an empty search can mean
  /// something else: /resume deletes the session). The picker is then read
  /// again soon, as is whatever it opens next.
  Future<void> _answerMenu(String key, String window, LiveAsk ask, Map<String, dynamic> p) async {
    final answers = [for (final a in p['answers'] as List? ?? const []) LiveAnswer.fromJson((a as Map).cast())];
    final answer = answers.length == 1 ? answers.single : null;
    final w = _menus[key];
    final menu = parseMenu(await _terms.plainScreen(window));
    if (w == null || menu == null || menu.title != ask.title) {
      throw const LiveException("The menu isn't on the computer's screen anymore. Open the screen to see what is.");
    }
    final query = answer?.custom;
    if (query != null && answer!.picks.isEmpty) {
      if (!menu.filter) throw const LiveException("This menu can't be searched.");
      var same = 0;
      while (same < query.length && same < w.query.length && query[same] == w.query[same]) {
        same++;
      }
      await _terms.pressKeys(window, [for (var k = same; k < w.query.length; k++) 'backspace']);
      if (same < query.length) await _terms.type(window, query.substring(same));
      w
        ..query = query
        ..arm();
      return;
    }
    final pick = answer != null && answer.picks.length == 1 ? answer.picks.single : -1;
    if (pick < 0 || pick >= ask.items.length) throw const LiveException('Pick one item.');
    var shown = menu;
    for (var tries = 0; tries < 4; tries++) {
      if (pick >= shown.items.length || shown.items[pick].label != ask.items[pick].label) {
        throw const LiveException('The menu on the computer has changed. Pick again.');
      }
      if (shown.current == pick) {
        await _terms.pressKeys(window, const ['enter']);
        w
          ..query = ''
          ..arm();
        return;
      }
      await _terms.pressKeys(window, menuKeys(shown.current, pick, enter: false));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final again = parseMenu(await _terms.plainScreen(window));
      if (again == null || again.title != ask.title) {
        throw const LiveException("The menu isn't on the computer's screen anymore. Open the screen to see what is.");
      }
      shown = again;
    }
    throw const LiveException("The agent won't move to that item. Open the screen to pick it there.");
  }

  /// Answers the agent's question, approval, plan review or a picker with
  /// keystrokes in its terminal window, once its screen shows that it is
  /// up: only where the terminal can both show its screen and press keys.
  Future<void> _answer(Map<String, dynamic> p) async {
    final s = _hub[p['session'] as String];
    final ask = s?.ask;
    if (s == null || ask == null || ask.id != p['ask']) throw const LiveException('That is no longer being asked.');
    final window = s.window;
    if (window == null) {
      throw const LiveException(
        "PocketTerm can't tell which terminal window this session runs in: answer it on the computer.",
      );
    }
    if (cantAnswer(_terms, window) case final why?) throw LiveException(why);
    if (ask.isPlan) return await _answerPlan(window, ask, s.agent, p);
    if (ask.isMenu) return await _answerMenu(s.key, window, ask, p);
    final steps = answerKeys(
      ask,
      answers: [for (final a in p['answers'] as List? ?? const []) LiveAnswer.fromJson((a as Map).cast())],
      approve: p['approve'] == true,
      agent: s.agent,
    );
    if (!askOnScreen(ask, await _terms.plainScreen(window), agent: s.agent)) {
      throw const LiveException("The question isn't on the computer's screen. Open the screen to answer it there.");
    }
    for (final step in steps) {
      switch (step) {
        case Keys(:final keys):
          await _terms.pressKeys(window, keys);
        case Typed(:final text):
          await _terms.type(window, text);
        case Settle():
          await Future<void>.delayed(const Duration(milliseconds: 450));
      }
    }
    await _answered(s, window, ask);
  }

  /// Waits for the agent to take the answer: its extension drops the ask
  /// (omp's when the tool ends, Claude Code's once the tool has run), or the
  /// dialog leaves the screen, which comes first for an approved long
  /// command; the ask goes then. omp's dialog still waiting on its Submit
  /// tab gets one more Enter: keys that came while it redrew were dropped.
  Future<void> _answered(LiveSession s, String window, LiveAsk ask) async {
    bool pending() => _hub[s.key]?.ask?.id == ask.id;
    var nudged = false;
    var gone = 0;
    for (var i = 0; i < 16 && pending(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (i < 2 || !pending()) continue;
      final screen = await _terms.plainScreen(window);
      if (!askOnScreen(ask, screen, agent: s.agent)) {
        if (++gone < 2) continue;
        _hub.updateAsk(s.key, ask.id, null);
        return;
      }
      gone = 0;
      if (i >= 7 && !nudged && s.agent == Agent.omp && _submitTab.hasMatch(screen)) {
        nudged = true;
        await _terms.pressKeys(window, const ['enter']);
      }
    }
    if (pending()) {
      throw LiveException(
        "${s.agent.label} hasn't taken the answer yet. Open the screen to check what it's waiting for.",
      );
    }
  }

  /// omp's ask dialog on its last tab, the answers listed above Submit.
  static final _submitTab = RegExp(r'Review answers[\s\S]*❯\s*Submit');
}

/// The terminals the phone hears about: the installed ones, and tmux
/// either way (its note says how to get it).
List<TermStatus> phoneTerminals(List<TermStatus> statuses) => [
  for (final s in statuses)
    if (s.state != TermState.missing || s.id == 'tmux') s,
];

/// The phone's error line: only when [nothingShown] (no window, no session)
/// and no terminal is usable, what the first one needing setup says.
String? terminalsError(List<TermStatus> statuses, {required bool nothingShown}) =>
    nothingShown && !statuses.any((s) => s.usable)
    ? statuses.where((s) => s.state == TermState.setup).map((s) => s.note).firstOrNull
    : null;

/// Why an agent's ask in [window] can't be answered from the phone (null:
/// it can): answering reads the screen and presses keys.
String? cantAnswer(Terminals terms, String window) {
  final read = terms.can(window, TermCap.read);
  if (read && terms.can(window, TermCap.keys)) return null;
  final label = terms.hostOf(window)?.label ?? 'This terminal';
  return "$label can't ${read ? 'press keys' : 'show its screen'}, so answer this on the computer. "
      '${(terms.tmux?.installed ?? false) ? 'Sessions you start from the phone run in tmux there, which can.' : 'With tmux installed (Homebrew: brew install tmux, or MacPorts: sudo port install tmux), sessions you start from the phone can.'}';
}

/// Why a slash command for the session in [window] can't be run from the
/// phone (null: it can): the agent's editor reads commands, so they're typed
/// into its terminal window.
String? cantCommand(Terminals terms, String? window) {
  if (window == null) {
    return "Slash commands are typed into the agent's terminal window, and PocketTerm can't reach this one: it isn't in "
        'kitty, tmux, WezTerm or Ghostty. Run it on the computer.';
  }
  if (terms.can(window, TermCap.line)) return null;
  return "${terms.hostOf(window)?.label ?? 'This terminal'} can't take a typed line, so run the command on the computer.";
}

/// Whether [window]'s screen changes over [gap]: the agent in it is at work (a spinner, a clock, output). Where the
/// terminal can't show its screen (Ghostty), its title, read a few times over [gap]: an agent at work spins there too.
Future<bool> screenChanges(Terminals terms, String window, {Duration gap = const Duration(seconds: 2)}) async {
  if (!terms.can(window, TermCap.read)) {
    Future<String?> title() async => (await terms.windows()).where((w) => w.key == window).firstOrNull?.title;
    final first = await title();
    if (first == null) throw const TerminalException('That window has closed.');
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(gap ~/ 4);
      if (await title() case final t? when t != first) return true;
    }
    return false;
  }
  final before = await terms.plainScreen(window);
  await Future<void>.delayed(gap);
  return await terms.plainScreen(window) != before;
}

/// Switches [agent] in [window] (an agent window no live session claims) to reporting its session to PocketTerm.
/// omp quits and starts again on the same conversation: Esc stops a run, Ctrl+C empties its editor (Ctrl+U clears
/// one line only), Ctrl+D on an empty editor quits; once the foreground program on [tty] isn't omp anymore (or
/// after [noTty], where the terminal tells no tty) the shell gets `omp -c`. Claude Code reloads its plugins in place.
/// Where [tty] tells, nothing is pressed unless [agent] still runs there: the agent may have quit since the phone
/// last looked, and Ctrl+D would end the shell (and close the window) instead.
Future<void> switchToConversation(
  Terminals terms,
  String window,
  Agent agent, {
  String tty = '',
  Duration settle = const Duration(milliseconds: 400),
  Duration quitFor = const Duration(seconds: 8),
  Duration noTty = const Duration(seconds: 2),
  Duration pollEvery = const Duration(milliseconds: 250),
}) async {
  if (!terms.can(window, TermCap.keys) || !terms.can(window, TermCap.type)) {
    throw TerminalException(
      "${terms.hostOf(window)?.label ?? 'This terminal'} can't press keys and type here, so switch it on the computer.",
    );
  }
  Future<bool> runs() async => Agent.ofProgram((await terms.snapshot()).foreground(tty)?.program ?? '') == agent;
  if (tty.isNotEmpty && !await runs()) {
    throw TerminalException("${agent.label} isn't running in that window anymore.");
  }
  switch (agent) {
    case Agent.claude:
      await terms.send(window, '/reload-plugins', enter: true);
    case Agent.omp:
      await terms.pressKeys(window, const ['esc']);
      await Future<void>.delayed(settle);
      await terms.pressKeys(window, const ['ctrl+c']);
      await Future<void>.delayed(settle);
      await terms.pressKeys(window, const ['ctrl+d']);
      if (tty.isEmpty) {
        await Future<void>.delayed(noTty);
      } else {
        final until = DateTime.now().add(quitFor);
        while (await runs()) {
          if (DateTime.now().isAfter(until)) {
            throw TerminalException("omp didn't quit. Quit it on the computer, then run ${agent.command} -c there.");
          }
          await Future<void>.delayed(pollEvery);
        }
      }
      await terms.send(window, '${agent.command} -c', enter: true);
  }
}

/// One session's screen followed for pickers: when it was last told to look
/// soon (a command, an answer, a key) and last saw a change, and what the
/// phone typed into the current picker's search.
class _MenuWatch {
  DateTime armed = DateTime.now();
  DateTime changed = DateTime.now();
  String query = '';
  Completer<void>? _wake;

  /// Reads soon again, for a while.
  void arm() {
    armed = changed = DateTime.now();
    wake();
  }

  void wake() {
    final c = _wake;
    _wake = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Waits [d], or less if woken.
  Future<void> sleep(Duration d) {
    final c = _wake = Completer<void>();
    final timer = Timer(d, wake);
    return c.future.whenComplete(timer.cancel);
  }
}

/// The requests phones sent lately, by id, and their answers. A phone that heard no answer (its app went to the
/// background, the network dropped) sends the same request again under the same id: it gets the answer it missed
/// (marked `repeat`) instead of the request running twice; one still running is answered once it ends.
class RunLog {
  RunLog({this.keep = const Duration(minutes: 2), DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// How long a request's answer is kept for a repeat.
  final Duration keep;
  final DateTime Function() _clock;
  final _runs = <String, ({DateTime at, Map<String, dynamic>? ran})>{};

  /// Whether request [id] is new, and then taken as running; for one that already ran, its answer goes to [again].
  bool start(String id, void Function(Map<String, dynamic> ran) again) {
    final now = _clock();
    _runs.removeWhere((_, r) => now.difference(r.at) > keep);
    if (_runs[id] case final r?) {
      if (r.ran case final ran?) again({...ran, 'repeat': true});
      return false;
    }
    _runs[id] = (at: now, ran: null);
    return true;
  }

  /// Request [id] ended with [ran].
  void done(String id, Map<String, dynamic> ran) => _runs[id] = (at: _clock(), ran: ran);
}
