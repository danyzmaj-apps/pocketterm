import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_core/file_types.dart';
import 'package:pocketterm_core/terminal_remote.dart';

/// The files phones send with prompts, as the agent gets them: each prompt's
/// in a folder of its own under [dir] (by default `pocketterm-files` in the
/// user's temp folder, `$TMPDIR` on a Mac), under the name it had on the
/// phone, made safe ([safeFileName]). The prompt names them as `@path`
/// ([withMentions]), as one would at the computer. Folders older than a day
/// go when more come and when PocketTerm starts.
class PromptFiles {
  PromptFiles([Directory? dir]) : dir = dir ?? Directory(p.join(Directory.systemTemp.path, 'pocketterm-files'));

  final Directory dir;

  static const keep = Duration(days: 1);

  /// Writes [files] into a new folder, none over another; their paths.
  Future<List<String>> save(List<PromptFile> files) async {
    if (files.isEmpty) return const [];
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
      // Private to this user; Windows' per-user temp folder already is.
      if (!Platform.isWindows) await Process.run('/bin/chmod', ['700', dir.path]);
    }
    await prune();
    final random = Random.secure();
    final folder = await Directory(
      p.join(dir.path, List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join()),
    ).create();
    return [for (final f in files) await _write(folder, safeFileName(f.name, mime: f.mime), f.bytes)];
  }

  /// [bytes] as [name] in [folder], or `name (2)`, `name (3)` … when that is taken.
  static Future<String> _write(Directory folder, String name, Uint8List bytes) async {
    final ext = p.extension(name);
    final stem = name.substring(0, name.length - ext.length);
    for (var n = 1; ; n++) {
      final file = File(p.join(folder.path, n == 1 ? name : '$stem ($n)$ext'));
      try {
        await file.create(exclusive: true);
      } on FileSystemException {
        if (file.existsSync()) continue;
        rethrow;
      }
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    }
  }

  /// Deletes the folders older than [keep].
  Future<void> prune() async {
    if (!dir.existsSync()) return;
    final before = DateTime.now().subtract(keep);
    await for (final e in dir.list()) {
      try {
        if (e is Directory && e.statSync().modified.isBefore(before)) await e.delete(recursive: true);
      } on FileSystemException catch (err) {
        debugPrint('PocketTerm: prompt files cleanup: $err');
      }
    }
  }
}

/// [name] as a file name that stays in its folder: only what follows its
/// last `/` or `\`, without control characters or the ones Windows refuses
/// (`<>:"|?*`), spaces and dots at its end (so never `.` or `..`) or a
/// Windows device name; at most 120 characters, its extension kept. Without
/// an extension it gets the one [mime] has. `file` when nothing is left.
@visibleForTesting
String safeFileName(String name, {String mime = ''}) {
  var n = name.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '').trim();
  n = n.replaceFirst(RegExp(r'[. ]+$'), '');
  if (n.isEmpty) n = 'file';
  if (fileExtension(n).isEmpty) {
    if (mimeExtension(mime) case final ext?) n = '$n.$ext';
  }
  if (RegExp(r'^(con|prn|aux|nul|com\d|lpt\d)(\..*)?$', caseSensitive: false).hasMatch(n)) n = '_$n';
  if (n.length > 120) {
    final ext = p.extension(n);
    n = ext.length < 20 ? '${n.substring(0, 120 - ext.length).trimRight()}$ext' : n.substring(0, 120);
  }
  return n;
}

/// [path] as omp and Claude Code take a file named in a prompt: `@path`,
/// or `@"path"` when it holds a character that would end the mention (a
/// space, a quote) or a trailing one they'd take for punctuation.
@visibleForTesting
String fileMention(String path) => RegExp(r'^[\w./+~,=%-]*[\w/+~=%-]$').hasMatch(path) ? '@$path' : '@"$path"';

/// [text] with a mention ([fileMention]) of each of [paths] after it.
String withMentions(String text, List<String> paths) {
  if (paths.isEmpty) return text;
  return [text.trim(), paths.map(fileMention).join(' ')].where((s) => s.isNotEmpty).join('\n\n');
}
