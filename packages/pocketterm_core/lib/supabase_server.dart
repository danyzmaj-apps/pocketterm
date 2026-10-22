import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/server_client.dart';

/// PocketTerm set up on a Supabase project (apps/pocketterm-desktop/supabase):
/// the same REST paths as the PocketTerm server under
/// `<project>/functions/v1/pocketterm`, so everything but the live channel
/// is [PocketTermServerClient]'s. The live channel is Supabase Realtime
/// broadcast on private topics: the function mints this device a Realtime
/// token for 10 minutes at a time (POST /v1/live/token), which Realtime
/// checks against the devices still signed in on every join and refresh.
class SupabaseServerClient extends PocketTermServerClient {
  SupabaseServerClient(super.backend, {required super.tokens});

  /// Computer only: a setup link for another computer (POST /v1/setup/new).
  /// The one before stops working; nobody is signed out.
  Future<Uri> newSetupLink() async {
    final answer = await request('POST', '/v1/setup/new');
    if (answer case {'setup': final String setup}) return backend.linkWithSetup(setup);
    throw const ServerException(500, 'internal', "The server didn't send a setup link.");
  }

  /// A Realtime token for this device, when it runs out, and the project's
  /// publishable key (Realtime takes it with every connection).
  Future<LiveToken> liveToken() async {
    final answer = await request('POST', '/v1/live/token');
    if (answer case {'token': final String token, 'expires': final int expires, 'apikey': final String apikey}) {
      return (token: token, expires: DateTime.fromMillisecondsSinceEpoch(expires * 1000), apikey: apikey);
    }
    throw const ServerException(500, 'internal', "The server didn't send a live channel token.");
  }

  @override
  Future<LiveSocket> connectLive() async {
    final first = await liveToken();
    final url = Uri.parse(backend.url);
    final ws = await WebSocket.connect(
      url
          .replace(
            scheme: url.scheme == 'https' ? 'wss' : 'ws',
            path: '/realtime/v1/websocket',
            queryParameters: {'apikey': first.apikey, 'vsn': '1.0.0'},
          )
          .toString(),
    ).timeout(const Duration(seconds: 20));
    return RealtimeLive(this, ws, first);
  }
}

typedef LiveToken = ({String token, DateTime expires, String apikey});

/// Supabase Realtime (Phoenix channels, protocol 1.0.0) as a [LiveSocket]:
/// PROTOCOL.md's frames in and out. A `join` joins the private channel
/// `realtime:<topic>` with this device's token, `send` broadcasts, `ping`
/// is Phoenix's heartbeat. The token is renewed a minute before it runs
/// out; a refusal (the device was signed out) closes this with 4003. A join
/// Realtime refuses, or a channel it closes, closes this too (the live
/// channel connects again), after asking the server whether the sign-in
/// still holds. `pt.left` on a topic (someone was signed out) asks it too.
@visibleForTesting
class RealtimeLive implements LiveSocket {
  RealtimeLive(this._server, this._ws, LiveToken token) : _token = token {
    _sub = _ws.listen(_receive, onDone: _gone, onError: (Object _) {});
    _renewLater();
  }

  final SupabaseServerClient _server;
  final WebSocket _ws;
  late final StreamSubscription<Object?> _sub;
  final _out = StreamController<String>();
  LiveToken _token;
  Timer? _renew;
  int? _code;
  int _ref = 0;

  /// The topics joined (or joining) and their join refs.
  final _joins = <String, String>{};

  /// Join refs waiting for Realtime's answer, and their topics.
  final _joining = <String, String>{};

  /// Heartbeat refs waiting for an answer.
  final _beats = <String>{};

  @override
  Stream<String> get frames => _out.stream;

  @override
  int? get closeCode => _code ?? _ws.closeCode;

  String _next() => '${++_ref}';

  void _phx(String topic, String event, Map<String, Object?> payload, {String? ref, String? joinRef}) {
    if (_out.isClosed) return;
    _ws.add(jsonEncode({'topic': topic, 'event': event, 'payload': payload, 'ref': ref, 'join_ref': ?joinRef}));
  }

  void _emit(Map<String, Object?> frame) {
    if (!_out.isClosed) _out.add(jsonEncode(frame));
  }

