import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/iterm.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/wezterm.dart';

/// [Terminals.tieGhostty]'s answer: Ghostty window key → the tty of the tmux
/// client it runs, and what was left that it couldn't tell apart.
typedef TieGhostty = ({Map<String, String> ttys, String untold});

/// Every terminal on this computer as one (lib/terminal.dart): their windows
/// merged (a terminal window showing tmux gives way to the tmux pane, which
/// can do more), each request routed to the window's own terminal, and new
/// windows opened where the person works. A host this platform lacks is
/// null (Windows has WezTerm only).
class Terminals {
  Terminals({
    required this.home,
    this.kitty,
    this.tmux,
    this.wezterm,
    this.iterm,
    this.ghostty,
    this.recency = appsByRecency,
    this.snapshot = Procs.snapshot,
  });

  /// The terminals of this computer: all five on a Mac (kitty's sockets in
  /// [kittyDir]), WezTerm alone on Windows ([windowsPath]: the PATH a new
  /// login has, for the WezTerm it starts; see WezTerm).
  factory Terminals.standard({String kittyDir = '/tmp', String? home, bool? windows, String Function()? windowsPath}) {
    final h = home ?? homeDir(windows: windows);
    if (windows ?? Platform.isWindows) {
      return Terminals(
        home: h,
        wezterm: WezTerm(home: h, windows: true, windowsPath: windowsPath),
      );
    }
    return Terminals(
      home: h,
      kitty: Kitty(socketDir: kittyDir, home: h),
      tmux: Tmux(),
      wezterm: WezTerm(home: h),
      iterm: ITerm2(),
      ghostty: Ghostty(),
    );
  }

  /// The home folder, which the phone shows as ~.
  final String home;
  final Kitty? kitty;
  final Tmux? tmux;
  final WezTerm? wezterm;
  final ITerm2? iterm;
  final Ghostty? ghostty;

  /// App names, most recently used first (`lsappinfo`); tests pass their own.
  final Future<List<String>> Function() recency;

  /// The computer's processes now (`ps`); tests pass their own.
  final Future<Procs> Function() snapshot;

  /// In the order their windows are listed.
  List<TerminalHost> get hosts => [?kitty, ?tmux, ?wezterm, ?iterm, ?ghostty];

  /// The terminal apps (tmux isn't one), in the order Auto prefers them
  /// when none was used lately.
  List<TerminalHost> get apps => [?kitty, ?wezterm, ?iterm, ?ghostty];

  /// Terminal windows PocketTerm opened to show a tmux session: their key → the
  /// pane's (Ghostty tells no tty to match them by).
  final _shows = <String, String>{};

  /// What each terminal said went wrong on the last [windows], by id.
  Map<String, String> problems = const {};

  TerminalHost? hostOf(String key) => hosts.where((h) => h.owns(key)).firstOrNull;

  TerminalHost _host(String key) => hostOf(key) ?? (throw const TerminalException('That window is gone.'));

  /// What window [key]'s terminal can do.
  Set<TermCap> capsOf(String key) => hostOf(key)?.caps ?? const {};

  bool can(String key, TermCap cap) => capsOf(key).contains(cap);

  /// Every window of every terminal. A terminal window attached to tmux is
  /// left out for its tmux pane, which names it as [TermWindow.via]; a
  /// Ghostty window, which tells no tty, once [tieGhostty] tells which
  /// tmux client it runs (its tty is then remembered).
  Future<List<TermWindow>> windows() async {
    final procs = await snapshot();
    final problems = <String, String>{};
    final lists = await Future.wait([
      for (final h in hosts)
        h.windows(procs).catchError((Object e) {
          problems[h.id] = e is TerminalException ? e.message : '$e';
          return const <TermWindow>[];
        }),
    ]);
    this.problems = problems;
    final clients = tmux?.clients ?? const <String, TmuxClient>{};
    final shows = {..._shows};
    if (ghostty case final ghostty? when clients.isNotEmpty) {
      final windows = lists[hosts.indexOf(ghostty)];
      if (windows.any((w) => w.tty.isEmpty)) {
        final tie = tieGhostty(
          windows: windows,
          clients: clients,
          surfaces: ghostty.surfaceTtys(procs),
          panes: lists[hosts.indexOf(tmux!)],
        );
        for (final MapEntry(key: window, value: tty) in tie.ttys.entries) {
          ghostty.learn(window, tty);
          shows[window] = clients[tty]!.pane;
        }
        if (tie.untold.isNotEmpty && _untold.add(tie.untold)) {
          debugPrint('PocketTerm: Ghostty windows in tmux not told apart, listed apart: ${tie.untold}');
        }
      }
    }
    return merge(hosts, lists, {for (final MapEntry(:key, :value) in clients.entries) key: value.pane}, shows);
  }

