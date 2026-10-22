import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_desktop/channel_keys.dart';

/// Windows' store as flutter_secure_storage_windows keeps it: one file each
/// write reads whole, changes and writes back, with a wait in between.
class _OneFile extends FlutterSecureStorage {
  Map<String, String> file = {};
  bool failNext = false;

  Future<void> _change(void Function(Map<String, String>) change) async {
    final map = Map.of(file);
    await Future<void>.delayed(Duration.zero);
    if (failNext) {
      failNext = false;
      throw Exception('locked');
    }
    change(map);
    file = map;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _change((m) => value == null ? m.remove(key) : m[key] = value);

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    await Future<void>.delayed(Duration.zero);
    return file[key];
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => _change((m) => m.remove(key));
}

void main() {
  test("a throwaway profile keeps its secrets apart from the person's", () {
    expect(SystemSecrets.keychainService(const {}), 'PocketTerm');
    expect(SystemSecrets.keychainService(const {'POCKETTERM_PROFILE': ''}), 'PocketTerm');
    expect(SystemSecrets.keychainService(const {'POCKETTERM_PROFILE': 'smoke-1'}), 'PocketTerm.smoke-1');
  });

  test('writes at once from the device token and the channel keys all stay (one file on Windows)', () async {
    final storage = _OneFile();
    final tokens = SecretDeviceTokens(SystemSecrets(storage));
    final keys = ChannelKeys(SystemSecrets(storage));
    await Future.wait([tokens.write('token'), keys.of('desk-1'), keys.of('desk-2'), tokens.write('token 2')]);
    expect(storage.file.keys, unorderedEquals(['device_token', 'channel_key_desk-1', 'channel_key_desk-2']));
    expect(storage.file['device_token'], 'token 2');
    expect(await tokens.read(), 'token 2');
  });

  test('a failed write fails alone: the next ones still run', () async {
    final storage = _OneFile()..failNext = true;
    final secrets = SystemSecrets(storage);
    final first = secrets.write('a', '1');
    final second = secrets.write('b', '2');
    await expectLater(first, throwsException);
    await second;
    expect(storage.file, {'b': '2'});
  });
}
