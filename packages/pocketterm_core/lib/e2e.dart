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

/// The additional data of a followed session's update (Android) from
/// computer [desktopId].
String activityAad(String desktopId) => 'pocketterm/v1|activity|$desktopId';

/// What a push says about the computer that sealed it, instead of its id:
/// the first 8 bytes of HMAC-SHA256([key], `pocketterm/v1|push-tag`) in
/// base64url without padding (11 characters). The same for every push from
/// that computer and meaningless without its key: the phone finds the key
/// whose tag it is, the relay and the push services can't tell which computer it is.
Future<String> pushTag(ChannelKey key) => _tag(key, 'pocketterm/v1|push-tag', 8);

/// What a push says about coding session [routedKey] (`<desktop id>/<key>`):
/// the first 16 bytes of HMAC-SHA256([key], `pocketterm/v1|push-session|<routedKey>`)
/// in base64url without padding (22 characters). It lets a newer push for the
/// session replace an older one (collapse id) and, on Android, names the session
/// a plain end is for, without telling anyone on the way which session it is.
Future<String> sessionTag(ChannelKey key, String routedKey) => _tag(key, 'pocketterm/v1|push-session|$routedKey', 16);

Future<String> _tag(ChannelKey key, String what, int length) async {
  final mac = await Hmac.sha256().calculateMac(utf8.encode(what), secretKey: SecretKey(key.bytes));
  return base64UrlEncode(mac.bytes.sublist(0, length)).replaceAll('=', '');
}

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

/// Drops opened live channel messages that are stale, seen before or out
/// of order. Every message carries `ts` (ms since epoch), `mid` (a random
/// id), `ep` (its sender's epoch: random, new each time a sender starts)
/// and `seq` (that sender's count, from 1). Dropped: a `ts` more than
/// [window] off this clock or before [notBefore] (sent before this guard
/// existed, so before this app started: nothing here remembers it), a
/// `mid` seen in the last [remember], and a `seq` at or below the last one
/// taken for its `ep`. Memory stays bounded: epochs and ids go after
/// [remember] unseen, and past [maxEpochs] / [maxIds] the oldest go first
/// (a message that old is out of [window] by then anyway, or caught by the
/// other check).
class ReplayGuard {
  ReplayGuard({
    this.window = const Duration(minutes: 5),
    this.remember = const Duration(minutes: 10),
    this.maxEpochs = 64,
    this.maxIds = 10000,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       notBefore = (clock ?? DateTime.now)();

  /// One guard per computer ([topic], its id) for this whole run of the
  /// app: it outlives each channel, so a channel made again (the bridge
  /// restarted, another sign-in) still knows what it took.
  static ReplayGuard of(String topic) => _byTopic.putIfAbsent(topic, ReplayGuard.new);
  static final _byTopic = <String, ReplayGuard>{};

  final Duration window;

  /// How long an id or an epoch is kept after it was last seen; at least
  /// twice [window], so a message taken once can't come back in time.
  final Duration remember;
  final int maxEpochs;
  final int maxIds;

  /// When this guard started: messages from before it are dropped.
  final DateTime notBefore;
  final DateTime Function() _clock;

  // Both in the order last seen, oldest first.
  final _ids = <String, DateTime>{};
  final _epochs = <String, ({int seq, DateTime at})>{};

  /// Null when [message] may go on (and it is remembered), else why not:
  /// `time`, `replay` or `order`.
  String? check(Map<String, dynamic> message) {
    final now = _clock();
    final ts = message['ts'];
    if (ts is! int ||
        (now.millisecondsSinceEpoch - ts).abs() > window.inMilliseconds ||
        ts < notBefore.millisecondsSinceEpoch) {
      return 'time';
    }
    final mid = message['mid'];
    final ep = message['ep'];
    final seq = message['seq'];
    if (mid is! String || mid.isEmpty || ep is! String || ep.isEmpty || seq is! int || seq < 1) return 'replay';
    _ids.removeWhere((_, at) => now.difference(at) > remember);
    _epochs.removeWhere((_, e) => now.difference(e.at) > remember);
    if (_ids.containsKey(mid)) return 'replay';
    final last = _epochs.remove(ep);
    if (last != null && seq <= last.seq) {
      _epochs[ep] = last;
      return 'order';
    }
    _epochs[ep] = (seq: seq, at: now);
    _ids[mid] = now;
    while (_epochs.length > maxEpochs) {
      _epochs.remove(_epochs.keys.first);
    }
    while (_ids.length > maxIds) {
      _ids.remove(_ids.keys.first);
    }
    return null;
  }
}

/// A push [notice] (`{title, body, session?, state?}`) from computer
/// [desktopId], sealed with its [key] for the phones (AAD [pushAad]), in
/// base64: the `enc` the server forwards. Inside it gains `ts` (ms since
/// epoch) and `id` (random), so a phone can refuse an old or repeated one.
Future<String> sealNotice(ChannelKey key, String desktopId, Map<String, Object?> notice) =>
    _sealPush(key, notice, pushAad(desktopId));

/// A followed session's [activity] (`{session, state, since, kind?}`) from
/// computer [desktopId] for Android phones, sealed like [sealNotice] (also
/// with `ts` and `id` inside) but for [activityAad].
Future<String> sealActivity(ChannelKey key, String desktopId, Map<String, Object?> activity) =>
    _sealPush(key, activity, activityAad(desktopId));

Future<String> _sealPush(ChannelKey key, Map<String, Object?> body, String aad) async => base64Encode(
  await sealBytes(
    key,
    utf8.encode(jsonEncode({...body, 'ts': DateTime.now().millisecondsSinceEpoch, 'id': newMessageId()})),
    aad,
  ),
);
