// /bin/sh stands in for an installed tmux.
@Tags(['posix'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/live_activity.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/terminal_bridge.dart';

/// Terminals that touch nothing on this Mac; [tmux]: an executable that exists.
Terminals _terms({bool tmux = false}) => Terminals(
  home: '/nonexistent-pocketterm',
  kitty: Kitty(socketDir: '/nonexistent-pocketterm', home: '/nonexistent-pocketterm', restoreFront: false),
  tmux: Tmux(executable: tmux ? '/bin/sh' : '/nonexistent-pocketterm/tmux', socketDirs: const []),
  wezterm: WezTerm(executable: '/nonexistent-pocketterm/wezterm', socketDir: '/nonexistent-pocketterm'),
  ghostty: Ghostty(appPath: '/nonexistent-pocketterm/Ghostty.app'),
);

void main() {
  group('answering an ask from the phone', () {
    test('works where the screen can be read and keys pressed', () {
      final terms = _terms();
      for (final key in ['kitty-1/2', 'tmux:default/0', 'wezterm:9/1']) {
        expect(cantAnswer(terms, key), isNull, reason: key);
      }
    });

    test("Ghostty can't show its screen; tmux is the way out", () {
      expect(
        cantAnswer(_terms(tmux: true), 'ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074'),
        contains('run in tmux there'),
      );
      final ghostty = cantAnswer(_terms(), 'ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074')!;
      expect(ghostty, startsWith("Ghostty can't show its screen"));
      expect(ghostty, contains('brew install tmux'));
    });
  });

  test('the phone hears of installed terminals, and of tmux even when missing', () {
    const statuses = [
      TermStatus('kitty', 'kitty', TermState.ready),
      TermStatus('tmux', 'tmux', TermState.missing, note: 'Install tmux'),
      TermStatus('wezterm', 'WezTerm', TermState.missing),
      TermStatus('ghostty', 'Ghostty', TermState.limited),
    ];
    expect(phoneTerminals(statuses).map((s) => s.id), ['kitty', 'tmux', 'ghostty']);
  });

  group('what goes to the phone fits under the server frame', () {
    int size(Object? json) => utf8.encode(jsonEncode(json)).length;
    final cmds = [
      for (var i = 0; i < 90; i++)
        ['command-$i', 'What command $i does, in up to eighty characters or so, as omp says'],
    ];
    Map<String, dynamic> state({int sessions = 60, int projects = 5000, int windows = 80}) => {
      'windows': [
        for (var i = 0; i < windows; i++)
          {'key': 'kitty-1/$i', 'title': 'π > 中文 window $i 😀', 'cwd': '/Users/me/p $i'},
      ],
      'sessions': [
        for (var i = 0; i < sessions; i++) {'key': 'kitty-1/$i', 'id': 's$i', 'title': 'Fix $i', 'cmds': cmds},
      ],
      'projects': [for (var i = 0; i < projects; i++) '/Users/me/Dev/some-organisation/project-number-$i'],
      'home': '/Users/me',
    };

    test('a small state goes as it is', () {
      final s = state(sessions: 2, projects: 10);
      expect(TerminalBridge.fitState(s, watched: const {}), same(s));
    });

    test("many sessions and repositories: unwatched sessions' commands go first, then repositories past what fits", () {
      final fit = TerminalBridge.fitState(state(), watched: {'kitty-1/3'});
      expect(size(fit), lessThanOrEqualTo(150000));
      final sessions = (fit['sessions'] as List).cast<Map<String, dynamic>>();
      expect(sessions.length, 60, reason: 'every session is still listed');
      expect(sessions.where((s) => s['cmds'] != null).map((s) => s['key']), ['kitty-1/3']);
      expect(sessions[3]['cmds'], cmds, reason: 'the watched one keeps its commands whole');
      expect((fit['windows'] as List).length, 80);
      final projects = fit['projects'] as List;
      expect(projects, isNotEmpty);
      expect(projects.length, lessThan(5000));
      expect(projects.first, '/Users/me/Dev/some-organisation/project-number-0');
    });

    test('with nothing else left to cut, windows go from the end', () {
      final fit = TerminalBridge.fitState(state(windows: 4000, projects: 0), watched: const {}, maxBytes: 100000);
      expect(size(fit), lessThanOrEqualTo(100000));
      expect((fit['windows'] as List).first, containsPair('key', 'kitty-1/0'));
    });

    test("unwatched sessions' queued prompts keep their start before anything a phone shows goes", () {
      final long = List.filled(4000, 'word').join(' ');
      final s = state(sessions: 8, projects: 100);
      for (final session in (s['sessions'] as List).cast<Map<String, dynamic>>()) {
        session['queue'] = [
          for (var i = 0; i < 4; i++) {'id': '${session['key']}-$i', 't': long, 'im': 1},
        ];
      }
      final fit = TerminalBridge.fitState(s, watched: {'kitty-1/3'});
      expect(size(fit), lessThanOrEqualTo(150000));
      final sessions = (fit['sessions'] as List).cast<Map<String, dynamic>>();
      final watched = (sessions[3]['queue'] as List).cast<Map<String, dynamic>>();
      expect(watched.map((q) => q['t']), everyElement(long), reason: 'the session a phone shows keeps them whole');
      expect(watched.map((q) => q['c']), everyElement(isNull));
      final other = LiveSummary.fromJson(sessions[0]).queue;
      expect(other.map((q) => q.cut), everyElement(isTrue));
      expect(other.first.text, startsWith('word word'));
      expect(other.first.text.length, lessThan(long.length));
      expect(other.first.images, 1);
      expect((fit['projects'] as List).length, 100, reason: 'nothing else had to go');
    });

    test('a screen keeps its newest lines; a single line too long keeps its start', () {
      final lines = [for (var i = 0; i < 5000; i++) '\x1b[38;2;1;2;3m$i 中文 😀\x1b[0m'];
      final fit = TerminalBridge.fitLines(lines, 60000);
      expect(size(fit), lessThanOrEqualTo(60000));
      expect(fit.last, lines.last);
      expect(fit, lines.sublist(lines.length - fit.length));
      final long = TerminalBridge.fitLines(['x' * 200000], 60000);
      expect(size(long), lessThanOrEqualTo(60000));
      expect(long.single, startsWith('xxx'));
      expect(TerminalBridge.fitLines(const [], 60000), isEmpty);
    });
  });

  test('an error only when nothing shows and no terminal is usable: the setup one', () {
    const setup = TermStatus('kitty', 'kitty', TermState.setup, note: "kitty isn't listening.");
    const idle = TermStatus('ghostty', 'Ghostty', TermState.idle);
    const limited = TermStatus('wezterm', 'WezTerm', TermState.limited);
    expect(terminalsError([idle, setup], nothingShown: true), "kitty isn't listening.");
    expect(terminalsError([idle, setup], nothingShown: false), isNull);
    expect(terminalsError([setup, limited], nothingShown: true), isNull);
    expect(terminalsError([idle], nothingShown: true), isNull);
  });

  test("a slash command for a session in no terminal PocketTerm drives (IntelliJ's) is refused, not sent as chat", () {
    final terms = _terms();
    for (final key in ['kitty-1/2', 'tmux:default/0', 'ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074']) {
      expect(cantCommand(terms, key), isNull, reason: key);
    }
    expect(cantCommand(terms, null), startsWith("Slash commands are typed into the agent's terminal window"));
  });

  test('a phone image goes as PNG or JPEG; off the Mac nothing else is read', () async {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D]);
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
    final heic = Uint8List.fromList([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]);
    expect((await TerminalBridge.image(png, macos: false)).mimeType, 'image/png');
    expect((await TerminalBridge.image(jpeg, macos: false)).mimeType, 'image/jpeg');
    await expectLater(
      TerminalBridge.image(heic, macos: false),
      throwsA(
        isA<LiveException>().having((e) => e.message, 'message', 'This computer reads PNG and JPEG images only.'),
      ),
    );
  });

  test("a phone's image or file is stored sealed, and only this computer's key opens it, for its own path; a file's "
      'name and type go only in the prompt', () async {
    final dir = Directory.systemTemp.createTempSync('pocketterm_image');
    addTearDown(() => dir.deleteSync(recursive: true));
    final key = ChannelKey.generate();
    final stored = <String, Uint8List>{};
    final runs = <Map<String, dynamic>>[];
    late final TerminalRemote phone;
    phone = TerminalRemote(
      PocketTermServerClient(const Backend(url: 'http://localhost:1'), tokens: MemoryDeviceTokens()),
      dir,
      desktopId: 'abcd1234',
      key: key,
      from: 'phone',
      upload: (path, sealed) async => stored[path] = sealed,
      send: (event, payload) {
        if (event != 'run') return;
        runs.add(payload);
        phone.handle('ran', {'id': payload['id']});
      },
    )..handle('state', {'windows': const <Object>[], 'sessions': const <Object>[]});
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 1, 2, 3]);
    final pdf = Uint8List.fromList('%PDF-1.7 quarterly numbers'.codeUnits);

    await phone.prompt(
      'kitty-1/2',
      'look',
      images: [png],
      files: [(name: 'Q3 report.pdf', mime: 'application/pdf', bytes: pdf)],
    );

    final path = (runs.single['images'] as List).single as String;
    expect(Server.isBlobPath(path), isTrue);
    final sealed = stored[path]!;
    expect(sealed, isNot(containsAllInOrder(png)), reason: 'Storage never holds the image itself');
    expect(await TerminalBridge.openBlob(key, path, sealed), png);
    expect(
      (await TerminalBridge.image(await TerminalBridge.openBlob(key, path, sealed), macos: false)).mimeType,
      'image/png',
    );
    await expectLater(TerminalBridge.openBlob(ChannelKey.generate(), path, sealed), throwsA(isA<LiveException>()));
    await expectLater(TerminalBridge.openBlob(key, 'another', sealed), throwsA(isA<LiveException>()));

    final file = (runs.single['files'] as List).single as Map<String, dynamic>;
    expect(file['name'], 'Q3 report.pdf');
    expect(file['mime'], 'application/pdf');
    final filePath = file['path'] as String;
    expect(Server.isBlobPath(filePath), isTrue);
    expect(filePath, isNot(path));
    final sealedFile = stored[filePath]!;
    expect(sealedFile, isNot(containsAllInOrder(pdf)), reason: 'Storage never holds the file itself');
    expect(sealedFile, isNot(containsAllInOrder('Q3 report'.codeUnits)), reason: 'nor its name');
    expect(await TerminalBridge.openBlob(key, filePath, sealedFile), pdf);
    await expectLater(TerminalBridge.openBlob(key, path, sealedFile), throwsA(isA<LiveException>()));
  });

  test("a followed session's update goes sealed for Android; iPhones get only its state", () async {
    final key = ChannelKey.generate();
    final body = await TerminalBridge.activityPush(key, 'abcd1234', 'kitty-1/2', (
      state: ActivityState.needs,
      kind: ActivityKind.approval,
    ));
    expect(body.keys, unorderedEquals(['session', 'state', 'kind', 'tag', 'enc']));
    expect(body['session'], 'abcd1234/kitty-1/2');
    // The phone finds the key by this computer's tag; the computer's id goes only inside the seal.
    expect(body['tag'], await pushTag(key));

    final sealed = base64Decode(body['enc']! as String);
    final opened = jsonDecode(utf8.decode((await openBytes(key, sealed, activityAad('abcd1234')))!));
    expect(opened, {
      'session': 'abcd1234/kitty-1/2',
      'state': 'needs',
      'kind': 'approval',
      'since': isA<int>(),
      'ts': isA<int>(),
      'id': isA<String>(),
    });
    // Not another computer's, not a notification.
    expect(await openBytes(key, sealed, activityAad('zzzz9999')), isNull);
    expect(await openBytes(key, sealed, pushAad('abcd1234')), isNull);
  });

  test('a request sent again under its id is answered as before, not run twice; ids are forgotten after a while', () {
    var now = DateTime(2026);
    final runs = RunLog(clock: () => now);
    final again = <Map<String, dynamic>>[];
    expect(runs.start('a', again.add), isTrue);
    expect(runs.start('a', again.add), isFalse, reason: 'still running: its answer goes out when it ends');
    expect(again, isEmpty);
    runs.done('a', {'id': 'a', 'error': 'nope'});
    expect(runs.start('a', again.add), isFalse);
    expect(again.single, {'id': 'a', 'error': 'nope', 'repeat': true});
    expect(runs.start('b', again.add), isTrue, reason: 'another request runs');
    now = now.add(const Duration(minutes: 3));
    expect(runs.start('a', again.add), isTrue);
  });

  group('switching a screen-only agent window to its conversation', () {
    const window = 'kitty-1/7';
    const tty = 'ttys004';
    late List<String> log;
    late _FakeKitty kitty;
    late List<String> foreground;

    /// A kitty that records what it's told, and `ps` showing [foreground]'s programs on [tty] in turn (the last
    /// one from then on).
    Terminals terms() => Terminals(
      home: '/nonexistent-pocketterm',
      kitty: kitty,
      snapshot: () async {
        final program = foreground.length > 1 ? foreground.removeAt(0) : foreground.single;
        log.add('ps $program');
        return Procs([
          Proc(pid: 40, ppid: 1, pgid: 40, tpgid: program == 'zsh' ? 40 : 50, tty: tty, stat: 'Ss', args: '-zsh'),
          if (program != 'zsh') Proc(pid: 50, ppid: 40, pgid: 50, tpgid: 50, tty: tty, stat: 'S+', args: program),
        ]);
      },
    );

    Future<void> run(Terminals t, Agent agent, {String tty = tty, String profile = ''}) => switchToConversation(
      t,
      window,
      agent,
      tty: tty,
      profile: profile,
      settle: Duration.zero,
      noTty: Duration.zero,
      pollEvery: Duration.zero,
      quitFor: const Duration(milliseconds: 200),
    );

    setUp(() {
      log = [];
      kitty = _FakeKitty(log);
      foreground = ['omp'];
    });

    test('omp: Esc, Ctrl+C, Ctrl+D, then omp -c once omp has quit', () async {
      foreground = ['omp', 'omp', 'omp', 'zsh'];
      await run(terms(), Agent.omp);
      expect(log, [
        'ps omp',
        'keys esc',
        'keys ctrl+c',
        'keys ctrl+d',
        'ps omp',
        'ps omp',
        'ps zsh',
        'type omp -c',
        'keys enter',
      ]);
    });

    test('omp in a profile starts again in that profile', () async {
      foreground = ['omp --profile=personal', 'omp --profile=personal', 'zsh'];
      await run(terms(), Agent.omp, profile: 'personal');
      expect(log.where((l) => l.startsWith('type')), ['type omp --profile=personal -c']);
    });

    test("a phone's launch runs omp only in a profile this computer has, and other agents in none", () {
      expect(launchProfile('personal', Agent.omp, ['personal']), 'personal');
      expect(launchProfile(null, Agent.omp, ['personal']), '');
      expect(launchProfile('', Agent.omp, ['personal']), '');
      expect(() => launchProfile('x', Agent.omp, ['personal']), throwsA(isA<TerminalException>()));
      expect(() => launchProfile('a; rm -rf ~', Agent.omp, ['personal']), throwsA(isA<TerminalException>()));
      expect(launchProfile('personal', Agent.claude, ['personal']), '');
    });

    test('an agent that quit since the phone looked gets no keys: Ctrl+D would end the shell', () async {
      foreground = ['zsh'];
      for (final agent in Agent.values) {
        await expectLater(
          run(terms(), agent),
          throwsA(isA<TerminalException>().having((e) => e.message, 'message', contains("isn't running"))),
        );
      }
      expect(log.where((l) => !l.startsWith('ps')), isEmpty);
    });

    test('omp in a terminal that tells no tty: omp -c after a wait', () async {
      await run(terms(), Agent.omp, tty: '');
      expect(log, ['keys esc', 'keys ctrl+c', 'keys ctrl+d', 'type omp -c', 'keys enter']);
    });

    test("omp that doesn't quit gets nothing typed into it", () async {
      await expectLater(
        run(terms(), Agent.omp),
        throwsA(isA<TerminalException>().having((e) => e.message, 'message', startsWith("omp didn't quit."))),
      );
      expect(log.where((l) => l.startsWith('type')), isEmpty);
    });

    test('Claude Code: /reload-plugins and Enter, nothing restarts', () async {
      foreground = ['claude'];
      await run(terms(), Agent.claude);
      expect(log, ['ps claude', 'type /reload-plugins', 'keys enter']);
    });

    test("a terminal that can't press keys is refused", () async {
      await expectLater(
        switchToConversation(terms(), 'nowhere:1', Agent.omp),
        throwsA(
          isA<TerminalException>().having((e) => e.message, 'message', startsWith("This terminal can't press keys")),
        ),
      );
    });

    test("probe: busy when the screen changes between two reads, not when it doesn't", () async {
      kitty.screens = ['π ⠋ Working', 'π ⠙ Working'];
      expect(await screenChanges(terms(), window, gap: Duration.zero), isTrue);
      kitty.screens = ['π > idle', 'π > idle'];
      expect(await screenChanges(terms(), window, gap: Duration.zero), isFalse);
    });

    test("probe in a terminal that can't show its screen (Ghostty): busy when the title spins", () async {
      const key = 'ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074';
      final ghostty = _FakeGhostty();
      final t = Terminals(home: '/nonexistent-pocketterm', ghostty: ghostty, snapshot: () async => Procs(const []));
      ghostty.titles = ['π ⠋ chat', 'π ⠋ chat', 'π ⠙ chat'];
      expect(await screenChanges(t, key, gap: Duration.zero), isTrue);
      ghostty.titles = ['π > chat'];
      expect(await screenChanges(t, key, gap: Duration.zero), isFalse);
      ghostty.titles = [];
      await expectLater(screenChanges(t, key, gap: Duration.zero), throwsA(isA<TerminalException>()));
    });
  });
}

/// kitty as the bridge drives it: what it's told goes to [log]; its screen is [screens] in turn.
class _FakeKitty extends Kitty {
  _FakeKitty(this.log)
    : super(socketDir: '/nonexistent-pocketterm', home: '/nonexistent-pocketterm', restoreFront: false);
  final List<String> log;
  List<String> screens = const [''];

  @override
  Future<void> pressKeys(String key, List<String> names) async => log.add('keys ${names.join(' ')}');

  @override
  Future<void> type(String key, String text) async => log.add('type $text');

  @override
  Future<String> plainScreen(String key) async => screens.length > 1 ? screens.removeAt(0) : screens.single;
}

/// Ghostty with one window whose title is [titles] in turn (none: no window).
class _FakeGhostty extends Ghostty {
  List<String> titles = const [];

  @override
  Future<List<TermWindow>> windows(Procs procs) async => [
    if (titles.isNotEmpty)
      TermWindow(
        key: 'ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074',
        title: titles.length > 1 ? titles.removeAt(0) : titles.single,
        tab: '',
        cwd: '/p/chat',
        program: '',
        app: 'ghostty',
        caps: caps,
      ),
  ];
}
