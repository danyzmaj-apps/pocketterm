/// The end-to-end run's shared pieces: the run's configuration (written by
/// bin/run.dart, read by the desktop's integration_test/e2e_test.dart), the
/// throwaway home the terminals run in, and the throwaway terminals
/// themselves, each started with a config of its own and stopped by pid.
///
/// Never touches what it didn't start: kitty listens in a socket folder of
/// its own, WezTerm keeps its socket under the throwaway home, Ghostty and
/// iTerm2 start as a new instance with only the throwaway config, tmux runs its own
/// server, and every process started is written down ([Owned]) to be
/// stopped at the end, even when the run fails.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The terminals the run covers, by the desktop's ids.
const terminalIds = ['kitty', 'ghostty', 'wezterm', 'iterm'];

/// One terminal's run: everything the desktop side needs, as JSON in
/// `<artifacts>/config.json`.
class E2eConfig {
  E2eConfig({
    required this.terminal,
    required this.artifacts,
    required this.work,
    required this.serverUrl,
    required this.setupLink,
    required this.phone,
    required this.terminalPath,
    this.serverCa,
    this.supabaseTokenFile,
  });

  factory E2eConfig.fromJson(Map<String, dynamic> j) => E2eConfig(
    terminal: j['terminal'] as String,
    artifacts: j['artifacts'] as String,
    work: j['work'] as String,
    serverUrl: j['serverUrl'] as String,
    setupLink: j['setupLink'] as String,
    phone: j['phone'] as bool,
    terminalPath: j['terminalPath'] as String,
    serverCa: j['serverCa'] as String?,
    supabaseTokenFile: j['supabaseTokenFile'] as String?,
  );

  factory E2eConfig.read(String path) =>
      E2eConfig.fromJson(jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>);

  /// kitty, ghostty, wezterm or iterm.
  final String terminal;

  /// Where logs, screenshots, results and the phone's hand-off files go
  /// (`build/e2e/<stamp>/<terminal>`).
  final String artifacts;

  /// The throwaway folder under /private/tmp (unix socket paths must stay
  /// short): the home, the projects, the sockets.
  final String work;

  /// The server's URL, or `builtin`: the desktop's own ("On this
  /// computer"), which makes its links itself ([setupLink] is empty), or
  /// `supabase-cloud`: a new project the setup's Supabase branch makes with
  /// the access token in [supabaseTokenFile] ([setupLink] is empty).
  final String serverUrl;
  final String setupLink;

  bool get builtIn => serverUrl == 'builtin';
  bool get supabaseCloud => serverUrl == 'supabase-cloud';

  /// The file with the Supabase personal access token (its path only: the
  /// token stays out of the config and the artifacts).
  final String? supabaseTokenFile;

  /// The ref of the project the run made on Supabase, written as soon as it
  /// exists: bin/run.dart deletes that project after the run.
  String get supabaseProject => p.join(artifacts, 'supabase-project.txt');

  /// Whether the phone's phases run (else the desktop goes on alone).
  final bool phone;

  /// The PATH the throwaway terminals' shells start with: the one of the
  /// terminal the run was started from, as a person's terminal has it (the
  /// desktop itself runs with launchd's, [launchServicesEnv]).
  final String terminalPath;

  /// A PEM root the desktop trusts besides the system's: a test server
  /// whose certificate is its own CA's (Caddy's `tls internal`).
  final String? serverCa;

  Map<String, Object> toJson() => {
    'terminal': terminal,
    'artifacts': artifacts,
    'work': work,
    'serverUrl': serverUrl,
    'setupLink': setupLink,
    'phone': phone,
    'terminalPath': terminalPath,
    'serverCa': ?serverCa,
    'supabaseTokenFile': ?supabaseTokenFile,
  };

  String get home => p.join(work, 'home');

  /// Not ASCII, so a tool whose output PocketTerm reads in a locale it
  /// doesn't have (an app from Finder has none) shows up as a wrong folder.
  String get projects => p.join(work, 'p-é漢');
  String get kittyDir => p.join(work, 'k');
  String get tmuxTmp => p.join(work, 't');
  String get bin => p.join(work, 'bin');
  String get typedLogs => p.join(work, 'typed');
  String get owned => p.join(artifacts, 'owned.jsonl');
  String get phaseDir => p.join(artifacts, 'phase');
  String get rpcDir => p.join(artifacts, 'rpc');
  String get results => p.join(artifacts, 'results.jsonl');
  String get screenshots => p.join(artifacts, 'screenshots');
  String get cliJson => p.join(home, '.config', 'pocketterm', 'cli.json');

