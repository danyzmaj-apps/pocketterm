@Tags(['posix'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';

/// A kitty listening on a unix socket: records each command and answers
/// with what [answer] returns, written in the given pieces (null: never).
class FakeKitty {
  FakeKitty._(this.dir, this._server);

  static Future<FakeKitty> start() async {
    // Short path: unix socket paths are limited to ~104 bytes on macOS.
    final dir = Directory('/tmp').createTempSync('kt');
    final server = await ServerSocket.bind(
      InternetAddress('${dir.path}/kitty-test', type: InternetAddressType.unix),
      0,
    );
    final fake = FakeKitty._(dir, server);
    server.listen(fake._serve);
    return fake;
  }

  final Directory dir;
  final ServerSocket _server;
  final requests = <Map<String, dynamic>>[];
  List<String>? Function(Map<String, dynamic> request) answer = (_) => [ok()];

  static String ok([Object? data]) => frame({'ok': true, 'data': ?data});
  static String frame(Map<String, Object?> reply) => '\x1bP@kitty-cmd${jsonEncode(reply)}\x1b\\';

  Kitty kitty({Duration timeout = const Duration(seconds: 5)}) =>
      Kitty(socketDir: dir.path, timeout: timeout, restoreFront: false);

  void _serve(Socket s) {
    final buf = <int>[];
    s.listen((bytes) async {
      buf.addAll(bytes);
      // Bytes until the end: a character may span two reads.
      if (buf.length < 2 || buf[buf.length - 2] != 0x1b || buf.last != 0x5c) return;
      final text = utf8.decode(buf);
      expect(text, startsWith('\x1bP@kitty-cmd'));
      final request = jsonDecode(text.substring('\x1bP@kitty-cmd'.length, text.length - 2)) as Map<String, dynamic>;
      requests.add(request);
      final pieces = answer(request);
      if (pieces == null) return;
      for (final p in pieces) {
        s.add(utf8.encode(p));
        await s.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await s.close();
    }, onError: (Object _) {});
  }

  Future<void> stop() async {
    await _server.close();
    dir.deleteSync(recursive: true);
  }
}

void main() {
  late FakeKitty fake;
  setUp(() async => fake = await FakeKitty.start());
  tearDown(() => fake.stop());

  test('frames each command as kitty-cmd JSON with version and payload', () async {
    await fake.kitty().close('kitty-test/7');
    expect(fake.requests, [
      {
        'cmd': 'close-window',
        'version': [0, 20, 0],
        'payload': {'match': 'id:7'},
      },
    ]);
  });

  test('reads an answer that arrives in several writes', () async {
    const colors = 'foreground #a0b0c0\nbackground #010203\ncolor1     #ff0000\n';
    final whole = FakeKitty.ok(colors);
    fake.answer = (_) => [whole.substring(0, 10), whole.substring(10, 40), whole.substring(40, whole.length - 1), r'\'];
    final c = await fake.kitty().colors('kitty-test/1');
    expect(c['fg'], 0xA0B0C0);
    expect(c['bg'], 0x010203);
    expect((c['palette']! as List)[1], 0xFF0000);
  });

  test('a multi-line send types each line, Shift+Enter between, Enter last', () async {
    await fake.kitty().send('kitty-test/3', 'one\n\ntwo', enter: true);
    final sent = [
      for (final r in fake.requests) (cmd: r['cmd'] as String, payload: r['payload'] as Map<String, dynamic>),
    ];
    String show(({String cmd, Map<String, dynamic> payload}) r) {
      if (r.cmd == 'send-key') return 'key ${(r.payload['keys'] as List).join(' ')}';
      return '${r.cmd} ${r.payload['data']}';
    }

    expect(sent.map(show), [
      'send-text text:one',
      'key shift+enter',
      'key shift+enter',
      'send-text text:two',
      'key enter',
    ]);
    for (final r in sent) {
      expect(r.payload['match'], 'id:3');
      if (r.cmd == 'send-text') expect(r.payload['bracketed_paste'], 'disable');
    }
  });

  test("Windows' and old Macs' line breaks (CRLF, CR) are line breaks too, never a bare Enter mid-text", () async {
    await fake.kitty().send('kitty-test/3', 'rm -rf build\r\necho done\rls', enter: false);
    final sent = [
      for (final r in fake.requests)
        if (r['payload'] case {'keys': final List<dynamic> keys}) keys.join() else '${(r['payload'] as Map)['data']}',
    ];
    expect(sent, ['text:rm -rf build', 'shift+enter', 'text:echo done', 'shift+enter', 'text:ls']);
  });

  test('pressKeys sends all names in one command; press refuses keys the phone may not press', () async {
    final kitty = fake.kitty();
    await kitty.pressKeys('kitty-test/2', ['down', 'down', 'enter']);
    expect(fake.requests.single['payload'], {
      'match': 'id:2',
      'keys': ['down', 'down', 'enter'],
    });
    await expectLater(
      Terminals.standard(kittyDir: fake.dir.path).press('kitty-test/2', 'ctrl+v'),
      throwsA(isA<TerminalException>()),
    );
    expect(fake.requests, hasLength(1));
  });

  test('windows() reads the ls JSON kitty nests inside data', () async {
    final ls = [
      {
        'id': 2,
        'tabs': [
          {
            'id': 3,
            'title': 'work',
            'windows': [
              {
                'id': 4,
                'title': 'omp: pocketterm',
                'is_focused': true,
                'cwd': '/x',
                'cmdline': ['-zsh'],
                'foreground_processes': [
                  {
                    'cwd': '/Users/me/pocketterm',
                    'cmdline': ['/opt/homebrew/bin/omp', '--resume'],
                  },
                ],
              },
              {
                'id': 5,
                'title': 'shell',
                'cwd': '/Users/me',
                'cmdline': ['-zsh'],
              },
            ],
          },
        ],
      },
    ];
    fake.answer = (_) => [FakeKitty.ok(jsonEncode(ls))];
    final windows = await fake.kitty().windows();
    expect(
      [for (final w in windows) w.toJson()],
      [
        {
          'key': 'kitty-test/4',
          'osWindow': 'kitty-test/os2',
          'tabId': 'kitty-test/tab3',
          'title': 'omp: pocketterm',
          'tab': 'work',
          'cwd': '/Users/me/pocketterm',
          'program': 'omp',
          'focused': true,
          'app': 'kitty',
          'caps': ['read', 'ansi', 'type', 'line', 'keys', 'close'],
        },
        {
          'key': 'kitty-test/5',
          'osWindow': 'kitty-test/os2',
          'tabId': 'kitty-test/tab3',
          'title': 'shell',
          'tab': 'work',
          'cwd': '/Users/me',
          'program': 'zsh',
          'focused': false,
          'app': 'kitty',
          'caps': ['read', 'ansi', 'type', 'line', 'keys', 'close'],
        },
      ],
    );
    expect(windows.first.agent, Agent.omp);
  });

  test('a window kitty no longer has reads as gone; other errors pass through', () async {
    fake.answer = (_) => [
      FakeKitty.frame({'ok': false, 'error': 'No matching windows for expression: id:9'}),
    ];
    await expectLater(
      fake.kitty().pressKeys('kitty-test/9', ['esc']),
      throwsA(isA<TerminalException>().having((e) => e.message, 'message', 'That window is gone.')),
    );
    fake.answer = (_) => [
      FakeKitty.frame({'ok': false, 'error': 'Something else broke'}),
    ];
    await expectLater(
      fake.kitty().type('kitty-test/9', 'x'),
      throwsA(isA<TerminalException>().having((e) => e.message, 'message', 'Something else broke')),
    );
  });

  test('a key for a socket that is not there is refused without asking kitty', () async {
    await expectLater(fake.kitty().close('kitty-gone/1'), throwsA(isA<TerminalException>()));
    await expectLater(fake.kitty().close('../kitty-test/1'), throwsA(isA<TerminalException>()));
    expect(fake.requests, isEmpty);
  });

  test("another account's kitty socket in the shared folder is neither listed nor typed into", () async {
    // The fake's socket is this user's; to a Kitty running as someone else
    // it is a stranger's.
    final asOther = Kitty(socketDir: fake.dir.path, restoreFront: false, uid: 4242424);
    await expectLater(asOther.windows(), throwsA(isA<TerminalException>()));
    await expectLater(asOther.type('kitty-test/1', 'x'), throwsA(isA<TerminalException>()));
    expect(fake.requests, isEmpty);
    await fake.kitty().close('kitty-test/1');
    expect(fake.requests, hasLength(1));
  });

  test('a kitty that never answers times out', () async {
    fake.answer = (_) => null;
    final watch = Stopwatch()..start();
    await expectLater(
      fake.kitty(timeout: const Duration(milliseconds: 200)).plainScreen('kitty-test/1'),
      throwsA(isA<TerminalException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('long text goes in pieces kitty takes, in order, none of it as a paste', () async {
    // kitty ignores a message over about 128 KB and hangs up.
    final text = List.generate(9000, (i) => 'é漢"\\\x1b$i').join();
    await fake.kitty().type('kitty-test/1', text);
    final payloads = [for (final r in fake.requests) r['payload'] as Map<String, dynamic>];
    expect(payloads.length, greaterThan(1));
    for (final p in payloads) {
      expect(utf8.encode(jsonEncode(p)).length, lessThan(100000));
      expect(p['bracketed_paste'], 'disable');
    }
    expect(payloads.map((p) => (p['data'] as String).substring('text:'.length)).join(), text);
  });

  test('a kitty that hangs up on what it was sent is an answer, not an error nobody handles', () async {
    final hup = await ServerSocket.bind(
      InternetAddress('${fake.dir.path}/kitty-hup', type: InternetAddressType.unix),
      0,
    );
    addTearDown(hup.close);
    hup.listen((s) => s.destroy());
    for (final size in [10, 9000]) {
      await expectLater(fake.kitty().type('kitty-hup/1', 'x' * size), throwsA(isA<TerminalException>()));
    }
    // An unhandled socket error would fail this test from its zone.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('a socket left behind by a kitty that was killed reads as kitty having quit', () async {
    // nc listens on it and is killed: the socket stays with nobody behind it.
    final path = '${fake.dir.path}/kitty-stale';
    final nc = await Process.start('/usr/bin/nc', ['-lU', path]);
    for (
      var i = 0;
      i < 50 && FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.notFound;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    nc.kill(ProcessSignal.sigkill);
    await nc.exitCode;
    expect(FileSystemEntity.typeSync(path, followLinks: false), FileSystemEntityType.unixDomainSock);
    await expectLater(
      fake.kitty().type('kitty-stale/1', 'x'),
      throwsA(isA<TerminalException>().having((e) => e.message, 'message', Kitty.quit)),
    );
    // The live one still lists; the stale one is passed over.
    fake.answer = (_) => [FakeKitty.ok('[]')];
    expect(await fake.kitty().windows(), isEmpty);
  });

  test('lines() strips padding, drops trailing blanks, and keeps the newest lines within historyBytes', () async {
    // 100 lines of 1000 bytes each, then padded and blank lines at the bottom.
    final body = [for (var i = 0; i < 100; i++) '${'$i'.padLeft(3, '0')}${'x' * 997}'];
    final text = [...body, 'prompt \x1b[31m  \x1b[m   ', '   ', '\x1b[m', ''].join('\n');
    fake.answer = (_) => [FakeKitty.ok(text)];
    final lines = await fake.kitty().lines('kitty-test/1', history: true);
    expect(fake.requests.single['payload'], {'match': 'id:1', 'extent': 'all', 'ansi': true});
    expect(lines.last, 'prompt\x1b[31m\x1b[m');
    final bytes = lines.fold(0, (n, l) => n + utf8.encode(l).length + 1);
    expect(bytes, lessThanOrEqualTo(historyBytes));
    // 59 full lines plus the prompt fit; the 60th would not.
    expect(lines, hasLength(60));
    expect(lines.first, body[41]);
  });

  group('a new session', () {
    /// Answers `ls` with [_ls] and `launch` with window 42.
    void listing() => fake.answer = (r) => [FakeKitty.ok(r['cmd'] == 'ls' ? _ls : '42')];
    Map<String, dynamic> launched() =>
        fake.requests.singleWhere((r) => r['cmd'] == 'launch')['payload'] as Map<String, dynamic>;

    test('into an OS window in the background: a tab there, next to one of its windows', () async {
      listing();
      expect(await fake.kitty().launch(fake.dir.path, into: 'kitty-test/os2'), 'kitty-test/42');
      expect(launched(), {
        'args': <String>[],
        'cwd': fake.dir.path,
        'type': 'tab',
        'match': 'window_id:5',
        'keep_focus': false,
      });
    });

    test('into the OS window being typed in: a tab that takes no focus from it', () async {
      listing();
      await fake.kitty().launch(fake.dir.path, command: ['omp'], into: 'kitty-test/os1');
      expect(launched(), {
        'args': ['omp'],
        'cwd': fake.dir.path,
        'type': 'tab',
        'match': 'window_id:1',
        'keep_focus': true,
      });
    });

    test('into an OS window that is gone, or of a kitty that is: a new OS window', () async {
      for (final into in ['kitty-test/os9', 'kitty-gone/os2']) {
        listing();
        fake.requests.clear();
        expect(await fake.kitty().launch(fake.dir.path, into: into), 'kitty-test/42');
        expect(launched(), {'args': <String>[], 'cwd': fake.dir.path, 'type': 'os-window', 'keep_focus': true});
      }
    });

    test('into no window: a new OS window, without asking what kitty has open', () async {
      listing();
      await fake.kitty().launch(fake.dir.path);
      expect(fake.requests.map((r) => r['cmd']), ['launch']);
      expect(launched(), {'args': <String>[], 'cwd': fake.dir.path, 'type': 'os-window', 'keep_focus': true});
    });
  });

  test("closing an OS window's last window is told apart from closing a tab", () {
    expect(lastInOsWindow(_ls, 1), isTrue);
    expect(lastInOsWindow(_ls, 7), isFalse);
  });
}

// kitty's ls: OS window 1 (focused) holds window 1; OS window 2 holds windows
// 5 and 7, each in a tab of its own.
final String _ls = jsonEncode([
  {
    'id': 1,
    'is_focused': true,
    'tabs': [
      {
        'id': 1,
        'windows': [
          {'id': 1},
        ],
      },
    ],
  },
  {
    'id': 2,
    'is_focused': false,
    'tabs': [
      {
        'id': 2,
        'windows': [
          {'id': 5},
        ],
      },
      {
        'id': 3,
        'windows': [
          {'id': 7},
        ],
      },
    ],
  },
]);
