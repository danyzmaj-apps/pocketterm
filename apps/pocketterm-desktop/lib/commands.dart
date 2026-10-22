import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// How a command went: its exit code (null when it was stopped) and what it
/// printed, both streams.
typedef CommandResult = ({int? code, String output});

/// Runs a program with its arguments in [environment]; tests hand in a fake.
typedef RunCommand = Future<CommandResult> Function(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
);

/// The installs the setup offers to run for the person (`brew install
/// tmux`, `brew install --cask tailscale-app`), each only after they
/// confirmed it (lib/onboarding/commands_view.dart), never on its own.
class Commands {
  Commands({RunCommand? run, String? Function()? brew}) : _run = run ?? _runProcess, _brew = brew ?? findBrew;

  final RunCommand _run;
  final String? Function() _brew;

  /// Homebrew's `brew`, when it's on this Mac; null elsewhere.
  String? get brew => _brew();

  /// Where Homebrew lives on Apple silicon and on Intel Macs.
  static String? findBrew({bool Function(String path)? exists}) {
    if (!Platform.isMacOS && exists == null) return null;
    final isFile = exists ?? (String path) => File(path).existsSync();
    for (final path in ['/opt/homebrew/bin/brew', '/usr/local/bin/brew']) {
      if (isFile(path)) return path;
    }
    return null;
  }

  /// Runs [argv] (`brew` first stands for [brew]). [password]: why macOS
  /// asks for the person's password, should the command need it (a
  /// package Homebrew installs with sudo): macOS's own dialog asks.
  Future<CommandResult> run(List<String> argv, {String? password}) {
    final exe = argv.first == 'brew' ? brew : argv.first;
    if (exe == null) return Future.value((code: 127, output: 'Homebrew isn’t installed.'));
    final env = {
      // A GUI app's PATH is short: Homebrew's own folder first.
      'PATH': [p.dirname(exe), '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':'),
      'HOMEBREW_NO_ENV_HINTS': '1',
      if (password != null) 'SUDO_ASKPASS': _askpass(password),
    };
    return _run(exe, argv.sublist(1), env);
  }

  /// A script sudo runs for the password (sudo -A, which Homebrew uses when
  /// SUDO_ASKPASS is set): macOS's dialog, saying [why].
  static String _askpass(String why) {
    final dir = Directory.systemTemp.createTempSync('pocketterm-askpass');
    final file = File(p.join(dir.path, 'askpass.sh'));
    final prompt = why.replaceAll(RegExp(r'''["'\\]'''), '');
    file.writeAsStringSync(
      '#!/bin/sh\n'
      'exec /usr/bin/osascript -e \'text returned of (display dialog "$prompt" default answer "" '
      'with hidden answer with title "PocketTerm" with icon caution)\'\n',
    );
    Process.runSync('/bin/chmod', ['700', file.path]);
    return file.path;
  }

  static Future<CommandResult> _runProcess(String exe, List<String> args, Map<String, String> env) async {
    final process = await Process.start(exe, args, environment: env);
    final out = StringBuffer();
    await Future.wait([
      process.stdout.transform(utf8.decoder).forEach(out.write),
      process.stderr.transform(utf8.decoder).forEach(out.write),
    ]);
    return (code: await process.exitCode, output: out.toString());
  }
}
