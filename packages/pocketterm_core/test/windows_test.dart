import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/wezterm.dart';

// Windows behaviour, injected with `windows: true` so it runs on a Mac too.

/// `tasklist /fo csv /nh` as Windows 11 prints it.
const _tasklist = '''
"System Idle Process","0","Services","0","8 K"
"System","4","Services","0","2,404 K"
"wezterm-gui.exe","4242","Console","1","98,120 K"
"pwsh.exe","5120","Console","1","80,312 K"
''';

/// `wezterm cli list --format json` on Windows: no tty, the folder as a
/// drive path.
const _wezList = r'''
[
  {"window_id": 0, "tab_id": 0, "pane_id": 3, "title": "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
   "cwd": "file:///C:/Users/x/src/", "tab_title": "", "is_active": true, "tty_name": null}
]''';

void main() {
  test('homeDir: USERPROFILE on Windows, HOME elsewhere, empty when unset', () {
    const env = {'HOME': '/Users/me', 'USERPROFILE': r'C:\Users\me'};
    expect(homeDir(env: env, windows: true), r'C:\Users\me');
    expect(homeDir(env: env, windows: false), '/Users/me');
    expect(homeDir(env: const {}, windows: true), '');
  });

  test('parseTasklist: each process by pid and image name', () {
    final procs = Procs(parseTasklist(_tasklist));
    expect(procs.all.map((p) => (p.pid, p.args)), [
      (0, 'System Idle Process'),
      (4, 'System'),
      (4242, 'wezterm-gui.exe'),
      (5120, 'pwsh.exe'),
    ]);
    expect(procs.byPid(4242)?.program, 'wezterm-gui.exe');
    expect(procs.foreground(''), isNull);
    expect(parseTasklist('INFO: No tasks are running which match the specified criteria.\n'), isEmpty);
  });

  test('cwdOfUri: a drive path from a file URL, any host dropped; a Mac path as is', () {
    expect(cwdOfUri(Uri.parse('file:///C:/Users/x/')), r'C:\Users\x');
    expect(cwdOfUri(Uri.parse('file://PC/C:/x')), r'C:\x');
    expect(cwdOfUri(Uri.parse('file:///C:/')), r'C:\');
    expect(cwdOfUri(Uri.parse('file://mac.local/Users/me/Dev')), '/Users/me/Dev');
  });

  test('cwdOfUri on Windows: a share as its UNC path (WSL too); the WSL shell telling its own folder as is', () {
    String cwd(String uri) => cwdOfUri(Uri.parse(uri), windows: true, localHost: 'DESKTOP-1');
    expect(cwd('file://wsl.localhost/Ubuntu/home/x/'), r'\\wsl.localhost\Ubuntu\home\x');
    expect(cwd(r'file://wsl$/Ubuntu-22.04/home/x/my%20app'), r'\\wsl$\Ubuntu-22.04\home\x\my app');
    expect(cwd('file://nas/projects/'), r'\\nas\projects');
    // A shell in WSL (OSC 7) names the PC itself: a Linux folder, no share.
    expect(cwd('file://desktop-1/home/x'), '/home/x');
    expect(cwd('file://localhost/home/x'), '/home/x');
    expect(cwd('file:///C:/Users/J%C3%BCrgen%20M/src/'), r'C:\Users\Jürgen M\src');
    // On a Mac a host is never a share.
    expect(cwdOfUri(Uri.parse('file://nas/projects/'), localHost: 'mac'), '/projects/');
  });

  test('weztermRelease: the date of a release or nightly; null when it tells none', () {
    expect(weztermRelease('wezterm 20240203-110809-5046fc22\r\n'), 20240203);
    expect(weztermRelease('wezterm 20230326-111934-3666303c'), WezTerm.minRelease);
    expect(weztermRelease('wezterm 0-unknown'), isNull);
    expect(weztermRelease(''), isNull);
  });

  test('WezTerm too old for kill-pane: needs an update, said in the status', () async {
    final dir = Directory.systemTemp.createTempSync('pocketterm-wez-old');
    addTearDown(() => dir.deleteSync(recursive: true));
    final exe = File(p.join(dir.path, 'wezterm'))..writeAsStringSync('#!/bin/sh\necho "wezterm \$(cat "\$0.v")"\n');
    Process.runSync('chmod', ['+x', exe.path]);
    final version = File('${exe.path}.v')..writeAsStringSync('20230320-124340-559cb7b0');
    final wez = WezTerm(executable: exe.path, socketDir: dir.path, windows: true);

    final old = await wez.status(Procs(const []));
    expect(old.state, TermState.setup);
    expect(old.note, contains('too old'));
    expect(old.note, contains('winget upgrade wez.wezterm'));
    // Updated in place: asked again since the file changed.
    version.writeAsStringSync('20240203-110809-5046fc22');
    exe.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    expect((await wez.status(Procs(const []))).state, TermState.idle);
  }, skip: Platform.isWindows ? 'needs a shell script as wezterm' : null);

  test('programOfTitle: the program a title starts with, lowercased, without .exe', () {
    expect(programOfTitle(r'C:\Program Files\PowerShell\7\pwsh.exe'), 'pwsh');
    expect(programOfTitle('claude'), 'claude');
    expect(programOfTitle('✳ Claude Code'), '✳');
    expect(programOfTitle(r'C:\Users\x\.local\bin\claude.EXE --resume'), 'claude');
  });

  test('WezTerm list on Windows: the folder from the drive URL, the program from the title', () {
    final w = parseWezTermList('4242', _wezList, procs: Procs(parseTasklist(_tasklist)), windows: true).single;
    expect((w.key, w.cwd, w.tty, w.program), ('wezterm:4242/3', r'C:\Users\x\src', '', 'pwsh'));
  });

  test('findExecutable on Windows: .exe on PATH, then extra, then .cmd; never the bare name', () {
    final dir = Directory.systemTemp.createTempSync('pocketterm-exe');
    addTearDown(() => dir.deleteSync(recursive: true));
    final npm = Directory(p.join(dir.path, 'npm'))..createSync();
    final bin = Directory(p.join(dir.path, 'bin'))..createSync();
    File(p.join(npm.path, 'claude')).createSync();
    File(p.join(npm.path, 'claude.cmd')).createSync();
    final native = File(p.join(dir.path, 'claude.exe'))..createSync();
    final path = [p.join(dir.path, 'missing'), npm.path, bin.path].join(';');
    String? find(List<String> extra) => findExecutable('claude', env: {'PATH': path}, windows: true, extra: extra);

    expect(find(const []), p.join(npm.path, 'claude.cmd'));
    expect(find([native.path]), native.path);
    File(p.join(bin.path, 'claude.exe')).createSync();
    expect(find([native.path]), p.join(bin.path, 'claude.exe'));
    expect(findExecutable('kitty', env: {'PATH': path}, windows: true), isNull);
  });

  test('findExecutable on Windows: a quoted PATH entry counts', () {
    final dir = Directory.systemTemp.createTempSync('pocketterm exe q');
    addTearDown(() => dir.deleteSync(recursive: true));
    final exe = File(p.join(dir.path, 'omp.exe'))..createSync();
    expect(findExecutable('omp', env: {'PATH': 'C:\\x;"${dir.path}";'}, windows: true), exe.path);
  });

  test('mergeWindowsPath: system, then user, then this process only; each folder once, any case', () {
    expect(
      mergeWindowsPath(
        machine: r'C:\Windows\system32;C:\Windows;"C:\Program Files\Git\cmd"',
        user: r'C:\Users\x\.local\bin;C:\Users\x\AppData\Roaming\npm;;',
        current: r'C:\WINDOWS\system32\;C:\Windows;C:\Users\x\AppData\Local\Temp\pocketterm-dev',
      ),
      [
        r'C:\Windows\system32',
        r'C:\Windows',
        r'C:\Program Files\Git\cmd',
        r'C:\Users\x\.local\bin',
        r'C:\Users\x\AppData\Roaming\npm',
        r'C:\Users\x\AppData\Local\Temp\pocketterm-dev',
      ].join(';'),
    );
    // Registry unreadable: what the process has.
    expect(mergeWindowsPath(current: r'C:\a;C:\b'), r'C:\a;C:\b');
  });

  test("windowsCommand: an npm .cmd through cmd's call (quoted paths with spaces survive); an .exe as is", () {
    const exe = r'C:\Users\Jane Doe\AppData\Roaming\npm\claude.cmd';
    final (shell, args) = windowsCommand(exe, ['plugin', 'add', r'C:\Users\Jane Doe\x']);
    expect(shell, 'cmd.exe');
    expect(args, ['/d', '/c', 'call', exe, 'plugin', 'add', r'C:\Users\Jane Doe\x']);
    expect(windowsCommand(r'C:\x\SETUP.BAT', const []).$1, 'cmd.exe');
    const native = r'C:\Users\Jane Doe\.local\bin\claude.exe';
    final (same, sameArgs) = windowsCommand(native, ['--version']);
    expect(same, native);
    expect(sameArgs, ['--version']);
  });

  test('windowsFileName: what Windows refuses or silently changes', () {
    for (final ok in ['app', 'my app', 'CONSOLE', 'con-app', 'nul2', 'Jürgen', 'a.b', 'com10']) {
      expect(windowsFileName(ok), isTrue, reason: ok);
    }
    for (final bad in [
      'a<b',
      'a>b',
      'a"b',
      'a|b',
      'a?',
      'a*',
      'app.',
      'app ',
      'CON',
      'con.txt',
      'Nul',
      'COM1',
      'lpt9.md',
    ]) {
      expect(windowsFileName(bad), isFalse, reason: bad);
    }
  });

  test('createProject on Windows: a name Windows would refuse or change is turned down before anything is made', () {
    final root = Directory.systemTemp.createTempSync('pocketterm-proj');
    addTearDown(() => root.deleteSync(recursive: true));
    final terms = Terminals.standard(home: root.path, windows: true);
    for (final name in ['CON', 'app.', 'a?b']) {
      expect(
        () => terms.createProject(root.path, name, roots: [root.path], windows: true),
        throwsA(isA<TerminalException>().having((e) => e.message, 'message', contains('Windows'))),
        reason: name,
      );
    }
    expect(root.listSync(), isEmpty);
    expect(terms.createProject(root.path, 'app', roots: [root.path], windows: true), p.join(root.path, 'app'));
  });

  test('WezTerm on Windows: a socket that failed once is asked again a minute later', () async {
    final dir = Directory.systemTemp.createTempSync('pocketterm-wez');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'gui-sock-4242')).createSync();
    File(p.join(dir.path, 'list.json')).writeAsStringSync(_wezList);
    final exe = File(p.join(dir.path, 'wezterm'))
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'if [ -f "${dir.path}/ok" ]; then cat "${dir.path}/list.json"; else echo busy >&2; exit 1; fi\n',
      );
    Process.runSync('chmod', ['+x', exe.path]);
    var now = DateTime(2026);
    final wez = WezTerm(executable: exe.path, socketDir: dir.path, windows: true, clock: () => now);
    final procs = Procs(const []);

    expect(await wez.windows(procs), isEmpty);
    File(p.join(dir.path, 'ok')).createSync();
    expect(await wez.windows(procs), isEmpty, reason: 'skipped right after failing');
    now = now.add(const Duration(minutes: 1));
    expect((await wez.windows(procs)).map((w) => w.key), ['wezterm:4242/3']);
  }, skip: Platform.isWindows ? 'needs a shell script as wezterm' : null);

  test('Terminals.standard on Windows: WezTerm only', () {
    final terms = Terminals.standard(home: r'C:\Users\x', windows: true);
    expect(terms.hosts.map((h) => h.id), ['wezterm']);
    expect(terms.apps.map((h) => h.id), ['wezterm']);
    expect(terms.home, r'C:\Users\x');
  });

  test('WezTerm missing on Windows: an install fix', () async {
    final s = await WezTerm(
      executable: '/nonexistent-pocketterm/wezterm.exe',
      socketDir: '/nonexistent-pocketterm',
      windows: true,
    ).status(Procs(const []));
    expect((s.state, s.fix), (TermState.missing, TermFix.install));
  });

  test("an agent in WezTerm on Windows: its pane from the socket's pid", () {
    expect(
      windowOfTerm({
        'TERM_PROGRAM': 'WezTerm',
        'WEZTERM_PANE': '3',
        'WEZTERM_UNIX_SOCKET': r'C:\Users\x\.local\share\wezterm\gui-sock-4242',
      }),
      'wezterm:4242/3',
    );
  });
}
