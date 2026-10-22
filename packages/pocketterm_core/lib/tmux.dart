import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:pocketterm_core/terminal.dart';

/// tmux, whichever terminal shows it: every server of this user (the
/// default socket and any `-L` one in `$TMUX_TMPDIR/tmux-<uid>` or
/// `/private/tmp/tmux-<uid>`), through its command line. Window keys:
/// `tmux:<socket name>/<pane number>` (the pane `%n`).
class Tmux extends TerminalHost {
  Tmux({String? executable, List<String>? socketDirs, this.env, this.timeout = const Duration(seconds: 5)})
    : _fixedExe = executable,
      _fixedDirs = socketDirs;

  final String? _fixedExe;
  final List<String>? _fixedDirs;

  /// The environment PocketTerm runs in: where tmux is looked up, and
  /// whether a server it starts needs a UTF-8 locale ([utf8Locale]); this
  /// process's when null.
  final Map<String, String>? env;

  /// How long one tmux command may take.
  final Duration timeout;

  /// Looked up until found, not once at start: tmux installed while the app
  /// runs shows up without a restart.
  String? _found;
  String? get _exe {
    if (_fixedExe != null) return _fixedExe;
    final found = _found;
    if (found != null && File(found).existsSync()) return found;
    return _found = findExecutable('tmux', env: env);
  }

  /// Listed on each look: a server's directory appears when it first starts.
  List<String> get _dirs => _fixedDirs ?? _defaultDirs(env ?? Platform.environment);

  /// Sockets learnt from agents (their `TMUX`), by name, for servers in a
  /// directory not scanned.
  final _known = <String, String>{};

  /// The clients attached on the last [windows], by tty, so a terminal
  /// window showing tmux can give way to its pane.
  Map<String, TmuxClient> clients = const {};