  /// What [tieGhostty] couldn't tell apart, as logged (once each).
  final _untold = <String>{};

  /// Which tmux client each of Ghostty's [windows] whose tty it doesn't
  /// tell runs (a window the person opened, its command tmux): of the
  /// [clients] on Ghostty's terminals ([surfaces]) not known as another
  /// window's, the one giving that window its title (tmux's `set-titles`,
  /// which PocketTerm's Ghostty line turns on, the session named in it);
  /// else, when every such terminal runs a client, the one whose pane
  /// ([panes]) is in the window's folder; else the one left when one window
  /// and one terminal are. Only a match that's the only one either way
  /// counts: `ttys`, window key → the client's tty. `untold`: the windows
  /// and clients left that might belong together (empty: none).
  static TieGhostty tieGhostty({
    required List<TermWindow> windows,
    required Map<String, TmuxClient> clients,
    required Set<String> surfaces,
    required List<TermWindow> panes,
  }) {
    final open = [
      for (final w in windows)
        if (w.tty.isEmpty) w,
    ];
    // Each window whose tty isn't known on one of these.
    final free = surfaces.difference({for (final w in windows) w.tty});
    final on = {
      for (final MapEntry(key: tty, value: c) in clients.entries)
        if (free.contains(tty)) tty: c,
    };
    final ttys = <String, String>{};
    void tieWhere(bool Function(TermWindow w, TmuxClient c) match) {
      for (final MapEntry(key: tty, value: c) in on.entries.toList()) {
        final ws = open.where((w) => match(w, c)).toList();
        if (ws.length != 1) continue;
        final w = ws.single;
        if (on.values.where((c) => match(w, c)).length != 1) continue;
        ttys[w.key] = tty;
        open.remove(w);
        free.remove(tty);
        on.remove(tty);
      }
    }

    tieWhere((w, c) => c.title.isNotEmpty && w.title == c.title);
    // A window running no tmux may be in any folder.
    if (on.length == free.length) {
      final cwds = {for (final pane in panes) pane.key: pane.cwd};
      tieWhere((w, c) => _sameFolder(w.cwd, cwds[c.pane] ?? ''));
    }
    if (open.length == 1 && free.length == 1 && on.containsKey(free.single)) {
      ttys[open.single.key] = free.single;
      open.clear();
      on.clear();
    }
    final untold = open.isEmpty || on.isEmpty
        ? ''
        : '${[for (final w in open) w.key].join(', ')} / ${[for (final tty in on.keys) tty].join(', ')}';
    return (ttys: ttys, untold: untold);
  }

  /// Whether [a] and [b] are one folder as a terminal and tmux tell it
  /// (`/private/tmp` is `/tmp`); never for an empty one.
  static bool _sameFolder(String a, String b) =>
      a.isNotEmpty && b.isNotEmpty && (a == b || '/private$a' == b || a == '/private$b');

  /// [lists] (one per host of [hosts]) as one list: a window whose tty is a
  /// tmux client's in [clients] (tty → pane key), or which [shows] a pane,
  /// gives way to that pane, which gets its app's label as `via`.
  static List<TermWindow> merge(
    List<TerminalHost> hosts,
    List<List<TermWindow>> lists,
    Map<String, String> clients,
    Map<String, String> shows,
  ) {
    final via = <String, String>{};
    final kept = <TermWindow>[];
    for (final (i, list) in lists.indexed) {
      final host = hosts[i];
      for (final w in list) {
        final pane = host.id == 'tmux' ? null : (shows[w.key] ?? (w.tty.isEmpty ? null : clients[w.tty]));
        if (pane != null) {
          via[pane] = host.label;
          continue;
        }
        kept.add(w);
      }
    }
    return [for (final w in kept) w.copyWith(via: via[w.key])];
  }

  /// How each installed terminal stands, for Settings and the phone. A
  /// limited terminal whose phone sessions run in tmux ([viaTmux]) is ready
  /// for those; its limit stays, for the windows opened in it directly.
  Future<List<TermStatus>> statuses() async {
    final procs = await snapshot();
    return await Future.wait([
      for (final h in hosts)
        h
            .status(procs)
            .then(
              (s) => s.state == TermState.limited && viaTmux(h)
                  ? TermStatus(
                      s.id,
                      s.label,
                      TermState.ready,
                      note:
                          '${s.note.replaceFirst(h.limits, '').trim()} Sessions from your phone run in tmux, '
                                  'with full control. In windows you open yourself: ${h.limits}'
                              .trim(),
                      fix: s.fix,
                    )
                  : s,
            )
            .catchError((Object e) => TermStatus(h.id, h.label, TermState.limited, note: '$e')),
    ]);
  }

