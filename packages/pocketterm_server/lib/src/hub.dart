import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The largest WebSocket frame the server takes (256 KiB); a larger one closes the socket with 1009.
const int maxFrameBytes = 256 * 1024;

/// How many topics one socket may join.
const maxTopicsPerSocket = 32;

/// How many WebSockets one device may have open at once (a phone opens one per computer it shows).
const maxSocketsPerDevice = 64;

/// How often the server pings every socket (a socket whose pong is missing by the next ping is closed).
const pingInterval = Duration(seconds: 25);

/// Close code for a device that was revoked or left: its token no longer works.
const closeRevoked = 4003;

final _topic = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');
final _event = RegExp(r'^[A-Za-z0-9_.:-]{1,64}$');

/// One connected WebSocket of device [device].
class _Socket {
  _Socket(this.ws, this.device);

  final WebSocket ws;
  final String device;
  final Set<String> topics = {};

  /// Sends [text] unless the peer is closing. The hub closes a socket only after removing it, so nothing is
  /// ever added after its own close.
  void send(String text) {
    if (ws.closeCode == null) ws.add(text);
  }
}

/// The live channel: sockets joined to topics, each message passed to the topic's other sockets untouched.
class Hub {
  final Set<_Socket> _sockets = {};
  final Map<String, Set<_Socket>> _topics = {};

  /// How many sockets device [device] has open.
  int socketsOf(String device) => _sockets.where((s) => s.device == device).length;

  /// Serves [ws], opened by device [device], until it closes.
  void add(WebSocket ws, String device) {
    ws.pingInterval = pingInterval;
    final socket = _Socket(ws, device);
    _sockets.add(socket);
    ws.listen(
      (data) => _onFrame(socket, data),
      onDone: () => _remove(socket),
      onError: (Object _) => _remove(socket),
      cancelOnError: true,
    );
  }

  /// Closes every socket of [device] (revoked or left).
  void closeDevice(String device) {
    for (final s in _sockets.where((s) => s.device == device).toList()) {
      _remove(s);
      unawaited(s.ws.close(closeRevoked, 'revoked'));
    }
  }

  /// Closes every socket: with 1001 when the server stops, [closeRevoked] when everything was erased.
  Future<void> closeAll({int code = WebSocketStatus.goingAway, String reason = 'server stopping'}) async {
    final all = _sockets.toList()..forEach(_remove);
    await Future.wait(all.map((s) => s.ws.close(code, reason)));
  }

  void _remove(_Socket s) {
    if (!_sockets.remove(s)) return;
    for (final t in s.topics) {
      final members = _topics[t];
      members?.remove(s);
      if (members != null && members.isEmpty) _topics.remove(t);
    }
    s.topics.clear();
  }

  void _onFrame(_Socket s, Object? data) {
    // Frames already buffered when the socket was dropped (revoked, frame too large) go nowhere.
    if (!_sockets.contains(s)) return;
    final size = data is String ? data.length : (data is List<int> ? data.length : 0);
    // A string's length counts UTF-16 units; its UTF-8 size is at least that, and checked exactly below
    // only when close to the limit.
    if (size > maxFrameBytes ||
        (data is String && size > maxFrameBytes ~/ 3 && utf8.encode(data).length > maxFrameBytes)) {
      _remove(s);
      unawaited(s.ws.close(WebSocketStatus.messageTooBig, 'frame over $maxFrameBytes bytes'));
      return;
    }
    Object? frame;
    try {
      frame = jsonDecode(data is String ? data : utf8.decode(data! as List<int>));
    } on Object {
      frame = null;
    }
    if (frame is! Map<String, dynamic>) return _error(s, 'bad_frame', 'A frame is one JSON object.');
    final topic = frame['topic'];
    switch (frame['t']) {
      case 'ping':
        s.send('{"t":"pong"}');
      case 'join':
        if (topic is! String || !_topic.hasMatch(topic)) return _error(s, 'bad_frame', 'topic is missing or bad.');
        if (!s.topics.contains(topic) && s.topics.length >= maxTopicsPerSocket) {
          return _error(s, 'too_many_topics', 'A socket joins at most $maxTopicsPerSocket topics.');
        }
        s.topics.add(topic);
        (_topics[topic] ??= {}).add(s);
        s.send(jsonEncode({'t': 'joined', 'topic': topic}));
      case 'leave':
        if (topic is! String) return _error(s, 'bad_frame', 'topic is missing.');
        if (s.topics.remove(topic)) {
          final members = _topics[topic]!..remove(s);
          if (members.isEmpty) _topics.remove(topic);
        }
      case 'send':
        final event = frame['event'];
        if (topic is! String || !_topic.hasMatch(topic)) return _error(s, 'bad_frame', 'topic is missing or bad.');
        if (event is! String || !_event.hasMatch(event)) return _error(s, 'bad_frame', 'event is missing or bad.');
        if (!s.topics.contains(topic)) return _error(s, 'not_joined', 'Join $topic before sending to it.');
        final out = jsonEncode({'t': 'msg', 'topic': topic, 'event': event, 'payload': frame['payload']});
        for (final other in _topics[topic]!) {
          if (!identical(other, s)) other.send(out);
        }
      default:
        _error(s, 'bad_frame', 't must be join, send, leave or ping.');
    }
  }

  void _error(_Socket s, String code, String message) =>
      s.send(jsonEncode({'t': 'error', 'error': code, 'message': message}));
}
