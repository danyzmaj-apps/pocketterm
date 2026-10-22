import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/channel_keys.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/desktop_host.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_e2e/e2e.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real app, with everything it keeps and reaches pointed at the run's
/// throwaway home: its terminals (kitty's socket folder, the run's tmux
/// server, WezTerm's sockets under the throwaway home), omp's extensions,
/// the pairing links it makes (kept for the phone's hand-off files).
class E2eApp extends AppController {
  E2eApp(
    this.e2e,
    SharedPreferences prefs,
    DesktopHost host, {
    required SecretStore secrets,
    required Integrations integrations,
  }) : super(
         prefs,
         'PocketTerm E2E ${e2e.terminal}',
         host,
         secrets: secrets,
         integrations: integrations,
         serverDir: () async => Directory(p.join(e2e.work, 'builtin-server')),
       );

  final E2eConfig e2e;

  @override
  Terminals get terminals => _terminals;
  late final Terminals _terminals = Terminals(
    home: e2e.home,
    kitty: Kitty(socketDir: e2e.kittyDir, home: e2e.home),
    tmux: Tmux(socketDirs: [p.dirname(e2e.tmuxSocket)]),
    wezterm: WezTerm(home: e2e.home),
    ghostty: Ghostty(),
  );

  /// Every pairing link made, newest last.
  final pairingLinks = <Uri>[];

  @override
  Future<Uri> pairingLink() async {
    final link = await super.pairingLink();
    pairingLinks.add(link);
    return link;
  }
}

/// The Mac's host, minus what would reach past the run: launch at login
/// stays off (it would register the debug build), keeping awake is a no-op,
/// the folder picker answers with the run's projects folder.
class E2eHost implements DesktopHost {
  E2eHost(this.e2e);
  final E2eConfig e2e;
  final _mac = MacHost();
  bool _launchAtLogin = false;

  @override
  Future<void> start({required FutureOr<void> Function(String event) onEvent}) => _mac.start(onEvent: onEvent);

  @override
  Future<void> showMain() => _mac.showMain();

  @override
  Future<void> hideMain() => _mac.hideMain();

  @override
  Future<void> quit() async {}

  @override
  Future<String> deviceName() async => 'PocketTerm E2E ${e2e.terminal}';

  @override
  Future<int> idleSeconds() => _mac.idleSeconds();

  @override
  Future<bool> launchAtLogin() async => _launchAtLogin;

  @override
  Future<void> setLaunchAtLogin({required bool on}) async => _launchAtLogin = on;

  @override
  Future<List<String>> pickFolders() async => [e2e.projects];

  @override
  Future<void> setKeepAwake({required bool on}) async {}

  @override
  Future<void> startDrag() => _mac.startDrag();
}

/// The keychain, in memory: the owner's PocketTerm items stay untouched. One
/// store lives through the run, so a restarted app finds its sign-in.
class MemorySecrets implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String name) async => values[name];

  @override
  Future<void> write(String name, String value) async => values[name] = value;

  @override
  Future<void> delete(String name) async => values.remove(name);
}

/// What [Integrations] may run: the login shell's `command -v omp` answers
/// with the run's fake omp, and Claude Code is never found (installing its
/// plugin would change the owner's Claude Code settings). Anything else is
/// refused and remembered.
class GuardedRun {
  GuardedRun(this.e2e);
  final E2eConfig e2e;
  final refused = <String>[];

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    if (executable == '/bin/zsh' && arguments.length == 2 && arguments.first == '-lc') {
      if (arguments.last == 'command -v omp') return ProcessResult(0, 0, p.join(e2e.bin, 'omp'), '');
      return ProcessResult(0, 1, '', '');
    }
    refused.add('$executable ${arguments.join(' ')}');
    return ProcessResult(0, 1, '', 'refused by the e2e run');
  }
}
