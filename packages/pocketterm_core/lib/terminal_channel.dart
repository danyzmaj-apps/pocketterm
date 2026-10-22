import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal.dart' show TerminalException;

/// Receives one message, opened: its fields as the sender gave them.
typedef TopicHandler = void Function(Map<String, dynamic> payload);

/// Seals what goes out on [topic] with the computer's [key] and opens what
/// comes in (lib/e2e.dart). Each message gets a `ts`, a random `mid`, this
/// seal's `ep` (random, new for each seal: each start of a sender) and
/// `seq` (1, 2, 3 …). What doesn't open or the [ReplayGuard] refuses
/// (stale, seen before, out of order) is dropped and logged once per kind.
/// The guard is the computer's for this run of the app
/// ([ReplayGuard.of]) unless one is given (`guard`, or a fresh one on a
/// test `clock`).
class ChannelSeal {
  ChannelSeal(this.key, this.topic, {this.name = 'channel', ReplayGuard? guard, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _guard = guard ?? (clock == null ? ReplayGuard.of(topic) : ReplayGuard(clock: clock));

  final ChannelKey key;
  final String topic;

  /// Who this is, in the log.
  final String name;
  final DateTime Function() _clock;
  final ReplayGuard _guard;
  final _logged = <String>{};
  final String _epoch = newMessageId();
  int _seq = 0;

  /// [payload] of [event], as it goes on the topic. Seal in the order sent:
  /// a receiver drops a `seq` below one it already took. The payload goes
  /// whole under `m`, beside the envelope's `ts`, `mid`, `ep` and `seq`, so
  /// a payload's own keys of those names (an items catch-up's `seq`) stay.
  Future<Map<String, dynamic>> seal(String event, Map<String, dynamic> payload) => sealEnvelope(key, {
    'm': payload,
    'ts': _clock().millisecondsSinceEpoch,
    'mid': newMessageId(),
    'ep': _epoch,
    'seq': ++_seq,
  }, channelAad(topic, event));

  /// What [wire] (an [event] off the topic) says: the payload [seal] put in;
  /// null when it's dropped.
  Future<Map<String, dynamic>?> open(String event, Map<String, dynamic> wire) async {
    final (:message, :drop) = await openEnvelope(key, wire, channelAad(topic, event));
    final why = drop ?? _guard.check(message!);
    if (why != null) {
      if (_logged.add('$event $why')) debugPrint('PocketTerm: $name: dropped $event ($why); more alike go unlogged');
      return null;
    }
    final payload = message!['m'];
    if (payload is! Map) {
      if (_logged.add('$event shape')) debugPrint('PocketTerm: $name: dropped $event (no payload)');
      return null;
    }
    return payload.cast<String, dynamic>();
  }
}

/// A computer's [topic] (its id) on the server's WebSocket (GET /v1/ws,
/// packages/pocketterm_server/PROTOCOL.md), kept joined while open.
/// Everything on it is sealed with the computer's key ([ChannelSeal]): the
/// server only relays envelopes; handlers get the opened messages, in the
/// order they came.
///
/// Whenever it isn't joined (no connection, the server went away or
/// restarted, a join nobody answers, two pings without a pong) this
/// connects again after 1 s, 2 s, 4 s … up to [_maxWait]. A close with 4003
/// (this device was revoked or left) ends the sign-in instead
/// ([PocketTermServerClient.refused]).
class TerminalChannel {
  TerminalChannel(
    this._server,
    this.topic,
    this._handlers, {
    required ChannelKey key,
    required this.name,
    this.onJoined,
  }) : _seal = ChannelSeal(key, topic, name: name);

  final PocketTermServerClient _server;

  /// The topic joined: the computer's id.
  final String topic;
  final Map<String, TopicHandler> _handlers;
  final ChannelSeal _seal;

  /// Who this is, in the log.
  final String name;

  /// The channel joined (true), or stopped being joined (false).
  final void Function({required bool joined})? onJoined;

  /// Sealing and opening take a moment (the system's AES-GCM, through a
  /// platform channel); messages still go out and are handled in order.
  Future<void> _outbox = Future.value();
  Future<void> _inbox = Future.value();

  static const _firstWait = Duration(seconds: 1);
  static const _maxWait = Duration(seconds: 30);

  /// How long a join may take before it counts as stuck.
  static const _stuck = Duration(seconds: 20);

  /// How often to ping the server; two without a pong and the link is dead.
  static const _pingEvery = Duration(seconds: 25);

  WebSocket? _ws;
  StreamSubscription<Object?>? _sub;
  bool _open = false;
  bool _joined = false;
  Timer? _retry;
  Timer? _joinWait;
  Timer? _ping;
  int _unanswered = 0;
  Duration _wait = _firstWait;

  /// Bumped by [open] and [close]: a connection still on its way from
  /// before must not make a second one.
  int _gen = 0;

  bool get joined => _joined;

  void open() {
    if (_open) return;
    _open = true;
    final gen = ++_gen;
    debugPrint('PocketTerm: $name: open');
    _wait = _firstWait;
    unawaited(_connect(gen));
  }

  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _gen++;
    debugPrint('PocketTerm: $name: close');
    _retry?.cancel();
    _retry = null;
    _drop();
  }

  /// The largest frame the server takes (packages/pocketterm_server/PROTOCOL.md); a larger one would close the
  /// socket, and every message after it would be lost until the next join.
  static const maxFrameBytes = 256 * 1024;

  /// Drops [event] if the channel isn't joined: whoever waits on an answer
  /// times out, and the other side catches up after the next join. A
  /// message too big for the server fails with a [TerminalException] and
  /// goes nowhere; the connection stays.
  Future<void> send(String event, Map<String, dynamic> payload) {
    if (_ws == null || !_joined) return Future.value();
    final out = _outbox.then((_) async {
      final sealed = await _seal.seal(event, payload);
      final ws = _ws;
      if (ws == null || !_joined) return;
      // Sealed, it's all ASCII: its length is its size in bytes.
      final frame = jsonEncode({'t': 'send', 'topic': topic, 'event': event, 'payload': sealed});
      if (frame.length > maxFrameBytes) {
        debugPrint('PocketTerm: $name: $event not sent: ${frame.length} bytes, over $maxFrameBytes');
        throw const TerminalException('That is too big to send in one go. Send it in smaller parts.');
      }
      ws.add(frame);
    });
    _outbox = out.then((_) {}, onError: (Object _) {});
    return out;
  }

  void _receive(String event, TopicHandler handler, Map<String, dynamic> wire) {
    _inbox = _inbox.then((_) async {
      try {
        if (await _seal.open(event, wire) case final message?) handler(message);
      } on Object catch (e) {
        debugPrint('PocketTerm: $name: $event: $e');
      }
    });
  }

  Future<void> _connect(int gen) async {
    bool stale() => !_open || gen != _gen;
    final WebSocket ws;
    try {
      ws = await _server.connectSocket();
    } on Object catch (e) {
      if (stale()) return;
      // Refused at the door: maybe the token stopped working.
      unawaited(_server.verify());
      return _again(null, '$e');
    }
    if (stale()) return unawaited(ws.close(1000).then((_) {}, onError: (Object _) {}));
    _ws = ws;
    _sub = ws.listen((data) => _frame(ws, data), onDone: () => _closed(ws), onError: (Object _) {});
    ws.add(jsonEncode({'t': 'join', 'topic': topic}));
    _joinWait = Timer(_stuck, () => _again(ws, 'no answer to the join'));
    _unanswered = 0;
    _ping = Timer.periodic(_pingEvery, (_) {
      if (_unanswered >= 2) return _again(ws, 'no answer to the pings');
      _unanswered++;
      ws.add(jsonEncode({'t': 'ping'}));
    });
  }

  void _frame(WebSocket ws, Object? data) {
    if (!identical(ws, _ws) || data is! String) return;
    final Object? frame;
    try {
      frame = jsonDecode(data);
    } on FormatException {
      return;
    }
    switch (frame) {
      case {'t': 'joined', 'topic': final String t} when t == topic:
        _joinWait?.cancel();
        _wait = _firstWait;
        _setJoined(joined: true);
      case {'t': 'msg', 'topic': final String t, 'event': final String event, 'payload': final Map<String, dynamic> p}
          when t == topic:
        if (_handlers[event] case final handler?) _receive(event, handler, p);
      case {'t': 'pong'}:
        _unanswered = 0;
      case {'t': 'error', 'error': final String error}:
        debugPrint('PocketTerm: $name: the server said $error');
        // Joined on the server no more (it restarted under us).
        if (error == 'not_joined') _again(ws, error);
    }
  }

  void _closed(WebSocket ws) {
    if (!identical(ws, _ws)) return;
    if (ws.closeCode == 4003) {
      debugPrint('PocketTerm: $name: this device was signed out on the server');
      _drop();
      unawaited(_server.refused());
      return;
    }
    _again(ws, 'closed${ws.closeCode == null ? '' : ' (${ws.closeCode})'}');
  }

  /// Leaves the connection there is, if any.
  void _drop() {
    _joinWait?.cancel();
    _ping?.cancel();
    _joinWait = _ping = null;
    _setJoined(joined: false);
    final ws = _ws;
    _ws = null;
    unawaited(_sub?.cancel());
    _sub = null;
    if (ws != null) unawaited(ws.close(1000).then((_) {}, onError: (Object e) => debugPrint('PocketTerm: $name: $e')));
  }

  /// [ws] (null: none was made) is no good: a new one after a while.
  void _again(WebSocket? ws, String why) {
    if (!_open || _retry != null || !identical(ws, _ws)) return;
    _drop();
    final wait = _wait;
    _wait = _wait * 2 > _maxWait ? _maxWait : _wait * 2;
    debugPrint('PocketTerm: $name: joining again in ${wait.inSeconds} s ($why)');
    final gen = _gen;
    _retry = Timer(wait, () {
      _retry = null;
      if (gen == _gen) unawaited(_connect(gen));
    });
  }

  void _setJoined({required bool joined}) {
    if (_joined == joined) return;
    _joined = joined;
    debugPrint('PocketTerm: $name: ${joined ? 'joined' : 'not joined'}');
    onJoined?.call(joined: joined);
  }
}
