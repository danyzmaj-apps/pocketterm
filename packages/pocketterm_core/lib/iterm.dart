import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:pocketterm_core/ansi.dart';
import 'package:pocketterm_core/terminal.dart';

/// iTerm2, through its AppleScript dictionary (macOS asks once whether
/// PocketTerm may control iTerm2). Its sessions (a tab, or a split pane of
/// one) tell an id, a tty and a title; `write text` sends bytes as typed (not
/// as a paste); `contents` is a session's whole text, scrollback then
/// screen, plain. A new tab doesn't take the focus, a new window does.
/// Window keys: `iterm:<session UUID>`, the UUID that ends the
/// `ITERM_SESSION_ID` (`w0t1p0:<UUID>`) of what runs in it.
class ITerm2 extends TerminalHost {
  /// [appleScript]: the osascript runner; the terminals' shared one if null.
  ITerm2({this.appPath = '/Applications/iTerm.app', this._appleScript});

  final String appPath;
  final AppleScript? _appleScript;

  @override
  String get id => 'iterm';

  @override
  String get label => 'iTerm2';

  @override
  String? get appName => 'iTerm2';

  @override
  String? get bundleId => 'com.googlecode.iterm2';

  @override
  Set<TermCap> get caps => const {TermCap.read, TermCap.type, TermCap.line, TermCap.keys, TermCap.close};

  @override
  String get limits => 'iTerm2 shares its screen without colors.';

  @override
  bool owns(String key) => key.startsWith('iterm:');

  bool get installed => Directory(appPath).existsSync();
  bool _running(Procs procs) => procs.running('$appPath/Contents/MacOS/iTerm2');

  Future<String> _osa(String script, [List<String> args = const []]) => _appleScript != null
      ? _appleScript.run(label, bundleId!, script, args)
      : runAppleScript(label, bundleId!, script, args);

  String _session(String key) {
    final id = RegExp(r'^iterm:([0-9A-Fa-f-]{36})$').firstMatch(key)?[1];
    if (id == null) throw const TerminalException('That window is gone.');
    return id;
  }

