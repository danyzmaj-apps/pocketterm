@Tags(['posix'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/wezterm.dart';

// Real outputs captured from each app (names shortened), with the `ps`
// lines of the same windows.

const _psWezTerm = ' 1129  1128  1129 5249 ttys008  Ss+  -zsh\n 5249  1129  5249 5249 ttys008  S+   claude\n';

const _wezList = '''
[
  {
    "window_id": 0, "tab_id": 0, "pane_id": 0, "workspace": "default",
    "size": {"rows": 24, "cols": 80, "pixel_width": 1120, "pixel_height": 768, "dpi": 144},
    "title": "cap-wezterm", "cwd": "file://mac.local/tmp/dzt/cap-wezterm",
    "cursor_x": 15, "cursor_y": 0, "cursor_shape": "Default", "cursor_visibility": "Visible",
    "left_col": 0, "top_row": 0, "tab_title": "", "window_title": "cap-wezterm",
    "is_active": true, "is_zoomed": false, "tty_name": "/dev/ttys008"
  }
]''';

/// Hosts that touch nothing on this Mac (paths that don't exist).
Terminals _terms() => Terminals(
  home: '/nonexistent-pocketterm',
  kitty: Kitty(socketDir: '/nonexistent-pocketterm', home: '/nonexistent-pocketterm', restoreFront: false),
  tmux: Tmux(executable: '/nonexistent-pocketterm/tmux', socketDirs: const []),
  wezterm: WezTerm(executable: '/nonexistent-pocketterm/wezterm', socketDir: '/nonexistent-pocketterm'),
  ghostty: Ghostty(appPath: '/nonexistent-pocketterm/Ghostty.app'),
);

TermWindow _w(String key, {String tty = '', String app = 'x'}) =>
    TermWindow(key: key, title: '', tab: '', cwd: '', program: '', app: app, tty: tty);

void main() {
  group('tmux', () {
    test('list-panes: a pane per line, its program from the tty, the window name for a host-name title', () {
      const out =
          '%0\t/dev/ttys008\tzsh\t/private/tmp/dzt/cap-tmux\tcap-tmux\tzsh\tpt-mv82o7z3\t1\t1\t1\n'
          '%3\t/dev/ttys012\tnode\t/Users/me/Dev/x\t\teditor\twork\t1\t0\t0\n';
      final procs = Procs(parsePs(' 97892 97891 97892 97892 ttys008  Ss+  -zsh\n'));
      final panes = parseTmuxPanes('default', out, procs);
      expect(panes.map((w) => w.key), ['tmux:default/0', 'tmux:default/3']);
      final first = panes.first;
      expect(
        (first.title, first.tab, first.cwd, first.program, first.tty, first.focused, first.app),
        ('cap-tmux', 'pt-mv82o7z3:zsh', '/private/tmp/dzt/cap-tmux', 'zsh', 'ttys008', true, 'tmux'),
      );
      expect(first.caps, allCaps);
      // No ps entry: tmux's own idea of the command; an inactive window isn't focused.
      expect((panes[1].title, panes[1].program, panes[1].focused), ('editor', 'node', false));
    });

    test('list-clients: client tty → the pane it shows', () {
      expect(parseTmuxClients('default', '/dev/ttys009\t%0\n/dev/ttys011\t%14\n\n'), {
        'ttys009': 'tmux:default/0',
        'ttys011': 'tmux:default/14',
      });
    });

    test("send-keys runs: tmux's key names, characters literally, Shift+Enter as M-Enter", () {
      final runs = tmuxKeyRuns(['down', 'enter', '1', ';', 'esc', 'shift+enter', 'ctrl+c', 'shift+tab']);
      expect(runs.map((r) => r.literal), [false, true, false]);
      expect(runs.map((r) => r.keys), [
        ['Down', 'Enter'],
        ['1', ';'],
        ['Escape', 'M-Enter', 'C-c', 'BTab'],
      ]);
      expect(() => tmuxKeyRuns(['hyper+x']), throwsA(isA<TerminalException>()));
    });
  });

  test('WezTerm list: pane key with the GUI pid, folder from the file URL, program from the tty', () {
    final w = parseWezTermList('1128', _wezList, procs: Procs(parsePs(_psWezTerm))).single;
    expect(
      (w.key, w.title, w.cwd, w.tty, w.program, w.focused, w.app),
      ('wezterm:1128/0', 'cap-wezterm', '/tmp/dzt/cap-wezterm', 'ttys008', 'claude', true, 'wezterm'),
    );
  });

  test("Ghostty list: id, title and folder; no tty, and its windows can't be read", () {
    const out =
        'CB2035E7-67BF-48C7-8D0A-83F3FA5B8074\tcap-ghostty\t/tmp/dzt/cap-ghostty\tcap-ghostty\ttrue\nfront\tfalse\n';
    final w = parseGhosttyList(out).single;
    expect(
      (w.key, w.title, w.cwd, w.tty, w.focused),
      ('ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074', 'cap-ghostty', '/tmp/dzt/cap-ghostty', '', false),
    );
    expect(w.can(TermCap.read), isFalse);
    expect(w.can(TermCap.keys), isTrue);
  });

  test("ghosttyText escapes what a Zig string literal can't hold", () {
    expect(ghosttyText(r'echo "a\b"'), r'echo \"a\\b\"');
    expect(ghosttyText('\x1b[A\r\x7f'), r'\x1b[A\x0d\x7f');
    expect(ghosttyText('čšž ✓'), 'čšž ✓');
  });

  group('Terminals.merge', () {
    final terms = _terms();

    test("a terminal window attached to tmux gives way to the tmux pane, which names the app it's in", () {
      final merged = Terminals.merge(
        terms.hosts,
        [
          [_w('kitty-1/2', tty: 'ttys003')],
          [_w('tmux:default/0', tty: 'ttys008'), _w('tmux:default/1', tty: 'ttys011')],
          [_w('wezterm:9/1', tty: 'ttys009'), _w('wezterm:9/2', tty: 'ttys010')],
          [],
        ],
        {'ttys009': 'tmux:default/0'},
        const {},
      );
      expect(merged.map((w) => (w.key, w.via)), [
        ('kitty-1/2', ''),
        ('tmux:default/0', 'WezTerm'),
        ('tmux:default/1', ''),
        ('wezterm:9/2', ''),
      ]);
    });

    test('a Ghostty window (no tty) PocketTerm opened to show a pane gives way through the shows map', () {
      final merged = Terminals.merge(
        terms.hosts,
        [
          [],
          [_w('tmux:default/4', tty: 'ttys012')],
          [],
          [_w('ghostty:G1'), _w('ghostty:G2')],
        ],
        const {},
        {'ghostty:G1': 'tmux:default/4'},
      );
      expect(merged.map((w) => (w.key, w.via)), [('tmux:default/4', 'Ghostty'), ('ghostty:G2', '')]);
    });
  });

  group('pickApp', () {
    final terms = _terms();
    TermStatus s(String id, TermState state) => TermStatus(id, id, state);
    final statuses = {
      'kitty': s('kitty', TermState.setup),
      'wezterm': s('wezterm', TermState.limited),
      'ghostty': s('ghostty', TermState.idle),
    };

    test('a chosen app that is installed wins, even when not running', () {
      expect(Terminals.pickApp(terms.apps, statuses, 'ghostty', ['WezTerm']).id, 'ghostty');
    });

    test('Auto: the usable app used most recently, skipping ones that need setup', () {
      expect(Terminals.pickApp(terms.apps, statuses, 'auto', ['Zen', 'kitty', 'Ghostty', 'WezTerm']).id, 'wezterm');
      // A missing choice falls back the same way.
      final noGhostty = {...statuses, 'ghostty': s('ghostty', TermState.missing)};
      expect(Terminals.pickApp(terms.apps, noGhostty, 'ghostty', ['WezTerm']).id, 'wezterm');
    });

    test('Auto with none used lately: the first usable in preference order, else one that can be started', () {
      expect(Terminals.pickApp(terms.apps, statuses, 'auto', const []).id, 'wezterm');
      final none = {
        'kitty': s('kitty', TermState.idle),
        'wezterm': s('wezterm', TermState.missing),
        'ghostty': s('ghostty', TermState.idle),
      };
      // kitty can't be started listening: Ghostty, the next idle app.
      expect(Terminals.pickApp(terms.apps, none, 'auto', const []).id, 'ghostty');
    });
  });

  test('new sessions run in tmux only where the app lacks screen or keys, and only with tmux', () {
    final terms = _terms();
    expect(terms.viaTmux(terms.ghostty!), isFalse); // no tmux here
    final withTmux = Terminals(
      home: terms.home,
      kitty: terms.kitty,
      tmux: Tmux(executable: '/bin/sh', socketDirs: const []),
      wezterm: terms.wezterm,
      ghostty: terms.ghostty,
    );
    expect(withTmux.viaTmux(withTmux.ghostty!), isTrue);
    expect(withTmux.viaTmux(withTmux.wezterm!), isFalse);
    expect(withTmux.describe(withTmux.ghostty!), 'Ghostty (in tmux)');
    expect(withTmux.describe(withTmux.kitty!), 'kitty');
  });

  test('tmux installed while the app runs is found without a restart', () {
    final bin = Directory.systemTemp.createTempSync('pocketterm-tmux');
    addTearDown(() => bin.deleteSync(recursive: true));
    final tmux = Tmux(env: {'PATH': bin.path}, socketDirs: const []);
    final installedBefore = File('/opt/homebrew/bin/tmux').existsSync() || File('/usr/local/bin/tmux').existsSync();
    if (installedBefore) markTestSkipped('tmux is installed on this machine');
    if (installedBefore) return;
    expect(tmux.installed, isFalse);

    File('${bin.path}/tmux')
      ..writeAsStringSync('#!/bin/sh\n')
      ..createSync();
    Process.runSync('chmod', ['+x', '${bin.path}/tmux']);

    expect(tmux.installed, isTrue);
  });

  test('with tmux, Ghostty is ready for phone sessions and still names its own limit', () async {
    Terminals with_(Tmux tmux) => Terminals(
      home: '/nonexistent-pocketterm',
      tmux: tmux,
      ghostty: _RunningGhostty(),
      snapshot: () async => Procs(parsePs('')),
    );
    final without = (await with_(
      Tmux(executable: '/nonexistent-pocketterm/tmux', socketDirs: const []),
    ).statuses()).firstWhere((s) => s.id == 'ghostty');
    expect(without.state, TermState.limited);

    final withTmux = (await with_(
      Tmux(executable: '/bin/sh', socketDirs: const []),
    ).statuses()).firstWhere((s) => s.id == 'ghostty');
    expect(withTmux.state, TermState.ready);
    expect(withTmux.note, contains(_RunningGhostty().limits));
  });

  group('locate: Ghostty windows sharing a folder', () {
    TermWindow g(String id, String title, {String cwd = '/tmp/work'}) =>
        TermWindow(key: 'ghostty:$id', title: title, tab: '', cwd: cwd, program: '', app: 'ghostty');
    Terminals with_(List<TermWindow> listed) => Terminals(
      home: '/nonexistent-pocketterm',
      ghostty: _ListedGhostty(listed),
      snapshot: () async => Procs(parsePs('')),
    );
    Map<String, dynamic> term(String tty) => {'TERM_PROGRAM': 'ghostty', 'tty': '/dev/$tty'};

    test("each omp session gets the window whose title is its own, or its folder's while untitled", () async {
      final terms = with_([
        g('A', 'π > Fix missing playable sources for the player'),
        g('B', 'π > work'),
        g('C', 'zsh', cwd: '/tmp/other'),
      ]);
      expect(
        await terms.locate(term('ttys001'), cwd: '/tmp/work', title: 'Fix missing playable sources for the player'),
        'ghostty:A',
      );
      expect(await terms.locate(term('ttys002'), cwd: '/tmp/work'), 'ghostty:B');
      // Matched once, found by its tty from then on, whatever the title says.
      expect(await terms.locate(term('ttys001'), cwd: '/tmp/work', title: 'Renamed'), 'ghostty:A');
    });

    test("omp's title while it works or asks still names the session", () async {
      final terms = with_([g('A', 'π ⠋ Paint the button'), g('B', 'π ! Fix the build'), g('C', 'π: work')]);
      expect(await terms.locate(term('ttys001'), cwd: '/tmp/work', title: 'Fix the build'), 'ghostty:B');
      expect(await terms.locate(term('ttys002'), cwd: '/tmp/work', title: 'Paint the button'), 'ghostty:A');
      expect(await terms.locate(term('ttys003'), cwd: '/tmp/work'), 'ghostty:C');
    });

    test('the one window there no other session runs in is the one', () async {
      final terms = with_([g('A', 'π > work'), g('B', 'π > work')]);
      expect(await terms.locate(term('ttys002'), cwd: '/tmp/work', claimed: {'ghostty:A'}), 'ghostty:B');
      // Claude Code's title names no session: only what's left tells.
      final claude = with_([g('A', '✳ Claude Code'), g('B', '✳ Claude Code')]);
      expect(
        await claude.locate(term('ttys002'), cwd: '/tmp/work', agent: Agent.claude, claimed: {'ghostty:B'}),
        'ghostty:A',
      );
    });

    test('still more than one: none, rather than a guess', () async {
      final untitled = with_([g('A', 'π > work'), g('B', 'π > work')]);
      expect(await untitled.locate(term('ttys001'), cwd: '/tmp/work'), isNull);
      final titled = with_([g('A', 'π > Fix the build'), g('B', 'π > work'), g('C', 'π > Paint the button')]);
      expect(await titled.locate(term('ttys001'), cwd: '/tmp/work', title: 'Write docs'), isNull);
      final claude = with_([g('A', '✳ Claude Code'), g('B', '✳ Claude Code')]);
      expect(await claude.locate(term('ttys001'), cwd: '/tmp/work', agent: Agent.claude), isNull);
      // Nothing learned from a miss.
      expect(untitled.ghostty!.byTty('ttys001'), isNull);
    });
  });

  group('projects', () {
    final terms = _terms();
    late Directory dir;
    late String root;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('pocketterm-projects');
      root = dir.resolveSymbolicLinksSync();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    void mk(String path) => Directory('$root/$path').createSync(recursive: true);

    test('git repositories up to three levels under the given folders, not inside one another', () async {
      mk('a/.git');
      mk('a/sub/.git');
      mk('org/b/.git');
      mk('plain/x');
      mk('.hidden/c/.git');
      mk('1/2/3/.git');
      mk('4/5/6/7/.git');
      expect(await terms.projects([root, '$root/nonexistent']), ['$root/1/2/3', '$root/a', '$root/org/b']);
      // Nested folders list a repository once.
      expect(await terms.projects([root, '$root/org']), ['$root/1/2/3', '$root/a', '$root/org/b']);
      expect(await terms.projects(const []), isEmpty);
    });

    test('symlinked folders are followed under their own path; a loop or one folder by two paths lists once', () async {
      mk('real/repo/.git');
      mk('elsewhere/linked/.git');
      mk('deep/x/y/z/.git');
      Link('$root/projects').createSync('$root/elsewhere');
      Link('$root/real/loop').createSync(root);
      Link('$root/real/again').createSync('$root/real/repo');
      expect(await terms.projects([root]), ['$root/projects/linked', '$root/real/repo']);
      expect(await terms.projects(['$root/', '$root/deep']), [
        '$root/deep/x/y/z',
        '$root/projects/linked',
        '$root/real/repo',
      ], reason: 'a root inside another is walked to its own depth; a trailing slash changes nothing');
    });

    test('createProject makes the folder under one of the project folders, once', () {
      expect(terms.createProject(root, ' new ', roots: [root]), '$root/new');
      expect(Directory('$root/new').existsSync(), isTrue);
      expect(
        () => terms.createProject(root, 'new', roots: [root]),
        throwsA(isA<TerminalException>().having((e) => e.message, 'message', contains('already'))),
      );
      expect(() => terms.createProject(root, 'other', roots: const []), throwsA(isA<TerminalException>()));
      for (final name in ['', '  ', 'a/b', r'a\b', 'C:x', '.x', '..', 'a\x00b', 'a\nb']) {
        expect(() => terms.createProject(root, name, roots: [root]), throwsA(isA<TerminalException>()), reason: name);
      }
      // A Project folder deleted since it was added.
      expect(
        () => terms.createProject('$root/gone', 'x', roots: ['$root/gone']),
        throwsA(isA<TerminalException>().having((e) => e.message, 'message', startsWith('No such folder'))),
      );
    });

    test('launchNewProject takes the folder back when no window opens, so trying again works', () async {
      // kitty isn't listening here: the launch fails.
      Future<String> attempt() => terms.launchNewProject(root, 'demo', roots: [root], host: terms.kitty!);
      await expectLater(attempt(), throwsA(isA<TerminalException>()));
      expect(Directory('$root/demo').existsSync(), isFalse);
      // The same failure again, not "already something named demo there".
      await expectLater(
        attempt(),
        throwsA(isA<TerminalException>().having((e) => e.message, 'message', isNot(contains('already')))),
      );
    });
  });
}

class _RunningGhostty extends Ghostty {
  _RunningGhostty() : super(appPath: '/nonexistent-pocketterm/Ghostty.app');

  @override
  Future<TermStatus> status(Procs procs) async => TermStatus(id, label, TermState.limited, note: '2 windows · $limits');
}

/// Ghostty listing these windows.
class _ListedGhostty extends Ghostty {
  _ListedGhostty(this.listed) : super(appPath: '/nonexistent-pocketterm/Ghostty.app');
  final List<TermWindow> listed;

  @override
  Future<List<TermWindow>> windows(Procs procs) async => listed;
}
