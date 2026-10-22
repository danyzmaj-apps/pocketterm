import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/terminal.dart';

/// Ghostty (1.3 and later), through its AppleScript dictionary (macOS asks
/// once whether PocketTerm may control Ghostty). Its terminals give an id, a
/// title and a folder; its `text:` action writes bytes to one as typed
/// (its `input text` would paste); new windows take a folder and a command
/// and stay behind. It has no tty to tell and no way to read a screen but
/// through the clipboard or a file it opens, so its windows can't be read;
/// the phone's sessions there run in tmux when it's installed. Window keys:
/// `ghostty:<terminal UUID>`.
class Ghostty extends TerminalHost {
  /// [appleScript]: the osascript runner; the terminals' shared one if null.
  Ghostty({this.appPath = '/Applications/Ghostty.app', this._appleScript});

  final String appPath;
  final AppleScript? _appleScript;

  @override
  String get id => 'ghostty';

  @override
  String get label => 'Ghostty';

  @override
  String? get appName => 'Ghostty';

  @override
  String? get bundleId => 'com.mitchellh.ghostty';

  @override
  Set<TermCap> get caps => const {TermCap.type, TermCap.line, TermCap.keys, TermCap.close};

  @override
  String get limits => "Ghostty can't share its screen.";

  @override
  bool owns(String key) => key.startsWith('ghostty:');

  bool get installed => Directory(appPath).existsSync();
  bool _running(Procs procs) => procs.running('$appPath/Contents/MacOS/');

  Future<String> _osa(String script, [List<String> args = const []]) => _appleScript != null
      ? _appleScript.run(label, bundleId!, script, args)
      : runAppleScript(label, bundleId!, script, args);

  String _terminal(String key) {
    final id = RegExp(r'^ghostty:([0-9A-Fa-f-]{36})$').firstMatch(key)?[1];
    if (id == null) throw const TerminalException('That window is gone.');
    return id;
  }

  /// Runs [body] on the terminal of [key], with `t` set to it. A Ghostty
  /// that has quit isn't started again for a window it no longer has.
  Future<String> _on(String key, String body, [List<String> args = const []]) async {
    try {
      return await _osa(
        '''
on run argv
  if application id "com.mitchellh.ghostty" is not running then error "Ghostty isn't running." number -600
  tell application "Ghostty"
    set t to first terminal whose id is (item 1 of argv)
$body
  end tell
  return ""
end run''',
        [_terminal(key), ...args],
      );
    } on AutomationDenied {
      rethrow;
    } on TerminalException catch (e) {
      if (e.message.contains('-1719') || e.message.contains('-1728') || e.message == "$label isn't running.") {
        throw const TerminalException('That window is gone.');
      }
      rethrow;
    }
  }

  /// A terminal a record, ended by RS and a newline, its fields apart by US:
  /// a title or a folder's name may hold a tab or a line break.
  static const _list = '''
set sep to ASCII character 31
set eol to (ASCII character 30) & linefeed
set out to ""
tell application "Ghostty"
  set focusedId to ""
  try
    set focusedId to id of focused terminal of selected tab of front window
  end try
  repeat with w in windows
    repeat with b in tabs of w
      repeat with t in terminals of b
        set out to out & (id of t) & sep & (name of t) & sep & (working directory of t) & sep & (name of b) & sep & ((id of t) is focusedId) & eol
      end repeat
    end repeat
  end repeat
  set out to out & "front" & sep & frontmost
end tell
return out''';

  @override
  Future<TermStatus> status(Procs procs) async {
    if (!installed) return TermStatus(id, label, TermState.missing);
    if (!_running(procs)) return TermStatus(id, label, TermState.idle, note: 'Not running');
    try {
      final n = (await windows(procs)).length;
      return TermStatus(id, label, TermState.limited, note: '$n window${n == 1 ? '' : 's'} · $limits');
    } on AutomationDenied catch (e) {
      return TermStatus(id, label, TermState.setup, note: e.message, fix: TermFix.automation);
    } on AutomationPending catch (e) {
      return TermStatus(id, label, TermState.setup, note: e.message);
    } on TerminalException catch (e) {
      // Before 1.3 Ghostty had no scripting.
      return TermStatus(id, label, TermState.limited, note: 'Needs Ghostty 1.3 or later (${e.message})');
    }
  }

