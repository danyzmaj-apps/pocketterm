// /bin/sh stands in for an installed tmux.
@Tags(['posix'])
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/apple_terminal.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/iterm.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/terminal_bridge.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;

/// Terminals that touch nothing on this Mac; [tmux]: an executable that exists.
Terminals _terms({bool tmux = false}) => Terminals(
  home: '/nonexistent-pocketterm',
  kitty: Kitty(socketDir: '/nonexistent-pocketterm', home: '/nonexistent-pocketterm', restoreFront: false),
  tmux: Tmux(executable: tmux ? '/bin/sh' : '/nonexistent-pocketterm/tmux', socketDirs: const []),
  wezterm: WezTerm(executable: '/nonexistent-pocketterm/wezterm', socketDir: '/nonexistent-pocketterm'),
  iterm: ITerm(appPath: '/nonexistent-pocketterm/iTerm.app'),
  terminal: AppleTerminal(appPath: '/nonexistent-pocketterm/Terminal.app'),
  ghostty: Ghostty(appPath: '/nonexistent-pocketterm/Ghostty.app'),
);

void main() {
  group('answering an ask from the phone', () {
    test('works where the screen can be read and keys pressed', () {
      final terms = _terms();
      for (final key in ['kitty-1/2', 'tmux:default/0', 'wezterm:9/1', 'iterm:6A4030A3-8364-4898-9CEA-F189424E874A']) {
        expect(cantAnswer(terms, key), isNull, reason: key);
      }
    });

    test("Terminal can't press keys, Ghostty can't show its screen; tmux is the way out", () {
      expect(cantAnswer(_terms(tmux: true), 'terminal:ttys009'), startsWith("Terminal can't press keys"));
      expect(cantAnswer(_terms(tmux: true), 'terminal:ttys009'), contains('run in tmux there'));
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

  test('an error only when nothing shows and no terminal is usable: the setup one', () {
    const setup = TermStatus('kitty', 'kitty', TermState.setup, note: "kitty isn't listening.");
    const idle = TermStatus('ghostty', 'Ghostty', TermState.idle);
    const limited = TermStatus('terminal', 'Terminal', TermState.limited);
    expect(terminalsError([idle, setup], nothingShown: true), "kitty isn't listening.");
    expect(terminalsError([idle, setup], nothingShown: false), isNull);
    expect(terminalsError([setup, limited], nothingShown: true), isNull);
    expect(terminalsError([idle], nothingShown: true), isNull);
  });

  test("a slash command for a session in no terminal PocketTerm drives (IntelliJ's) is refused, not sent as chat", () {
    final terms = _terms();
    for (final key in [
      'kitty-1/2',
      'tmux:default/0',
      'terminal:ttys009',
      'ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074',
    ]) {
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

  test("a phone's image is stored sealed, and only this computer's key opens it, for its own path", () async {
    final dir = Directory.systemTemp.createTempSync('pocketterm_image');
    addTearDown(() => dir.deleteSync(recursive: true));
    final key = ChannelKey.generate();
    final stored = <String, Uint8List>{};
    final runs = <Map<String, dynamic>>[];
    late final TerminalRemote phone;
    phone = TerminalRemote(
      SupabaseClient('http://localhost:1', 'anon'),
      'u1',
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

    await phone.prompt('kitty-1/2', 'look', images: [png]);

    final path = (runs.single['images'] as List).single as String;
    expect(path, startsWith('u1/'));
    final sealed = stored[path]!;
    expect(sealed, isNot(containsAllInOrder(png)), reason: 'Storage never holds the image itself');
    expect(await TerminalBridge.openImage(key, path, sealed), png);
    expect(
      (await TerminalBridge.image(await TerminalBridge.openImage(key, path, sealed), macos: false)).mimeType,
      'image/png',
    );
    await expectLater(TerminalBridge.openImage(ChannelKey.generate(), path, sealed), throwsA(isA<LiveException>()));
    await expectLater(TerminalBridge.openImage(key, 'u1/another', sealed), throwsA(isA<LiveException>()));
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
      terminal: AppleTerminal(appPath: '/nonexistent-pocketterm/Terminal.app'),
      snapshot: () async {
        final program = foreground.length > 1 ? foreground.removeAt(0) : foreground.single;
        log.add('ps $program');
        return Procs([
          Proc(pid: 40, ppid: 1, pgid: 40, tpgid: program == 'zsh' ? 40 : 50, tty: tty, stat: 'Ss', args: '-zsh'),
          if (program != 'zsh') Proc(pid: 50, ppid: 40, pgid: 50, tpgid: 50, tty: tty, stat: 'S+', args: program),
        ]);
      },
    );

    Future<void> run(Terminals t, Agent agent, {String tty = tty}) => switchToConversation(
      t,
      window,
      agent,
      tty: tty,
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
      foreground = ['omp', 'omp', 'zsh'];
      await run(terms(), Agent.omp);
      expect(log, [
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
      await run(terms(), Agent.claude);
      expect(log, ['type /reload-plugins', 'keys enter']);
    });

    test("a terminal that can't press keys is refused", () async {
      await expectLater(
        switchToConversation(terms(), 'terminal:ttys009', Agent.omp),
        throwsA(isA<TerminalException>().having((e) => e.message, 'message', startsWith("Terminal can't press keys"))),
      );
    });

    test("probe: busy when the screen changes between two reads, not when it doesn't", () async {
      kitty.screens = ['π ⠋ Working', 'π ⠙ Working'];
      expect(await screenChanges(terms(), window, gap: Duration.zero), isTrue);
      kitty.screens = ['π > idle', 'π > idle'];
      expect(await screenChanges(terms(), window, gap: Duration.zero), isFalse);
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
