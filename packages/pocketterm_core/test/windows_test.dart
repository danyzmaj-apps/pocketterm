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

  test('programOfTitle: the program a title starts with, lowercased, without .exe', () {
    expect(programOfTitle(r'C:\Program Files\PowerShell\7\pwsh.exe'), 'pwsh');
    expect(programOfTitle('claude'), 'claude');
    expect(programOfTitle('✳ Claude Code'), '✳');
    expect(programOfTitle(r'C:\Users\x\.local\bin\claude.EXE --resume'), 'claude');
  });

  test('WezTerm list on Windows: the folder from the drive URL, the program from the title', () {
    final w = parseWezTermList('4242', _wezList, Procs(parseTasklist(_tasklist))).single;
    expect((w.key, w.cwd, w.tty, w.program), ('wezterm:4242/3', r'C:\Users\x\src', '', 'pwsh'));
  });

  test('findExecutable on Windows: PATH split on ;, name.exe before name', () {
    final dir = Directory.systemTemp.createTempSync('pocketterm-exe');
    addTearDown(() => dir.deleteSync(recursive: true));
    File(p.join(dir.path, 'wezterm')).createSync();
    File(p.join(dir.path, 'wezterm.exe')).createSync();
    final path = [p.join(dir.path, 'missing'), dir.path].join(';');
    expect(findExecutable('wezterm', env: {'PATH': path}, windows: true), p.join(dir.path, 'wezterm.exe'));
    expect(findExecutable('kitty', env: {'PATH': path}, windows: true), isNull);
  });

  test('Terminals.standard on Windows: WezTerm only', () {
    final terms = Terminals.standard(home: r'C:\Users\x', windows: true);
    expect(terms.hosts.map((h) => h.id), ['wezterm']);
    expect(terms.apps.map((h) => h.id), ['wezterm']);
    expect(terms.home, r'C:\Users\x');
  });

  test('WezTerm missing on Windows: the winget line and an install fix', () async {
    final s = await WezTerm(
      executable: '/nonexistent-pocketterm/wezterm.exe',
      socketDir: '/nonexistent-pocketterm',
      windows: true,
    ).status(Procs(const []));
    expect((s.state, s.note, s.fix), (TermState.missing, 'winget install wez.wezterm', TermFix.install));
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
