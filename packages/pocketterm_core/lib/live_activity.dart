import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal_remote.dart';

// Coding sessions followed on the phone: iPhone Live Activities (Lock Screen,
// Dynamic Island; apps/pocketterm-mobile/ios/Shared/SessionActivity.swift) and Android ongoing
// notifications (SessionActivities.kt). The app starts one when a prompt goes
// out from the phone or on "Follow", and updates it itself while it's in
// front; otherwise the Mac tells the server (POST /v1/push/activity) and
// the server pushes to the token: the activity's own on iOS,
// the phone's FCM token (one per followed session) on Android. A push
// carries only what's below, never text: a Live Activity push can't be
// decrypted on the iPhone, so the relay would read it.

enum ActivityState { working, needs, done, ended }

/// What the agent waits for, when it needs you.
enum ActivityKind { question, approval, plan }

typedef ActivityStatus = ({ActivityState state, ActivityKind? kind});

/// What a session's activity shows: its agent asks something, works, or has
/// stopped (done). A picker the person opened from the phone isn't the agent
/// asking.
ActivityStatus activityStatus({required bool busy, LiveAsk? ask}) => switch (ask?.kind) {
  AskKind.questions => (state: ActivityState.needs, kind: ActivityKind.question),
  AskKind.approval => (state: ActivityState.needs, kind: ActivityKind.approval),
  AskKind.plan => (state: ActivityState.needs, kind: ActivityKind.plan),
  AskKind.menu || null => (state: busy ? ActivityState.working : ActivityState.done, kind: null),
};

/// The same for a session in the Mac's state; null: it's gone (ended).
ActivityStatus summaryStatus(LiveSummary? s) =>
    s == null ? (state: ActivityState.ended, kind: null) : activityStatus(busy: s.busy, ask: s.ask);

/// The `state` and `kind` of a push or a channel call.
Map<String, dynamic> activityJson(ActivityStatus s) => {'state': s.state.name, 'kind': ?s.kind?.name};

/// Phone: the sessions followed on [TerminalRemote]'s computer, kept current
/// from it while the app is in front, and their push tokens handed to the
/// server. The native side and the server know a session by its routedKey
/// (lib/live.dart), this by its own key.
class LiveActivities extends ChangeNotifier {
  LiveActivities(this._server, this._remote) {
    _remote.addListener(_sync);
    unawaited(_load());
  }

  final Server _server;
  final TerminalRemote _remote;

  /// Followed sessions: what each activity shows and since when. Null: one
  /// still running from before this launch, which only pushes have updated.
  final _shown = <String, ({ActivityStatus status, DateTime since})?>{};

  /// When a prompt last went to a session: its agent may not have reported busy
  /// yet, so for a while "done" is taken to be from before it.
  final _prompted = <String, DateTime>{};
  static const _promptWait = Duration(seconds: 30);

  /// Sessions whose push token the server has, as `routed key\ntoken`: on
  /// Android one token serves every followed session.
  final _registered = <String>{};

  bool following(String key) => _shown.containsKey(key);

  String _routed(String key) => routedKey(_remote.desktopId, key);

  /// [routed]'s session key if it's on this computer.
  String? _mine(String routed) {
    final r = splitRoutedKey(routed);
    return r != null && r.desktop == _remote.desktopId ? r.key : null;
  }

  /// The activities running from before (and tokens iOS handed over before
  /// Dart listened); the server learns every token, whichever computer its
  /// session is on.
  Future<void> _load() async {
    try {
      for (final a in await Native.liveActivities()) {
        if (splitRoutedKey(a.key) == null) continue;
        if (_mine(a.key) case final key?) _shown.putIfAbsent(key, () => null);
        final token = a.token;
        if (token != null) unawaited(_register(a.key, token));
      }
    } on MissingPluginException {
      return; // Not on a phone.
    }
    _sync();
    notifyListeners();
  }