  /// Where an agent runs, from the `term` its extension reports
  /// ([windowOfTerm]); for Ghostty, which tells nothing to match, the window
  /// PocketTerm opened on the agent's tty, else the Ghostty window in the
  /// agent's folder [cwd] its session ([title], [agent]) is in, of those not
  /// [claimed] by other sessions ([Ghostty.byFolder]; then its tty is
  /// remembered).
  Future<String?> locate(
    Map<String, dynamic>? term, {
    String cwd = '',
    String title = '',
    Agent agent = Agent.omp,
    Set<String> claimed = const {},
  }) async {
    if (term == null) return null;
    final socket = term['TMUX'];
    if (socket is String && socket.isNotEmpty) tmux?.learn(socket.split(',').first);
    final key = windowOfTerm(term);
    if (key != null) return key;
    final ghostty = this.ghostty;
    if (ghostty == null || term['TERM_PROGRAM'] != 'ghostty') return null;
    final tty = term['tty'] is String ? term['tty'] as String : '';
    final known = tty.isEmpty ? null : ghostty.byTty(tty);
    if (known != null) return known;
    final found = await ghostty.byFolder(cwd, await snapshot(), tty: tty, title: title, agent: agent, claimed: claimed);
    if (found != null && tty.isNotEmpty) ghostty.learn(found, tty);
    return found;
  }

  // ------------------------------------------------------------ requests

  Future<List<String>> lines(String key, {bool history = false}) => _host(key).lines(key, history: history);

  Future<String> plainScreen(String key) => _host(key).plainScreen(key);

  Future<Map<String, Object>?> colors(String key) => _host(key).colors(key);

  Future<void> send(String key, String text, {required bool enter}) => _host(key).send(key, text, enter: enter);

  Future<void> type(String key, String text) => _host(key).type(key, text);

  Future<void> pressKeys(String key, List<String> names) => _host(key).pressKeys(key, names);

  /// One of [phoneKeys] (what the phone may press).
  Future<void> press(String key, String name) async {
    if (!phoneKeys.contains(name)) throw TerminalException('Unknown key: $name');
    await pressKeys(key, [name]);
  }

  /// Closes window [key]; for a tmux pane a terminal window shows (one
  /// PocketTerm opened to show it, or a Ghostty window tied to its client),
  /// that window too keeping the focus where it is (Ghostty comes to the
  /// front as it closes it).
  Future<void> close(String key) async {
    final guis = {
      for (final MapEntry(key: gui, value: pane) in _shows.entries)
        if (pane == key) gui,
      for (final MapEntry(key: tty, value: c) in tmux?.clients.entries ?? const <MapEntry<String, TmuxClient>>[])
        if (c.pane == key) ?ghostty?.byTty(tty),
    }.toList();
    if (guis.isEmpty) return await _host(key).close(key);
    await keepFront(() async {
      await _host(key).close(key);
      for (final gui in guis) {
        _shows.remove(gui);
        try {
          await _host(gui).close(gui);
        } on TerminalException {
          // Already gone with its tmux (Ghostty closes it itself).
        }
      }
    }, app: hostOf(guis.first)?.bundleId);
  }

  // ------------------------------------------------------------ new windows

  /// The terminal app new windows open in: [choice] (an app's id) if it's
  /// installed; else (Auto) the running one used most recently; else the
  /// first installed of [apps].
  Future<TerminalHost> opensIn(String choice) async {
    final procs = await snapshot();
    final statuses = {
      for (final h in apps)
        h.id: await h.status(procs).catchError((Object _) => TermStatus(h.id, h.label, TermState.limited)),
    };
    return pickApp(apps, statuses, choice, await recency());
  }

  /// [opensIn]'s choice among [apps], given their [statuses] and the apps by
  /// [recency]: a chosen app that's installed; else the usable one used
  /// last; else the first usable one; else the first that can be started
  /// (kitty can't be: it must listen first).
  static TerminalHost pickApp(
    List<TerminalHost> apps,
    Map<String, TermStatus> statuses,
    String choice,
    List<String> recency,
  ) {
    final chosen = apps.where((h) => h.id == choice).firstOrNull;
    if (chosen != null && statuses[choice]?.state != TermState.missing) return chosen;
    for (final name in recency) {
      final h = apps.where((h) => h.appName == name).firstOrNull;
      if (h != null && (statuses[h.id]?.usable ?? false)) return h;
    }
    return apps.where((h) => statuses[h.id]?.usable ?? false).firstOrNull ??
        apps.where((h) => h.id != 'kitty' && statuses[h.id]?.state == TermState.idle).firstOrNull ??
        apps.last;
  }

