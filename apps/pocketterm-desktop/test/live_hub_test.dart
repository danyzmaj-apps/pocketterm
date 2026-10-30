// tmux's /tmp socket paths.
@Tags(['posix'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/prompt_files.dart';

/// An omp extension's side of the socket.
class _Ext {
  _Ext(this.ws) {
    ws.listen((f) => received.add(jsonDecode(f as String) as Map<String, dynamic>));
  }

  final WebSocket ws;
  final received = StreamController<Map<String, dynamic>>();
  late final StreamIterator<Map<String, dynamic>> next = StreamIterator(received.stream);

  void send(Map<String, dynamic> m) => ws.add(jsonEncode(m));

  Future<Map<String, dynamic>> request() async {
    await next.moveNext();
    return next.current;
  }

  void hello({
    String? window = 'kitty-1/7',
    String id = 's1',
    List<Map<String, dynamic>> items = const [],
    List<Map<String, dynamic>> commands = const [],
  }) => send({
    't': 'hello',
    'v': 1,
    'session': {'id': id, 'title': 'Fix bug', 'cwd': '/Users/me/Dev/pocketterm', 'model': 'm'},
    'window': window,
    'pid': 42,
    'busy': false,
    'items': items,
    'older': false,
    'commands': commands,
  });
}

void main() {
  late HttpServer server;
  late LiveHub hub;

  setUp(() async {
    hub = LiveHub();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((req) async {
        final ws = await WebSocketTransformer.upgrade(req);
        await hub.accept(ws.cast<String>(), SocketLink(ws));
      });
  });

  tearDown(() => server.close(force: true));

  Future<_Ext> connect() async => _Ext(await WebSocket.connect('ws://127.0.0.1:${server.port}'));

  /// Waits until [check] holds (the hub reads frames asynchronously).
  Future<void> until(bool Function() check) async {
    for (var i = 0; i < 200 && !check(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(check(), isTrue);
  }

  test('a session is known by its kitty window, with its snapshot and summary', () async {
    final ext = await connect();
    ext.hello(
      items: [
        {'id': 'u', 'k': 'user', 't': 'hi'},
        {'id': 'a', 'k': 'assistant', 't': '**Done.** All tests pass\nmore'},
      ],
    );
    await until(() => hub['kitty-1/7'] != null);
    final s = hub['kitty-1/7']!;
    expect(s.log.items.map((i) => i.id), ['u', 'a']);
    expect(s.summary.preview, 'Done. All tests pass');
    expect(hub.projectName(s), 'pocketterm');
  });

  test('two projects with the same folder name are told apart by the folder above; odd paths still name one', () async {
    Future<LiveSession> at(int n, String cwd) async {
      (await connect()).send({
        't': 'hello',
        'session': {'id': 's$n', 'cwd': cwd},
        'window': 'kitty-1/$n',
      });
      await until(() => hub['kitty-1/$n'] != null);
      return hub['kitty-1/$n']!;
    }

    final work = await at(1, '/Users/me/work/api');
    expect(hub.projectName(work), 'api', reason: 'alone, the folder name is enough');
    final mine = await at(2, '/Users/me/My Projects/api/');
    final windows = await at(3, r'C:\Users\me\Ünïcode Dev\web');
    final unknown = await at(4, '');
    expect(hub.projectName(work), 'work/api');
    expect(hub.projectName(mine), 'My Projects/api');
    expect(hub.projectName(windows), 'web');
    expect(hub.projectName(unknown), '');
  });

  test("frames an older or newer extension sends that the hub can't read are skipped; the session goes on", () async {
    final ext = await connect();
    ext
      ..send({
        't': 'hello',
        'session': {'id': 's1', 'cwd': '/tmp'},
        'window': 'kitty-1/7',
        'items': [
          {'k': 'user'},
          'junk',
          {'id': 'a', 'k': 'assistant', 't': 'kept'},
        ],
      })
      ..send({'t': 'item'})
      ..send({'t': 'append', 'text': 'x'})
      ..send({'t': 'meta', 'title': 7})
      ..send({'t': 'shiny-new-thing', 'what': true});
    ext.ws.add('[1, 2]');
    ext.ws.add('not json');
    ext.send({
      't': 'item',
      'item': {'id': 'b', 'k': 'assistant', 't': 'after'},
    });
    await until(() => hub['kitty-1/7']?.log.items.length == 2);
    expect(hub['kitty-1/7']!.log.items.map((i) => i.text), ['kept', 'after']);
  });

  test('outside kitty the key is the pid', () async {
    (await connect()).hello(window: null);
    await until(() => hub['pid:42'] != null);
  });

  test("a reported term names the window: tmux's pane over kitty variables leaked into it", () async {
    (await connect()).send({
      't': 'hello',
      'v': 1,
      'session': {'id': 's1', 'cwd': '/Users/me/Dev/pocketterm'},
      // A newer extension still sends kitty's `window` from the leaked variables.
      'window': 'kitty-23224/116',
      'term': {
        'TERM_PROGRAM': 'tmux',
        'KITTY_WINDOW_ID': '116',
        'KITTY_PID': '23224',
        'TMUX': '/private/tmp/tmux-501/default,4226,0',
        'TMUX_PANE': '%0',
      },
      'pid': 42,
      'items': const <Object>[],
    });
    await until(() => hub['tmux:default/0'] != null);
    expect(hub['kitty-23224/116'], isNull);
  });

  test('a term that names no window keys the session by pid, not by the leaked kitty window', () async {
    (await connect()).send({
      't': 'hello',
      'v': 1,
      'session': {'id': 's1', 'cwd': '/Users/me/Dev/pocketterm'},
      'window': 'kitty-23224/116',
      'term': {'TERM_PROGRAM': 'ghostty', 'KITTY_WINDOW_ID': '116', 'KITTY_PID': '23224', 'tty': '/dev/ttys011'},
      'pid': 42,
      'items': const <Object>[],
    });
    await until(() => hub['pid:42'] != null);
    expect(hub['kitty-23224/116'], isNull);
  });

  test(
    "Ghostty windows sharing a folder: a session's title arriving later claims its window, the other the one left",
    () async {
      TermWindow g(String id, String title) =>
          TermWindow(key: 'ghostty:$id', title: title, tab: '', cwd: '/tmp/work', program: '', app: 'ghostty');
      final listed = [g('A', 'π > work'), g('B', 'π > work')];
      final terms = Terminals(
        home: '/nonexistent-pocketterm',
        ghostty: _ListedGhostty(listed),
        snapshot: () async => Procs(parsePs('')),
      );
      hub = LiveHub(locate: terms.locate);
      Future<_Ext> omp(int pid, {String id = 's1'}) async {
        final ext = await connect();
        ext.send({
          't': 'hello',
          'v': 1,
          'agent': 'omp',
          'session': {'id': id, 'title': '', 'cwd': '/tmp/work'},
          'term': {'TERM_PROGRAM': 'ghostty', 'tty': '/dev/ttys0$pid'},
          'pid': pid,
          'items': const <Object>[],
        });
        return ext;
      }

      final first = await omp(41);
      await omp(42);
      await until(() => hub['pid:41'] != null && hub['pid:42'] != null);
      // Two untitled omps, two windows titled alike: neither is guessed.
      expect(hub.sessions.map((s) => s.window), [null, null]);

      // The first prompt names the session, and omp the window after it.
      listed[0] = g('A', 'π > Fix missing playable sources');
      first.send({'t': 'meta', 'title': 'Fix missing playable sources'});
      await until(() => hub['pid:41']?.window == 'ghostty:A' && hub['pid:42']?.window == 'ghostty:B');
      // Under the keys the phone knows, each naming its window, which the phone then shows as the session only.
      expect([
        for (final s in hub.sessions) (s.summary.toJson()['key'], s.summary.toJson()['window']),
      ], unorderedEquals([('pid:41', 'ghostty:A'), ('pid:42', 'ghostty:B')]));

      // /new in the first: the same window, under the same key.
      first.send({
        't': 'hello',
        'v': 1,
        'agent': 'omp',
        'session': {'id': 's9', 'title': '', 'cwd': '/tmp/work'},
        'term': {'TERM_PROGRAM': 'ghostty', 'tty': '/dev/ttys041'},
        'pid': 41,
        'items': const <Object>[],
      });
      await until(() => hub['pid:41']?.id == 's9');
      expect(hub['pid:41']!.window, 'ghostty:A');
      expect(hub['ghostty:A'], isNull);
    },
  );

  test(
    'slash commands come with the hello and change with a meta that has them; ctx and cost reach the phone',
    () async {
      final ext = await connect();
      ext.hello(
        commands: [
          {'name': 'new', 'description': 'Start a new session'},
          {'name': 'review'},
        ],
      );
      await until(() => hub['kitty-1/7'] != null);
      final s = hub['kitty-1/7']!;
      expect(s.summary.commands, [
        (name: 'new', description: 'Start a new session'),
        (name: 'review', description: ''),
      ]);
      ext.send({'t': 'meta', 'ctx': 40, 'cost': 43.34});
      await until(() => s.ctx == 40);
      expect(s.commands.length, 2);
      final phone = LiveSummary.fromJson(jsonDecode(jsonEncode(s.summary.toJson())) as Map<String, dynamic>);
      expect((phone.ctx, phone.cost), (40, 43.34));
      ext.send({
        't': 'meta',
        'commands': [
          {'name': 'skill:pdf', 'description': 'Read PDFs'},
        ],
      });
      await until(() => s.commands.length == 1);
      expect(s.commands.single.name, 'skill:pdf');
    },
  );

  test('items and streamed text become ops in order', () async {
    final ext = await connect();
    final ops = <LiveOp>[];
    hub.ops.listen((e) => ops.addAll(e.$2));
    ext
      ..hello()
      ..send({
        't': 'item',
        'item': {'id': 'a', 'k': 'assistant', 't': ''},
      })
      ..send({'t': 'append', 'id': 'a', 'text': 'Hel'})
      ..send({'t': 'append', 'id': 'a', 'text': 'lo'})
      ..send({'t': 'append', 'id': 'nope', 'text': 'x'});
    await until(() => ops.length == 3);
    final view = LiveView(epoch: hub['kitty-1/7']!.log.epoch);
    expect(view.apply(view.epoch, ops), isTrue);
    expect(view.items.single.text, 'Hello');
  });

  test('a finished run and a question are events; a run that will go on is not', () async {
    final ext = await connect();
    final events = <LiveEvent>[];
    hub.events.listen(events.add);
    ext
      ..hello()
      ..send({'t': 'busy', 'busy': true})
      ..send({'t': 'busy', 'busy': false})
      ..send({'t': 'busy', 'busy': false, 'summary': 'All done'})
      ..send({
        't': 'ask',
        'ask': {
          'kind': 'ask',
          'id': 'call1',
          'questions': [
            {
              'id': 'db',
              'question': 'Database?',
              'options': ['SQLite', 'Postgres'],
            },
          ],
        },
      });
    await until(() => events.length == 2);
    expect((events[0] as LiveFinished).summary, 'All done');
    expect((events[1] as LiveAsked).ask.questions!.single.options, ['SQLite', 'Postgres']);
    expect(hub['kitty-1/7']!.summary.ask?.id, 'call1');
    ext.send({'t': 'ask', 'ask': null});
    await until(() => hub['kitty-1/7']!.ask == null);
  });

  test('a plan review is an event; its options read off the screen update the ask without another', () async {
    final ext = await connect();
    final events = <LiveEvent>[];
    hub.events.listen(events.add);
    var changes = 0;
    hub.changes.listen((_) => changes++);
    ext
      ..hello()
      ..send({
        't': 'ask',
        'ask': {'kind': 'plan', 'id': 'call9', 'title': 'notes-plan'},
      });
    await until(() => events.length == 1);
    final asked = (events.single as LiveAsked).ask;
    expect(asked.isPlan, isTrue);
    expect(asked.text, 'Plan ready: notes-plan');
    expect(asked.options, isEmpty);

    final before = changes;
    const read = LiveAsk.plan(
      'call9',
      title: 'notes-plan',
      options: ['Approve and execute', 'Refine plan'],
      selected: 1,
    );
    expect(hub.updateAsk('kitty-1/7', 'call9', read), isTrue);
    expect(changes, before + 1);
    expect(hub['kitty-1/7']!.summary.toJson()['ask'], read.toJson());
    // An ask that's no longer there isn't brought back.
    expect(hub.updateAsk('kitty-1/7', 'other', read), isFalse);
    expect(hub.updateAsk('kitty-1/7', 'call9', null), isTrue);
    expect(hub['kitty-1/7']!.ask, isNull);
    expect(hub.updateAsk('kitty-1/7', 'call9', read), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(events, hasLength(1));
  });

  test("a picker read off the screen takes a free ask's place, never omp's, and makes no push", () async {
    final ext = await connect();
    final events = <LiveEvent>[];
    hub.events.listen(events.add);
    ext.hello();
    await until(() => hub['kitty-1/7'] != null);
    const menu = LiveAsk.menu('menu-1', title: 'Select theme', items: [(label: 'dark', detail: '')]);
    expect(hub.updateAsk('kitty-1/7', null, menu), isTrue);
    expect(hub['kitty-1/7']!.summary.ask?.isMenu, isTrue);
    // Another picker opened from it (/model, then its thinking level) replaces it.
    const next = LiveAsk.menu('menu-2', title: 'Thinking level', items: [(label: 'high', detail: '')]);
    expect(hub.updateAsk('kitty-1/7', 'menu-1', next), isTrue);
    // omp's own question wins, and a picker doesn't push it aside.
    ext.send({
      't': 'ask',
      'ask': {'kind': 'plan', 'id': 'call9', 'title': 'notes-plan'},
    });
    await until(() => hub['kitty-1/7']!.ask?.isPlan ?? false);
    expect(hub.updateAsk('kitty-1/7', null, menu), isFalse);
    expect(hub.updateAsk('kitty-1/7', 'menu-2', null), isFalse);
    expect(hub['kitty-1/7']!.ask?.id, 'call9');
    expect(events.whereType<LiveAsked>().map((e) => e.ask.id), ['call9']);
  });

  test('a prompt reaches the extension and its reply completes it; an error reply fails it', () async {
    final ext = await connect();
    ext.hello();
    await until(() => hub['kitty-1/7'] != null);
    final ok = hub.prompt('kitty-1/7', 'go on', followUp: true);
    final req = await ext.request();
    expect(req, containsPair('t', 'prompt'));
    expect(req, containsPair('text', 'go on'));
    expect(req, containsPair('deliver', 'followUp'));
    ext.send({'t': 'reply', 'req': req['req']});
    await ok;

    final failing = hub.abort('kitty-1/7');
    final abort = await ext.request();
    ext.send({'t': 'reply', 'req': abort['req'], 'error': 'Nothing to stop.'});
    await expectLater(failing, throwsA(isA<LiveException>().having((e) => e.message, 'message', 'Nothing to stop.')));
  });

  group('the queue', () {
    const key = 'kitty-1/7';
    List<String> queued() => [for (final q in hub[key]!.summary.queue) q.text];

    /// An omp session at work.
    Future<_Ext> working() async {
      final ext = await connect();
      ext
        ..hello()
        ..send({'t': 'busy', 'busy': true});
      await until(() => hub[key]?.busy ?? false);
      return ext;
    }

    /// The prompt the hub hands [ext] next, answered.
    Future<Map<String, dynamic>> handed(_Ext ext) async {
      final req = await ext.request();
      expect(req, containsPair('t', 'prompt'));
      ext.send({'t': 'reply', 'req': req['req']});
      return req;
    }

    test(
      'a prompt sent to wait goes when the run ends, one per run, and the session never looks done between',
      () async {
        final events = <LiveEvent>[];
        final sub = hub.events.listen(events.add);
        addTearDown(sub.cancel);
        final ext = await working();
        final first = await hub.prompt(key, 'then the docs', followUp: true);
        await hub.prompt(key, 'then the changelog', followUp: true);
        expect(first, isNotNull);
        expect(queued(), ['then the docs', 'then the changelog']);
        expect(hub[key]!.summary.queue.first.id, first);

        ext.send({'t': 'busy', 'busy': false, 'summary': 'Fixed.'});
        final req = await handed(ext);
        expect(req['text'], 'then the docs');
        expect(req['deliver'], 'followUp', reason: 'an agent that started meanwhile keeps it for the run end');
        expect(hub[key]!.busy, isTrue, reason: 'working from the hand-off on');
        expect(queued(), ['then the changelog']);

        ext
          ..send({'t': 'busy', 'busy': true})
          ..send({'t': 'busy', 'busy': false, 'summary': 'Docs done.'});
        expect((await handed(ext))['text'], 'then the changelog');
        ext
          ..send({'t': 'busy', 'busy': true})
          ..send({'t': 'busy', 'busy': false, 'summary': 'All done.'});
        await until(() => !hub[key]!.busy);
        expect(queued(), isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect([for (final e in events.whereType<LiveFinished>()) e.summary], ['All done.']);
      },
    );

    test('a steer and a prompt to an agent at rest go now; Claude Code queues any prompt while it works', () async {
      final ext = await working();
      final steer = hub.prompt(key, 'look at the tests too');
      final req = await handed(ext);
      expect(await steer, isNull);
      expect(req['deliver'], 'steer');

      final claude = await connect();
      claude.send({
        't': 'hello',
        'agent': 'claude',
        'session': {'id': 'c1', 'cwd': '/tmp'},
        'window': 'kitty-1/8',
        'busy': true,
      });
      await until(() => hub['kitty-1/8']?.busy ?? false);
      expect(await hub.prompt('kitty-1/8', 'and then this'), isNotNull);
      expect(hub['kitty-1/8']!.summary.queue.single.text, 'and then this');
      await expectLater(
        hub.sendQueuedNow('kitty-1/8', hub['kitty-1/8']!.summary.queue.single.id),
        throwsA(isA<LiveException>()),
      );
    });

    test('Stop holds the queue until Resume; so does a run stopped at the computer', () async {
      final ext = await working();
      await hub.prompt(key, 'next', followUp: true);
      final stopping = hub.abort(key);
      final abort = await ext.request();
      expect(abort['t'], 'abort');
      ext
        ..send({'t': 'reply', 'req': abort['req']})
        ..send({'t': 'busy', 'busy': false, 'stopped': true});
      await stopping;
      await until(() => !hub[key]!.busy);
      expect(hub[key]!.summary.paused, isTrue);
      expect(queued(), ['next']);

      hub.pauseQueue(key, paused: false);
      expect((await handed(ext))['text'], 'next');

      // Esc at the computer: the extension says the run was stopped.
      ext.send({'t': 'busy', 'busy': true});
      await until(() => hub[key]!.busy && queued().isEmpty);
      await hub.prompt(key, 'after that', followUp: true);
      ext.send({'t': 'busy', 'busy': false, 'stopped': true});
      await until(() => !hub[key]!.busy);
      expect(hub[key]!.summary.paused, isTrue);
      expect(queued(), ['after that']);
    });

    test('a run that ended in an error shows failed until the next run starts', () async {
      final ext = await working();
      ext.send({'t': 'busy', 'busy': false, 'failed': true});
      await until(() => !hub[key]!.busy);
      expect(hub[key]!.summary.failed, isTrue);
      expect(LiveSummary.fromJson(hub[key]!.summary.toJson()).failed, isTrue, reason: 'it reaches the phone');

      ext.send({'t': 'busy', 'busy': true});
      await until(() => hub[key]!.busy);
      expect(hub[key]!.summary.failed, isFalse);

      // Stopped is not failed: the phone hears nothing of it.
      ext.send({'t': 'busy', 'busy': false, 'stopped': true});
      await until(() => !hub[key]!.busy);
      expect(hub[key]!.summary.failed, isFalse);
      expect(hub[key]!.summary.toJson().containsKey('failed'), isFalse);
    });

    test('edits, moves and removals change what goes; an emptied queue is no longer paused', () async {
      final ext = await working();
      final a = (await hub.prompt(key, 'a', followUp: true))!;
      final b = (await hub.prompt(key, 'b', followUp: true))!;
      final c = (await hub.prompt(key, 'c', followUp: true))!;
      hub
        ..editQueued(key, b, 'b, but better')
        ..moveQueued(key, c, 0)
        ..removeQueued(key, a);
      expect(queued(), ['c', 'b, but better']);
      expect(() => hub.editQueued(key, c, '  '), throwsA(isA<LiveException>()), reason: 'nothing left to send');
      expect(() => hub.removeQueued(key, a), throwsA(isA<LiveException>()), reason: 'gone already');

      hub
        ..pauseQueue(key, paused: true)
        ..removeQueued(key, c)
        ..removeQueued(key, b);
      expect(hub[key]!.summary.paused, isFalse);

      await hub.prompt(key, 'd', followUp: true);
      ext.send({'t': 'busy', 'busy': false});
      expect((await handed(ext))['text'], 'd');
    });

    test('Send now steers the run with it, out of the queue', () async {
      final ext = await working();
      await hub.prompt(key, 'first', followUp: true);
      final now = (await hub.prompt(key, 'right away', followUp: true))!;
      final sending = hub.sendQueuedNow(key, now);
      final req = await handed(ext);
      await sending;
      expect(req['text'], 'right away');
      expect(req['deliver'], 'steer');
      expect(queued(), ['first']);
    });

    test("one the agent doesn't take goes back first, and the queue pauses", () async {
      final ext = await working();
      await hub.prompt(key, 'one', followUp: true);
      await hub.prompt(key, 'two', followUp: true);
      ext.send({'t': 'busy', 'busy': false});
      final req = await ext.request();
      ext.send({'t': 'reply', 'req': req['req'], 'error': 'No model.'});
      await until(() => !hub[key]!.busy);
      expect(queued(), ['one', 'two']);
      expect(hub[key]!.summary.paused, isTrue);
    });

    test('the same agent back in the same window keeps the queue', () async {
      final ext = await working();
      await hub.prompt(key, 'still wanted', followUp: true);
      await ext.ws.close();
      await until(() => hub[key] == null);

      final again = await connect();
      again.send({
        't': 'hello',
        'session': {'id': 's1', 'cwd': '/tmp'},
        'window': key,
        'busy': true,
      });
      await until(() => hub[key] != null);
      expect(queued(), ['still wanted']);
    });

    test('it holds at most ${LiveHub.maxQueued} prompts', () async {
      await working();
      for (var i = 0; i < LiveHub.maxQueued; i++) {
        await hub.prompt(key, 'p$i', followUp: true);
      }
      await expectLater(hub.prompt(key, 'one more', followUp: true), throwsA(isA<LiveException>()));
      expect(queued(), hasLength(LiveHub.maxQueued));
    });
  });

  group('a prompt with files', () {
    late Directory dir;
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1]);
    final files = [
      (name: 'notes.txt', mime: 'text/plain', bytes: Uint8List.fromList('the notes'.codeUnits)),
      (name: '../my plan.md', mime: 'text/markdown', bytes: Uint8List.fromList('# plan'.codeUnits)),
    ];

    setUp(() {
      dir = Directory.systemTemp.createTempSync('pocketterm_hub_files');
      hub = LiveHub(files: PromptFiles(dir));
    });
    tearDown(() => dir.deleteSync(recursive: true));

    /// The paths [text] names as @path or @"path".
    List<String> mentioned(String text) => [
      for (final m in RegExp(r'@(?:"([^"]+)"|(\S+))').allMatches(text)) m[1] ?? m[2]!,
    ];

    test('omp gets them named in the text as @path, saved on this computer, and the images inline', () async {
      final ext = await connect();
      ext.hello();
      await until(() => hub['kitty-1/7'] != null);
      final done = hub.prompt('kitty-1/7', 'read these', images: [(bytes: png, mimeType: 'image/png')], files: files);
      final req = await ext.request();
      ext.send({'t': 'reply', 'req': req['req']});
      await done;

      final text = req['text'] as String;
      expect(text, startsWith('read these\n\n@'));
      final paths = mentioned(text);
      expect(paths.map(p.basename), ['notes.txt', 'my plan.md']);
      expect(text, contains('@"${paths.last}"'), reason: 'a path with a space is quoted');
      expect(paths.map((f) => File(f).readAsStringSync()), ['the notes', '# plan']);
      for (final f in paths) {
        expect(p.isWithin(dir.path, f), isTrue, reason: f);
      }
      expect((req['images'] as List).single, {'data': base64Encode(png), 'mimeType': 'image/png'});
      expect(req.containsKey('docs'), isFalse);
    });

    test('Claude Code gets them named in the text, and their paths to read without asking', () async {
      final ext = await connect();
      ext.send({
        't': 'hello',
        'v': 1,
        'agent': 'claude',
        'session': {'id': 'c1', 'title': '', 'cwd': '/Users/me/Dev/pocketterm'},
        'window': 'kitty-1/7',
        'items': const <Object>[],
      });
      await until(() => hub['kitty-1/7']?.agent == Agent.claude);
      final done = hub.prompt('kitty-1/7', '', images: [(bytes: png, mimeType: 'image/png')], files: files);
      final req = await ext.request();
      ext.send({'t': 'reply', 'req': req['req']});
      await done;

      final docs = (req['docs'] as List).cast<String>();
      expect(mentioned(req['text'] as String), docs, reason: 'nothing but the mentions, with no words');
      expect(docs.map(p.basename), ['notes.txt', 'my plan.md']);
      expect(req['images'], isEmpty);
      expect(File((req['files'] as List).single as String).readAsBytesSync(), png, reason: 'the image, from disk');
      expect(req['deliver'], 'followUp');
    });

    test('images and files older than a day go when PocketTerm starts; newer ones stay', () async {
      final images = Directory(p.join(dir.path, 'images'))..createSync();
      final files = Directory(p.join(dir.path, 'files'))..createSync();
      final old = DateTime.now().subtract(const Duration(days: 2));
      final oldImage = File(p.join(images.path, 'old.png'))
        ..writeAsBytesSync(png)
        ..setLastModifiedSync(old);
      final newImage = File(p.join(images.path, 'new.png'))..writeAsBytesSync(png);
      final oldFolder = Directory(p.join(files.path, 'old'))..createSync();
      File(p.join(oldFolder.path, 'notes.txt')).writeAsStringSync('the notes');
      await Process.run('/usr/bin/touch', ['-t', '200001010000', oldFolder.path]);

      LiveHub(files: PromptFiles(files), images: images);
      await until(() => !oldFolder.existsSync());
      expect(oldImage.existsSync(), isFalse);
      expect(newImage.existsSync(), isTrue);
      expect(oldFolder.existsSync(), isFalse);
    });
  });

  test('older items arrive as ops above the oldest', () async {
    final ext = await connect();
    final ops = <LiveOp>[];
    hub.ops.listen((e) => ops.addAll(e.$2));
    ext.send({
      't': 'hello',
      'session': {'id': 's'},
      'window': 'kitty-1/7',
      'items': [
        {'id': 'c', 'k': 'user', 't': 'c'},
      ],
      'older': true,
    });
    await until(() => hub['kitty-1/7'] != null);
    final done = hub.older('kitty-1/7');
    final req = await ext.request();
    ext.send({
      't': 'reply',
      'req': req['req'],
      'items': [
        {'id': 'a', 'k': 'user', 't': 'a'},
        {'id': 'b', 'k': 'user', 't': 'b'},
      ],
      'older': false,
    });
    await done;
    expect(hub['kitty-1/7']!.log.items.map((i) => i.id), ['a', 'b', 'c']);
    expect(hub['kitty-1/7']!.log.older, isFalse);
    expect(ops, hasLength(2));
  });

  test('/new in the same omp starts a new transcript under the same key', () async {
    final ext = await connect();
    ext.hello(
      items: [
        {'id': 'x', 'k': 'user', 't': 'old'},
      ],
    );
    await until(() => hub['kitty-1/7'] != null);
    final epoch = hub['kitty-1/7']!.log.epoch;
    ext.hello(id: 's2');
    await until(() => hub['kitty-1/7']!.id == 's2');
    expect(hub['kitty-1/7']!.log.epoch, isNot(epoch));
    expect(hub['kitty-1/7']!.log.items, isEmpty);
  });

  test('a new omp in the same window replaces the old one; its end removes it and fails what waits', () async {
    final first = await connect();
    first.hello();
    await until(() => hub['kitty-1/7'] != null);
    final pending = expectLater(hub.prompt('kitty-1/7', 'x'), throwsA(isA<LiveException>()));
    await first.request();
    final second = await connect();
    second.hello(id: 's9');
    await until(() => hub['kitty-1/7']?.id == 's9');
    await pending;
    await second.ws.close();
    await until(() => hub['kitty-1/7'] == null);
    expect(hub.sessions, isEmpty);
  });

  group('the orchestrator', () {
    late Directory tmp;
    late String dir;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('pocketterm_orchestrator');
      dir = p.join(tmp.path, 'orchestrator');
      Directory(dir).createSync();
      hub.orchestratorDir = dir;
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<_Ext> at(
      String window,
      String cwd, {
      String title = 'Fix bug',
      bool busy = false,
      List<Map<String, dynamic>> items = const [],
    }) async {
      final ext = await connect();
      ext.send({
        't': 'hello',
        'session': {'id': window, 'title': title, 'cwd': cwd},
        'window': window,
        'busy': busy,
        'items': items,
      });
      await until(() => hub[window] != null);
      return ext;
    }

    var calls = 0;
    Future<Map<String, dynamic>> call(_Ext ext, Map<String, dynamic> m) async {
      final id = ++calls;
      ext.send({'t': 'call', 'id': id, ...m});
      final r = await ext.request();
      expect(r, containsPair('t', 'result'));
      expect(r, containsPair('id', id));
      return r;
    }

    test('a session in its folder is the orchestrator, through a symlink too; one elsewhere is not', () async {
      await at('kitty-1/1', dir);
      final link = Link(p.join(tmp.path, 'via'))..createSync(dir);
      await at('kitty-1/2', link.path);
      await at('kitty-1/3', '/Users/me/Dev/api');
      expect(hub['kitty-1/1']!.summary.orchestrator, isTrue);
      expect(hub['kitty-1/2']!.summary.orchestrator, isTrue);
      expect(hub['kitty-1/3']!.summary.orchestrator, isFalse);
      expect(LiveSummary.fromJson(hub['kitty-1/1']!.summary.toJson()).orchestrator, isTrue);
    });

    test('sessions lists every session but the orchestrator', () async {
      final orch = await at('kitty-1/1', dir);
      expect((await call(orch, {'op': 'sessions'}))['text'], 'No other coding sessions are running on this computer.');
      await at('kitty-1/2', '/Users/me/Dev/api', title: 'Add login');
      final text = (await call(orch, {'op': 'sessions'}))['text'] as String;
      expect(text, startsWith('1 coding session on this computer:'));
      expect(text, contains('kitty-1/2 | api | "Add login" | omp | idle'));
      expect(text, isNot(contains('kitty-1/1')));
    });

    test('only the orchestrator may call', () async {
      final other = await at('kitty-1/2', '/Users/me/Dev/api');
      final r = await call(other, {'op': 'sessions'});
      expect(r['error'], 'Only the PocketTerm orchestrator can do that.');
      expect(r.containsKey('text'), isFalse);
    });

    test('prompt steers an idle session, queues for a busy one, and never the orchestrator or a command', () async {
      final orch = await at('kitty-1/1', dir);
      final idle = await at('kitty-1/2', '/Users/me/Dev/api', title: 'Add login');
      orch.send({
        't': 'call',
        'id': 1,
        'op': 'prompt',
        'session': 'kitty-1/2',
        'text': 'run the tests',
        'deliver': 'steer',
      });
      final req = await idle.request();
      expect(req, containsPair('t', 'prompt'));
      expect(req, containsPair('text', 'run the tests'));
      expect(req, containsPair('deliver', 'steer'));
      idle.send({'t': 'reply', 'req': req['req']});
      final sent = await orch.request();
      expect(sent['text'], startsWith('Sent to api "Add login" (kitty-1/2)'));

      await at('kitty-1/3', '/Users/me/Dev/web', busy: true);
      final queued = await call(orch, {'op': 'prompt', 'session': 'kitty-1/3', 'text': 'then the docs'});
      expect(queued['text'], startsWith('Queued in'));
      expect(hub['kitty-1/3']!.summary.queue.single.text, 'then the docs');

      final self = await call(orch, {'op': 'prompt', 'session': 'kitty-1/1', 'text': 'hi'});
      expect(self['error'], 'That is the orchestrator itself.');
      final slash = await call(orch, {'op': 'prompt', 'session': 'kitty-1/2', 'text': '/model'});
      expect(slash['error'], "Slash commands can't be sent from the orchestrator.");
    });

    test('read gives the newest items, oldest first, each clipped', () async {
      final orch = await at('kitty-1/1', dir);
      await at(
        'kitty-1/2',
        '/Users/me/Dev/api',
        items: [
          {'id': 'a', 'k': 'user', 't': 'first question'},
          {'id': 'b', 'k': 'assistant', 't': 'first answer'},
          {'id': 'c', 'k': 'user', 't': 'second question'},
          {'id': 'd', 'k': 'assistant', 't': 'x' * 10000},
        ],
      );
      final text = (await call(orch, {'op': 'read', 'session': 'kitty-1/2', 'last': 2}))['text'] as String;
      expect(text, contains('(earlier items left out)'));
      expect(text, isNot(contains('first')));
      expect(text.indexOf('[user] second question'), lessThan(text.indexOf('[assistant] ')));
      expect(text, contains('${'x' * 6000}…'));
      expect(text, isNot(contains('x' * 6001)));
    });
  });
}

/// Ghostty listing these windows (as they are when asked).
class _ListedGhostty extends Ghostty {
  _ListedGhostty(this.listed) : super(appPath: '/nonexistent-pocketterm/Ghostty.app');
  final List<TermWindow> listed;

  @override
  Future<List<TermWindow>> windows(Procs procs) async => [...listed];
}
