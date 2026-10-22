import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/server_client.dart';

/// Where secrets are kept; tests pass their own.
abstract interface class SecretStore {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
  Future<void> delete(String name);
}

/// The system's: the login Keychain on a Mac (no keychain entitlement
/// needed, so any signing works); on Windows one file in the app's
/// %APPDATA% folder, encrypted for this Windows user (DPAPI), so no size
/// limit as in Credential Manager. Uninstalling leaves it.
class SystemSecrets implements SecretStore {
  /// [storage]: the system's if null; tests pass their own.
  SystemSecrets([FlutterSecureStorage? storage]) : _storage = storage ?? _system;

  static const _system = FlutterSecureStorage(
    mOptions: MacOsOptions(accountName: 'PocketTerm', usesDataProtectionKeychain: false),
  );

  final FlutterSecureStorage _storage;

  /// One operation at a time, across every SystemSecrets: on Windows each
  /// write reads the whole file, changes it and writes it back, so two
  /// writes at once (the device token and a channel key, at sign-in) would
  /// keep only one, and a read during a write can fail.
  static Future<void> _last = Future.value();

  static Future<T> _serial<T>(Future<T> Function() op) {
    final run = _last.then((_) => op());
    _last = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<String?> read(String name) => _serial(() => _storage.read(key: name));

  @override
  Future<void> write(String name, String value) => _serial(() => _storage.write(key: name, value: value));

  @override
  Future<void> delete(String name) => _serial(() => _storage.delete(key: name));
}

/// This computer's sign-in on its server (the device token and what came
/// with it), kept in [SecretStore] next to the channel keys.
class SecretDeviceTokens implements DeviceTokens {
  SecretDeviceTokens(this._store);
  final SecretStore _store;

  static const _name = 'device_token';

  @override
  Future<String?> read() => _store.read(_name);

  @override
  Future<void> write(String? value) => value == null ? _store.delete(_name) : _store.write(_name, value);
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