  /// tmux's default socket for [tmuxTmp] (what `TMUX_TMPDIR` points at).
  String get tmuxSocket => p.join(tmuxTmp, 'tmux-${_uid()}', 'default');

  /// What the throwaway terminals run with: the throwaway home, the run's tmux,
  /// and nothing of the terminal the run itself was started from.
  Map<String, String> terminalEnv() => {
    for (final MapEntry(:key, :value) in Platform.environment.entries)
      if (!_inherited(key)) key: value,
    'HOME': home,
    'TMUX_TMPDIR': tmuxTmp,
    'ZDOTDIR': home,
    'LANG': 'en_US.UTF-8',
    'PATH': terminalPath,
  };

  /// The project folder [name] of this terminal's run.
  String project(String name) => p.join(projects, name);
}

/// The variables a terminal sets for its own windows, which the run's
/// throwaway terminals must not inherit from the one the run started in.
bool _inherited(String key) =>
    key.startsWith('KITTY_') ||
    key.startsWith('WEZTERM_') ||
    key.startsWith('ITERM_') ||
    key.startsWith('GHOSTTY_') ||
    key == 'TMUX' ||
    key == 'TMUX_PANE' ||
    key == 'TERM_PROGRAM' ||
    key == 'TERM_PROGRAM_VERSION' ||
    key == 'TERM_SESSION_ID' ||
    key == 'POCKETTERM_CLI_JSON' ||
    key == 'ZDOTDIR';

/// The environment without what a terminal sets for its windows.
Map<String, String> cleanEnv([Map<String, String>? env]) => {
  for (final MapEntry(:key, :value) in (env ?? Platform.environment).entries)
    if (!_inherited(key)) key: value,
};

/// launchd's PATH: all an app started from Finder or the Dock has.
const launchdPath = '/usr/bin:/bin:/usr/sbin:/sbin';

/// What Launch Services starts an app from Finder or the Dock with: the
/// home, user, shell and temp folder, launchd's PATH ([tools] after it:
/// what `flutter test` itself needs), no TERM, no locale, nothing a shell or
/// terminal sets; [extra] on top. The e2e desktop runs in it, so whatever
/// PocketTerm starts behaves as it does for someone who opened the app,
/// not as from the terminal the run was started in.
Map<String, String> launchServicesEnv({List<String> tools = const [], Map<String, String> extra = const {}}) {
  const kept = {'HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'SSH_AUTH_SOCK', '__CF_USER_TEXT_ENCODING'};
  return {
    for (final MapEntry(:key, :value) in Platform.environment.entries)
      if (kept.contains(key)) key: value,
    'PATH': [launchdPath, ...tools].join(':'),
    ...extra,
  };
}

int? _uidCache;
int _uid() => _uidCache ??= int.parse('${Process.runSync('/usr/bin/id', ['-u']).stdout}'.trim());

// ---------------------------------------------------------------- owned

/// The processes and servers the run started, one JSON line each in
/// [path], so the end of the run (or the next one) stops them and nothing
/// else.
class Owned {
  Owned(this.path);
  final String path;

  void pid(int pid, String what) => _add({'pid': pid, 'what': what});

  void tmux(String socket) => _add({'tmux': socket, 'what': 'tmux server'});

  void _add(Map<String, Object> entry) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${jsonEncode(entry)}\n', mode: FileMode.append, flush: true);
  }

  /// Stops everything written down in [path]: SIGTERM, then SIGKILL for
  /// what's still there a few seconds later.
  static Future<List<String>> stopAll(String path) async {
    final f = File(path);
    if (!f.existsSync()) return const [];
    final stopped = <String>[];
    final pids = <int>[];
    var ghosttyKilled = false;
    for (final line in f.readAsLinesSync().where((l) => l.trim().isNotEmpty)) {
      final e = jsonDecode(line) as Map<String, dynamic>;
      if (e['tmux'] case final String socket) {
        if (File(socket).existsSync() || FileSystemEntity.typeSync(socket) != FileSystemEntityType.notFound) {
          final r = await Process.run('/opt/homebrew/bin/tmux', ['-S', socket, 'kill-server']);
          if (r.exitCode == 0) stopped.add('tmux $socket');
        }
      } else if (e['pid'] case final int pid) {
        if (_alive(pid)) {
          // A killed Ghostty or iTerm2 is reopened by macOS with its windows
          // (and the default config): it's asked to quit first, as Quit would.
          if (e['what'] == 'ghostty' || e['what'] == 'iterm') await _quitApp(pid);
          if (_alive(pid)) {
            Process.killPid(pid);
            if (e['what'] == 'ghostty') ghosttyKilled = true;
          }
          pids.add(pid);
          stopped.add('${e['what']} ($pid)');
        }
      }
    }
    for (var i = 0; i < 30 && pids.any(_alive); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    for (final pid in pids.where(_alive)) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    // One that didn't quit (hung) and was killed: macOS starts it again at
    // once, restoring its windows in the default config. That one quits too.
    if (ghosttyKilled) {
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final r = await Process.run('/usr/bin/pgrep', ['-f', '${GhosttyThrowaway.app}/Contents/MacOS/ghostty']);
        final again = '${r.stdout}'.split('\n').map(int.tryParse).whereType<int>().where((p) => !pids.contains(p));
        if (again.isEmpty) continue;
        for (final p in again) {
          await _quitApp(p);
          stopped.add('ghostty reopened by macOS ($p)');
        }
        break;
      }
    }
    return stopped;
  }
}