  /// Its terminals; those whose tty is known ([launch], [learn]) with it
  /// and their foreground program, and that program's folder where Ghostty
  /// tells none (a window opened with a command, or before its shell's
  /// first prompt).
  @override
  Future<List<TermWindow>> windows(Procs procs) async {
    if (!_running(procs)) return const [];
    final all = parseGhosttyList(await _osa(_list));
    final listed = {for (final w in all) w.key};
    _ttys.removeWhere((key, _) => !listed.contains(key));
    final front = <String, Proc>{
      for (final w in all)
        if (_ttys[w.key] case final tty?) w.key: ?procs.foreground(tty),
    };
    final cwds = await Procs.cwds([
      for (final w in all)
        if (w.cwd.isEmpty) ?front[w.key]?.pid,
    ]);
    return [
      for (final w in all)
        if (_ttys[w.key] case final tty?)
          TermWindow(
            key: w.key,
            title: w.title,
            tab: w.tab,
            cwd: w.cwd.isNotEmpty ? w.cwd : cwds[front[w.key]?.pid] ?? '',
            program: front[w.key]?.program ?? '',
            focused: w.focused,
            app: w.app,
            caps: w.caps,
            tty: tty,
          )
        else
          w,
    ];
  }

  /// Through Ghostty's `text:` action: bytes to the program as if typed.
  Future<void> _write(String key, String bytes) =>
      _on(key, '    perform action (item 2 of argv) on t', ['text:${ghosttyText(bytes)}']);

  /// The most UTF-8 bytes of text one script types: its argument, four
  /// bytes per control character once escaped, stays well within a
  /// command line's 1 MB.
  static const typeBytes = 32000;

  /// In pieces of [typeBytes], a script each.
  @override
  Future<void> type(String key, String text) async {
    for (final chunk in textChunks(text, typeBytes)) {
      await _write(key, chunk);
    }
  }

