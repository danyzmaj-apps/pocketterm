import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

final _x25519 = X25519();
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _aes = AesGcm.with256bits();
final List<int> _info = utf8.encode('pocketterm-relay/v1');

/// [plain] sealed to the relay's [publicKey] (v1): a fresh ephemeral X25519 key, HKDF-SHA256 (salt: the
/// ephemeral public key then the relay's; info `pocketterm-relay/v1`) and AES-256-GCM. The body:
/// `{"v": 1, "epk", "n", "c"}`, base64; c is the ciphertext then the 16-byte tag. Only the relay can open it
/// (apps/pocketterm-relay/src/seal.ts).
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
    'epk': base64.encode(epk),
    'n': base64.encode(box.nonce),
    'c': base64.encode([...box.cipherText, ...box.mac.bytes]),
  };
}

/// Posts pushes to the relay, sealed to its key: whatever carries them sees only ciphertext.
class Relay {
  Relay(this.url, this.publicKey, {this.log});

  final Uri url;

  /// The relay's X25519 public key (32 bytes).
  final List<int> publicKey;
  final void Function(String)? log;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  /// The relay's status for one push (410: the phone is gone), or null when it couldn't be reached.
  Future<int?> post(Map<String, dynamic> body) async {
    try {
      final sealed = await sealForRelay(publicKey, utf8.encode(jsonEncode(body)));
      final req = await _client.postUrl(url);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(sealed));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await utf8.decodeStream(res);
      if (res.statusCode >= 300 && res.statusCode != 410) log?.call('relay ${res.statusCode} $text');
      return res.statusCode;
    } on Object catch (e) {
      log?.call('relay unreachable: $e');
      return null;
    }
  }

  void close() => _client.close(force: true);
}