bool _alive(int pid) => Process.runSync('/bin/kill', ['-0', '$pid']).exitCode == 0;

/// Asks the app with [pid] (and no other instance) to quit, and waits up to
/// 5 s for it to go.
Future<void> _quitApp(int pid) async {
  await Process.run('/usr/bin/osascript', [
    '-l',
    'JavaScript',
    '-e',
    "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate",
  ]);
  for (var i = 0; i < 50 && _alive(pid); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

// ---------------------------------------------------------------- the home

/// The throwaway home: a zsh that puts the fake omp first on its PATH, names
/// its windows `shell <folder>`, writes each command run and each Esc, arrow,
/// Tab, Enter and Ctrl+C key it gets to `<typedLogs>/<folder>.log`, and runs a folder's
/// `.e2e-autorun` once when it starts there; the terminals' configs.
void writeHome(E2eConfig c) {
  for (final d in [c.home, c.projects, c.kittyDir, c.typedLogs, c.bin, c.phaseDir, c.rpcDir, c.screenshots]) {
    Directory(d).createSync(recursive: true);
  }
  Process.runSync('/bin/chmod', ['700', c.kittyDir]);
  File(p.join(c.home, '.zshenv')).writeAsStringSync('');
  File(p.join(c.home, '.zshrc')).writeAsStringSync('''
# PocketTerm e2e: a throwaway shell. Nothing here touches the real home
# (kitty starts shells through login(1), which puts the real HOME back).
export HOME="${c.home}"
export PTE2E=1
export POCKETTERM_CLI_JSON="${c.cliJson}"
export PATH="${c.bin}:\$PATH"
export HISTFILE="\$HOME/.zsh_history"
export E2E_TYPED="${c.typedLogs}"
PROMPT='%1~ \$ '
unsetopt PROMPT_SP
# The folder, as Ghostty's own shell integration tells it (off here: it
# would wrap this shell); Ghostty knows a window's folder only this way.
precmd() {
  [[ \$TERM_PROGRAM == ghostty ]] && print -n "\\e]7;file://\$HOST\$PWD\\a"
  print -Pn "\\e]2;shell %1~\\a"
}
preexec() { print -r -- "cmd:\$1" >> "\$E2E_TYPED/\${PWD:t}.log" }
e2e-key() { print -r -- "key:\$1" >> "\$E2E_TYPED/\${PWD:t}.log" }
e2e-up() { e2e-key up; zle up-line-or-history }
e2e-down() { e2e-key down; zle down-line-or-history }
e2e-left() { e2e-key left; zle backward-char }
e2e-right() { e2e-key right; zle forward-char }
e2e-esc() { e2e-key esc }
e2e-tab() { e2e-key tab; zle expand-or-complete }
e2e-enter() { e2e-key enter; zle accept-line }
zle -N e2e-up; zle -N e2e-down; zle -N e2e-left; zle -N e2e-right; zle -N e2e-esc
zle -N e2e-tab; zle -N e2e-enter
bindkey -e
bindkey '^[[A' e2e-up '^[OA' e2e-up '^[[B' e2e-down '^[OB' e2e-down
bindkey '^[[D' e2e-left '^[OD' e2e-left '^[[C' e2e-right '^[OC' e2e-right
bindkey '^[' e2e-esc '^I' e2e-tab '^M' e2e-enter
# Ctrl+C at the prompt: logged, then the line goes as zsh's own would.
TRAPINT() { e2e-key ctrl+c; return \$(( 128 + \$1 )) }
if [[ -f .e2e-autorun ]]; then
  __e2e=\$(<.e2e-autorun); rm -f .e2e-autorun; eval "\$__e2e"
fi
''');
  File(p.join(c.home, '.config', 'kitty', 'kitty.conf'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
allow_remote_control socket-only
listen_on unix:${c.kittyDir}/kitty
confirm_os_window_close 0
shell_integration disabled
startup_session none
macos_quit_when_last_window_closed yes
remember_window_size no
initial_window_width 100c
initial_window_height 30c
update_check_interval 0
shell /bin/zsh -l
''');
  File(p.join(c.home, '.wezterm.lua')).writeAsStringSync('''
return {
  check_for_updates = false,
  window_close_confirmation = 'NeverPrompt',
  skip_close_confirmation_for_processes_named = { 'zsh', 'omp', 'tmux' },
  quit_when_all_windows_are_closed = true,
  default_prog = { '/bin/zsh', '-l' },
  initial_cols = 100,
  initial_rows = 30,
  automatically_reload_config = false,
}
''');
  File(p.join(c.home, '.config', 'ghostty', 'config'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
window-save-state = never
confirm-close-surface = false
quit-after-last-window-closed = true
shell-integration = none
auto-update = off
''');
}

/// A git repository [name] in the run's projects folder (the phone lists
/// repositories), which runs [autorun] in the first shell started there.
String makeProject(E2eConfig c, String name, {String? autorun}) {
  final dir = Directory(c.project(name))..createSync(recursive: true);
  if (!Directory(p.join(dir.path, '.git')).existsSync()) {
    Process.runSync('/usr/bin/git', ['init', '-q', dir.path]);
  }
  final run = File(p.join(dir.path, '.e2e-autorun'));
  if (autorun != null) {
    run.writeAsStringSync(autorun);
  } else if (run.existsSync()) {
    run.deleteSync();
  }
  return dir.path;
}

/// What the fake omp in [project] logged (.fake_omp/log.jsonl), oldest first.
List<Map<String, dynamic>> fakeOmpLog(String project) {
  final f = File(p.join(project, '.fake_omp', 'log.jsonl'));
  if (!f.existsSync()) return const [];
  return [
    for (final l in f.readAsLinesSync())
      if (l.trim().isNotEmpty) jsonDecode(l) as Map<String, dynamic>,
  ];
}

/// What the throwaway shell in folder [name] ran and the keys it got.
List<String> typedLog(E2eConfig c, String name) {
  final f = File(p.join(c.typedLogs, '$name.log'));
  return f.existsSync() ? f.readAsLinesSync() : const [];
}

/// Waits until [check] holds, polling; throws [what] on timeout.
Future<T> until<T>(
  String what,
  FutureOr<T?> Function() check, {
  Duration timeout = const Duration(seconds: 30),
  Duration every = const Duration(milliseconds: 300),
}) async {
  final end = DateTime.now().add(timeout);
  Object? last;
  while (true) {
    try {
      final v = await check();
      if (v != null && v != false) return v;
    } on Object catch (e) {
      last = e;
    }
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('$what${last == null ? '' : ' (last error: $last)'}', timeout);
    }
    await Future<void>.delayed(every);
  }
}

// ---------------------------------------------------------------- terminals

/// One throwaway terminal app: started once with a first window, more
/// windows on demand, stopped by pid.
abstract class Throwaway {
  Throwaway(this.c, this.owned);
  final E2eConfig c;
  final Owned owned;

  String get id;

  /// Starts the app with one window in [cwd].
  Future<void> start(String cwd);

  /// Another window in [cwd], opened like the person would (the terminal's
  /// own command line); null when the desktop app should open it instead
  /// (Ghostty, whose windows only AppleScript makes).
  Future<void> open(String cwd);

  static Throwaway of(String terminal, E2eConfig c, Owned owned) => switch (terminal) {
    'kitty' => KittyThrowaway(c, owned),
    'wezterm' => WezTermThrowaway(c, owned),
    'ghostty' => GhosttyThrowaway(c, owned),
    'iterm' => ITermThrowaway(c, owned),
    _ => throw ArgumentError('Unknown terminal: $terminal'),
  };
}

class KittyThrowaway extends Throwaway {
  KittyThrowaway(super.c, super.owned);

  static const _app = '/Applications/kitty.app/Contents/MacOS';

  @override
  String get id => 'kitty';

  String? socket;

  @override
  Future<void> start(String cwd) async {
    final proc = await Process.start(
      '$_app/kitty',
      ['--single-instance=no', '--config', p.join(c.home, '.config', 'kitty', 'kitty.conf'), '--directory', cwd],
      environment: c.terminalEnv(),
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
      workingDirectory: cwd,
    );
    owned.pid(proc.pid, 'kitty');
    final path = p.join(c.kittyDir, 'kitty-${proc.pid}');
    await until(
      'kitty listening at $path',
      () => FileSystemEntity.typeSync(path) == FileSystemEntityType.unixDomainSock,
    );
    socket = path;
  }

  @override
  Future<void> open(String cwd) async {
    final r = await Process.run(
      '$_app/kitten',
      ['@', '--to', 'unix:$socket', 'launch', '--type=os-window', '--cwd', cwd],
      environment: c.terminalEnv(),
      includeParentEnvironment: false,
    );
    if (r.exitCode != 0) throw StateError('kitty launch: ${r.stderr}');
  }
}

class WezTermThrowaway extends Throwaway {
  WezTermThrowaway(super.c, super.owned);

  static const _exe = '/Applications/WezTerm.app/Contents/MacOS/wezterm';

  @override
  String get id => 'wezterm';

  String? socket;

  String get _sockets => p.join(c.home, '.local', 'share', 'wezterm');

  @override
  Future<void> start(String cwd) async {
    final proc = await Process.start(
      _exe,
      [
        '--config-file',
        p.join(c.home, '.wezterm.lua'),
        'start',
        '--always-new-process',
        '--class',
        'pte2e',
        '--cwd',
        cwd,
      ],
      environment: c.terminalEnv(),
      includeParentEnvironment: false,
      mode: ProcessStartMode.detached,
      workingDirectory: cwd,
    );
    owned.pid(proc.pid, 'wezterm');
    final sock = await until('WezTerm listening in $_sockets', () {
      final d = Directory(_sockets);
      if (!d.existsSync()) return null;
      for (final e in d.listSync()) {
        final name = p.basename(e.path);
        if (name.startsWith('gui-sock-')) return e.path;
      }
      return null;
    });
    final gui = int.tryParse(p.basename(sock).substring('gui-sock-'.length));
    if (gui != null) owned.pid(gui, 'wezterm-gui');
    socket = sock;
  }

  @override
  Future<void> open(String cwd) async {
    final r = await Process.run(
      _exe,
      ['cli', '--no-auto-start', 'spawn', '--new-window', '--cwd', cwd],
      environment: {...c.terminalEnv(), 'WEZTERM_UNIX_SOCKET': socket!},
      includeParentEnvironment: false,
    );
    if (r.exitCode != 0) throw StateError('wezterm spawn: ${r.stderr}');
  }
}

/// Ghostty as a new instance with only the throwaway config. Refuses to
/// start while another Ghostty runs: AppleScript (all Ghostty can be driven
/// with) can't tell two instances apart, and the person's must not be
/// touched.
class GhosttyThrowaway extends Throwaway {
  GhosttyThrowaway(super.c, super.owned);

  static const app = '/Applications/Ghostty.app';

  @override
  String get id => 'ghostty';

  static Future<Set<int>> running() async {
    final r = await Process.run('/usr/bin/pgrep', ['-f', '$app/Contents/MacOS/ghostty']);
    return {for (final w in '${r.stdout}'.split(RegExp(r'\s+'))) ?int.tryParse(w)};
  }

  int? pid;

  @override
  Future<void> start(String cwd) async {
    final before = await running();
    if (before.isNotEmpty) {
      throw StateError('Another Ghostty is running (pid ${before.join(', ')}): quit it to run the Ghostty matrix.');
    }
    final env = c.terminalEnv();
    final r = await Process.run('/usr/bin/open', [
      '-na',
      app,
      for (final k in ['HOME', 'TMUX_TMPDIR', 'ZDOTDIR', 'LANG', 'PATH']) ...['--env', '$k=${env[k]}'],
      '--args',
      '--config-default-files=false',
      '--window-save-state=never',
      '--config-file=${p.join(c.home, '.config', 'ghostty', 'config')}',
      '--working-directory=$cwd',
    ], environment: cleanEnv());
    if (r.exitCode != 0) throw StateError('open Ghostty: ${r.stderr}');
    pid = await until('Ghostty started', () async {
      final now = (await running()).difference(before);
      return now.isEmpty ? null : now.first;
    });
    owned.pid(pid!, 'ghostty');
  }

  /// Ghostty's windows come from the desktop app's Ghostty host (AppleScript).
  @override
  Future<void> open(String cwd) => throw UnsupportedError('Open Ghostty windows with the app’s Ghostty host.');
}

/// iTerm2 as a new instance that opens no window by itself, with its
/// settings for this run given on its command line (NSArgumentDomain: none
/// is written to its preferences): no question on quit, no update check, no
/// windows restored. Refuses to start while another iTerm2 runs, as
/// AppleScript can't tell two instances apart. Its sessions get the throwaway
/// home from its own environment.
class ITermThrowaway extends Throwaway {
  ITermThrowaway(super.c, super.owned);

  static const app = '/Applications/iTerm.app';

  @override
  String get id => 'iterm';

  static Future<Set<int>> running() async {
    final r = await Process.run('/usr/bin/pgrep', ['-f', '$app/Contents/MacOS/iTerm2']);
    return {for (final w in '${r.stdout}'.split(RegExp(r'\s+'))) ?int.tryParse(w)};
  }

  @override
  Future<void> start(String cwd) async {
    final before = await running();
    if (before.isNotEmpty) {
      throw StateError('Another iTerm2 is running (pid ${before.join(', ')}): quit it to run the iTerm2 matrix.');
    }
    final env = c.terminalEnv();
    final r = await Process.run('/usr/bin/open', [
      '-na',
      app,
      for (final k in ['HOME', 'TMUX_TMPDIR', 'ZDOTDIR', 'LANG', 'PATH']) ...['--env', '$k=${env[k]}'],
      '--args',
      for (final (k, v) in const [
        ('PromptOnQuit', '0'),
        ('OnlyWhenMoreTabs', '0'),
        ('OpenNoWindowsAtStartup', '1'),
        ('NSQuitAlwaysKeepsWindows', '0'),
        ('QuitWhenAllWindowsClosed', '0'),
        ('SUEnableAutomaticChecks', '0'),
        ('SUAutomaticallyUpdate', '0'),
      ]) ...['-$k', v],
    ], environment: cleanEnv());
    if (r.exitCode != 0) throw StateError('open iTerm2: ${r.stderr}');
    final pid = await until('iTerm2 started', () async {
      final now = (await running()).difference(before);
      return now.isEmpty ? null : now.first;
    });
    owned.pid(pid, 'iterm');
    await open(cwd);
  }

  /// A new window, as the person's ⌘N would make it, whose shell starts in
  /// [cwd] (a script of its own: iTerm2 splits a command line itself).
  @override
  Future<void> open(String cwd) async {
    final script = File(p.join(c.work, 'iterm-${DateTime.now().microsecondsSinceEpoch}.sh'))
      ..writeAsStringSync("cd -- '${cwd.replaceAll("'", r"'\''")}'\nexec /bin/zsh -l\n");
    const newWindow = '''
on run argv
  tell application id "com.googlecode.iterm2" to create window with default profile command (item 1 of argv)
end run''';
    final r = await Process.run('/usr/bin/osascript', [
      '-e',
      newWindow,
      '/bin/sh ${script.path}',
    ], environment: cleanEnv());
    if (r.exitCode != 0) throw StateError('iTerm2 window: ${r.stderr}');
  }
}

/// The run's own tmux server (on [E2eConfig.tmuxSocket], where the desktop
/// app's TMUX_TMPDIR points), started with the throwaway home so its panes
/// run the throwaway shell.
Future<void> startTmux(E2eConfig c, Owned owned) async {
  final dir = Directory(p.dirname(c.tmuxSocket))..createSync(recursive: true);
  Process.runSync('/bin/chmod', ['700', dir.path]);
  final r = await Process.run(
    '/opt/homebrew/bin/tmux',
    ['-S', c.tmuxSocket, '-f', '/dev/null', 'start-server', ';', 'set-option', '-g', 'exit-empty', 'off'],
    environment: c.terminalEnv(),
    includeParentEnvironment: false,
  );
  if (r.exitCode != 0) throw StateError('tmux: ${r.stderr}');
  owned.tmux(c.tmuxSocket);
}
