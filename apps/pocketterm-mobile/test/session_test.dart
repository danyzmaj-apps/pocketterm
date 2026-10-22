import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phone whose sign-in goes without its own sign-out.
class _Phone extends MobileSession {
  _Phone(SharedPreferences prefs) : super(prefs, 'iPhone');

  /// The computer signed this phone out, or the server was erased.
  Future<void> signedOutByServer() => onSignedOut();
}

void main() {
  testWidgets('the sign-in ending takes its push token and choice, computer keys and followed sessions off the phone', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'pocketterm_push_token': 'push-token',
      'pocketterm_push_on_srv00000000001': true,
      'pocketterm_terminal_sort': 'recent',
    });
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
    expect(
      calls.where((c) => c.method == 'removeAllChannelKeys'),
      hasLength(1),
      reason: 'every key goes, also ones Dart never loaded',
    );
    expect(phone.computerKey('abcd1234'), isNull, reason: 'the next sign-in scans a code, and gets its key');
    expect(
      prefs.getBool('pocketterm_push_on_srv00000000001'),
      isNull,
      reason: 'signing in again asks about notifications again, never carried over',
    );
    expect(prefs.getString('pocketterm_terminal_sort'), 'recent', reason: "the phone's own settings stay");
  });
}
