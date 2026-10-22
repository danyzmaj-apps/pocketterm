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
/// tmux`, `brew install --cask tailscale-app`, on Windows `winget install
/// Tailscale.Tailscale`), each only after they confirmed it
/// (lib/onboarding/commands_view.dart), never on its own.
class Commands {
  Commands({RunCommand? run, String? Function()? brew, String? Function()? macPorts, bool? windows})
    : _run = run ?? _runProcess,
      _brew = brew ?? findBrew,
      _macPorts = macPorts ?? findMacPorts,
      _windows = windows ?? Platform.isWindows;

  final RunCommand _run;
  final String? Function() _brew;
  final String? Function() _macPorts;
  final bool _windows;

  /// Homebrew's `brew`, when it's on this Mac; null elsewhere.
  String? get brew => _brew();

  /// MacPorts' `port`, when it's on this Mac; null elsewhere. Its installs
  /// need sudo in a terminal, so the setup only shows its line.
  String? get macPorts => _macPorts();

  /// Windows' package manager, which comes with Windows 10 and 11 (App
  /// Installer); null elsewhere. Whether it really runs shows when it does.
  String? get winget => _windows ? 'winget' : null;

  /// Where Homebrew lives on Apple silicon and on Intel Macs.
  static String? findBrew({bool Function(String path)? exists}) {
    if (!Platform.isMacOS && exists == null) return null;
    final isFile = exists ?? (String path) => File(path).existsSync();
    for (final path in ['/opt/homebrew/bin/brew', '/usr/local/bin/brew']) {
      if (isFile(path)) return path;
    }
    return null;
  }

  /// Where MacPorts puts `port`.
  static String? findMacPorts({bool Function(String path)? exists}) {
    if (!Platform.isMacOS && exists == null) return null;
    const path = '/opt/local/bin/port';
    return (exists ?? (String path) => File(path).existsSync())(path) ? path : null;
  }

  /// Runs [argv] (`brew` first stands for [brew]). [password]: why macOS
  /// asks for the person's password, should the command need it (a
  /// package Homebrew installs with sudo): macOS's own dialog asks. On
  /// Windows the command keeps this app's own environment.
  Future<CommandResult> run(List<String> argv, {String? password}) async {
    if (_windows) {
      try {
        return await _run(argv.first, argv.sublist(1), const {});
      } on ProcessException {
        if (argv.first != 'winget') rethrow;
        return (
          code: 127,
          output: 'winget isn’t on this PC (it comes with Windows’ App Installer, from the Microsoft Store).',
        );
      }
    }
    final exe = argv.first == 'brew' ? brew : argv.first;
    if (exe == null) return (code: 127, output: 'Homebrew isn’t installed.');
    // Deleted once the command is done.
    final askpass = password == null ? null : _askpass(password);
    final env = {
      // A GUI app's PATH is short: Homebrew's own folder first.
      'PATH': [p.dirname(exe), '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':'),
      'HOMEBREW_NO_ENV_HINTS': '1',
      if (askpass != null) 'SUDO_ASKPASS': askpass.path,
    };
    try {
      return await _run(exe, argv.sublist(1), env);
    } finally {
      try {
        askpass?.parent.deleteSync(recursive: true);
      } on FileSystemException {
        // Left in the temp folder.
      }
    }
  }

  /// A script sudo runs for the password (sudo -A, which Homebrew uses when
  /// SUDO_ASKPASS is set): macOS's dialog, saying [why]. In a folder of its
  /// own, which goes with it.
  static File _askpass(String why) {
    final dir = Directory.systemTemp.createTempSync('pocketterm-askpass');
    final file = File(p.join(dir.path, 'askpass.sh'));
    final prompt = why.replaceAll(RegExp(r'''["'\\]'''), '');
    file.writeAsStringSync(
      '#!/bin/sh\n'
      'exec /usr/bin/osascript -e \'text returned of (display dialog "$prompt" default answer "" '
      'with hidden answer with title "PocketTerm" with icon caution)\'\n',
    );
    Process.runSync('/bin/chmod', ['700', file.path]);
    return file;
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
