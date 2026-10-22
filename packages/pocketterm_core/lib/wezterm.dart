import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:pocketterm_core/terminal.dart';

/// WezTerm, through `wezterm cli` against each running GUI's socket
/// (`~/.local/share/wezterm/gui-sock-<pid>`, on Windows too). Window keys:
/// `wezterm:<gui pid>/<pane id>`.
class WezTerm extends TerminalHost {
  /// [clock]: the time, for when a socket that stopped answering is asked again.
  /// [windowsPath]: on Windows, the PATH a new login would have
  /// (mergeWindowsPath), to find wezterm and to hand the WezTerm it starts,
  /// so a shell there finds what was installed while PocketTerm ran;
  /// PocketTerm's own PATH if null.
  WezTerm({
    String? executable,
    String? socketDir,
    String? home,
    bool? windows,
    DateTime Function()? clock,
    String Function()? windowsPath,
  }) : this._(executable, socketDir, home, windows ?? Platform.isWindows, clock ?? DateTime.now, windowsPath);

  WezTerm._(this._given, String? socketDir, String? home, this._windows, this._now, this._windowsPath)
    : _dir = socketDir ?? p.join(home ?? homeDir(windows: _windows), '.local', 'share', 'wezterm');

  String? _find() => findExecutable(
    'wezterm',
    windows: _windows,
    env: _windows && _windowsPath != null ? {'PATH': _windowsPath()} : null,
    extra: _windows
        ? ['${Platform.environment['ProgramFiles'] ?? r'C:\Program Files'}\\WezTerm\\wezterm.exe']
        : const ['/Applications/WezTerm.app/Contents/MacOS/wezterm'],
  );

  final String Function()? _windowsPath;

  final String? _given;
  String? _found;

  /// Looked for again while it isn't found: WezTerm installed while
  /// PocketTerm runs (Settings or the setup checklist installs it) counts.
  String? get _exe => _given ?? (_found ??= _find());

  final String _dir;
  final bool _windows;
  final DateTime Function() _now;

  /// Sockets that stopped answering (Windows, where a GUI's socket outlives
  /// it), by when: not asked again for [_deadFor]. A live GUI that was slow
  /// once comes back; a stale socket whose GUI's pid a process snapshot
  /// lacks is skipped by [_sockets] anyway.
  final _dead = <String, DateTime>{};
  static const _deadFor = Duration(minutes: 1);

  bool _isDead(String socket) {
    final at = _dead[socket];
    if (at == null) return false;
    if (_now().difference(at) < _deadFor) return true;
    _dead.remove(socket);
    return false;
  }

  @override
  String get id => 'wezterm';

  @override
  String get label => 'WezTerm';

  @override
  String? get appName => 'WezTerm';

  @override
  String? get bundleId => 'com.github.wez.wezterm';

  @override
  Set<TermCap> get caps => allCaps;

  @override
  bool owns(String key) => key.startsWith('wezterm:');

  bool get installed {
    final exe = _exe;
    return exe != null && File(exe).existsSync();
  }

  /// GUI pid → its socket, for each socket whose GUI still runs (when
  /// [procs] tell: on Windows, an empty process list tells nothing) and
  /// that didn't stop answering.
  Map<String, String> _sockets(Procs? procs) {
    final d = Directory(_dir);
    if (!d.existsSync()) return const {};
    final out = <String, String>{};
    final check = procs != null && !(_windows && procs.all.isEmpty);
    for (final e in d.listSync(followLinks: false)) {
      final m = RegExp(r'^gui-sock-(\d+)$').firstMatch(e.uri.pathSegments.last);
      if (m == null || _isDead(e.path)) continue;
      if (check && procs.byPid(int.parse(m[1]!)) == null) continue;
      out[m[1]!] = e.path;
    }
    return out;
  }

  Future<String> _cli(String socket, List<String> args) async {
    final exe = _exe;
    if (exe == null) throw const TerminalException('WezTerm is not installed.');
    final ProcessResult r;
    try {
      r = await Process.run(
        exe,
        ['cli', '--no-auto-start', ...args],
        environment: {'WEZTERM_UNIX_SOCKET': socket},
        // wezterm writes UTF-8; the default is the ANSI code page on Windows.
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (_windows) _dead[socket] = _now();
      throw const TerminalException('WezTerm did not answer.');
    }
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      if (err.contains('is not valid') || err.contains('pane') && err.contains('not found')) {
        throw const TerminalException('That window is gone.');
      }
      if (_windows) _dead[socket] = _now();
      throw TerminalException('WezTerm: ${err.split('\n').last}');
    }
    return r.stdout as String;
  }

