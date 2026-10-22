@Tags(['posix'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/terminal.dart';

const _key = 'ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074';

void main() {
  // osascript stood in for by sh: macOS's answer for Ghostty is the next of
  // [looks] (0 allowed, -1743 refused); a script runs the next of [scripts]
  // (the last one again when they run out) and its argv is kept.
  late List<List<String>> argvs;
  late Directory app;
  setUp(() {
    argvs = [];
    app = Directory.systemTemp.createTempSync('ptg');
  });
  tearDown(() => app.deleteSync(recursive: true));

  Ghostty ghostty(List<String> looks, List<String> scripts) => Ghostty(
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

  test("an agent in a symlinked folder finds the Ghostty window whose shell names the link's path", () async {
    final real = Directory('${app.path}/real')..createSync();
    final link = Link('${app.path}/link')..createSync(real.path);
    final g = ghostty(
      ['0'],
      ["printf '${_key.substring(8)}\\037omp\\037${link.path}\\037t\\037true\\036\\nfront\\037true'"],
    );
    final procs = Procs([
      Proc(pid: 1, ppid: 0, pgid: 1, tpgid: -1, tty: '', stat: 'S', args: '${app.path}/Contents/MacOS/ghostty'),
    ]);
    expect(await g.byFolder(real.resolveSymbolicLinksSync(), procs), _key);
  });

  test("a window Ghostty tells no folder for (opened with a command) has its program's, where its tty is known", () async {
    final dir = Directory('${app.path}/project')..createSync();
    final sleep = await Process.start('/bin/sleep', ['30'], workingDirectory: dir.path);
    addTearDown(sleep.kill);
    final g = ghostty(
      ['0', '0'],
      ["printf '${_key.substring(8)}\\037omp\\037\\037t\\037true\\036\\nfront\\037true'"],
    );
    final procs = Procs([
      Proc(pid: 1, ppid: 0, pgid: 1, tpgid: -1, tty: '', stat: 'S', args: '${app.path}/Contents/MacOS/ghostty'),
      Proc(pid: sleep.pid, ppid: 9, pgid: sleep.pid, tpgid: sleep.pid, tty: 'ttys099', stat: 'S+', args: '/bin/sleep 30'),
    ]);
    expect((await g.windows(procs)).single.cwd, isEmpty, reason: 'tty unknown');
    g.learn(_key, '/dev/ttys099');
    final w = (await g.windows(procs)).single;
    expect(w.cwd, dir.resolveSymbolicLinksSync());
    expect(w.program, 'sleep');
  });
  Matcher says(String message) => throwsA(isA<TerminalException>().having((e) => e.message, 'message', message));

  test('long text goes in pieces of what a command line takes, a script each, in order', () async {
    final g = ghostty(['0'], ['exit 0']);
    final text = List.generate(9000, (i) => 'é漢"\\\x1b$i').join();
    await g.type(_key, text);
    expect(argvs.length, greaterThan(1));
    for (final argv in argvs) {
      expect(argv.first, _key.substring('ghostty:'.length));
      expect(argv[1].length, lessThan(200000));
    }
    expect(argvs.map((a) => a[1].substring('text:'.length)).join(), ghosttyText(text));
  });

  test('a Ghostty that has quit: its windows read as gone (it is not started again for them)', () async {
    final g = ghostty(
      ['-600'],
      ["echo \"x.applescript:82:106: execution error: Ghostty isn't running. (-600)\" >&2; exit 1"],
    );
    await expectLater(g.type(_key, 'x'), says('That window is gone.'));
  });

  test(
    'Automation turned off while in use: refused, then nothing more goes to Ghostty, and Settings offers the fix',
    () async {
      final g = ghostty(
        ['0', '-1743'],
        ['echo "execution error: Not authorized to send Apple events to Ghostty. (-1743)" >&2; exit 1'],
      );
      await expectLater(g.type(_key, 'x'), throwsA(isA<AutomationDenied>()));
      expect(argvs, hasLength(1));
      final procs = Procs([
        Proc(pid: 1, ppid: 0, pgid: 1, tpgid: -1, tty: '', stat: 'S', args: '${app.path}/Contents/MacOS/ghostty'),
      ]);
      final status = await g.status(procs);
      expect((status.state, status.fix), (TermState.setup, TermFix.automation));
      expect(argvs, hasLength(1), reason: 'refused before the script ran');
    },
  );
}