  @override
  Future<void> pressKeys(String key, List<String> names) async {
    for (final (i, run) in keyRuns(names).indexed) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 40));
      await _write(key, run);
    }
  }

  /// Ghostty tells no tty, so the ones of windows PocketTerm opened (and of
  /// windows an agent named its tty in, or tied to their tmux client) are
  /// kept here: key → `ttys012`.
  final _ttys = <String, String>{};

  /// The ttys of Ghostty's terminals now ([ghosttySurfaceTtys]).
  Set<String> surfaceTtys(Procs procs) => ghosttySurfaceTtys(procs, procs.pidOf('$appPath/Contents/MacOS/'));

  /// [key]'s tty is [tty] (an agent there said so, or its tmux client runs there).
  void learn(String key, String tty) => _ttys[key] = tty.replaceFirst('/dev/', '');

  /// The window on [tty], when it's one whose tty is known.
  String? byTty(String tty) {
    final t = tty.replaceFirst('/dev/', '');
    return _ttys.entries.where((e) => e.value == t).firstOrNull?.key;
  }

  /// What runs on its tty ends first where the tty is known (Ghostty would
  /// ask on the Mac whether to close a window something runs in; with
  /// nothing left it closes it itself). Ghostty comes to the front when it
  /// closes a window while in the background (or starts, below): the app
  /// that was in front gets it back.
  @override
  Future<void> close(String key) => keepFront(() async {
    final tty = _ttys.remove(key);
    if (tty != null) {
      Future<List<int>> onTty() async => [
        for (final w in '${(await Process.run('/bin/ps', ['-t', tty, '-o', 'pid='])).stdout}'.split(RegExp(r'\s+')))
          ?int.tryParse(w),
      ];
      for (final pid in await onTty()) {
        Process.killPid(pid, ProcessSignal.sighup);
      }
      for (var i = 0; i < 20 && (await onTty()).isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    try {
      await _on(key, '    close t');
    } on TerminalException catch (e) {
      // Closed by itself once its shell ended.
      if (tty == null || e.message != 'That window is gone.') rethrow;
    }
  }, app: bundleId);

  /// The id of the Ghostty window PocketTerm opened last.
  String? _window;

  /// A new tab in [cwd] in the Ghostty window PocketTerm opened last, or a new
  /// window (it stays behind the app in front) if that one is gone, running
  /// the shell, or [command] in place of it. Ghostty comes to the front for
  /// a new window (the app that was in front gets it back), not for a tab.
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final before = surfaceTtys(await Procs.snapshot());
    final out = await keepFront(
      () => _osa(
        '''
on run argv
  set sep to ASCII character 9
  tell application "Ghostty"
    set cfg to new surface configuration
    set initial working directory of cfg to (item 1 of argv)
    if (item 2 of argv) is not "" then set command of cfg to (item 2 of argv)
    repeat with w in windows
      if (id of w) is (item 3 of argv) then
        set b to new tab in w with configuration cfg
        return (item 3 of argv) & sep & (id of focused terminal of b)
      end if
    end repeat
    set w to new window with configuration cfg
    return (id of w) & sep & (id of focused terminal of selected tab of w)
  end tell
end run''',
        [cwd, if (command != null) command.map(shellQuote).join(' ') else '', _window ?? ''],
      ),
      app: bundleId,
    );
    final [window, id] = out.split('\t');
    _window = window;
    final key = 'ghostty:$id';
    // Its tty: the one new among Ghostty's terminals (not known as another
    // window's) whose processes are in [cwd]; another window starting
    // meanwhile adds one too.
    for (var i = 0; i < 50; i++) {
      final procs = await Procs.snapshot();
      final added = surfaceTtys(procs).difference(before).difference(_ttys.values.toSet());
      final tty = added.isEmpty
          ? null
          : ghosttyNewTty(
              added,
              procs,
              await Procs.cwds(procs.all.where((p) => added.contains(p.tty)).map((p) => p.pid)),
              cwd,
            );
      if (tty != null) {
        _ttys[key] = tty;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return key;
  }

  /// The terminal in folder [cwd] an [agent] on [tty] runs in, when its tty
  /// isn't one known: the one terminal there (the same folder by another
  /// path, through a symlink, counts: a shell tells the path it was given,
  /// an agent the real one); else, of those not [claimed] by other sessions
  /// and not known to be on another tty, the one left, or the one whose
  /// title is the session's (what [agent] sets: its [title], or the folder's
  /// name while it has none). None there: the one whose title is the
  /// session's among those Ghostty tells no folder for (opened with a
  /// command, or before their shell's first prompt) and whose tty isn't
  /// known. More than one: null.
  Future<String?> byFolder(
    String cwd,
    Procs procs, {
    String tty = '',
    String title = '',
    Agent agent = Agent.omp,
    Set<String> claimed = const {},
  }) async {
    if (cwd.isEmpty) return null;
    final List<TermWindow> all;
    try {
      all = await windows(procs);
    } on TerminalException {
      return null;
    }
    final t = tty.replaceFirst('/dev/', '');
    final real = _realFolder(cwd);
    final here = [
      for (final w in all)
        if ((w.cwd == cwd || w.cwd == '/private$cwd' || w.cwd.isNotEmpty && _realFolder(w.cwd) == real) &&
            (w.tty.isEmpty || t.isEmpty || w.tty == t))
          w,
    ];
    if (here.length == 1) return here.single.key;
    final name = title.trim().isNotEmpty ? title.trim() : p.basename(cwd);
    bool named(TermWindow w) => !claimed.contains(w.key) && agent.sessionOfTitle(w.title) == name;
    if (here.isEmpty) {
      final folderless = all.where((w) => w.cwd.isEmpty && w.tty.isEmpty && named(w)).toList();
      return folderless.length == 1 ? folderless.single.key : null;
    }
    final open = here.where((w) => !claimed.contains(w.key)).toList();
    if (open.length == 1) return open.single.key;
    final titled = open.where(named).toList();
    return titled.length == 1 ? titled.single.key : null;
  }

  /// [path] with its symlinks resolved; as is when it can't be.
  static String _realFolder(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return path;
    }
  }
}

/// The ttys of the terminals of the Ghostty at pid [ghostty]: each one's
/// first process, a child of Ghostty, or (Ghostty 1.3 double-forks it) an
/// orphan whose parent is gone, which is Ghostty's `login -flp <user>` or
/// the command it ran as a login one (`-zsh`, `-/bin/sleep 9`). A process
/// whose parent is still there (another terminal's shell, a tmux pane) never
/// counts.
@visibleForTesting
Set<String> ghosttySurfaceTtys(Procs procs, int? ghostty) {
  if (ghostty == null) return const {};
  final alive = {for (final p in procs.all) p.pid};
  bool orphanRoot(Proc p) =>
      p.ppid > 1 && !alive.contains(p.ppid) && (p.args.startsWith('/usr/bin/login -f') || p.args.startsWith('-'));
  return {
    for (final p in procs.all)
      if (p.tty.isNotEmpty && (p.ppid == ghostty || orphanRoot(p))) p.tty,
  };
}

/// Of the new terminals' [ttys], the one a launch in [folder] made: the one
/// whose processes ([procs], with their working directories [cwds]) are in
/// [folder] (by its real path, as a process tells it); with no working
/// directory known (no lsof), the only one. Else null: none yet, or
/// another window starting meanwhile can't be told apart.
@visibleForTesting
String? ghosttyNewTty(Set<String> ttys, Procs procs, Map<int, String> cwds, String folder) {
  String real(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return path;
    }
  }

  final on = procs.all.where((p) => ttys.contains(p.tty)).toList();
  if (!on.any((p) => cwds.containsKey(p.pid))) return ttys.length == 1 ? ttys.single : null;
  final want = real(folder);
  final here = {
    for (final p in on)
      if (cwds[p.pid] case final cwd? when cwd == want || real(cwd) == want) p.tty,
  };
  return here.length == 1 ? here.single : null;
}

