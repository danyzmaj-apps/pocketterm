@Tags(['posix'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/terminal.dart';

// Outputs and environments below were captured on a Mac (macOS 26, tmux 3.6,
// WezTerm 20240203, Ghostty 1.3.1, kitty 0.4x), names shortened.

/// `ps -Ao pid=,ppid=,pgid=,tpgid=,tty=,stat=,args=`: a terminal tab (login,
/// then zsh in front), a Ghostty window attached to tmux (login, tmux client
/// in front), omp running in a tab, and a daemon without a tty.
const _ps = '''
98233 94784 98233 98234 ttys009  Ss   login -pf me
98234 98233 98234 98234 ttys009  S+   -zsh
97914 97159 97914 97914 ttys010  Ss+  /usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l '/opt/homebrew/bin/tmux' 'attach-session' '-t' '=pt-mv82o7z3'
97915 97914 97914 97914 ttys010  S+   -/opt/homebrew/bin/tmux attach-session -t =pt-mv82o7z3
 5150  5149  5150  5249 ttys008  Ss   -zsh
 5249  5150  5249  5249 ttys008  Rl+  omp --no-extensions -e /Users/me/live.ts
 7885 95874  7885     -1 ?        Rsl  /opt/homebrew/Cellar/omp/18.4.2/bin/omp __omp_worker_daemon_broker
''';

void main() {
  group('processes', () {
    test('parsePs reads every line, a missing tty as empty', () {
      final procs = parsePs(_ps);
      expect(procs.map((p) => p.pid), [98233, 98234, 97914, 97915, 5150, 5249, 7885]);
      final daemon = procs.last;
      expect((daemon.ppid, daemon.pgid, daemon.tpgid, daemon.tty, daemon.stat), (95874, 7885, -1, '', 'Rsl'));
      expect(procs[5].args, 'omp --no-extensions -e /Users/me/live.ts');
    });

    test('the foreground program of a tty is the leader of its foreground group', () {
      final procs = Procs(parsePs(_ps));
      expect(procs.foreground('ttys009')?.program, 'zsh');
      expect(procs.foreground('/dev/ttys008')?.program, 'omp');
      expect(procs.foreground('ttys008')?.pid, 5249);
      expect(procs.foreground('ttys099'), isNull);
      expect(procs.foreground(''), isNull);
    });

    test('programOf names the program, a login shell without its dash, a script by its name', () {
      expect(programOf('-zsh'), 'zsh');
      expect(programOf('/opt/homebrew/Cellar/omp/18.4.2/bin/omp __omp_worker_daemon_broker'), 'omp');
      expect(programOf('-/opt/homebrew/bin/tmux attach-session -t =x'), 'tmux');
      expect(programOf('node --no-warnings /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js'), 'cli');
      expect(programOf('bun /Users/me/bin/omp.ts --continue'), 'omp');
      expect(programOf('python3 -u server.py'), 'server');
      expect(programOf('claude'), 'claude');
      expect(programOf('   '), '');
    });

    test('parseLsofCwd maps each pid to its folder', () {
      const out = 'p98234\nfcwd\nn/private/tmp/dzt/cap-terminal\np1129\nfcwd\nn/Users/me/Dev/x y\n';
      expect(parseLsofCwd(out), {98234: '/private/tmp/dzt/cap-terminal', 1129: '/Users/me/Dev/x y'});
      expect(parseLsofCwd(''), isEmpty);
    });

    test('utf8Locale adds a UTF-8 LC_CTYPE only when the first locale set is none (Finder sets none)', () {
      const add = {'LC_CTYPE': 'UTF-8'};
      expect(utf8Locale(const {}), add);
      expect(utf8Locale(const {'LANG': ''}), add);
      expect(utf8Locale(const {'LANG': 'C'}), add);
      expect(utf8Locale(const {'LANG': 'hr_HR.UTF-8'}), isEmpty);
      expect(utf8Locale(const {'LANG': 'C', 'LC_CTYPE': 'de_DE.utf8'}), isEmpty);
    });
  });

  group('keys', () {
    test('keyBytes sends what a terminal sends for each key, Shift+Enter as Alt+Enter', () {
      expect(keyBytes('enter'), '\r');
      expect(keyBytes('esc'), '\x1b');
      expect(keyBytes('tab'), '\t');
      expect(keyBytes('shift+tab'), '\x1b[Z');
      expect(keyBytes('up'), '\x1b[A');
      expect(keyBytes('left'), '\x1b[D');
      expect(keyBytes('backspace'), '\x7f');
      expect(keyBytes('shift+enter'), '\x1b\r');
      expect(keyBytes('ctrl+c'), '\x03');
      expect(keyBytes('ctrl+a'), '\x01');
      expect(keyBytes('3'), '3');
      expect(() => keyBytes('ctrl+shift+x'), throwsA(isA<TerminalException>()));
    });

    test('keyRuns keeps Esc apart, so what follows is not read as Alt+key', () {
      expect(keyRuns(['down', 'down', 'enter']), ['\x1b[B\x1b[B\r']);
      expect(keyRuns(['up', 'esc', 'x']), ['\x1b[A', '\x1b', 'x']);
      expect(keyRuns(['esc']), ['\x1b']);
      expect(keyRuns([]), isEmpty);
    });

    test('textChunks cuts long text between characters, within the byte limit, keeping every byte in order', () {
      final text = 'ab漢👍🏽e\u0301${'x' * 20}';
      final chunks = textChunks(text, 5);
      expect(chunks.join(), text);
      for (final c in chunks) {
        expect(c.runes.isNotEmpty, isTrue);
        expect(utf8.encode(c).length, lessThanOrEqualTo(5), reason: c);
      }
      // A surrogate pair (an emoji) is never split.
      expect(chunks, contains('👍'));
      expect(textChunks('', 5), isEmpty);
      expect(textChunks('short', 100), ['short']);
    });
  });

  group('screens', () {
    test("screenLines drops WezTerm's charset choices, so a reset-only line is blank", () {
      // `wezterm cli get-text --escapes` of a prompt in an otherwise empty pane.
      const text = '\x1b(B\x1b[0;1m\x1b[32m➜  \x1b[36mwezterm\r\n\x1b(B\x1b[0m\r\n';
      expect(screenLines(text), ['\x1b[0;1m\x1b[32m➜  \x1b[36mwezterm']);
    });

    test('a newest line longer than the history budget comes as its end, not as nothing', () {
      // kitty's history joins a wrapped line's rows: `cat` of a minified file.
      final long = '\x1b[38:2:1:2:3m${'é' * historyBytes}';
      final lines = screenLines('older\n$long\n\n');
      expect(lines, hasLength(1));
      expect(utf8.encode(lines.single).length, lessThan(historyBytes));
      expect(lines.single, endsWith('é' * 100));
      // A cut inside an escape starts after it, so none of its bytes show.
      final colored = List.filled(historyBytes ~/ 4, '\x1b[31mx').join();
      expect(screenLines(colored).single, matches(RegExp('^(\x1b\\[31m)?x(\x1b\\[31mx)*\$')));
    });
  });

  group('titles', () {
    test('control characters, escapes and bidi overrides go; tab and newline read as spaces', () {
      expect(cleanTitle('x\ty\nz\x1b[31m red\x07\x01'), 'x y z red');
      expect(cleanTitle('\x1b]0;inner\x07omp \u202eevil'), 'omp evil');
      expect(cleanTitle('漢字 👍🏽 é שלום zero\u200bwidth'), '漢字 👍🏽 é שלום zero\u200bwidth');
    });

    test('a very long title is cut to titleRunes characters, never inside an emoji', () {
      final t = cleanTitle('👍' * 1000);
      expect(t.runes, hasLength(titleRunes));
      expect(t, endsWith('👍\u2026'));
      expect(cleanTitle('t' * titleRunes), 't' * titleRunes);
    });
  });

  group('windowOfTerm', () {
    test('kitty: the socket it listens on, else its pid', () {
      expect(
        windowOfTerm({'KITTY_WINDOW_ID': '7', 'KITTY_PID': '88858', 'KITTY_LISTEN_ON': 'unix:/tmp/dzt/ks/kitty'}),
        'kitty/7',
      );
      expect(
        windowOfTerm({'KITTY_WINDOW_ID': '116', 'KITTY_PID': '23224', 'KITTY_LISTEN_ON': 'unix:/tmp/kitty-23224'}),
        'kitty-23224/116',
      );
      expect(windowOfTerm({'KITTY_WINDOW_ID': '3', 'KITTY_PID': '501'}), 'kitty-501/3');
      // A socket that isn't kitty's own name can't be found again.
      expect(windowOfTerm({'KITTY_WINDOW_ID': '3', 'KITTY_LISTEN_ON': 'unix:/tmp/other'}), isNull);
    });

    test('tmux wins over the terminal showing it, even with kitty variables leaked in', () {
      expect(
        windowOfTerm({
          'TERM_PROGRAM': 'tmux',
          'KITTY_WINDOW_ID': '116',
          'KITTY_PID': '23224',
          'KITTY_LISTEN_ON': 'unix:/tmp/kitty-23224',
          'TMUX': '/private/tmp/tmux-501/default,4226,0',
          'TMUX_PANE': '%0',
        }),
        'tmux:default/0',
      );
      expect(windowOfTerm({'TMUX': '/private/tmp/tmux-501/work,1,0', 'TMUX_PANE': '%12'}), 'tmux:work/12');
    });

    test('WezTerm and Ghostty started from kitty: their own TERM_PROGRAM wins over the leaked KITTY_*', () {
      const leaked = {'KITTY_WINDOW_ID': '116', 'KITTY_PID': '23224', 'KITTY_LISTEN_ON': 'unix:/tmp/kitty-23224'};
      expect(
        windowOfTerm({
          ...leaked,
          'TERM_PROGRAM': 'WezTerm',
          'WEZTERM_PANE': '2',
          'WEZTERM_UNIX_SOCKET': '/Users/me/.local/share/wezterm/gui-sock-40899',
        }),
        'wezterm:40899/2',
      );
      // Ghostty tells nothing to match: Terminals.locate finds it by folder.
      expect(windowOfTerm({...leaked, 'TERM_PROGRAM': 'ghostty', 'tty': '/dev/ttys007'}), isNull);
    });

    test('nothing known: null', () {
      expect(windowOfTerm(null), isNull);
      expect(windowOfTerm({}), isNull);
      expect(windowOfTerm({'TERM_PROGRAM': 'vscode', 'tty': '/dev/ttys003'}), isNull);
    });
  });

  group('TermWindow', () {
    test("an older Mac's window (no app, no caps) is kitty's, able to do everything", () {
      final w = TermWindow.fromJson({'key': 'kitty-1/2', 'title': 't', 'program': 'claude'});
      expect(w.app, 'kitty');
      expect(w.caps, allCaps);
      expect(w.agent, Agent.claude);
    });

    test('caps and via survive the trip to the phone; unknown caps are dropped', () {
      const w = TermWindow(
        key: 'tmux:default/0',
        title: 'x',
        tab: 's:w',
        cwd: '/x',
        program: 'zsh',
        app: 'tmux',
        via: 'Ghostty',
        caps: {TermCap.type, TermCap.keys},
      );
      final back = TermWindow.fromJson({
        ...w.toJson(),
        'caps': [...(w.toJson()['caps'] as List), 'teleport'],
      });
      expect((back.app, back.via), ('tmux', 'Ghostty'));
      expect(back.caps, {TermCap.type, TermCap.keys});
    });
  });

  group('AppleScript', () {
    // osascript stood in for by sh: the consent look answers the next of
    // [looks], the question to the person runs [ask], a script runs [script].
    late List<List<String>> started;
    late List<Process> procs;

    AppleScript osa(List<String> looks, {String ask = 'sleep 30', String script = 'echo out'}) => AppleScript(
      timeout: const Duration(milliseconds: 600),
      stuckAfter: const Duration(milliseconds: 200),
      start: (exe, args) async {
        started.add(args);
        final cmd = !args.contains('JavaScript')
            ? script
            : args.last == 'ask'
            ? ask
            : 'echo ${looks.removeAt(0)}';
        final p = await Process.start('/bin/sh', ['-c', cmd]);
        procs.add(p);
        return p;
      },
    );

    List<String> kinds() => [
      for (final a in started)
        if (a.contains('JavaScript')) a.last else 'script',
    ];
    final pending = isA<AutomationPending>().having((e) => e.app, 'app', 'Terminal');

    setUp(() {
      started = [];
      procs = [];
    });
    tearDown(() {
      for (final p in procs) {
        p.kill(ProcessSignal.sigkill);
      }
    });

    test('while macOS asks, scripts fail at once naming the app, and nothing piles up', () async {
      final o = osa(['-1744']);
      for (var i = 0; i < 3; i++) {
        await expectLater(o.run('Terminal', 'com.apple.Terminal', 'x'), throwsA(pending));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(kinds(), ['look', 'ask']);
    });

    test('once the person says yes, scripts go to the app without asking again', () async {
      final o = osa(['-1744'], ask: 'echo 0');
      await expectLater(o.run('Terminal', 'com.apple.Terminal', 'x'), throwsA(pending));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await Future.wait([for (final p in procs) p.exitCode]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await o.run('Terminal', 'com.apple.Terminal', 'x'), 'out');
      expect(await o.run('Terminal', 'com.apple.Terminal', 'x'), 'out');
      expect(kinds(), ['look', 'ask', 'script', 'script']);
    });

    test('a "no" fails without sending the app anything', () async {
      await expectLater(
        osa(['-1743']).run('Terminal', 'com.apple.Terminal', 'x'),
        throwsA(isA<AutomationDenied>().having((e) => e.app, 'app', 'Terminal')),
      );
      expect(kinds(), ['look']);
    });

    test('a script that never finishes is killed', () async {
      final o = osa(['0'], script: 'sleep 30');
      await expectLater(
        o.run('Terminal', 'com.apple.Terminal', 'x'),
        throwsA(isA<TerminalException>().having((e) => e.message, 'message', contains('did not answer'))),
      );
      expect(await procs.last.exitCode, -9);
    });

    test('a script that started the app and then waits on macOS asking is killed and fails as asking', () async {
      // Not running when looked at (-600); the script starts it, and macOS asks.
      final o = osa(['-600', '-1744'], script: 'sleep 30');
      await expectLater(o.run('Terminal', 'com.apple.Terminal', 'x'), throwsA(pending));
      expect(await procs[1].exitCode, -9);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(kinds(), ['look', 'script', 'look', 'ask']);
    });

    test('a question helper that fails to start leaves the next script free to look again', () async {
      final looks = ['-1744', '0'];
      final o = AppleScript(
        timeout: const Duration(milliseconds: 600),
        stuckAfter: const Duration(milliseconds: 200),
        start: (exe, args) async {
          started.add(args);
          if (args.last == 'ask') throw const ProcessException('/usr/bin/osascript', [], 'Resource busy');
          final cmd = args.contains('JavaScript') ? 'echo ${looks.removeAt(0)}' : 'echo out';
          final p = await Process.start('/bin/sh', ['-c', cmd]);
          procs.add(p);
          return p;
        },
      );
      await expectLater(o.run('Terminal', 'com.apple.Terminal', 'x'), throwsA(pending));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await o.run('Terminal', 'com.apple.Terminal', 'x'), 'out');
      expect(kinds(), ['look', 'ask', 'look', 'script']);
    });
  });
}
