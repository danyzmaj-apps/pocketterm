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

TermWindow _w(
  String key, {
  String tty = '',
  String app = 'x',
  String cwd = '',
  String osWindow = '',
  String tabId = '',
  String via = '',
}) => TermWindow(
  key: key,
  title: '',
  tab: '',
  cwd: cwd,
  program: '',
  app: app,
  tty: tty,
  osWindow: osWindow,
  tabId: tabId,
  via: via,
);

void main() {
  group('tmux', () {
    test('list-panes: a pane per record, its program from the tty, the window name for a host-name title', () {
      const out =
          '%0\x1f/dev/ttys008\x1fzsh\x1f/private/tmp/dzt/cap-tmux\x1fcap-tmux\x1fzsh\x1fpt-mv82o7z3\x1f1\x1f1\x1f1'
          '\x1f\$0\x1f@0\x1e\n'
          '%3\x1f/dev/ttys012\x1fnode\x1f/Users/me/Dev/x\x1f\x1feditor\x1fwork\x1f1\x1f0\x1f0\x1f\$2\x1f@5\x1e\n';
      final procs = Procs(parsePs(' 97892 97891 97892 97892 ttys008  Ss+  -zsh\n'));
      final panes = parseTmuxPanes('default', out, procs);
      expect(panes.map((w) => (w.key, w.osWindow, w.tabId)), [
        ('tmux:default/0', 'tmux:default/s0', 'tmux:default/w0'),
        ('tmux:default/3', 'tmux:default/s2', 'tmux:default/w5'),
      ]);
      final first = panes.first;
      expect(
        (first.title, first.tab, first.cwd, first.program, first.tty, first.focused, first.app),
        ('cap-tmux', 'pt-mv82o7z3:zsh', '/private/tmp/dzt/cap-tmux', 'zsh', 'ttys008', true, 'tmux'),
      );
      expect(first.caps, allCaps);
      // No ps entry: tmux's own idea of the command; an inactive window isn't focused.
      expect((panes[1].title, panes[1].program, panes[1].focused), ('editor', 'node', false));
    });

    test('a folder whose name holds a tab or a line break keeps its pane, and the panes after it', () {
      // As tmux 3.8 prints them: the folder's bytes as they are.
      const out =
          '%1\x1f/dev/ttys014\x1fbash\x1f/tmp/ptx/tab\tdir\nnl\x1f\x1fbash\x1fs\x1f1\x1f1\x1f0\x1f\$1\x1f@1\x1e\n'
          '%2\x1f/dev/ttys015\x1fzsh\x1f/tmp\x1ft\x1fzsh\x1fs\x1f1\x1f0\x1f0\x1f\$1\x1f@2\x1e\n';
      final panes = parseTmuxPanes('edge', out);
      expect(panes.map((w) => (w.key, w.cwd)), [('tmux:edge/1', '/tmp/ptx/tab\tdir\nnl'), ('tmux:edge/2', '/tmp')]);
    });

    test('list-clients: client tty → the pane it shows and the title tmux gives its terminal', () {
      expect(parseTmuxClients('default', '/dev/ttys009\x1f%0\x1f\x1e\n/dev/ttys011\x1f%14\x1f~ (tmux 3)\x1e\n'), {
        'ttys009': (pane: 'tmux:default/0', title: ''),
        'ttys011': (pane: 'tmux:default/14', title: '~ (tmux 3)'),
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

  test(
    'WezTerm list: pane key with the GUI pid, its window and tab, folder from the file URL, program from the tty',
    () {
      final w = parseWezTermList('1128', _wezList, procs: Procs(parsePs(_psWezTerm))).single;
      expect(
        (w.key, w.title, w.cwd, w.tty, w.program, w.focused, w.app),
        ('wezterm:1128/0', 'cap-wezterm', '/tmp/dzt/cap-wezterm', 'ttys008', 'claude', true, 'wezterm'),
      );
      expect((w.osWindow, w.tabId), ('wezterm:1128/w0', 'wezterm:1128/t0'));
    },
  );

  test("Ghostty list: id, title, folder, window and tab; no tty, and its windows can't be read", () {
    const out =
        'CB2035E7-67BF-48C7-8D0A-83F3FA5B8074\x1fcap-ghostty\x1f/tmp/dzt/cap-ghostty\x1fcap-ghostty\x1ftrue\x1f'
        'W-1\x1fT-2\x1e\n'
        'front\x1ffalse';
    final w = parseGhosttyList(out).single;
    expect(
      (w.key, w.title, w.cwd, w.tty, w.focused),
      ('ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074', 'cap-ghostty', '/tmp/dzt/cap-ghostty', '', false),
    );
    expect((w.osWindow, w.tabId), ('ghostty:wW-1', 'ghostty:tT-2'));
    expect(w.can(TermCap.read), isFalse);
    expect(w.can(TermCap.keys), isTrue);
  });

  test('Ghostty list: a title or folder with a tab or line break stays one window; the title reads as one line', () {
    const out =
        'CB2035E7-67BF-48C7-8D0A-83F3FA5B8074\x1fa\tb\nc\x1f/tmp/x\ty\x1ftab\x1ftrue\x1fW-1\x1fT-1\x1e\r'
        'DB2035E7-67BF-48C7-8D0A-83F3FA5B8074\x1fsecond\x1f/tmp\x1ftab\x1ffalse\x1fW-1\x1fT-1\x1e\n'
        'front\x1ftrue\n';
    final ws = parseGhosttyList(out);
    expect(ws.map((w) => (w.title, w.cwd, w.focused)), [('a b c', '/tmp/x\ty', true), ('second', '/tmp', false)]);
  });

  test("ghosttyText escapes what a Zig string literal can't hold", () {
    expect(ghosttyText(r'echo "a\b"'), r'echo \"a\\b\"');
    expect(ghosttyText('\x1b[A\r\x7f'), r'\x1b[A\x0d\x7f');
    expect(ghosttyText('čšž ✓'), 'čšž ✓');
  });

  group('Terminals.merge', () {
    final terms = _terms();

    test("a terminal window attached to tmux gives way to the tmux pane, in its place, naming the app it's in", () {
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
        ('tmux:default/1', ''),
        ('tmux:default/0', 'WezTerm'),
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

    test("every pane of a shown tmux session sits in the app's window and tab; another session keeps its own", () {
      final merged = Terminals.merge(
        terms.hosts,
        [
          [_w('kitty-1/2', tty: 'ttys003', osWindow: 'kitty-1/os1', tabId: 'kitty-1/tab4')],
          [
            _w('tmux:default/0', osWindow: 'tmux:default/s1', tabId: 'tmux:default/w1'),
            _w('tmux:default/1', osWindow: 'tmux:default/s1', tabId: 'tmux:default/w2'),
            _w('tmux:default/2', osWindow: 'tmux:default/s2', tabId: 'tmux:default/w3'),
          ],
          [],
          [],
        ],
        {'ttys003': 'tmux:default/1'},
        const {},
      );
      expect(merged.map((w) => (w.key, w.via, w.osWindow, w.tabId)), [
        ('tmux:default/0', 'kitty', 'kitty-1/os1', 'kitty-1/tab4'),
        ('tmux:default/1', 'kitty', 'kitty-1/os1', 'kitty-1/tab4'),
        ('tmux:default/2', '', 'tmux:default/s2', 'tmux:default/w3'),
      ]);
    });
  });

  group('Terminals.projectWindow', () {
    final terms = _terms();
    const home = '/Users/me';
    String? find(List<TermWindow> ws, String cwd) => Terminals.projectWindow(ws, terms.kitty!, cwd, home: home);

    test("the app's window with the most of the project's tabs; panes of one tab count once", () {
      final ws = [
        _w('kitty-1/1', app: 'kitty', cwd: '/Users/me/a', osWindow: 'kitty-1/os1', tabId: 'kitty-1/tab1'),
        _w('kitty-1/2', app: 'kitty', cwd: '/Users/me/a', osWindow: 'kitty-1/os1', tabId: 'kitty-1/tab1'),
        _w('kitty-1/3', app: 'kitty', cwd: '/Users/me/b', osWindow: 'kitty-1/os1', tabId: 'kitty-1/tab2'),
        _w('kitty-1/4', app: 'kitty', cwd: '/Users/me/a/lib', osWindow: 'kitty-1/os2', tabId: 'kitty-1/tab3'),
        _w('kitty-1/5', app: 'kitty', cwd: '/Users/me/a', osWindow: 'kitty-1/os2', tabId: 'kitty-1/tab5'),
        // Another app's window, and a tmux pane no app shows: not kitty's to open a tab in.
        _w('wezterm:9/1', app: 'wezterm', cwd: '/Users/me/a', osWindow: 'wezterm:9/w1', tabId: 'wezterm:9/t1'),
        _w('tmux:default/0', app: 'tmux', cwd: '/Users/me/a', osWindow: 'tmux:default/s1'),
      ];
      expect(find(ws, '/Users/me/a'), 'kitty-1/os2');
      expect(find(ws, '/Users/me/b'), 'kitty-1/os1');
      expect(find(ws, '/Users/me/ab'), isNull, reason: 'a folder whose name starts the same is another project');
    });

    test('a tmux pane counts for the app window showing it', () {
      final ws = [
        _w(
          'tmux:default/0',
          app: 'tmux',
          via: 'kitty',
          cwd: '/Users/me/a',
          osWindow: 'kitty-1/os3',
          tabId: 'kitty-1/tab7',
        ),
      ];
      expect(find(ws, '/Users/me/a'), 'kitty-1/os3');
    });

    test('the home folder (General) counts only tabs in it, not every folder under it', () {
      final ws = [
        _w('kitty-1/1', app: 'kitty', cwd: '/Users/me/a', osWindow: 'kitty-1/os1', tabId: 'kitty-1/tab1'),
        _w('kitty-1/2', app: 'kitty', cwd: '/Users/me/b', osWindow: 'kitty-1/os1', tabId: 'kitty-1/tab2'),
        _w('kitty-1/3', app: 'kitty', cwd: '/Users/me', osWindow: 'kitty-1/os2', tabId: 'kitty-1/tab3'),
      ];
      expect(find(ws, home), 'kitty-1/os2');
      expect(find(ws.take(2).toList(), home), isNull);
    });

    test('a window that tells no app window is no place for a tab (an older listing)', () {
      expect(find([_w('kitty-1/1', app: 'kitty', cwd: '/Users/me/a')], '/Users/me/a'), isNull);
    });
  });

  test('the home folder is General; a project is its folder', () {
    expect(Terminals.projectName('/Users/me', home: '/Users/me'), 'General');
    expect(Terminals.projectName('/Users/me/wrkly', home: '/Users/me'), 'wrkly');
  });

  group('Ghostty windows running tmux (its config line): one row each', () {
    const app = '/nonexistent-pocketterm/Ghostty.app';
    // As a real Ghostty 1.3.1 with the line runs it: each terminal's login
    // (a child of Ghostty, or orphaned) execs tmux's client on its tty; the
    // server, detached, runs the panes' shells on ttys of their own.
    const client = '-/opt/homebrew/bin/tmux new-session ; set-option destroy-unattached on';
    const login = '/usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l $client';
    String ps(List<String> clientTtys, {List<String> plainTtys = const []}) => [
      '  500     1   500     0 ??       S    $app/Contents/MacOS/ghostty',
      '  600     1   600     0 ??       Ss   $client',
      for (final (i, tty) in clientTtys.indexed) ...[
        '  ${700 + i * 10}   500   ${700 + i * 10}   ${700 + i * 10} $tty  Ss+  $login',
        '  ${701 + i * 10}   ${700 + i * 10}   ${700 + i * 10}   ${700 + i * 10} $tty  S+   $client',
      ],
      for (final (i, tty) in plainTtys.indexed) '  ${900 + i}   888   ${900 + i}   ${900 + i} $tty  Ss+  -zsh',
      '  610   600   610   610 ttys014  Ss+  -zsh',
      '  620   600   620   620 ttys015  Ss+  -zsh',
    ].join('\n');
    const g1 = 'E7AD8A26-8A2F-4A2E-B8AA-AB5575C50B75';
    const g2 = 'F1AD8A26-8A2F-4A2E-B8AA-AB5575C50B75';
    String ghosttyList(List<(String id, String title, String cwd)> ws) =>
        '${[for (final (id, title, cwd) in ws) '$id\x1f$title\x1f$cwd\x1f$title\x1ffalse\x1fW-$id\x1fT-$id\x1e\n'].join()}'
        'front\x1ffalse';
    final panes = parseTmuxPanes(
      'default',
      '%0\x1f/dev/ttys014\x1fzsh\x1f/Users/me/a\x1fa\x1fzsh\x1f3\x1f1\x1f1\x1f1\x1f\$3\x1f@0\x1e\n'
          '%1\x1f/dev/ttys015\x1fzsh\x1f/Users/me/b\x1fb\x1fzsh\x1f4\x1f1\x1f1\x1f1\x1f\$4\x1f@1\x1e\n',
    );
    TieGhostty tie(String ps, String list, String clients) => Terminals.tieGhostty(
      windows: parseGhosttyList(list),
      clients: parseTmuxClients('default', clients),
      surfaces: ghosttySurfaceTtys(Procs(parsePs(ps)), 500),
      panes: panes,
    );
    // Ties [ttys], nothing left untold.
    void expectTied(TieGhostty tie, Map<String, String> ttys) {
      expect(tie.ttys, ttys);
      expect(tie.untold, '');
    }

    test('one window and one client: it shows that pane, and its tty is learnt', () async {
      final ghostty = _ListedGhostty(parseGhosttyList(ghosttyList([(g1, '👻', '')])));
      final terms = Terminals(
        home: '/nonexistent-pocketterm',
        tmux: _ListedTmux(panes.sublist(0, 1), parseTmuxClients('default', '/dev/ttys013\x1f%0\x1f\x1e\n')),
        ghostty: ghostty,
        snapshot: () async => Procs(parsePs(ps(['ttys013']))),
      );
      expect((await terms.windows()).map((w) => (w.key, w.app, w.via)), [('tmux:default/0', 'tmux', 'Ghostty')]);
      expect(ghostty.byTty('ttys013'), 'ghostty:$g1', reason: 'what closes it with its pane');
    });

    test("two windows and two clients: by the title tmux gives each (PocketTerm's line), else by folder", () {
      const clients = '/dev/ttys013\x1f%0\x1fa (tmux 3)\x1e\n/dev/ttys016\x1f%1\x1fb (tmux 4)\x1e\n';
      final titled = tie(
        ps(['ttys013', 'ttys016']),
        ghosttyList([(g1, 'b (tmux 4)', ''), (g2, 'a (tmux 3)', '')]),
        clients,
      );
      expectTied(titled, {'ghostty:$g1': 'ttys016', 'ghostty:$g2': 'ttys013'});
      // The line without titles, where Ghostty tells each window's folder.
      final byFolder = tie(
        ps(['ttys013', 'ttys016']),
        ghosttyList([(g1, '👻', '/Users/me/b'), (g2, '👻', '/Users/me/a')]),
        '/dev/ttys013\x1f%0\x1f\x1e\n/dev/ttys016\x1f%1\x1f\x1e\n',
      );
      expectTied(byFolder, {'ghostty:$g1': 'ttys016', 'ghostty:$g2': 'ttys013'});
    });

    test('what can be told two ways stays two rows, said once in the log', () {
      const untitled = '/dev/ttys013\x1f%0\x1f\x1e\n/dev/ttys016\x1f%1\x1f\x1e\n';
      final same = tie(ps(['ttys013', 'ttys016']), ghosttyList([(g1, '👻', ''), (g2, '👻', '')]), untitled);
      expect(same.ttys, isEmpty);
      expect(same.untold, 'ghostty:$g1, ghostty:$g2 / ttys013, ttys016');
      // Both in one folder, or both titled alike.
      expect(
        tie(
          ps(['ttys013', 'ttys016']),
          ghosttyList([(g1, '👻', '/Users/me/a'), (g2, '👻', '/Users/me/a')]),
          '/dev/ttys013\x1f%0\x1f\x1e\n/dev/ttys016\x1f%0\x1f\x1e\n',
        ).ttys,
        isEmpty,
      );
      // A plain window in the pane's folder beside the tmux one Ghostty tells
      // no folder for: the folder could be the plain one's, so neither.
      final plain = tie(
        ps(['ttys013'], plainTtys: ['ttys020']),
        ghosttyList([(g1, 'zsh', '/Users/me/a'), (g2, '👻', '')]),
        '/dev/ttys013\x1f%0\x1f\x1e\n',
      );
      expect(plain.ttys, isEmpty);
      expect(plain.untold, isNotEmpty);
    });

    test('a Ghostty window running no tmux is left alone, and windows whose tty is known count out', () {
      // Its client runs in kitty, not in Ghostty.
      final alone = tie(
        ps([], plainTtys: ['ttys020']),
        ghosttyList([(g1, 'zsh', '/Users/me/a')]),
        '/dev/ttys030\x1f%0\x1f\x1e\n',
      );
      expectTied(alone, const {});
      // PocketTerm's own window (tty known) beside one the person opened.
      final known = Terminals.tieGhostty(
        windows: [
          ...parseGhosttyList(ghosttyList([(g1, '👻', '')])),
          const TermWindow(
            key: 'ghostty:$g2',
            title: '👻',
            tab: '',
            cwd: '',
            program: '',
            app: 'ghostty',
            tty: 'ttys016',
          ),
        ],
        clients: parseTmuxClients('default', '/dev/ttys013\x1f%0\x1f\x1e\n/dev/ttys016\x1f%1\x1f\x1e\n'),
        surfaces: ghosttySurfaceTtys(Procs(parsePs(ps(['ttys013', 'ttys016']))), 500),
        panes: panes,
      );
      expectTied(known, {'ghostty:$g1': 'ttys013'});
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

  test("an omp window carries the profile its command line names; other windows and the default don't", () async {
    TermWindow pane(String id, String tty, String program) =>
        TermWindow(key: 'tmux:default/$id', title: '', tab: '', cwd: '', program: program, app: 'tmux', tty: tty);
    final terms = Terminals(
      home: '/nonexistent-pocketterm',
      tmux: _ListedTmux([pane('1', 'ttys004', 'omp'), pane('2', 'ttys005', 'zsh'), pane('3', 'ttys006', 'omp')], {}),
      snapshot: () async => Procs(
        parsePs(
          '  500   400   500   500 ttys004  S+   omp --profile=personal\n'
          '  600     1   600   600 ttys005  Ss+  -zsh --profile=personal\n'
          '  700   400   700   700 ttys006  S+   /opt/homebrew/bin/omp -c\n',
        ),
      ),
    );
    expect((await terms.windows()).map((w) => (w.key, w.profile)), [
      ('tmux:default/1', 'personal'),
      ('tmux:default/2', ''),
      ('tmux:default/3', ''),
    ]);
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
      Future<Opened> attempt() => terms.launchNewProject(root, 'demo', roots: [root], host: terms.kitty!);
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

/// tmux listing these panes, attached by these clients.
class _ListedTmux extends Tmux {
  _ListedTmux(this.listed, this.attached) : super(executable: '/nonexistent-pocketterm/tmux', socketDirs: const []);
  final List<TermWindow> listed;
  final Map<String, TmuxClient> attached;

  @override
  Future<List<TermWindow>> windows(Procs procs) async {
    clients = attached;
    return listed;
  }
}
