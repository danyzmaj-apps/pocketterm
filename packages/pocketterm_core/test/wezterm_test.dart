@Tags(['posix'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/wezterm.dart';

/// `wezterm cli list --format json` of WezTerm 20240203 on a Mac, its pane in
/// `sp ace'q 漢字 100%` (a `%` the shell's report left unescaped).
const _list = r'''
[{"window_id":0,"tab_id":0,"pane_id":0,"workspace":"default","title":"bash\u0007\u001b[31mx","tab_title":"",
"cwd":"file:///private/tmp/ptw/sp%20ace'q%20%E6%BC%A2%E5%AD%97%20100%","is_active":true,"tty_name":"/dev/ttys014"}]''';

void main() {
  late Directory dir;
  setUp(() => dir = Directory('/tmp').createTempSync('ptw'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// A WezTerm whose `wezterm` runs [script] (each run's last argument
  /// appended to `log`, RS after it), and a GUI socket for pid 1.
  WezTerm fake(String script, {bool windows = false}) {
    final exe = File('${dir.path}/wezterm')
      ..writeAsStringSync(
        '#!/bin/sh\nfor a; do last="\$a"; done\nprintf \'%s\\036\' "\$last" >> ${dir.path}/log\n$script\n',
      );
    Process.runSync('/bin/chmod', ['+x', exe.path]);
    File('${dir.path}/gui-sock-1').writeAsStringSync('');
    return WezTerm(executable: exe.path, socketDir: dir.path, windows: windows);
  }

  List<String> runs() {
    final log = File('${dir.path}/log');
    if (!log.existsSync()) return const [];
    final parts = log.readAsStringSync().split('\x1e');
    return parts.sublist(0, parts.length - 1);
  }

  Matcher says(String message) => throwsA(isA<TerminalException>().having((e) => e.message, 'message', message));

  test('a pane WezTerm no longer has reads as gone (its "no such pane")', () async {
    final w = fake(
      'echo \'03:33:56.758  ERROR  wezterm > unexpected response Ok(ErrorResponse(ErrorResponse { reason: "Error: no '
      'such pane 99" })); terminating\' >&2; exit 1',
    );
    await expectLater(w.type('wezterm:1/99', 'x'), says('That window is gone.'));
    await expectLater(w.close('wezterm:1/99'), says('That window is gone.'));
  });

  test('a GUI that quit and left its socket says WezTerm is not running, not its log line', () async {
    final w = fake(
      'echo \'03:18:43.546  ERROR  wezterm > failed to connect to Socket("/x/gui-sock-1"): connecting to '
      "/x/gui-sock-1; terminating' >&2; exit 1",
    );
    await expectLater(w.plainScreen('wezterm:1/0'), says("WezTerm isn't running."));
  });

  test('another error says what the GUI gave as its reason', () async {
    final w = fake(
      'echo \'03:33:56.823  ERROR  wezterm > unexpected response Ok(ErrorResponse(ErrorResponse { reason: "Error: '
      'window_id 99 not found on this server" })); terminating\' >&2; exit 1',
    );
    await expectLater(w.plainScreen('wezterm:1/0'), says('WezTerm: window_id 99 not found on this server'));
  });

  test("on Windows, a command too new for this WezTerm doesn't hide its windows for a minute", () async {
    final w = fake("echo \"error: unrecognized subcommand 'kill-pane'\" >&2; exit 2", windows: true);
    await expectLater(w.close('wezterm:1/0'), says(WezTerm.tooOld));
    // The socket is still asked: the GUI is fine.
    await expectLater(w.close('wezterm:1/0'), says(WezTerm.tooOld));
    expect(runs(), hasLength(2));
  });

  test("output that isn't UTF-8 reads with U+FFFD instead of failing", () async {
    final w = fake(r"printf 'a\377b'");
    expect(await w.plainScreen('wezterm:1/0'), 'a\uFFFDb');
  });

  test('long text goes in pieces a command line takes, in order', () async {
    final w = fake('exit 0');
    final text = List.generate(3000, (i) => 'é漢👍"\'\$x$i ').join();
    await w.type('wezterm:1/0', text);
    final sent = runs();
    expect(sent.length, greaterThan(1));
    for (final s in sent) {
      expect(utf8.encode(s).length, lessThanOrEqualTo(WezTerm.typeBytes));
    }
    expect(sent.join(), text);
  });

  test('a folder in the pane list: percent escapes decoded, a bare % kept; a title without escapes', () {
    final w = parseWezTermList('1', _list).single;
    expect(w.cwd, "/private/tmp/ptw/sp ace'q 漢字 100%");
    expect(w.title, 'bashx');
    expect((w.osWindow, w.tabId), ('wezterm:1/w0', 'wezterm:1/t0'));
  });

  group('a new session', () {
    /// A WezTerm (GUI pid 1) with windows 0 and 3 whose `spawn` makes pane 9
    /// and writes its arguments to `spawned`.
    WezTerm two() => fake(
      // Its arguments: cli --no-auto-start <command> ...
      'case "\$1 \$3" in\n'
      '"cli list") echo \'[{"window_id":0,"tab_id":0,"pane_id":0},{"window_id":3,"tab_id":4,"pane_id":5}]\';;\n'
      '"cli spawn") shift 3; echo "\$*" > ${dir.path}/spawned; echo 9;;\n'
      'esac',
    );
    String spawned() => File('${dir.path}/spawned').readAsStringSync().trim();

    test('asked into a window, a tab in it', () async {
      expect(await two().launch(dir.path, into: 'wezterm:1/w3'), 'wezterm:1/9');
      expect(spawned(), '--window-id 3 --cwd ${dir.path}');
    });

    test('asked into a window that is gone (or of a GUI that is), a new window', () async {
      for (final into in ['wezterm:1/w7', 'wezterm:2/w3']) {
        expect(await two().launch(dir.path, into: into), 'wezterm:1/9');
        expect(spawned(), '--new-window --cwd ${dir.path}');
      }
    });

    test('asked into no window, a new window, even with windows open', () async {
      expect(await two().launch(dir.path, command: ['omp']), 'wezterm:1/9');
      expect(spawned(), '--new-window --cwd ${dir.path} -- omp');
    });
  });
}
