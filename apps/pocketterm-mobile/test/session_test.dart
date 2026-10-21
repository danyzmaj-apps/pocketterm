import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phone whose account goes without its own sign-out.
class _Phone extends MobileSession {
  _Phone(SharedPreferences prefs) : super(prefs, 'iPhone');

  /// The server refused a refresh, the account was deleted on another
  /// device, or the reviewer access ended.
  Future<void> signedOutByServer() => onSignedOut();
}

void main() {
  testWidgets(
    "the server ending the session takes the account's push token, computer keys and followed sessions off the phone",
    (tester) async {
      SharedPreferences.setMockInitialValues({'pocketterm_push_token': 'push-token'});
      final prefs = await SharedPreferences.getInstance();
      final key = ChannelKey.generate();
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('pocketterm/native'), (
        call,
      ) async {
        calls.add(call);
        return switch (call.method) {
          'liveActivities' => [
            {'key': 'kitty-1/2', 'token': 'activity-token'},
          ],
          'channelKeys' => {'abcd1234': key.toBase64(), 'broken01': 'not a key'},
          _ => null,
        };
      });

      final phone = _Phone(prefs);
      await phone.loadComputerKeys();
      expect(phone.computerKey('abcd1234'), key, reason: 'read from where the push extension reads it');
      expect(phone.computerKey('broken01'), isNull);

      await phone.signedOutByServer();

      expect(calls.where((c) => c.method == 'endActivity').map((c) => (c.arguments as Map)['key']), ['kitty-1/2']);
      expect(prefs.getString('pocketterm_push_token'), isNull, reason: 'the next account registers for push afresh');
      expect(calls.where((c) => c.method == 'removeChannelKey').map((c) => c.arguments), [
        {'desktop': 'abcd1234'},
      ]);
      expect(phone.computerKey('abcd1234'), isNull, reason: 'the next sign-in scans a code, and gets its key');
    },
  );
}