  (String socket, String pane) _parse(String key) {
    final m = RegExp(r'^wezterm:(\d+)/(\d+)$').firstMatch(key);
    final socket = m == null ? null : _sockets(null)[m[1]];
    if (socket == null) throw const TerminalException('That window is gone.');
    return (socket, m![2]!);
  }

  @override
  Future<TermStatus> status(Procs procs) async {
    if (!installed) {
      return _windows
          ? TermStatus(
              id,
              label,
              TermState.missing,
              note: "Needed for your phone to reach this PC's terminals",
              fix: TermFix.install,
            )
          : TermStatus(id, label, TermState.missing);
    }
    if (await _release() case final release? when release < minRelease) {
      return TermStatus(
        id,
        label,
        TermState.setup,
        note:
            'WezTerm $release is too old for PocketTerm: update it to $minRelease or later'
            '${_windows ? ' (winget upgrade wez.wezterm)' : ''}',
      );
    }
    if (_sockets(procs).isEmpty) return TermStatus(id, label, TermState.idle, note: 'Not running');
    final n = (await windows(procs)).length;
    return TermStatus(id, label, TermState.ready, note: '$n window${n == 1 ? '' : 's'}');
  }

  /// The oldest WezTerm release (its date) whose `wezterm cli` has all
  /// PocketTerm uses: kill-pane came in 20230326-111934-3666303c.
  static const minRelease = 20230326;

  /// The release date of the installed wezterm, asked once per version of
  /// the file (an update in place is asked again); null when it doesn't say.
  Future<int?> _release() async {
    final exe = _exe;
    if (exe == null) return null;
    final DateTime modified;
    try {
      modified = File(exe).statSync().modified;
    } on FileSystemException {
      return null;
    }
    if (_asked case (final e, final at, final release) when e == exe && at == modified) return release;
    int? release;
    try {
      final r = await Process.run(exe, ['--version'], stdoutEncoding: utf8).timeout(const Duration(seconds: 5));
      release = weztermRelease('${r.stdout}');
    } on Object {
      release = null;
    }
    _asked = (exe, modified, release);
    return release;
  }

  (String, DateTime, int?)? _asked;

  @override
  Future<List<TermWindow>> windows(Procs procs) async {
    final out = <TermWindow>[];
    for (final MapEntry(key: pid, value: socket) in _sockets(procs).entries) {
      final String json;
      try {
        json = await _cli(socket, ['list', '--format', 'json']);
      } on TerminalException {
        continue;
      }
      out.addAll(parseWezTermList(pid, json, procs: procs, windows: _windows));
    }
    // The foreground program's own folder, where the shell's report is older.
    final cwds = await Procs.cwds(windows: _windows, [
      for (final w in out)
        if (procs.foreground(w.tty) case final p?) p.pid,
    ]);
    return [
      for (final w in out)
        if (cwds[procs.foreground(w.tty)?.pid] case final cwd?)
          TermWindow(
            key: w.key,
            title: w.title,
            tab: w.tab,
            cwd: cwd,
            program: w.program,
            focused: w.focused,
            app: w.app,
            caps: w.caps,
            tty: w.tty,
          )
        else
          w,
    ];
  }

  @override
  Future<List<String>> lines(String key, {bool history = false}) async {
    final (socket, pane) = _parse(key);
    return screenLines(
      await _cli(socket, [
        'get-text',
        '--pane-id',
        pane,
        '--escapes',
        if (history) ...['--start-line', '-10000'],
      ]),
    );
  }

  @override
  Future<String> plainScreen(String key) async {
    final (socket, pane) = _parse(key);
    return (await _cli(socket, ['get-text', '--pane-id', pane])).trimRight();
  }

  /// `--no-paste`: as typed, not a bracketed paste.
  Future<void> _write(String key, String bytes) async {
    final (socket, pane) = _parse(key);
    await _cli(socket, ['send-text', '--pane-id', pane, '--no-paste', '--', bytes]);
  }

  @override
  Future<void> type(String key, String text) => _write(key, text);

