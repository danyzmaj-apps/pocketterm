import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocketterm_core/terminal.dart';

/// Who sets the command Ghostty's new windows run.
enum GhosttyCommandState {
  /// Nobody: they run the login shell.
  none,

  /// PocketTerm's lines ([GhosttyConfig.add]): a tmux session each.
  ours,

  /// A `command =` line of the person's own, which PocketTerm leaves alone.
  theirs,
}

typedef GhosttyCommand = ({GhosttyCommandState state, String command});

/// Ghostty's config files, for the one setting PocketTerm offers there: new
/// windows (and tabs) opening in tmux, each in a session of its own that
/// ends with its window. Ghostty loads every file of [files] that exists, in
/// that order; PocketTerm writes to the first that exists (else the first),
/// two marked lines and nothing else, and [remove] takes exactly those out.
class GhosttyConfig {
  GhosttyConfig(this.files);

  /// The files Ghostty 1.3 reads on a Mac, in its order: `~/.config`'s,
  /// then Application Support's. (`XDG_CONFIG_HOME` is left out: apps
  /// started from the Dock don't get it.)
  factory GhosttyConfig.standard({required String home}) {
    final base = p.join(home, '.config', 'ghostty');
    final support = p.join(home, 'Library', 'Application Support', 'com.mitchellh.ghostty');
    return GhosttyConfig([
      p.join(base, 'config.ghostty'),
      p.join(base, 'config'),
      p.join(support, 'config.ghostty'),
      p.join(support, 'config'),
    ]);
  }

  final List<String> files;

  static const marker =
      '# Added by PocketTerm: new windows open in tmux. Remove with Settings \u2192 Terminals \u2192 Remove.';

  /// The line for [tmux] (an absolute path: Ghostty may not have Homebrew on
  /// its PATH). Ghostty runs it through `/bin/sh -c`; every window gets a new
  /// session (none shared, so windows don't mirror each other), which ends
  /// when its window closes rather than pile up detached, and titles its
  /// window with its pane's title and its own name (`~ (tmux 3)`), which
  /// ties the window to its session (Terminals.tieGhostty).
  static String line(String tmux) =>
      'command = ${_word(tmux)} new-session \\; set-option destroy-unattached on'
      r" \; set-option set-titles on \; set-option set-titles-string '#T (tmux #S)'";

  static String _word(String s) => RegExp(r'^[A-Za-z0-9_./+-]+$').hasMatch(s) ? s : shellQuote(s);

  /// A `command =` line's value (quotes off), or null for any other line
  /// and for an empty one (which puts the default back).
  static String? _command(String line) {
    final m = RegExp(r'^\s*command\s*=(.*)$').firstMatch(line);
    if (m == null) return null;
    var v = m[1]!.trim();
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) v = v.substring(1, v.length - 1);
    return v.isEmpty ? null : v;
  }

  static bool _isMarker(String line) => line.trimRight() == marker;

  String? _text(String path) {
    try {
      return File(path).readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  /// What the files say now (read each time: edits by hand count). Ours
  /// when PocketTerm's lines are anywhere; else the person's own command,
  /// the last one Ghostty would read.
  GhosttyCommand read() {
    String? ours;
    String? theirs;
    for (final path in files) {
      final lines = _text(path)?.split('\n');
      if (lines == null) continue;
      for (final (i, l) in lines.indexed) {
        final v = _command(l);
        if (v == null) continue;
        if (i > 0 && _isMarker(lines[i - 1])) {
          ours ??= v;
        } else {
          theirs = v;
        }
      }
    }
    if (ours != null) return (state: GhosttyCommandState.ours, command: ours);
    if (theirs != null) return (state: GhosttyCommandState.theirs, command: theirs);
    return (state: GhosttyCommandState.none, command: '');
  }

  /// PocketTerm's lines for [tmux], at the end of the first file that exists
  /// (made, with its folders, when none does); nothing when a command is
  /// already set. The file written.
  String? add(String tmux) {
    if (read().state != GhosttyCommandState.none) return null;
    final path = files.firstWhere((f) => File(f).existsSync(), orElse: () => files.first);
    final target = File(path).existsSync() ? File(path).resolveSymbolicLinksSync() : path;
    final text = _text(target) ?? '';
    final block = '$marker\n${line(tmux)}';
    _write(target, text.isEmpty || text.endsWith('\n') ? '$text$block\n' : '$text\n$block');
    return target;
  }

  /// PocketTerm's lines out of every file they're in; every other byte stays.
  void remove() {
    for (final path in files) {
      if (!File(path).existsSync()) continue;
      final target = File(path).resolveSymbolicLinksSync();
      final text = _text(target);
      if (text == null) continue;
      final out = _without(text);
      if (out != text) _write(target, out);
    }
  }

  /// [text] without each marker line and the `command =` line under it. As
  /// [add] puts them in: at the end of a file not ending in a newline, the
  /// newline before them is theirs too.
  static String _without(String text) {
    final out = StringBuffer();
    var at = 0;
    while (at < text.length) {
      final nl = text.indexOf('\n', at);
      final lineEnd = nl < 0 ? text.length : nl;
      if (_isMarker(text.substring(at, lineEnd)) && nl >= 0) {
        final next = text.indexOf('\n', nl + 1);
        final cmdEnd = next < 0 ? text.length : next;
        if (_command(text.substring(nl + 1, cmdEnd)) != null) {
          if (next < 0) {
            // The block ends the file without a newline: the one before it goes.
            final s = '$out';
            out
              ..clear()
              ..write(s.endsWith('\n') ? s.substring(0, s.length - 1) : s);
            at = text.length;
          } else {
            at = next + 1;
          }
          continue;
        }
      }
      out.write(text.substring(at, nl < 0 ? text.length : nl + 1));
      at = nl < 0 ? text.length : nl + 1;
    }
    return '$out';
  }

  /// [text] in place of [path]'s content all at once (a file beside it, then
  /// renamed over it), keeping its permissions.
  static void _write(String path, String text) {
    try {
      final file = File(path);
      final mode = file.existsSync() ? file.statSync().mode & 0x1ff : null;
      Directory(p.dirname(path)).createSync(recursive: true);
      final tmp = File('$path.pocketterm-tmp')..writeAsBytesSync(utf8.encode(text), flush: true);
      if (mode != null) Process.runSync('/bin/chmod', [mode.toRadixString(8), tmp.path]);
      tmp.renameSync(path);
    } on FileSystemException catch (e) {
      throw TerminalException('Couldn\u2019t change $path: ${e.osError?.message ?? e.message}');
    }
  }
}
