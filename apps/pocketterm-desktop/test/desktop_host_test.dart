import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_desktop/desktop_host.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pocketterm/native');
  final messenger = binding.defaultBinaryMessenger;

  /// The Mac answers setLaunchAtLogin with [enabled]: whether PocketTerm is a login item after.
  void macSays({required bool enabled}) =>
      messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'setLaunchAtLogin' ? enabled : null);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('MacHost.setLaunchAtLogin', () {
    test('a login item macOS left off (waiting for approval) throws, saying where to allow it', () async {
      macSays(enabled: false);
      await expectLater(
        MacHost().setLaunchAtLogin(on: true),
        throwsA(isA<PlatformException>().having((e) => e.message, 'message', contains('Login Items'))),
      );
    });

    test('a login item macOS keeps after turning it off throws', () async {
      macSays(enabled: true);
      await expectLater(MacHost().setLaunchAtLogin(on: false), throwsA(isA<PlatformException>()));
    });

    test('done as asked: no error', () async {
      macSays(enabled: true);
      await MacHost().setLaunchAtLogin(on: true);
      macSays(enabled: false);
      await MacHost().setLaunchAtLogin(on: false);
    });
  });
}