/// The listing script's output: a record per terminal (id, title, folder,
/// tab title, focused; apart by US, each ended by RS and a line break),
/// then `front<US>true|false`.
List<TermWindow> parseGhosttyList(String out) {
  final records = [for (final r in out.split('\x1e')) r.replaceFirst(RegExp(r'^(\r\n|\n|\r)'), '').trimRight()];
  final front = records.any((r) => r == 'front\x1ftrue');
  return [
    for (final r in records)
      if (r.split('\x1f') case [final id, final title, final cwd, final tab, final focused] when id != 'front')
        TermWindow(
          key: 'ghostty:$id',
          title: cleanTitle(title),
          tab: cleanTitle(tab),
          cwd: cwd,
          program: '',
          focused: front && focused == 'true',
          app: 'ghostty',
          caps: const {TermCap.type, TermCap.line, TermCap.keys, TermCap.close},
        ),
  ];
}

/// [bytes] as the argument of Ghostty's `text:` action, which reads it as
/// a Zig string literal's body: a backslash and a quote escaped, anything
/// below space (and DEL) as `\xNN`.
String ghosttyText(String bytes) {
  final out = StringBuffer();
  for (final c in bytes.runes) {
    if (c == 0x5c) {
      out.write(r'\\');
    } else if (c == 0x22) {
      out.write(r'\"');
    } else if (c < 0x20 || c == 0x7f) {
      out.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
    } else {
      out.writeCharCode(c);
    }
  }
  return '$out';
}
