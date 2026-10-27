@Tags(['posix'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/iterm.dart';
import 'package:pocketterm_core/terminal.dart';

const _id = '4E0BF942-D30A-4EDD-BD3A-616CCAED64DF';
const _key = 'iterm:$_id';

void main() {
  // osascript stood in for by sh: macOS's answer for iTerm2 is the next of
  // [looks] (0 allowed); a script runs the next of [scripts] (the last one
  // again when they run out) and its argv is kept.
  late List<List<String>> argvs;
  late Directory app;
  setUp(() {
    argvs = [];
    app = Directory.systemTemp.createTempSync('pti');
  });
  tearDown(() => app.deleteSync(recursive: true));

  ITerm2 iterm(List<String> looks, List<String> scripts) => ITerm2(
    appPath: app.path,
    appleScript: AppleScript(
      timeout: const Duration(seconds: 5),
      start: (exe, args) {
        if (args.contains('JavaScript')) return Process.start('/bin/sh', ['-c', 'echo ${looks.removeAt(0)}']);
        argvs.add(args.sublist(2));
        final script = scripts.length > 1 ? scripts.removeAt(0) : scripts.single;
        return Process.start('/bin/sh', ['-c', script]);
      },
    ),
  );

  Proc running() =>
      Proc(pid: 1, ppid: 0, pgid: 1, tpgid: -1, tty: '', stat: 'S', args: '${app.path}/Contents/MacOS/iTerm2');

  test(
    "a session's program and folder are its tty's foreground program's; focused only while iTerm2 is in front",
    () async {
      final dir = Directory('${app.path}/project')..createSync();
      final sleep = await Process.start('/bin/sleep', ['30'], workingDirectory: dir.path);
      addTearDown(sleep.kill);
      const other = '0A1C3C37-F3DC-4313-86DA-23419F1086CE';
      String list({required bool front}) =>
          "printf '$_id\\037π > chat\\037chat (omp)\\037/dev/ttys099\\037/elsewhere\\037true\\036\\n"
          "$other\\037~\\037~ (-zsh)\\037/dev/ttys098\\037/Users/me\\037false\\036\\nfront\\037$front'";
      final i = iterm(['0'], [list(front: true), list(front: false)]);
      final procs = Procs([
        running(),
        Proc(
          pid: sleep.pid,
          ppid: 9,
          pgid: sleep.pid,
          tpgid: sleep.pid,
          tty: 'ttys099',
          stat: 'S+',
          args: '/bin/sleep 30',
        ),
      ]);
      final [w, shell] = await i.windows(procs);
      expect(
        (w.key, w.title, w.tab, w.program, w.tty, w.focused),
        (_key, 'π > chat', 'chat (omp)', 'sleep', 'ttys099', true),
      );
      expect(w.cwd, dir.resolveSymbolicLinksSync(), reason: "the program's, over iTerm2's");
      expect(
        (shell.cwd, shell.program, shell.focused),
        ('/Users/me', '', false),
        reason: "nothing on its tty: iTerm2's folder",
      );
      expect(w.can(TermCap.read) && w.can(TermCap.keys) && !w.can(TermCap.ansi), isTrue);
      expect((await i.windows(procs)).first.focused, isFalse, reason: 'iTerm2 in the background');
    },
  );

  test("the screen is contents' last rows (a cleared screen's lines went to the scrollback above it)", () async {
    // rows, then contents, every row ended by a line break (and osascript's own after it): two lines of scrollback,
    // a three-row screen whose last row is blank.
    final i = iterm(['0'], [r"printf '3\nLast login\nclear\n$ ls\na.txt\n\n\n'"]);
    expect(await i.lines(_key), [r'$ ls', 'a.txt']);
    expect(await i.plainScreen(_key), '\$ ls\na.txt');
    expect(await i.lines(_key, history: true), ['Last login', 'clear', r'$ ls', 'a.txt']);
  });

  test('a session iTerm2 no longer has, or an iTerm2 that has quit, reads as a window gone', () async {
    final gone = iterm(['0'], ['echo "x.applescript:1:2: execution error: That window is gone. (-1728)" >&2; exit 1']);
    await expectLater(
      gone.type(_key, 'x'),
      throwsA(isA<TerminalException>().having((e) => e.message, 'message', 'That window is gone.')),
    );
    final quit = iterm(
      ['-600'],
      ["echo \"x.applescript:1:2: execution error: iTerm2 isn't running. (-600)\" >&2; exit 1"],
    );
    await expectLater(
      quit.lines(_key),
      throwsA(isA<TerminalException>().having((e) => e.message, 'message', 'That window is gone.')),
    );
  });

  test("colors: iTerm2's 16-bit channels as 0xRRGGBB, its 16 ANSI colors, xterm's above them", () {
    final c = parseITermColors(
      [
        '65535,32896,0', // foreground
        '0,0,257', // background
        for (var i = 0; i < 16; i++) '${i * 257},0,0',
      ].join('\n'),
    );
    expect(c['fg'], 0xFF8000);
    expect(c['bg'], 0x000001);
    final palette = c['palette']! as List<int>;
    expect(palette, hasLength(256));
    expect(palette[15], 0x0F0000);
    expect(palette[16], 0x000000, reason: "xterm's cube starts black");
    expect(palette[21], 0x0000FF);
    expect(parseITermColors('')['fg'], 0xDDDDDD, reason: 'nothing readable: the defaults');
  });
}
