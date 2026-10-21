import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final Random _random = Random.secure();

/// [length] random bytes from the system's secure generator.
List<int> randomBytes(int length) => List<int>.generate(length, (_) => _random.nextInt(256));

/// A bearer secret (setup or device token): 32 random bytes, base64url without padding (43 characters).
String newToken() => base64Url.encode(randomBytes(32)).replaceAll('=', '');

/// An id of [length] characters `[a-z0-9]`.
String newId([int length = 16]) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return String.fromCharCodes(List<int>.generate(length, (_) => chars.codeUnitAt(_random.nextInt(chars.length))));
}

/// The SHA-256 of [text] in hex: how tokens and codes are stored.
String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

// Crockford's base32: no I, L, O or U, so a
// code read aloud or typed can't be misread. 28 characters of 5 bits: 140 bits.
const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const pairingCodeLength = 28;

/// A new pairing code in groups of four: "K7QM-3XRT-…".
String newPairingCode() {
  final chars = randomBytes(pairingCodeLength).map((b) => _alphabet[b & 31]).join();
  return [for (var i = 0; i < chars.length; i += 4) chars.substring(i, i + 4)].join('-');
}

/// [code] as stored: upper case, separators gone, look-alikes mapped.
String normalizePairingCode(String code) =>
    code.toUpperCase().replaceAll(RegExp('[^0-9A-Z]'), '').replaceAll('O', '0').replaceAll(RegExp('[IL]'), '1');