  @override
  Future<void> pressKeys(String key, List<String> names) async {
    for (final (i, run) in keyRuns(names).indexed) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 40));
      await _write(key, run);
    }
  }

  @override
  Future<void> close(String key) async {
    final (socket, pane) = _parse(key);
    await _cli(socket, ['kill-pane', '--pane-id', pane]);
  }

  /// A new tab in WezTerm's newest window (a new window would take the
  /// focus), or a new window if it has none. A WezTerm not running is
  /// started in the background (on Windows, its GUI in [cwd]), and its first
  /// window is the new one.
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    var sockets = _sockets(await Procs.snapshot(windows: _windows));
    final fresh = sockets.isEmpty;
    if (fresh) {
      if (_windows) {
        final exe = _exe;
        if (exe == null) throw const TerminalException('WezTerm is not installed.');
        await Process.start(
          p.join(p.dirname(exe), 'wezterm-gui.exe'),
          ['start', '--cwd', cwd],
          // Its shells find what was installed since PocketTerm started.
          environment: {if (_windowsPath case final path?) 'PATH': path()},
          mode: ProcessStartMode.detached,
        );
      } else {
        await Process.run('/usr/bin/open', ['-g', '-a', 'WezTerm']);
      }
      for (var i = 0; i < 40 && sockets.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        sockets = _sockets(await Procs.snapshot(windows: _windows));
      }
      if (sockets.isEmpty) throw const TerminalException("WezTerm didn't start.");
    }
    final MapEntry(key: pid, value: socket) = sockets.entries.last;
    final panes = [
      for (final p in jsonDecode(await _cli(socket, ['list', '--format', 'json'])) as List) p as Map,
    ];
    if (fresh && command == null && panes.length == 1) {
      final key = 'wezterm:$pid/${panes.single['pane_id']}';
      // Windows' GUI started in cwd already.
      if (!_windows) await type(key, ' cd -- ${shellQuote(cwd)} && clear\r');
      return key;
    }
    final newest = panes.isEmpty ? null : panes.map((p) => p['window_id'] as int).reduce(max);
    Future<String> spawn() => _cli(socket, [
      'spawn',
      if (newest != null) ...['--window-id', '$newest'] else '--new-window',
      '--cwd',
      cwd,
      if (command != null) ...['--', ...command],
    ]);
    final pane = (newest != null ? await spawn() : await keepFront(spawn, app: bundleId, windows: _windows)).trim();
    return 'wezterm:$pid/$pane';
  }
}

/// `wezterm cli list --format json` (the GUI with pid [pid]) as windows. A
/// pane with no tty (Windows) names its program by its title. [windows]:
/// folders as Windows has them ([cwdOfUri]).
List<TermWindow> parseWezTermList(String pid, String json, {Procs? procs, bool windows = false, String? localHost}) => [
  for (final p in jsonDecode(json) as List)
    () {
      final pane = p as Map;
      final tty = (pane['tty_name'] as String? ?? '').replaceFirst('/dev/', '');
      final title = pane['title'] as String? ?? '';
      final fg = procs?.foreground(tty);
      final cwd = Uri.tryParse(pane['cwd'] as String? ?? '');
      return TermWindow(
        key: 'wezterm:$pid/${pane['pane_id']}',
        title: title,
        tab: pane['tab_title'] as String? ?? '',
        cwd: cwd != null && cwd.scheme == 'file' ? cwdOfUri(cwd, windows: windows, localHost: localHost) : '',
        program: fg?.program ?? (tty.isEmpty ? programOfTitle(title) : ''),
        focused: pane['is_active'] == true,
        app: 'wezterm',
        tty: tty,
      );
    }(),
];

/// A `file:` URI's folder: a Mac's path as is; `file:///C:/Users/x/` (any
/// host dropped) as `C:\Users\x`, a drive's root as `C:\`. [windows]: a
/// share's (`file://wsl.localhost/Ubuntu/home/x/`, `file://wsl$/…`,
/// `file://server/share/`) as its UNC path (`\\wsl.localhost\Ubuntu\home\x`),
/// unless its host is this computer ([localHost], else its name, or
/// localhost): a WSL shell telling its own Linux folder, kept as is.
String cwdOfUri(Uri u, {bool windows = false, String? localHost}) {
  String trim(String path, int root) =>
      path.length > root && path.endsWith(r'\') ? path.substring(0, path.length - 1) : path;
  if (RegExp('^/[A-Za-z]:/').hasMatch(u.path)) return trim(Uri(path: u.path.substring(1)).toFilePath(windows: true), 3);
  final host = u.host.toLowerCase();
  final here = (localHost ?? Platform.localHostname).toLowerCase();
  if (windows && host.isNotEmpty && host != 'localhost' && host != here && u.path.length > 1) {
    return trim('\\\\$host${Uri(path: u.path).toFilePath(windows: true)}', 2);
  }
  return u.path;
}

/// The release date `wezterm --version` tells (`wezterm 20240203-110809-5046fc22`
/// → 20240203); null for a build that tells none.
int? weztermRelease(String version) => switch (RegExp(r'\b(\d{8})-\d{6}-[0-9a-f]+\b').firstMatch(version)) {
  final m? => int.parse(m[1]!),
  null => null,
};
