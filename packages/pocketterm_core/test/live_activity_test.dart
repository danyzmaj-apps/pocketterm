import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/live_activity.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal_remote.dart';

void main() {
  LiveSummary summary({bool busy = false, LiveAsk? ask}) => LiveSummary(
    key: 'kitty-1/2',
    id: 's',
    title: 'Fix it',
    cwd: '/x/pocketterm',
    busy: busy,
    ask: ask,
    epoch: 'e',
    seq: 0,
  );

  const question = LiveAsk.questions('q', [
    LiveQuestion(id: 'a', question: 'Which?', options: ['A', 'B']),
  ]);

  test('a session maps to working, done, or needs with what it waits for', () {
    expect(summaryStatus(summary(busy: true)), (state: ActivityState.working, kind: null));
    expect(summaryStatus(summary()), (state: ActivityState.done, kind: null));
    expect(summaryStatus(summary(ask: question)), (state: ActivityState.needs, kind: ActivityKind.question));
    expect(summaryStatus(summary(busy: true, ask: const LiveAsk.approval('t', tool: 'bash'))), (
      state: ActivityState.needs,
      kind: ActivityKind.approval,
    ));
    expect(summaryStatus(summary(busy: true, ask: const LiveAsk.plan('p'))), (
      state: ActivityState.needs,
      kind: ActivityKind.plan,
    ));
  });

  test('a session gone from the Mac has ended', () {
    expect(summaryStatus(null), (state: ActivityState.ended, kind: null));
  });

  test('pushes carry the state and, only when it needs you, the kind', () {
    expect(activityJson((state: ActivityState.working, kind: null)), {'state': 'working'});
    expect(activityJson((state: ActivityState.needs, kind: ActivityKind.plan)), {'state': 'needs', 'kind': 'plan'});
  });

  test("the native side knows a session with its computer; another computer's activities are left alone", () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('pocketterm/native'),
      (call) async {
        calls.add(call);
        return switch (call.method) {
          'liveActivities' => [
            {'key': 'abcd1234/kitty-1/1'},
            {'key': 'zzzz9999/kitty-1/1'},
          ],
          'startActivity' => true,
          _ => null,
        };
      },
    );
    final dir = Directory.systemTemp.createTempSync('pocketterm_activity');
    addTearDown(() => dir.deleteSync(recursive: true));
    final client = PocketTermServerClient(const Backend(url: 'http://localhost:1'), tokens: MemoryDeviceTokens());
    final remote =
        TerminalRemote(client, dir, desktopId: 'abcd1234', key: ChannelKey(List.filled(32, 7)), send: (_, _) {})
          ..handle('state', {
            'windows': const <Object>[],
            'sessions': [
              {'key': 'kitty-1/1', 'id': 's1', 'title': 'Old', 'cwd': '/x', 'epoch': 'e', 'seq': 0},
              {'key': 'kitty-1/2', 'id': 's2', 'title': 'Fix it', 'cwd': r'C:\Users\me\app\', 'epoch': 'e', 'seq': 0},
            ],
          });
    final a = LiveActivities(client, remote);
    await pumpEventQueue();
    expect(a.following('kitty-1/1'), isTrue);

    expect(await a.follow('kitty-1/2', title: 'Fix it'), isTrue);
    final start = calls.lastWhere((c) => c.method == 'startActivity').arguments as Map<Object?, Object?>;
    expect((start['key'], start['project']), ('abcd1234/kitty-1/2', 'app'));

    a.onNative('activityEnded', {'key': 'zzzz9999/kitty-1/1'});
    expect(a.following('kitty-1/1'), isTrue);
    a.onNative('activityEnded', {'key': 'abcd1234/kitty-1/1'});
    expect(a.following('kitty-1/1'), isFalse);

    await a.stop('kitty-1/2');
    expect(
      (calls.last.method, (calls.last.arguments as Map<Object?, Object?>)['key']),
      ('endActivity', 'abcd1234/kitty-1/2'),
    );
  });

  test('one Live Activity more than iOS shows is told apart from them being off; a prompt goes all the same', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('pocketterm/native'),
      (call) async => switch (call.method) {
        'startActivity' => throw PlatformException(code: 'too-many'),
        'liveActivities' => const <Object>[],
        _ => null,
      },
    );
    final dir = Directory.systemTemp.createTempSync('pocketterm_activity');
    addTearDown(() => dir.deleteSync(recursive: true));
    final client = PocketTermServerClient(const Backend(url: 'http://localhost:1'), tokens: MemoryDeviceTokens());
    final remote =
        TerminalRemote(client, dir, desktopId: 'abcd1234', key: ChannelKey(List.filled(32, 7)), send: (_, _) {})
          ..handle('state', {
            'windows': const <Object>[],
            'sessions': [
              {'key': 'kitty-1/2', 'id': 's2', 'title': 'Fix it', 'cwd': '/x/app', 'epoch': 'e', 'seq': 0},
            ],
          });
    final a = LiveActivities(client, remote);
    await pumpEventQueue();
    await expectLater(a.follow('kitty-1/2', title: 'Fix it'), throwsA(isA<TooManyActivities>()));
    await a.prompted('kitty-1/2', title: 'Fix it');
    expect(a.following('kitty-1/2'), isFalse);
  });

  test("an Android phone names a followed session to the server with a tag only that computer's key makes", () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('pocketterm/native'),
      (call) async => switch (call.method) {
        'liveActivities' => const <Object>[],
        'channelKeys' => {'zzzz9999': ChannelKey(List.filled(32, 9)).toBase64()},
        _ => null,
      },
    );
    final dir = Directory.systemTemp.createTempSync('pocketterm_activity');
    addTearDown(() => dir.deleteSync(recursive: true));
    final client = _Pushes();
    final remote = TerminalRemote(
      client,
      dir,
      desktopId: 'abcd1234',
      key: ChannelKey(List.filled(32, 7)),
      send: (_, _) {},
    );
    final a = LiveActivities(client, remote);
    await pumpEventQueue();
    final fcm = 'f' * 160;

    debugPushPlatform = 'android';
    addTearDown(() => debugPushPlatform = null);
    a
      ..onNative('activityToken', {'key': 'abcd1234/kitty-1/2', 'token': fcm})
      ..onNative('activityToken', {'key': 'zzzz9999/kitty-1/2', 'token': fcm})
      ..onNative('activityToken', {'key': 'qqqq0000/kitty-1/2', 'token': fcm});
    await pumpEventQueue();
    expect(client.sent.map((s) => s.$1).toSet(), {'activity_register'});
    expect(
      client.sent.map((s) => s.$2),
      unorderedEquals([
        {'token': fcm, 'session': 'abcd1234/kitty-1/2', 'platform': 'android', 'ref': 'yMPqtkm1TA3-r0AeuNDSHg'},
        {
          'token': fcm,
          'session': 'zzzz9999/kitty-1/2',
          'platform': 'android',
          'ref': await sessionTag(ChannelKey(List.filled(32, 9)), 'zzzz9999/kitty-1/2'),
        },
        // No key for that computer: nothing it sends would open, and the server refuses a session without its tag.
        {'token': fcm, 'session': 'qqqq0000/kitty-1/2', 'platform': 'android'},
      ]),
    );

    // An iPhone's activity has a token of its own: Apple routes by it, the server needs no tag.
    client.sent.clear();
    debugPushPlatform = 'ios';
    a.onNative('activityToken', {'key': 'abcd1234/kitty-1/2', 'token': 'ab' * 40});
    await pumpEventQueue();
    expect(client.sent.single.$2, {'token': 'ab' * 40, 'session': 'abcd1234/kitty-1/2', 'platform': 'ios'});
  });
}

/// A server client that records the pushes it is asked for.
class _Pushes extends PocketTermServerClient {
  _Pushes() : super(const Backend(url: 'http://localhost:1'), tokens: MemoryDeviceTokens());

  final sent = <(String, Map<String, Object?>)>[];

  @override
  Future<Map<String, dynamic>> push(String action, Map<String, Object?> body) async {
    sent.add((action, body));
    return {'ok': true};
  }
}
