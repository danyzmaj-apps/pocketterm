import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_remote.dart';

void main() {
  late Directory dir;
  late List<(String, Map<String, dynamic>)> sent;
  final client = PocketTermServerClient(const Backend(url: 'http://localhost:1'), tokens: MemoryDeviceTokens());

  TerminalRemote remote({String desktopId = 'abcd1234'}) => TerminalRemote(
    client,
    dir,
    desktopId: desktopId,
    key: ChannelKey(List.filled(32, 7)),
    from: 'phone',
    send: (event, payload) => sent.add((event, payload)),
  );

  List<Map<String, dynamic>> syncs() => [
    for (final (e, p) in sent)
      if (e == 'sync') p,
  ];

  Map<String, dynamic> item(String id, String text, int order, int seq) =>
      LiveItem(id: id, kind: ItemKind.assistant, text: text, order: order, seq: seq).toJson();

  Map<String, dynamic> state({String epoch = 'e1', int seq = 2}) => {
    'windows': [
      {'key': 'kitty-1/1', 'title': 'omp', 'cwd': '/Users/me/x', 'program': 'omp'},
    ],
    'sessions': [
      {
        'key': 'kitty-1/1',
        'id': 's1',
        'window': 'kitty-1/1',
        'title': 'Fix it',
        'cwd': '/Users/me/x',
        'epoch': epoch,
        'seq': seq,
      },
    ],
    'projects': ['/Users/me/x'],
    'roots': ['/Users/me'],
    'home': '/Users/me',
  };

  Map<String, dynamic> items({String to = 'phone', int seq = 2, bool last = true}) => {
    'to': to,
    'session': 'kitty-1/1',
    'epoch': 'e1',
    'seq': seq,
    'reset': true,
    'items': [item('a', 'one', 0, 1), item('b', 'two', 1, 2)],
    'last': last,
    'older': false,
  };

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_terminal');
    sent = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a new remote on the same cache shows the last state and transcript before the Mac answers', () {
    remote()
      ..handle('state', state())
      ..handle('items', items())
      ..flush();

    final b = remote();
    expect(b.fromCache, isTrue);
    expect(b.stateAt, isNotNull);
    expect(b.home, '/Users/me');
    expect(b.projects, ['/Users/me/x']);
    expect(b.roots, ['/Users/me']);
    expect(b.windows.single.key, 'kitty-1/1');
    expect(b.sessions.single.title, 'Fix it');
    final v = b.view('kitty-1/1')!;
    expect(v.epoch, 'e1');
    expect(v.seq, 2);
    expect(v.items.map((i) => i.text), ['one', 'two']);

    // The first state from the Mac replaces the cached one.
    b.handle('state', state());
    expect(b.fromCache, isFalse);
  });

  test("each computer has its own cache: another's state never shows", () {
    remote()
      ..handle('state', state())
      ..handle('items', items())
      ..flush();
    final other = remote(desktopId: 'zzzz9999');
    expect(other.fromCache, isFalse);
    expect(other.sessions, isEmpty);
    expect(other.view('kitty-1/1'), isNull);
  });

  test("where sessions open, the Mac's terminals and Project folders survive the cache; an older Mac has none", () {
    final a = remote()
      ..handle('state', {
        ...state(),
        'opensIn': 'Ghostty (in tmux)',
        'terminals': [
          {'id': 'ghostty', 'label': 'Ghostty', 'state': 'limited', 'note': 'no screen'},
          {'id': 'tmux', 'label': 'tmux', 'state': 'ready', 'note': ''},
        ],
      });
    expect(a.opensIn, 'Ghostty (in tmux)');
    expect(a.terminals.map((t) => (t.id, t.state, t.note)), [
      ('ghostty', TermState.limited, 'no screen'),
      ('tmux', TermState.ready, ''),
    ]);
    a.flush();

    final b = remote();
    expect(b.opensIn, 'Ghostty (in tmux)');
    expect(b.terminals.map((t) => (t.id, t.label, t.state)), [
      ('ghostty', 'Ghostty', TermState.limited),
      ('tmux', 'tmux', TermState.ready),
    ]);

    b.handle('state', {...state(), 'roots': <Object>[]});
    expect(b.roots, isEmpty);
    b.handle('state', state()..remove('roots'));
    expect(b.opensIn, isNull);
    expect(b.terminals, isEmpty);
    // No Project folders at all, not none added: it can't make a project.
    expect(b.roots, isNull);
  });

  test("where PocketTerm stands in each agent survives the cache; unknown ones and an older Mac's give none", () {
    final a = remote()
      ..handle('state', {
        ...state(),
        'agents': {'omp': 'installed', 'claude': 'off', 'codex': 'installed', 'other': 'weird'},
      });
    expect(a.agents, {Agent.omp: AgentIntegration.installed, Agent.claude: AgentIntegration.off});
    a.flush();

    final b = remote();
    expect(b.agents, {Agent.omp: AgentIntegration.installed, Agent.claude: AgentIntegration.off});
    b.handle('state', {
      ...state(),
      'agents': {'omp': 'bogus', 'claude': 'missing'},
    });
    expect(b.agents, {Agent.claude: AgentIntegration.missing});
    b.handle('state', state());
    expect(b.agents, isEmpty);
  });

  test('watching asks for what the cached view misses', () {
    remote()
      ..handle('items', items())
      ..flush();
    remote().watchSession('kitty-1/1');
    expect(syncs().single, {'from': 'phone', 'session': 'kitty-1/1', 'epoch': 'e1', 'since': 2});
  });

  test('a gap in live ops syncs from what the view has', () {
    final r = remote()..watchSession('kitty-1/1');
    expect(syncs().single['since'], 0);
    r.handle('items', items());
    sent.clear();

    // seq 3 never came.
    r.handle('live', {
      'session': 'kitty-1/1',
      'epoch': 'e1',
      'ops': [
        {'s': 4, 'id': 'b', 'a': '!'},
      ],
    });
    expect(syncs().single, {'from': 'phone', 'session': 'kitty-1/1', 'epoch': 'e1', 'since': 2});
  });

  test('live ops during a sync wait for it, then apply', () {
    final r = remote()
      ..watchSession('kitty-1/1')
      ..handle('live', {
        'session': 'kitty-1/1',
        'epoch': 'e1',
        'ops': [
          {'s': 3, 'id': 'b', 'a': ' more'},
        ],
      })
      ..handle('items', items());
    expect(r.view('kitty-1/1')!.items.last.text, 'two more');
    expect(r.view('kitty-1/1')!.seq, 3);
    expect(syncs(), hasLength(1));
  });

  test('a new epoch in the state syncs the watched session', () {
    final r = remote()
      ..watchSession('kitty-1/1')
      ..handle('items', items());
    sent.clear();
    r.handle('state', state(epoch: 'e2', seq: 1));
    expect(syncs().single['epoch'], 'e1');
  });

  test('items for another phone are ignored', () {
    final r = remote()..handle('items', items(to: 'other'));
    expect(r.view('kitty-1/1'), isNull);
  });

  test('a screen diff on a version the phone missed asks for the whole screen', () {
    final r = remote()..watchWindow('w');
    sent.clear();
    r
      ..handle('screen', {
        'window': 'w',
        'v': 1,
        'lines': ['a', 'b', 'c'],
      })
      ..handle('screen', {
        'window': 'w',
        'v': 2,
        'diff': const ScreenDiff(drop: 1, keep: 2, tail: ['d']).toJson(),
      });
    expect(r.screen('w')!.lines, ['b', 'c', 'd']);
    expect(r.screen('w')!.base, 1);
    expect(syncs(), isEmpty);

    // Version 3 went missing.
    r.handle('screen', {
      'window': 'w',
      'v': 4,
      'diff': const ScreenDiff(drop: 0, keep: 3, tail: ['e']).toJson(),
    });
    expect(r.screen('w')!.lines, ['b', 'c', 'd']);
    expect(syncs().single, {'from': 'phone', 'window': 'w'});
  });

  test('a whole screen that scrolled keeps count of the lines gone', () {
    final r = remote()
      ..handle('screen', {
        'window': 'w',
        'v': 1,
        'lines': ['a', 'b', 'c', 'd'],
      })
      ..handle('screen', {
        'window': 'w',
        'v': 2,
        'lines': ['c', 'd', 'e', 'f'],
      });
    expect(r.screen('w')!.base, 2);
  });

  test('closing a watch goes back to the one under it', () {
    final r = remote();
    final unwatchSession = r.watchSession('s');
    final unwatchWindow = r.watchWindow('w');
    expect((r.watchedSession, r.watchedWindow), (null, 'w'));
    unwatchWindow();
    expect((r.watchedSession, r.watchedWindow), ('s', null));
    unwatchSession();
    expect((r.watchedSession, r.watchedWindow), (null, null));
  });

  test('session files untouched for 14 days are pruned on load', () {
    remote()
      ..handle('items', items())
      ..flush();
    final file = Directory('${dir.path}/terminal/abcd1234/sessions').listSync().whereType<File>().single
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 15)));
    expect(remote().view('kitty-1/1'), isNull);
    expect(file.existsSync(), isFalse);
  });

  test("a window launched under an ended session's key starts with no transcript", () async {
    // The ended session's transcript, kept on disk too.
    remote()
      ..handle('items', items())
      ..flush();
    final r = remote()..handle('state', {...state(), 'sessions': <Object>[]});
    expect(r.view('kitty-1/1'), isNotNull);

    final launched = r.launch('/Users/me/x', startAgent: true);
    await Future<void>.delayed(Duration.zero);
    final run = sent.lastWhere((s) => s.$1 == 'run').$2;
    expect(run['op'], 'launch');
    // tmux numbers its panes from %0 again: the Mac answers with the same key.
    r.handle('ran', {'id': run['id'], 'window': 'kitty-1/1'});
    expect(await launched, 'kitty-1/1');

    expect(r.view('kitty-1/1'), isNull);
    r.flush();
    expect(remote().view('kitty-1/1'), isNull);
  });

  test('a prompt the computer did not answer goes again under the same id, so it never runs twice', () async {
    final r = remote()
      ..handle('state', state())
      ..answerWait = const Duration(milliseconds: 50);
    List<Map<String, dynamic>> runs() => [
      for (final (e, p) in sent)
        if (e == 'run') p,
    ];

    await expectLater(r.prompt('kitty-1/1', 'fix it'), throwsA(isA<TerminalException>()));
    final first = runs().last['id'];
    // Sent again (the person taps Send once more): same id; the computer answers it as a repeat.
    final again = r.prompt('kitty-1/1', 'fix it');
    await Future<void>.delayed(Duration.zero);
    expect(runs().last['id'], first);
    r.handle('ran', {'id': first, 'repeat': true});
    await again;
    // Answered: the same text later is a new prompt.
    final next = r.prompt('kitty-1/1', 'fix it');
    await Future<void>.delayed(Duration.zero);
    expect(runs().last['id'], isNot(first));
    r.handle('ran', {'id': runs().last['id']});
    await next;
    // Another prompt after an unanswered one is new too.
    await expectLater(r.prompt('kitty-1/1', 'one'), throwsA(isA<TerminalException>()));
    final one = runs().last['id'];
    await expectLater(r.prompt('kitty-1/1', 'two'), throwsA(isA<TerminalException>()));
    expect(runs().last['id'], isNot(one));
  });

  test('create sends root, name and agent, and takes the window', () async {
    final r = remote()..handle('state', state());
    expect(r.roots, ['/Users/me']);

    final made = r.create('/Users/me', 'new', startAgent: false);
    await Future<void>.delayed(Duration.zero);
    final run = sent.lastWhere((s) => s.$1 == 'run').$2;
    expect(
      run,
      allOf(
        containsPair('op', 'create'),
        containsPair('root', '/Users/me'),
        containsPair('name', 'new'),
        containsPair('agent', false),
      ),
    );
    r.handle('ran', {'id': run['id'], 'window': 'kitty-1/2'});
    expect(await made, 'kitty-1/2');
  });

  test("probe asks whether a window's screen changes and takes the answer; switch names the agent", () async {
    final r = remote()..handle('state', state());
    Map<String, dynamic> lastRun() => sent.lastWhere((s) => s.$1 == 'run').$2;

    final busy = r.probe('kitty-1/1');
    await Future<void>.delayed(Duration.zero);
    expect(lastRun(), allOf(containsPair('op', 'probe'), containsPair('window', 'kitty-1/1')));
    r.handle('ran', {'id': lastRun()['id'], 'busy': true});
    expect(await busy, isTrue);

    final idle = r.probe('kitty-1/1');
    await Future<void>.delayed(Duration.zero);
    r.handle('ran', {'id': lastRun()['id'], 'busy': false});
    expect(await idle, isFalse);

    final switched = r.switchToConversation('kitty-1/1', Agent.claude);
    await Future<void>.delayed(Duration.zero);
    expect(
      lastRun(),
      allOf(containsPair('op', 'switch'), containsPair('window', 'kitty-1/1'), containsPair('agent', 'claude')),
    );
    r.handle('ran', {'id': lastRun()['id']});
    await switched;

    final failed = r.switchToConversation('kitty-1/1', Agent.omp);
    await Future<void>.delayed(Duration.zero);
    expect(lastRun(), containsPair('agent', 'omp'));
    r.handle('ran', {'id': lastRun()['id'], 'error': "omp didn't quit."});
    await expectLater(
      failed,
      throwsA(isA<TerminalException>().having((e) => e.message, 'message', "omp didn't quit.")),
    );
  });
}