  /// Runs [body] on the session of [key], with `s` set to it; what [body]
  /// returns, else empty. Every session's id comes in one Apple Event and is
  /// looked through here, outside the `tell` (inside it, each `item` and
  /// `count` goes to iTerm2 as an event of its own: seconds with a dozen
  /// sessions open); the session is then addressed by its window's id and
  /// its place there, and checked once more by its id. An iTerm2 that has
  /// quit isn't started again for a window it no longer has.
  Future<String> _on(String key, String body, [List<String> args = const []]) async {
    try {
      return await _osa(
        '''
on run argv
  if application id "com.googlecode.iterm2" is not running then error "iTerm2 isn't running." number -600
  tell application id "com.googlecode.iterm2"
    set wids to id of windows
    set ids to id of sessions of tabs of windows
  end tell
  set found to missing value
  repeat with wi from 1 to count of ids
    set tw to item wi of ids
    repeat with ti from 1 to count of tw
      set tt to item ti of tw
      repeat with si from 1 to count of tt
        if (item si of tt) is (item 1 of argv) then set found to {item wi of wids, ti, si}
      end repeat
    end repeat
  end repeat
  if found is missing value then error "That window is gone." number -1728
  tell application id "com.googlecode.iterm2"
    set s to session (item 3 of found) of tab (item 2 of found) of window id (item 1 of found)
    if (id of s) is not (item 1 of argv) then error "That window is gone." number -1728
$body
  end tell
  return ""
end run''',
        [_session(key), ...args],
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

  /// A session a record, ended by RS and a newline, its fields apart by US
  /// (a title may hold a tab or a line break): id, title (iTerm2's name for
  /// it, as its tab shows it), tab title, tty, focused; then
  /// `front<US>true|false`. Each property of every session comes in one
  /// Apple Event and the records are made outside the `tell` ([_on] says
  /// why); a window opened or closed between those events leaves them out
  /// of step, and they're read again.
  static const _list = '''
set sep to ASCII character 31
set eol to (ASCII character 30) & linefeed
repeat 3 times
  tell application id "com.googlecode.iterm2"
    set focusedId to ""
    try
      set focusedId to id of current session of current window
    end try
    set ids to id of sessions of tabs of windows
    set nms to name of sessions of tabs of windows
    set ttys to tty of sessions of tabs of windows
    set tts to title of tabs of windows
    set isFront to frontmost
  end tell
  try
    set out to ""
    repeat with wi from 1 to count of ids
      set wid to item wi of ids
      if (count of wid) is not (count of item wi of tts) then error "out of step"
      repeat with ti from 1 to count of wid
        set bid to item ti of wid
        set bnm to item ti of item wi of nms
        set bty to item ti of item wi of ttys
        if (count of bid) is not (count of bnm) or (count of bid) is not (count of bty) then error "out of step"
        repeat with si from 1 to count of bid
          set out to out & (item si of bid) & sep & (item si of bnm) & sep & (item ti of item wi of tts) & sep & (item si of bty) & sep & ((item si of bid) is focusedId) & eol
        end repeat
      end repeat
    end repeat
    if (count of ids) is (count of nms) and (count of ids) is (count of ttys) and (count of ids) is (count of tts) then
      return out & "front" & sep & isFront
    end if
  end try
end repeat
error "iTerm2's windows kept changing while they were read."''';

  @override
  Future<TermStatus> status(Procs procs) async {
    if (!installed) return TermStatus(id, label, TermState.missing);
    if (!_running(procs)) return TermStatus(id, label, TermState.idle, note: 'Not running');
    try {
      final n = (await windows(procs)).length;
      return TermStatus(id, label, TermState.ready, note: '$n window${n == 1 ? '' : 's'} · $limits');
    } on AutomationDenied catch (e) {
      return TermStatus(id, label, TermState.setup, note: e.message, fix: TermFix.automation);
    } on AutomationPending catch (e) {
      return TermStatus(id, label, TermState.setup, note: e.message);
    } on TerminalException catch (e) {
      return TermStatus(id, label, TermState.limited, note: e.message);
    }
  }

  /// Its sessions, with their foreground program and that program's folder;
  /// a title without the ` (program)` iTerm2 adds to it by default.
  @override
  Future<List<TermWindow>> windows(Procs procs) async {
    if (!_running(procs)) return const [];
    final all = parseITermList(await _osa(_list));
    final cwds = await Procs.cwds([
      for (final w in all)
        if (procs.foreground(w.tty) case final p?) p.pid,
    ]);
    return [
      for (final w in all)
        if (procs.foreground(w.tty) case final fg)
          TermWindow(
            key: w.key,
            title: fg == null ? w.title : itermTitle(w.title, fg.program),
            tab: fg == null ? w.tab : itermTitle(w.tab, fg.program),
            cwd: cwds[fg?.pid] ?? '',
            program: fg?.program ?? '',
            focused: w.focused,
            app: w.app,
            caps: w.caps,
            tty: w.tty,
          ),
    ];
  }

  /// The session's text: its screen (the last of its rows), or with
  /// [history] its scrollback too.
  @override
  Future<List<String>> lines(String key, {bool history = false}) async {
    final (all, rows) = await _text(key);
    return screenLines((history ? all : all.skip(max(0, all.length - rows))).join('\n'));
  }

  @override
  Future<String> plainScreen(String key) async {
    final (all, rows) = await _text(key);
    return all.skip(max(0, all.length - rows)).join('\n').trimRight();
  }

  /// [key]'s `contents` line by line (its scrollback, then its screen, every
  /// row of it), and how many rows its screen has. iTerm2 hands over the
  /// whole scrollback each time: there's no asking for part of it.
  Future<(List<String>, int)> _text(String key) async {
    final out = await _on(key, '            return ((rows of s) as text) & linefeed & (contents of s)');
    final [rows, ...all] = out.split('\n');
    if (all.isNotEmpty && all.last.isEmpty) all.removeLast();
    return (all, int.tryParse(rows) ?? all.length);
  }

  /// Its default colors and its 16 ANSI ones (the 240 above them are
  /// xterm's, as in iTerm2), from iTerm2's 16-bit channels.
  @override
  Future<Map<String, Object>> colors(String key) async {
    final out = await _on(key, '''
            set out to ""
            repeat with c in {foreground color of s, background color of s, ANSI black color of s, ANSI red color of s, ANSI green color of s, ANSI yellow color of s, ANSI blue color of s, ANSI magenta color of s, ANSI cyan color of s, ANSI white color of s, ANSI bright black color of s, ANSI bright red color of s, ANSI bright green color of s, ANSI bright yellow color of s, ANSI bright blue color of s, ANSI bright magenta color of s, ANSI bright cyan color of s, ANSI bright white color of s}
              set out to out & (item 1 of c) & "," & (item 2 of c) & "," & (item 3 of c) & linefeed
            end repeat
            return out''');
    return parseITermColors(out);
  }

  /// Through `write text` without its newline: bytes to the program as if
  /// typed.
  Future<void> _write(String key, String bytes) =>
      _on(key, '            tell s to write text (item 2 of argv) newline no', [bytes]);

  /// The most UTF-8 bytes of text one script types: its argument stays well
  /// within a command line's 1 MB.
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

  /// iTerm2 ends what runs in it without asking.
  @override
  Future<void> close(String key) => _on(key, '            close s');

  /// The id of the iTerm2 window PocketTerm opened (or used) last.
  String? _window;

  /// A new tab in [cwd] in the iTerm2 window PocketTerm opened last, or a new
  /// window if that one is gone (iTerm2 comes to the front for it, and the
  /// app that was in front gets it back), running the login shell, or
  /// [command] in place of it. An iTerm2 that wasn't running is started in
  /// the background, and the one window it opens with is used.
  ///
  /// iTerm2 splits a session's command into words itself, and gets quotes
  /// wrong, so the shell line runs from a script of its own that removes
  /// itself. A folder that's gone by then leaves the shell in the home
  /// folder: a session that ends at once has iTerm2 stop everything for a
  /// warning until someone clicks it away.
  @override
  Future<String> launch(String cwd, {List<String>? command}) async {
    if (!Directory(cwd).existsSync()) throw TerminalException('No such folder: $cwd');
    final fresh = !_running(await Procs.snapshot());
    final script = _launcher(cwd, command);
    final String out;
    try {
      out = await keepFront(() async {
        if (fresh) {
          await Process.run('/usr/bin/open', ['-g', '-a', appPath]);
          for (var i = 0; i < 40; i++) {
            try {
              if (parseITermList(await _osa(_list)).isNotEmpty) break;
            } on AutomationDenied {
              rethrow;
            } on AutomationPending {
              rethrow;
            } on TerminalException {
              // Still starting.
            }
            await Future<void>.delayed(const Duration(milliseconds: 125));
          }
        }
        return await _osa(
          '''
on run argv
  set sep to ASCII character 9
  tell application id "com.googlecode.iterm2"
    if (item 3 of argv) is "reuse" and (count of windows) is 1 then
      set w to first window
      if (count of tabs of w) is 1 and (count of sessions of first tab of w) is 1 then return ((id of w) as text) & sep & (id of first session of first tab of w) & sep & "reused"
    end if
    repeat with w in windows
      if ((id of w) as text) is (item 2 of argv) then
        tell w to set b to (create tab with default profile command (item 1 of argv))
        return ((id of w) as text) & sep & (id of current session of b) & sep
      end if
    end repeat
    set w to (create window with default profile command (item 1 of argv))
    return ((id of w) as text) & sep & (id of current session of w) & sep
  end tell
end run''',
          ['/bin/sh ${script.path}', _window ?? '', if (fresh && command == null) 'reuse' else ''],
        );
      }, app: bundleId);
    } on Object {
      if (script.existsSync()) script.deleteSync();
      rethrow;
    }
    final [window, session, how] = out.split('\t');
    _window = window;
    final key = 'iterm:$session';
    if (how == 'reused') {
      script.deleteSync();
      await type(key, ' cd -- ${shellQuote(cwd)} && clear\r');
    }
    return key;
  }

  /// The script a new session runs: into [cwd], then the login shell (or
  /// [command]) in place of it; it removes itself first.
  static File _launcher(String cwd, List<String>? command) {
    final dir = Directory.systemTemp.path;
    if (!RegExp(r'^[\w./-]+$').hasMatch(dir)) {
      throw TerminalException("iTerm2 can't start a script from $dir (TMPDIR).");
    }
    final id = Random.secure().nextInt(1 << 32).toRadixString(16);
    return File('$dir/pocketterm-iterm-$id.sh')
      ..createSync(exclusive: true)
      ..writeAsStringSync(
        'rm -f -- "\$0"\n'
        'cd -- ${shellQuote(cwd)}\n'
        'exec ${command == null ? r'"${SHELL:-/bin/zsh}" -l' : command.map(shellQuote).join(' ')}\n',
      );
  }
}

/// The listing script's output (see [ITerm2]) as windows, without their
/// program and folder ([ITerm2.windows] adds them).
List<TermWindow> parseITermList(String out) {
  final records = [for (final r in out.split('\x1e')) r.replaceFirst(RegExp(r'^(\r\n|\n|\r)'), '').trimRight()];
  final front = records.any((r) => r == 'front\x1ftrue');
  return [
    for (final r in records)
      if (r.split('\x1f') case [final id, final title, final tab, final tty, final focused]
          when RegExp(r'^[0-9A-Fa-f-]{36}$').hasMatch(id))
        TermWindow(
          key: 'iterm:$id',
          title: cleanTitle(title),
          tab: cleanTitle(tab),
          cwd: '',
          program: '',
          focused: front && focused == 'true',
          app: 'iterm',
          caps: const {TermCap.read, TermCap.type, TermCap.line, TermCap.keys, TermCap.close},
          tty: tty.replaceFirst('/dev/', ''),
        ),
  ];
}

/// [title] as iTerm2 shows it, without the ` (job)` it adds by default when
/// that's [program] (a login shell's `-zsh` too): what the program set.
String itermTitle(String title, String program) {
  if (program.isEmpty) return title;
  final m = RegExp(' \\(-?${RegExp.escape(program)}\\)\$').firstMatch(title);
  return m == null || m.start == 0 ? title : title.substring(0, m.start);
}

/// The colors script's output (a line `r,g,b` of 16-bit channels each:
/// foreground, background, the 16 ANSI colors) as `{fg, bg, palette}`;
/// what's missing or unreadable as xterm's.
Map<String, Object> parseITermColors(String out) {
  final rgb = [
    for (final line in out.split('\n'))
      if (RegExp(r'^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*$').firstMatch(line) case final m?)
        _channel(m[1]!) << 16 | _channel(m[2]!) << 8 | _channel(m[3]!),
  ];
  int xterm(int i) => TermColors.xterm(i).toARGB32() & 0xFFFFFF;
  return {
    'fg': rgb.isNotEmpty ? rgb[0] : 0xDDDDDD,
    'bg': rgb.length > 1 ? rgb[1] : 0x000000,
    'palette': [
      for (var i = 0; i < 256; i++)
        if (i < 16 && rgb.length > i + 2) rgb[i + 2] else xterm(i),
    ],
  };
}

/// A 16-bit color channel as 8 bits.
int _channel(String digits) => ((int.tryParse(digits) ?? 0).clamp(0, 65535) / 257).round();