  static List<String> _defaultDirs(Map<String, String> env) {
    final tmp = env['TMUX_TMPDIR'];
    final roots = {if (tmp != null && tmp.isNotEmpty) tmp, '/private/tmp'};
    final dirs = <String>[];
    for (final root in roots) {
      final d = Directory(root);
      if (!d.existsSync()) continue;
      try {
        for (final e in d.listSync(followLinks: false)) {
          if (e is Directory && e.uri.pathSegments.where((s) => s.isNotEmpty).last.startsWith('tmux-')) {
            dirs.add(e.path);
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return dirs;
  }

  bool get installed {
    final exe = _exe;
    return exe != null && File(exe).existsSync();
  }

  /// The tmux found (an absolute path), or null when it isn't installed.
  String? get executable => installed ? _exe : null;

  @override
  String get id => 'tmux';

  @override
  String get label => 'tmux';

  @override
  String? get appName => null;

  @override
  Set<TermCap> get caps => allCaps;

  @override
  bool owns(String key) => key.startsWith('tmux:');

  /// A socket an agent named (its `TMUX`), for a server outside the
  /// directories scanned.
  void learn(String socketPath) {
    final name = socketPath.split('/').last;
    if (tmuxSocketName(name)) _known[name] = socketPath;
  }

  /// Socket name → path, for every live-looking socket we may open (a
  /// learnt one only while it's there: its server may have gone).
  Map<String, String> _sockets() {
    _known.removeWhere(
      (_, path) => FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.unixDomainSock,
    );
    final out = <String, String>{..._known};
    for (final dir in _dirs) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      try {
        for (final e in d.listSync(followLinks: false)) {
          final name = e.uri.pathSegments.last;
          if (tmuxSocketName(name) &&
              FileSystemEntity.typeSync(e.path, followLinks: false) == FileSystemEntityType.unixDomainSock) {
            out[name] = e.path;
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return out;
  }

  /// What tmux says when it isn't installed, as an error and as its status.
  static const notInstalled =
      'tmux is not installed. Install it with Homebrew (brew install tmux) or MacPorts (sudo port install tmux).';

  /// The most UTF-8 bytes of text one `send-keys` takes: tmux refuses a
  /// command over 16 KB ("command too long").
  static const typeBytes = 8000;

  /// tmux with [args] on server [socket]; killed when it hasn't answered
  /// within [timeout] (a server that hangs leaves no client behind each look).
  /// `-u`: names and folders come back in UTF-8 even when PocketTerm has no
  /// UTF-8 locale (started from Finder or the Dock), not with `_` for each
  /// other letter.
  Future<String> _run(String socket, List<String> args) async {
    final exe = _exe;
    if (exe == null) throw const TerminalException(notInstalled);
    final Process p;
    try {
      p = await Process.start(exe, ['-u', '-S', socket, ...args]);
    } on ProcessException catch (e) {
      throw TerminalException('tmux: ${e.message}');
    }
    unawaited(p.stdin.close().then((_) {}, onError: (Object _) {}));
    // Malformed UTF-8 reads as U+FFFD rather than failing the whole answer.
    final out = p.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    final code = await p.exitCode.then<int?>((c) => c).timeout(timeout, onTimeout: () => null);
    if (code == null) {
      p.kill(ProcessSignal.sigkill);
      throw const TerminalException('tmux did not answer.');
    }
    if (code != 0) {
      final e = (await err).trim();
      // A pane closed, a server killed, a socket deleted.
      if (e.contains("can't find pane") || e.contains('no server running') || e.contains('error connecting to')) {
        throw const TerminalException('That window is gone.');
      }
      throw TerminalException('tmux: $e');
    }
    return await out;
  }

  (String socket, String pane) _parse(String key) {
    final m = RegExp(r'^tmux:([\w.-]+)/(\d+)$').firstMatch(key);
    final path = m == null ? null : _sockets()[m[1]];
    if (path == null) throw const TerminalException('That window is gone.');
    return (path, '%${m![2]}');
  }

  /// A pane a record, ended by RS and a newline, its fields apart by US: a
  /// folder's name may hold a tab or a line break, which tmux prints as is.
  static const _format =
      '#{pane_id}\x1f#{pane_tty}\x1f#{pane_current_command}\x1f#{pane_current_path}\x1f#{pane_title}\x1f'
      '#{window_name}\x1f#{session_name}\x1f#{pane_active}\x1f#{window_active}\x1f#{session_attached}\x1e';

  /// A client a record like a pane: its tty, its pane, and the title tmux
  /// gives its terminal (`set-titles-string` as tmux expands it for that
  /// client), empty while `set-titles` is off.
  static const _clientFormat = '#{client_tty}\x1f#{pane_id}\x1f#{?set-titles,#{T:set-titles-string},}\x1e';

  @override
  Future<TermStatus> status(Procs procs) async {
    if (!installed) return TermStatus(id, label, TermState.missing, note: notInstalled);
    final n = (await windows(procs)).length;
    return TermStatus(
      id,
      label,
      n == 0 ? TermState.idle : TermState.ready,
      note: n == 0 ? 'No tmux server running' : '$n pane${n == 1 ? '' : 's'}',
    );
  }

  @override
  Future<List<TermWindow>> windows(Procs procs) async {
    if (!installed) return const [];
    final out = <TermWindow>[];
    final clients = <String, TmuxClient>{};
    for (final MapEntry(key: name, value: path) in _sockets().entries) {
      try {
        out.addAll(parseTmuxPanes(name, await _run(path, ['list-panes', '-a', '-F', _format]), procs));
        final list = await _run(path, ['list-clients', '-F', _clientFormat]);
        clients.addAll(parseTmuxClients(name, list));
      } on TerminalException {
        // A socket left behind by a server that has gone.
        continue;
      }
    }
    this.clients = clients;
    return out;
  }

  @override
  Future<List<String>> lines(String key, {bool history = false}) async {
    final (socket, pane) = _parse(key);
    return screenLines(
      await _run(socket, [
        'capture-pane',
        '-p',
        '-e',
        '-t',
        pane,
        if (history) ...['-S', '-'],
      ]),
    );
  }

  @override
  Future<String> plainScreen(String key) async {
    final (socket, pane) = _parse(key);
    return (await _run(socket, ['capture-pane', '-p', '-t', pane])).trimRight();
  }

  /// In pieces of [typeBytes], one `send-keys` each.
  @override
  Future<void> type(String key, String text) async {
    final (socket, pane) = _parse(key);
    for (final chunk in textChunks(text, typeBytes)) {
      await _run(socket, ['send-keys', '-t', pane, '-l', '--', chunk]);
    }
  }

  @override
  Future<void> pressKeys(String key, List<String> names) async {
    if (names.isEmpty) return;
    final (socket, pane) = _parse(key);
    for (final run in tmuxKeyRuns(names)) {
      await _run(socket, [
        'send-keys',
        '-t',
        pane,
        if (run.literal) ...['-l', '--'],
        ...run.keys,
      ]);
    }
  }

  @override
  Future<void> close(String key) async {
    final (socket, pane) = _parse(key);
    await _run(socket, ['kill-pane', '-t', pane]);
  }

  /// A detached session of its own on the default server (started if none
  /// runs): a terminal app then shows it with `tmux attach` ([attach]). A
  /// server started here keeps PocketTerm's environment for every shell in
  /// it, so it gets a UTF-8 locale should PocketTerm have none.
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final exe = _exe;
    if (exe == null) throw const TerminalException(notInstalled);
    final session = 'pt-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final r = await Process.run(exe, [
      '-u',
      'new-session',
      '-d',
      '-s',
      session,
      '-c',
      cwd,
      '-P',
      '-F',
      '#{socket_path}\t#{pane_id}',
      ...?command,
    ], environment: utf8Locale(env));
    if (r.exitCode != 0) throw TerminalException('tmux: ${'${r.stderr}'.trim()}');
    final [path, pane] = (r.stdout as String).trim().split('\t');
    learn(path);
    lastSession = session;
    return 'tmux:${path.split('/').last}/${pane.replaceFirst('%', '')}';
  }

  /// The session [launch] made last.
  String? lastSession;

  /// What a terminal app runs to show tmux session [session].
  List<String> attach(String session) => [_exe ?? 'tmux', 'attach-session', '-t', '=$session'];
}

/// tmux's `list-panes -a -F Tmux._format` output (server [socket]) as windows.
List<TermWindow> parseTmuxPanes(String socket, String out, [Procs? procs]) => [
  for (final record in out.split('\x1e\n'))
    if (record.split('\x1f') case [
      final id,
      final tty,
      final command,
      final path,
      final title,
      final window,
      final session,
      final paneActive,
      final windowActive,
      final attached,
    ])
      () {
        final fg = procs?.foreground(tty);
        final program = fg?.program ?? command;
        return TermWindow(
          key: 'tmux:$socket/${id.replaceFirst('%', '')}',
          // A pane's default title is the host name: its window's name says more.
          title: cleanTitle(title.isEmpty || title == Platform.localHostname ? window : title),
          tab: cleanTitle('$session:$window'),
          cwd: path,
          program: program,
          focused: paneActive == '1' && windowActive == '1' && attached != '0',
          app: 'tmux',
          tty: tty.replaceFirst('/dev/', ''),
        );
      }(),
];

/// A tmux client: the pane key it shows, and the title it gives the terminal
/// it runs in (empty: none).
typedef TmuxClient = ({String pane, String title});

/// `list-clients -F Tmux._clientFormat` output (server [socket]) as client
/// tty → [TmuxClient].
Map<String, TmuxClient> parseTmuxClients(String socket, String out) => {
  for (final record in out.split('\x1e\n'))
    if (record.split('\x1f') case [final tty, final pane, final title] when pane.startsWith('%'))
      tty.replaceFirst('/dev/', ''): (pane: 'tmux:$socket/${pane.substring(1)}', title: cleanTitle(title)),
};

/// kitty's key names as tmux's `send-keys` runs: tmux's names where it has
/// them (so it sends what the program in the pane expects), in one run;
/// a character goes literally (`-l`) in a run of its own, as tmux would
/// read `;` or a word like `Up` as something else. Shift+Enter is Alt+Enter
/// (M-Enter): tmux sends Shift+Enter like Enter unless extended keys are on.
List<({bool literal, List<String> keys})> tmuxKeyRuns(List<String> names) {
  final runs = <({bool literal, List<String> keys})>[];
  void add(String key, {required bool literal}) {
    final last = runs.lastOrNull;
    if (last != null && last.literal == literal) {
      last.keys.add(key);
    } else {
      runs.add((literal: literal, keys: [key]));
    }
  }

  for (final n in names) {
    final named = switch (n) {
      'enter' || 'return' => 'Enter',
      'esc' || 'escape' => 'Escape',
      'tab' => 'Tab',
      'shift+tab' => 'BTab',
      'space' => 'Space',
      'backspace' => 'BSpace',
      'delete' => 'DC',
      'up' => 'Up',
      'down' => 'Down',
      'left' => 'Left',
      'right' => 'Right',
      'home' => 'Home',
      'end' => 'End',
      'page_up' || 'pageup' => 'PPage',
      'page_down' || 'pagedown' => 'NPage',
      'shift+enter' || 'alt+enter' => 'M-Enter',
      _ when RegExp(r'^ctrl\+[a-z]$').hasMatch(n) => 'C-${n.substring(5)}',
      _ => null,
    };
    if (named != null) {
      add(named, literal: false);
    } else if (n.runes.length == 1) {
      add(n, literal: true);
    } else {
      throw TerminalException('Unknown key: $n');
    }
  }
  return runs;
}
