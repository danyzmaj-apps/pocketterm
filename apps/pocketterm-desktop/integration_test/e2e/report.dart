import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:pocketterm_e2e/e2e.dart';

/// The run's scenarios as they pass and fail: a line each in
/// results.jsonl (bin/run.dart makes the table of them), a screenshot of
/// the app's own window for each failure.
class Report {
  Report(this.c);
  final E2eConfig c;

  /// Wraps the app: what [shot] captures (the app's window only, never the
  /// screen with the person's other windows).
  final GlobalKey shotKey = GlobalKey();

  final List<String> failures = [];

  void log(String line) => debugPrint('E2E $line');

  void _record(String scenario, {required bool ok, bool skip = false, String detail = ''}) {
    File(c.results)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${jsonEncode({'scenario': scenario, 'ok': ok, 'skip': skip, 'detail': detail, 'at': DateTime.now().toIso8601String()})}\n',
        mode: FileMode.append,
        flush: true,
      );
  }

  /// Runs scenario [name]; a failure is recorded with a screenshot and, if
  /// [critical] (the rest can't go on without it), thrown on. A run limited
  /// to some steps (`--desktop-only`) skips it unless it's one of them, or
  /// critical, or [needed] (the steps after it need it done).
  Future<bool> step(String name, Future<void> Function() body, {bool critical = false, bool needed = false}) async {
    if (!critical && !needed && !c.desktopRuns(name)) {
      skip(name, 'not in --desktop-only');
      return false;
    }
    log('▶ $name');
    try {
      await body();
      _record(name, ok: true);
      log('✓ $name');
      return true;
    } on Object catch (e, st) {
      failures.add(name);
      _record(name, ok: false, detail: '$e'.split('\n').first);
      log('✗ $name: $e\n$st');
      await shot('fail-$name');
      if (critical) rethrow;
      return false;
    }
  }

  void skip(String name, String why) {
    _record(name, ok: false, skip: true, detail: why);
    log('- $name: $why');
  }

  /// The app's window as a PNG in screenshots/.
  Future<void> shot(String name) async {
    try {
      final boundary = shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return;
      final safe = name.replaceAll(RegExp(r'[^\w.-]+'), '_');
      File(p.join(c.screenshots, '$safe.png'))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes.buffer.asUint8List());
    } on Object catch (e) {
      log('no screenshot for $name: $e');
    }
  }
}

/// A file-based hand-off with bin/run.dart: `<dir>/<name>.ready` (or
/// `.req`) out, `<name>.done` back with its answer.
Future<String> handOff(String dir, String name, {required String out, required Duration timeout}) async {
  final done = File(p.join(dir, '$name.done'));
  if (done.existsSync()) done.deleteSync();
  File(p.join(dir, '$name.$out'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(DateTime.now().toIso8601String());
  return await until(
    '$name done',
    () => done.existsSync() ? done.readAsStringSync().trim() : null,
    timeout: timeout,
    every: const Duration(seconds: 1),
  );
}