  @override
  void add(String frame) {
    final Object? f;
    try {
      f = jsonDecode(frame);
    } on FormatException {
      return;
    }
    switch (f) {
      case {'t': 'join', 'topic': final String topic}:
        final ref = _next();
        _joins[topic] = ref;
        _joining[ref] = topic;
        _phx(
          'realtime:$topic',
          'phx_join',
          {
            'config': {
              'broadcast': {'self': false, 'ack': false},
              'presence': {'key': '', 'enabled': false},
              'private': true,
            },
            'access_token': _token.token,
          },
          ref: ref,
          joinRef: ref,
        );
      case {'t': 'send', 'topic': final String topic, 'event': final String event, 'payload': final Object? payload}:
        final joinRef = _joins[topic];
        if (joinRef == null || _joining.containsValue(topic)) {
          return _emit({'t': 'error', 'error': 'not_joined', 'message': 'Join $topic first.'});
        }
        _phx(
          'realtime:$topic',
          'broadcast',
          {'type': 'broadcast', 'event': event, 'payload': payload},
          ref: _next(),
          joinRef: joinRef,
        );
      case {'t': 'leave', 'topic': final String topic}:
        final joinRef = _joins.remove(topic);
        if (joinRef != null) _phx('realtime:$topic', 'phx_leave', {}, ref: _next(), joinRef: joinRef);
      case {'t': 'ping'}:
        final ref = _next();
        _beats.add(ref);
        _phx('phoenix', 'heartbeat', {}, ref: ref);
    }
  }

  void _receive(Object? data) {
    if (data is! String) return;
    final Object? m;
    try {
      m = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (m is! Map) return;
    final topic = (m['topic'] as String? ?? '').replaceFirst('realtime:', '');
    final payload = m['payload'];
    switch (m['event']) {
      case 'phx_reply' when _beats.remove(m['ref']):
        _emit({'t': 'pong'});
      case 'phx_reply' when _joining.containsKey(m['ref']):
        final joined = _joining.remove(m['ref'])!;
        if (payload is Map && payload['status'] == 'ok') return _emit({'t': 'joined', 'topic': joined});
        debugPrint('PocketTerm: Realtime refused $joined: ${payload is Map ? payload['response'] : payload}');
        _refused();
      case 'broadcast' when _joins.containsKey(topic):
        if (payload case {'event': final String event, 'payload': final Object? inner}) {
          // Someone was signed out: this device asks whether it was.
          if (event == 'pt.left') return unawaited(_server.recheck());
          _emit({'t': 'msg', 'topic': topic, 'event': event, 'payload': inner});
        }
      case 'phx_error' || 'phx_close' when _joins.containsKey(topic):
        debugPrint('PocketTerm: Realtime closed $topic (${m['event']})');
        _refused();
      case 'system' when payload is Map && payload['status'] == 'error':
        debugPrint('PocketTerm: Realtime: ${payload['message']}');
        _refused();
    }
  }

  /// Realtime turned this device away or closed its channel (an old token,
  /// a device signed out meanwhile): ask the server, then connect again.
  void _refused() {
    unawaited(_server.recheck());
    unawaited(close());
  }

  void _renewLater() {
    final wait = _token.expires.difference(DateTime.now()) - const Duration(minutes: 1);
    _renew = Timer(wait < const Duration(seconds: 10) ? const Duration(seconds: 10) : wait, _renewNow);
  }

  Future<void> _renewNow() async {
    try {
      _token = await _server.liveToken();
    } on ServerException catch (e) {
      if (e.status == 401) return await close(4003);
      _renew = Timer(const Duration(seconds: 15), _renewNow);
      return;
    }
    if (_out.isClosed) return;
    _joins.forEach((topic, joinRef) {
      _phx('realtime:$topic', 'access_token', {'access_token': _token.token}, ref: _next(), joinRef: joinRef);
    });
    _renewLater();
  }

  void _gone() {
    _renew?.cancel();
    if (!_out.isClosed) unawaited(_out.close());
  }

  @override
  Future<void> close([int code = 1000]) async {
    _code ??= code == 1000 ? null : code;
    _renew?.cancel();
    if (!_out.isClosed) unawaited(_out.close());
    await _sub.cancel();
    await _ws.close(1000).then((_) {}, onError: (Object _) {});
  }
}
