import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pocketterm_core/e2e.dart';

/// Where secrets are kept; tests pass their own.
abstract interface class SecretStore {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
}

/// The system's: the login Keychain on a Mac (no keychain entitlement
/// needed, so any signing works), Credential Manager on Windows.
class SystemSecrets implements SecretStore {
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(accountName: 'PocketTerm', usesDataProtectionKeychain: false),
  );

  @override
  Future<String?> read(String name) => _storage.read(key: name);

  @override
  Future<void> write(String name, String value) => _storage.write(key: name, value: value);
}

/// This computer's channel keys (packages/pocketterm_core/lib/e2e.dart), one
/// per computer id (an account's, lib/controller.dart): made the first time
/// one is needed, then kept in [SecretStore]. Never sent to a server; a
/// phone gets it from this computer's QR code.
class ChannelKeys {
  ChannelKeys(this._store);

  final SecretStore _store;
  final _keys = <String, Future<ChannelKey>>{};

  /// Computer [desktopId]'s key; two asking at once get the same one. A
  /// store that failed (a locked Keychain) is asked again next time.
  Future<ChannelKey> of(String desktopId) async {
    final pending = _keys[desktopId] ??= _load(desktopId);
    try {
      return await pending;
    } on Object {
      _keys.removeWhere((id, k) => id == desktopId && identical(k, pending));
      rethrow;
    }
  }

  /// A new key for [desktopId]: phones with the old one can't read it any
  /// more.
  Future<ChannelKey> reset(String desktopId) async {
    final key = ChannelKey.generate();
    await _store.write(_name(desktopId), key.toBase64());
    _keys[desktopId] = Future.value(key);
    return key;
  }

  Future<ChannelKey> _load(String desktopId) async {
    if (ChannelKey.tryParse(await _store.read(_name(desktopId))) case final key?) return key;
    final key = ChannelKey.generate();
    await _store.write(_name(desktopId), key.toBase64());
    return key;
  }

  static String _name(String desktopId) => 'channel_key_$desktopId';
}