  /// Whether a window [host] opens runs in tmux: the app can't press keys
  /// or show its screen, and tmux can.
  bool viaTmux(TerminalHost host) =>
      (tmux?.installed ?? false) && !(host.caps.contains(TermCap.keys) && host.caps.contains(TermCap.read));

  /// How the phone names where a new session opens: "kitty", "Ghostty (in tmux)".
  String describe(TerminalHost host) => viaTmux(host) ? '${host.label} (in tmux)' : host.label;

  /// A new window in [cwd] in [host] running the login shell, which then
  /// starts [agent] if given; its key (the tmux pane's, where [viaTmux]).
  Future<String> launch(String cwd, {required TerminalHost host, Agent? agent}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final String key;
    if (viaTmux(host)) {
      final tmux = this.tmux!;
      key = await tmux.launch(cwd);
      try {
        final gui = await host.launch(cwd, command: tmux.attach(tmux.lastSession!));
        _shows[gui] = key;
      } on Object {
        await tmux.close(key);
        rethrow;
      }
    } else {
      key = await host.launch(cwd);
    }
    // The shell reads it once it's up: the terminal holds what's typed.
    if (agent != null) await send(key, agent.command, enter: true);
    return key;
  }

  /// Git repositories up to three levels under [roots] (the Mac's Project
  /// folders setting), for the phone's New session list. A symlinked folder
  /// is followed (under the link's own path), each real folder once: a
  /// link loop, or two roots that are one folder, list nothing twice.
  Future<List<String>> projects(List<String> roots) async {
    // Each repository by its real folder: under that path when it's found there too, else the first link to it.
    final found = <String, String>{};
    // Each real folder walked, with how deep it was walked from there.
    final seen = <String, int>{};
    Future<void> walk(Directory dir, int depth) async {
      final String real;
      final List<FileSystemEntity> entries;
      try {
        real = await dir.resolveSymbolicLinks();
        if (dir.path == real && found.containsKey(real)) found[real] = real;
        if ((seen[real] ?? -1) >= depth) return;
        seen[real] = depth;
        entries = await dir.list(followLinks: false).toList();
      } on FileSystemException {
        return;
      }
      if (entries.any((e) => p.basename(e.path) == '.git')) {
        found[real] = dir.path == real ? real : found[real] ?? dir.path;
        return;
      }
      if (depth == 0) return;
      for (final e in entries) {
        final name = p.basename(e.path);
        if (name.startsWith('.') || name == 'node_modules') continue;
        if (e is Directory || (e is Link && FileSystemEntity.isDirectorySync(e.path))) {
          await walk(Directory(e.path), depth - 1);
        }
      }
    }

    for (final root in roots) {
      final dir = Directory(root.length > 1 && root.endsWith('/') ? root.substring(0, root.length - 1) : root);
      if (dir.existsSync()) await walk(dir, 3);
    }
    return found.values.toList()..sort();
  }

  /// A new project folder [name] under [root], which must be one of [roots]
  /// (the Mac's Project folders setting); its path. Only the folder is made.
  /// [windows]: also Windows' rules for names (the running platform's if null).
  String createProject(String root, String name, {required List<String> roots, bool? windows}) {
    if (!roots.contains(root)) throw TerminalException('Not one of your project folders: $root');
    final n = name.trim();
    if (n.isEmpty ||
        n.contains(RegExp(r'[/\\:]')) ||
        n.startsWith('.') ||
        n.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      throw const TerminalException(
        r'A project name can’t be empty, contain /, \, : or control characters, or start with a dot.',
      );
    }
    if ((windows ?? Platform.isWindows) && !windowsFileName(n)) {
      throw const TerminalException(
        'Windows doesn’t allow that name: no < > " | ? *, no dot at the end, '
        'and not a device name such as CON, NUL, COM1 or LPT1.',
      );
    }
    if (!Directory(root).existsSync()) throw TerminalException('No such folder: $root');
    final path = p.join(root, n);
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      throw TerminalException('There is already something named $n there.');
    }
    try {
      Directory(path).createSync();
    } on FileSystemException catch (e) {
      throw TerminalException('Couldn’t create $path: ${e.osError?.message ?? e.message}');
    }
    return path;
  }

  /// The phone's New project: [createProject], then a window in it as
  /// [launch]. Should no window open, the folder goes again (while still
  /// empty), so trying again with the same name works.
  Future<String> launchNewProject(
    String root,
    String name, {
    required List<String> roots,
    required TerminalHost host,
    Agent? agent,
  }) async {
    final cwd = createProject(root, name, roots: roots);
    try {
      return await launch(cwd, host: host, agent: agent);
    } on Object {
      try {
        Directory(cwd).deleteSync();
      } on FileSystemException {
        // Something was put in it meanwhile: it stays.
      }
      rethrow;
    }
  }
}
