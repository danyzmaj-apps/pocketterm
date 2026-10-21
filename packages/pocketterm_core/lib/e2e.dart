import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

// End-to-end encryption between a computer and its phones (docs/ARCHITECTURE.md,
// SECURITY.md). Each computer has one channel key, made on the computer and
// handed to a phone only in its QR code; the server relays what it seals and
// can't read it. Sealed bytes are nonce (12) || ciphertext || tag (16),
// AES-256-GCM, with additional data naming what they are, so a message can't
// be moved to another computer, event, image or push.

/// A computer (its id, lib/desktops.dart) and its channel key, as the
/// computer's QR code hands them to a phone.
typedef ComputerKey = ({String desktop, ChannelKey key});

/// One computer's channel key: 32 random bytes.
@immutable
class ChannelKey {
  ChannelKey(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != length) throw ArgumentError('A channel key is $length bytes, not ${bytes.length}.');
  }

  /// A new random key.
  factory ChannelKey.generate() {
    final r = Random.secure();
    return ChannelKey([for (var i = 0; i < length; i++) r.nextInt(256)]);
  }

  /// A key as [toBase64] or [toBase64Url] write it, with or without padding;
  /// null when it isn't one.
  static ChannelKey? tryParse(String? text) {
    if (text == null) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(text.trim().replaceAll('+', '-').replaceAll('/', '_')));
      return bytes.length == length ? ChannelKey(bytes) : null;
    } on FormatException {
      return null;
    }
  }

  static const length = 32;

  final Uint8List bytes;

  /// Standard base64 with padding: how the phone's native side keeps it.
  String toBase64() => base64Encode(bytes);

  /// URL-safe base64 without padding: how a setup link carries it.
  String toBase64Url() => base64UrlEncode(bytes).replaceAll('=', '');

  @override
  bool operator ==(Object other) => other is ChannelKey && listEquals(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'ChannelKey(…)';
}

/// The additional data of a live channel [event] on [topic].
String channelAad(String topic, String event) => 'pocketterm/v1|$topic|$event';

/// The additional data of an image stored at [path].
String imageAad(String path) => 'pocketterm/v1|image|$path';

/// The additional data of a push from computer [desktopId].
String pushAad(String desktopId) => 'pocketterm/v1|push|$desktopId';

const _nonceLength = 12;
const _tagLength = 16;

// Looked up on each use: cryptography_flutter puts the operating system's
// AES-GCM in place when the app starts.
AesGcm get _aes => AesGcm.with256bits();

/// [plain] sealed with [key] for [aad]: nonce || ciphertext || tag.
Future<Uint8List> sealBytes(ChannelKey key, List<int> plain, String aad) async {
  final box = await _aes.encrypt(plain, secretKey: SecretKey(key.bytes), aad: utf8.encode(aad));
  return box.concatenation();
}

/// What [sealed] holds, or null when it wasn't sealed with [key] for
/// [aad] (another key, another purpose, changed on the way, too short).
Future<Uint8List?> openBytes(ChannelKey key, List<int> sealed, String aad) async {
  if (sealed.length < _nonceLength + _tagLength) return null;
  try {
    final box = SecretBox.fromConcatenation(sealed, nonceLength: _nonceLength, macLength: _tagLength, copy: false);
    final plain = await _aes.decrypt(box, secretKey: SecretKey(key.bytes), aad: utf8.encode(aad));
    return Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    return null;
  }
}

/// The version an envelope's `v` says.
const envelopeVersion = 1;

/// [message] as it goes on the live channel:
/// `{"v":1,"n":"<base64 nonce>","c":"<base64 ciphertext and tag>"}`.
Future<Map<String, dynamic>> sealEnvelope(ChannelKey key, Map<String, dynamic> message, String aad) async {
  final sealed = await sealBytes(key, utf8.encode(jsonEncode(message)), aad);
  return {
    'v': envelopeVersion,
    'n': base64Encode(sealed.sublist(0, _nonceLength)),
    'c': base64Encode(sealed.sublist(_nonceLength)),
  };
}

/// The message in [envelope], or why it was dropped: `version` (not one
/// this reads), `sealed` (not sealed with [key] for [aad]), `json` (not a
/// JSON object inside).
Future<({Map<String, dynamic>? message, String? drop})> openEnvelope(
  ChannelKey key,
  Map<String, dynamic> envelope,
  String aad,
) async {
  if (envelope['v'] != envelopeVersion) return (message: null, drop: 'version');
  final n = envelope['n'];
  final c = envelope['c'];
  if (n is! String || c is! String) return (message: null, drop: 'sealed');
  final List<int> nonce;
  final List<int> rest;
  try {
    nonce = base64Decode(n);
    rest = base64Decode(c);
  } on FormatException {
    return (message: null, drop: 'sealed');
  }
  if (nonce.length != _nonceLength) return (message: null, drop: 'sealed');
  final plain = await openBytes(key, [...nonce, ...rest], aad);
  if (plain == null) return (message: null, drop: 'sealed');
  try {
    final message = jsonDecode(utf8.decode(plain));
    if (message is Map<String, dynamic>) return (message: message, drop: null);
  } on FormatException {
    // Below.
  }
  return (message: null, drop: 'json');
}

/// A new message id: 16 random URL-safe characters.
String newMessageId() {
  final r = Random.secure();
  return base64UrlEncode([for (var i = 0; i < 12; i++) r.nextInt(256)]);
}

/// Drops opened messages that are stale or seen before: a `ts` (ms since
/// epoch) more than [window] off this clock, and, where [requireMid], a
/// missing `mid` or one seen in the last [remember].
class ReplayGuard {
  ReplayGuard({
    this.requireMid = false,
    this.window = const Duration(minutes: 5),
    this.remember = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final bool requireMid;
  final Duration window;
  final Duration remember;
  final DateTime Function() _clock;
  final _seen = <String, DateTime>{};

  /// Null when [message] may go on, else why not: `time` or `replay`.
  String? check(Map<String, dynamic> message) {
    final now = _clock();
    final ts = message['ts'];
    if (ts is! int || (now.millisecondsSinceEpoch - ts).abs() > window.inMilliseconds) return 'time';
    _seen.removeWhere((_, at) => now.difference(at) > remember);
    final mid = message['mid'];
    if (mid is! String || mid.isEmpty) return requireMid ? 'replay' : null;
    if (_seen.containsKey(mid)) return 'replay';
    _seen[mid] = now;
    return null;
  }
}
