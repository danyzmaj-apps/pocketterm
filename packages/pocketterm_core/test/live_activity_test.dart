import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/live_activity.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    final client = SupabaseClient('http://localhost:1', 'anon');
    final remote = TerminalRemote(client, 'u1', dir, desktopId: 'abcd1234', send: (_, _) {})
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
}