  /// Starts following [key], shown as [title]; [status] if known better
  /// than the Mac's state (a prompt just sent). False: Live Activities are
  /// off for PocketTerm, or the session isn't there. Throws
  /// [TooManyActivities] when iOS shows as many as it allows.
  Future<bool> follow(String key, {required String title, ActivityStatus? status}) async {
    final s = _remote.session(key);
    if (s == null) return false;
    final shown = (status: status ?? summaryStatus(s), since: DateTime.now());
    final started = await Native.startActivity(
      key: _routed(key),
      title: title,
      project: s.cwd.split(RegExp(r'[\\/]')).lastWhere((p) => p.isNotEmpty, orElse: () => s.cwd),
      state: shown.status.state.name,
      kind: shown.status.kind?.name,
      since: shown.since,
    );
    if (started) {
      _shown[key] = shown;
      notifyListeners();
    }
    return started;
  }

  /// A prompt went to [key]: it's working now, followed from here on, if
  /// the phone can show one more.
  Future<void> prompted(String key, {required String title}) async {
    _prompted[key] = DateTime.now();
    const working = (state: ActivityState.working, kind: null);
    if (!following(key)) {
      try {
        await follow(key, title: title, status: working);
      } on TooManyActivities {
        return; // The prompt went all the same.
      }
    } else if (_shown[key]?.status.state != ActivityState.working) {
      await _show(key, working);
    }
  }

  /// The person stops following [key]: the activity goes at once.
  Future<void> stop(String key) async {
    _shown.remove(key);
    notifyListeners();
    await Native.endActivity(_routed(key), immediate: true);
  }

  /// From the native side: activityToken, activityEnded, for a [routedKey].
  void onNative(String event, Map<Object?, Object?> args) {
    final routed = args['key'] as String?;
    final token = args['token'] as String?;
    if (routed == null || splitRoutedKey(routed) == null) return;
    switch (event) {
      case 'activityToken' when token != null:
        unawaited(_register(routed, token));
      case 'activityEnded':
        if (token != null) {
          _registered.remove('$routed\n$token');
          unawaited(_push('activity_end', {'token': token, 'session': routed}));
        }
        if (_mine(routed) case final key?) {
          _shown.remove(key);
          _prompted.remove(key);
          notifyListeners();
        }
    }
  }

  Future<void> _register(String routed, String token) async {
    if (!_registered.add('$routed\n$token')) return;
    // An Android phone's plain end names the session only by its tag (sessionTag), which the server can't make.
    final ref = pushPlatform == 'android' ? await _ref(routed) : null;
    final body = {'token': token, 'session': routed, 'platform': pushPlatform, 'ref': ?ref};
    if (!await _push('activity_register', body)) _registered.remove('$routed\n$token');
  }

  /// [routed]'s [sessionTag] under its computer's key; null without the key (nothing from it would open anyway).
  Future<String?> _ref(String routed) async {
    final desktop = splitRoutedKey(routed)?.desktop;
    final key = desktop == _remote.desktopId
        ? _remote.key
        : ChannelKey.tryParse((await Native.channelKeys().catchError((Object _) => <String, String>{}))[desktop]);
    return key == null ? null : await sessionTag(key, routed);
  }

  Future<bool> _push(String action, Map<String, Object?> body) async {
    try {
      await _server.push(action, body);
      return true;
    } on Object catch (e) {
      debugPrint('PocketTerm: Live Activity $action: $e');
      return false;
    }
  }

  Future<void> _show(String key, ActivityStatus status) async {
    final since = DateTime.now();
    _shown[key] = (status: status, since: since);
    await Native.updateActivity(key: _routed(key), state: status.state.name, kind: status.kind?.name, since: since);
  }

  /// The Mac's state changed: each followed session's activity follows it.
  void _sync() {
    final macState = _remote.online && !_remote.fromCache;
    for (final key in _shown.keys.toList()) {
      final s = _remote.session(key);
      if (s == null) {
        if (!macState) continue;
        _shown.remove(key);
        _prompted.remove(key);
        unawaited(Native.endActivity(_routed(key)));
        notifyListeners();
        continue;
      }
      final status = summaryStatus(s);
      final shown = _shown[key];
      final prompted = _prompted[key];
      if (status.state == ActivityState.done && prompted != null && DateTime.now().difference(prompted) < _promptWait) {
        continue;
      }
      if (status.state != ActivityState.done) _prompted.remove(key);
      if (shown == null) {
        // Pushes have kept it current; its timer stays.
        _shown[key] = (status: status, since: DateTime.now());
      } else if (shown.status != status) {
        unawaited(_show(key, status));
      }
    }
  }

  @override
  void dispose() {
    _remote.removeListener(_sync);
    super.dispose();
  }
}
