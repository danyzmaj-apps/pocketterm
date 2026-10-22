import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// The publisher's push relay (it holds the APNs key and the Firebase service account), on the publisher's
/// own server. A fork with its own keys points `PUSH_RELAY_URL` and `PUSH_RELAY_KEY` elsewhere.
final Uri defaultRelay = Uri.parse('https://push.danyzmaj.com/v1/push');

/// The publisher's relay's X25519 public key (base64 of 32 bytes): every request is sealed to it.
const defaultRelayKey = 'VjwMi0GtvYoVT3Q9FlENy/dQOVe0vuqU8K4t+fw3fHc=';

/// The relay public key in [text] (base64 of 32 bytes), or null when it isn't one.
List<int>? parseRelayKey(String text) {
  try {
    final bytes = base64.decode(text.trim());
    return bytes.length == 32 ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// Which relay key a request is sealed to: the first 11 characters of the public key's base64. A relay that
/// holds a new key and the one before (while servers move over) opens with the one it names.
String relayKeyId(List<int> publicKey) => base64.encode(publicKey).substring(0, 11);

final _x25519 = X25519();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _aes = AesGcm.with256bits();
final List<int> _info = utf8.encode('pocketterm-relay/v1');

/// [plain] sealed to the relay's [publicKey] (v1): a fresh ephemeral X25519 key, HKDF-SHA256 (salt: the
/// ephemeral public key then the relay's; info `pocketterm-relay/v1`) and AES-256-GCM. The body:
/// `{"v": 1, "kid", "epk", "n", "c"}`, base64; kid is [relayKeyId], c the ciphertext then the 16-byte tag. Only
/// the relay can open it (apps/pocketterm-relay/src/seal.ts).
Future<Map<String, Object>> sealForRelay(List<int> publicKey, List<int> plain) async {
  final ephemeral = await _x25519.newKeyPair();
  final epk = (await ephemeral.extractPublicKey()).bytes;
  final shared = await _x25519.sharedSecretKey(
    keyPair: ephemeral,
    remotePublicKey: SimplePublicKey(publicKey, type: KeyPairType.x25519),
  );
  final key = await _hkdf.deriveKey(secretKey: shared, nonce: [...epk, ...publicKey], info: _info);
  final box = await _aes.encrypt(plain, secretKey: key);
  return {
    'v': 1,
    'kid': relayKeyId(publicKey),
    'epk': base64.encode(epk),
    'n': base64.encode(box.nonce),
    'c': base64.encode([...box.cipherText, ...box.mac.bytes]),
  };
}

/// One push waiting for the relay.
class _Push {
  _Push(this.body, this.key, this.added);

  Map<String, dynamic> body;
  final String? key;
  final DateTime added;
  int attempts = 0;
  DateTime notBefore = DateTime.fromMillisecondsSinceEpoch(0);
}

/// Posts pushes to the relay, sealed to its key (whatever carries them sees only ciphertext), in the background:
/// [send] queues and returns at once, so no request to the server waits on the relay. A relay that can't be
/// reached, answers 5xx or 429 is tried again after 2 s, 4 s, 8 s … (429: after its Retry-After), at most
/// [maxAttempts] times and for [maxAge]; anything else is final. At most [maxQueued] wait (past it the oldest
/// goes), [concurrency] at a time, and a newer push with the same key replaces a waiting one and never overtakes
/// one on its way (a Live Activity's states arrive in order).
class Relay {
  Relay(this.url, this.publicKey, {this.log, this.onGone, this.firstRetry = const Duration(seconds: 2)});

  static const maxQueued = 500;
  static const maxAttempts = 5;
  static const maxAge = Duration(minutes: 2);
  static const concurrency = 4;

  final Uri url;

  /// The relay's X25519 public key (32 bytes).
  final List<int> publicKey;
  final void Function(String)? log;

  /// The relay said the phone behind a token is gone (410): forget it.
  final void Function(String token)? onGone;

  /// How long the first retry waits; each next one twice as long.
  final Duration firstRetry;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..maxConnectionsPerHost = concurrency;

  final _queue = Queue<_Push>();
  final _sending = <String>{};
  var _active = 0;
  Timer? _wake;
  Completer<void>? _idle;
  var _closed = false;
  final _logged = <String, DateTime>{};

  /// Pushes waiting or on their way.
  int get pending => _queue.length + _active;

  /// Queues [body] for the relay. A waiting push with the same [key] is replaced by it.
  void send(Map<String, dynamic> body, {String? key}) {
    if (_closed) return;
    if (key != null) {
      for (final p in _queue) {
        if (p.key == key) {
          p
            ..body = body
            ..attempts = 0
            ..notBefore = DateTime.fromMillisecondsSinceEpoch(0);
          return _pump();
        }
      }
    }
    if (_queue.length >= maxQueued) {
      _queue.removeFirst();
      _logOnce('full', 'push queue full ($maxQueued): dropped the oldest');
    }
    _queue.add(_Push(body, key, DateTime.now()));
    _pump();
  }

  /// Completes once nothing waits or is on its way, or after [timeout].
  Future<void> idle({Duration timeout = const Duration(seconds: 30)}) {
    if (pending == 0) return Future.value();
    return (_idle ??= Completer<void>()).future.timeout(timeout, onTimeout: () {});
  }

  void _pump() {
    _wake?.cancel();
    _wake = null;
    if (_closed) return;
    final now = DateTime.now();
    DateTime? next;
    final ready = <_Push>[];
    for (final p in _queue) {
      if (_active + ready.length >= concurrency) break;
      if (p.key != null && (_sending.contains(p.key) || ready.any((r) => r.key == p.key))) continue;
      if (p.notBefore.isAfter(now)) {
        if (next == null || p.notBefore.isBefore(next)) next = p.notBefore;
        continue;
      }
      ready.add(p);
    }
    for (final p in ready) {
      _queue.remove(p);
      _active++;
      if (p.key != null) _sending.add(p.key!);
      unawaited(_deliver(p));
    }
    if (next != null && _active < concurrency) _wake = Timer(next.difference(now), _pump);
    if (pending == 0) {
      _idle?.complete();
      _idle = null;
    }
  }

  Future<void> _deliver(_Push p) async {
    final (status, retryAfter) = await _post(p.body);
    _active--;
    if (p.key != null) _sending.remove(p.key);
    if (_closed) return;
    p.attempts++;
    if (status == 410) {
      final token = p.body['token'];
      if (token is String) onGone?.call(token);
    } else if (status == null || status == 429 || (status >= 500 && status != 501)) {
      final age = DateTime.now().difference(p.added);
      if (p.attempts < maxAttempts && age < maxAge) {
        p.notBefore = DateTime.now().add(retryAfter ?? firstRetry * pow(2, p.attempts - 1).toInt());
        // A newer push with the same key queued meanwhile replaces this one.
        if (p.key == null || !_queue.any((q) => q.key == p.key)) _queue.addFirst(p);
      } else {
        _logOnce('gave up', 'relay: gave up on a push after ${p.attempts} tries (last: ${status ?? 'unreachable'})');
      }
    }
    _pump();
  }

  /// The relay's status for [body] and its Retry-After; a null status when it couldn't be reached.
  Future<(int?, Duration?)> _post(Map<String, dynamic> body) async {
    try {
      final sealed = await sealForRelay(publicKey, utf8.encode(jsonEncode(body)));
      final req = await _client.postUrl(url);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(sealed));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await utf8.decodeStream(res).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 300 && res.statusCode != 410) {
        _logOnce('${res.statusCode}', 'relay ${res.statusCode} $text');
      }
      final seconds = int.tryParse(res.headers.value('retry-after') ?? '');
      return (res.statusCode, seconds == null ? null : Duration(seconds: seconds.clamp(1, 60)));
    } on Object catch (e) {
      _logOnce('unreachable', 'relay unreachable: $e');
      return (null, null);
    }
  }

  /// Logs [message] unless one of the same [kind] was logged in the last 10 minutes: a relay that is down,
  /// or can't reach Android phones (501), says so once, not with every push.
  void _logOnce(String kind, String message) {
    final now = DateTime.now();
    final last = _logged[kind];
    if (last != null && now.difference(last) < const Duration(minutes: 10)) return;
    _logged[kind] = now;
    log?.call(message);
  }

  /// Drops what's waiting and stops.
  void close() {
    _closed = true;
    _wake?.cancel();
    _queue.clear();
    _idle?.complete();
    _idle = null;
    _client.close(force: true);
  }
}
