import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/channel_keys.dart';
import 'package:pocketterm_desktop/commands.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/desktop_host.dart';
import 'package:pocketterm_desktop/hosting/tailscale.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An [AppController] signed in as [fakeUser], its computer's side [host].
/// With `real`, its server and sign-in are Session's own (a real server,
/// say the built-in one), not [fakeBackend] and [fakeUser].
class FakeApp extends AppController {
  FakeApp._(
    SharedPreferences prefs,
    this._givenTerminals,
    Integrations integrations, {
    required this.real,
    Tailscale? tailscale,
    Directory? serverDir,
    Commands? commands,
    SecretStore? secrets,
  }) : super(
         prefs,
         'Mac',
         FakeDesktopHost(),
         integrations: integrations,
         secrets: secrets ?? MemorySecrets(),
         tailscale: tailscale ?? FakeTailscale().tailscale,
         serverDir: () async => serverDir ?? Directory('/nonexistent-pocketterm-test/server'),
         commands: commands ?? FakeCommands().commands,
       );

  /// [terminals] stand in for the computer's; none found by default.
  /// [prefs]: what this computer had saved. [integrations]: the coding
  /// agents', in a home of their own; by default no agent is found.
  /// [tailscale] and [serverDir]: the built-in server's (not installed, and
  /// nowhere, by default). [commands]: what installs run (no Homebrew by
  /// default). [secrets]: the Keychain's stand-in, in memory by default.
  static Future<FakeApp> create({
    Terminals? terminals,
    Map<String, Object> prefs = const {},
    Integrations? integrations,
    Tailscale? tailscale,
    Directory? serverDir,
    Commands? commands,
    SecretStore? secrets,
    bool real = false,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    return FakeApp._(
      await SharedPreferences.getInstance(),
      terminals,
      integrations ?? noAgents('/nonexistent-pocketterm-test'),
      real: real,
      tailscale: tailscale,
      serverDir: serverDir,
      commands: commands,
      secrets: secrets,
    );
  }

  /// The server and sign-in are Session's own.
  final bool real;

  /// How far a phone's clock is off, as the terminal bridge would say.
  @override
  Duration? phoneClockOff;

  /// Integrations in [home] with neither omp nor `claude` around.
  static Integrations noAgents(String home) => Integrations(
    home: home,
    run: (_, _) async => ProcessResult(0, 1, '', ''),
    claudePaths: const [],
    ompPaths: const [],
  );

  /// Whether a phone has signed in to the server (the server's answer to
  /// [phoneCodeUsed]).
  bool phoneUsedCode = false;

  @override
  Future<bool> phoneCodeUsed() async => phoneUsedCode;

  /// Codes the pairing QR made.
  int pairingLinks = 0;

  @override
  Future<Uri> pairingLink() async => real
      ? await super.pairingLink()
      : backend!.linkWithCode('PAIR-${++pairingLinks}AAA-BBBB-CCCC-DDDD-EEEE-FFFF', computer: await pairingComputer());

  /// Who the server says is signed in, unless [real].
  List<Device> devices = const [];

  @override
  Future<List<Device>> serverDevices() async => real ? await super.serverDevices() : devices;

  /// The devices signed out from Settings, unless [real].
  final revoked = <String>[];

  @override
  Future<void> revokeServerDevice(String id) async {
    if (real) return await super.revokeServerDevice(id);
    revoked.add(id);
    devices = [
      for (final d in devices)
        if (d.id != id) d,
    ];
  }

  /// What went to the server's push, in order: the action and its body.
  final pushes = <Map<String, Object>>[];

  @override
  Future<Map<String, dynamic>> invokePush(String action, Map<String, Object> body) async {
    pushes.add({'action': action, ...body});
    return {'sent': 1};
  }

  @override
  FakeDesktopHost get host => super.host as FakeDesktopHost;

  /// The signed-in user's name; Session's own when null.
  String? name;

  @override
  String get userName => name ?? super.userName;

  /// Who is signed in; null signs out.
  Account? fakeUser = const Account(
    id: 'server-1',
    device: Device(id: 'device-1', role: DeviceRole.desktop, label: 'Mac', platform: 'macos'),
  );

  /// What runs when [fakeUser] signs in (or is restored at launch).
  Future<void> signedIn() => onSignedIn(fakeUser!);

  /// Without a server there's no bridge to start: Terminal from phone is
  /// only its setting.
  @override
  Future<void> setTerminal({required bool on}) async {
    await (await SharedPreferences.getInstance()).setBool('terminal_bridge', on);
    notifyListeners();
  }

  /// The server this computer is set up with; null: none yet.
  Backend? fakeBackend = const Backend(url: 'https://pt.example.com');

  @override
  Backend? get backend => real ? super.backend : fakeBackend;

  @override
  Account? get user => real ? super.user : fakeUser;

  /// The server this computer talks to, when a test gives one.
  Server? fakeServer;

  @override
  Server? get server => fakeServer ?? super.server;

  /// When set, setup links go here instead of signing in.
  Future<void> Function(Uri link)? onConnectLink;

  @override
  Future<void> connectLink(Uri uri, {bool scanned = false}) =>
      onConnectLink?.call(uri) ?? super.connectLink(uri, scanned: scanned);

  /// Unless given: no terminal here, no kitty sockets, no tmux, no apps to script.
  @override
  Terminals get terminals => _givenTerminals ?? _terminals;
  final Terminals? _givenTerminals;
  late final _terminals = Terminals(
    home: '/nonexistent-pocketterm-test',
    // A fixed uid: looking up getuid would fail on Windows, where these tests run too.
    kitty: Kitty(socketDir: '/nonexistent-pocketterm-test', home: '/nonexistent-pocketterm-test', uid: 501),
    tmux: Tmux(executable: '/nonexistent-pocketterm-test/tmux', socketDirs: const []),
    wezterm: WezTerm(executable: '/nonexistent-pocketterm-test/wezterm', socketDir: '/nonexistent-pocketterm-test'),
    ghostty: Ghostty(appPath: '/nonexistent-pocketterm-test/Ghostty.app'),
    recency: () async => const [],
    snapshot: () async => Procs(const []),
  );
}

/// Secrets kept in memory, as the Keychain would keep them; while [locked],
/// writes fail as a locked Keychain's do.
class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  bool locked = false;

  @override
  Future<String?> read(String name) async => values[name];

  @override
  Future<void> write(String name, String value) async {
    if (locked) throw PlatformException(code: 'Unexpected security result code', message: 'Code: -25308');
    values[name] = value;
  }

  @override
  Future<void> delete(String name) async => values.remove(name);
}

/// The computer's side, recording what it was asked in [calls].
class FakeDesktopHost implements DesktopHost {
  final calls = <String>[];

  /// What [idleSeconds] answers.
  int idle = 0;

  /// Whether PocketTerm is a login item.
  bool loginItem = false;

  /// Makes [setLaunchAtLogin] fail with this.
  String? loginItemRefused;

  /// What [pickFolders] answers.
  List<String> folders = const [];

  /// What [start] was given.
  FutureOr<void> Function(String event)? onEvent;

  @override
  Future<void> start({required FutureOr<void> Function(String event) onEvent}) async {
    calls.add('start');
    this.onEvent = onEvent;
  }

  @override
  Future<void> showMain() async => calls.add('showMain');

  @override
  Future<void> hideMain() async => calls.add('hideMain');

  @override
  Future<void> quit() async => calls.add('quit');

  @override
  Future<String> deviceName() async {
    calls.add('deviceName');
    return 'Mac';
  }

  @override
  Future<int> idleSeconds() async {
    calls.add('idleSeconds');
    return idle;
  }

  @override
  Future<bool> launchAtLogin() async {
    calls.add('launchAtLogin');
    return loginItem;
  }

  @override
  Future<void> setLaunchAtLogin({required bool on}) async {
    calls.add('setLaunchAtLogin($on)');
    if (loginItemRefused case final reason?) throw PlatformException(code: 'launch_at_login', message: reason);
    loginItem = on;
  }

  @override
  Future<List<String>> pickFolders() async {
    calls.add('pickFolders');
    return folders;
  }

  @override
  Future<void> setKeepAwake({required bool on}) async => calls.add('setKeepAwake($on)');

  @override
  Future<void> startDrag() async => calls.add('startDrag');

  @override
  Future<void> setAppIcon(String icon) async => calls.add('setAppIcon($icon)');
}

/// A `claude` that answers from [list] (its `plugin list --json`) and records
/// what it's asked; [fail] makes that command fail as `--json` reports it,
/// [modsOff] has its `plugin test` refuse as with mods switched off.
class FakeClaude {
  FakeClaude(this.path);
  final String path;
  String version = '2.1.296 (Claude Code)';
  List<Map<String, Object?>> list = [];
  String? fail;
  bool modsOff = false;

  /// What a login shell's `command -v claude` prints; null: nothing found.
  String? onPath;
  final calls = <String>[];

  Future<ProcessResult> run(String exe, List<String> args) async {
    if (exe == '/bin/zsh') {
      return ProcessResult(0, onPath == null ? 1 : 0, onPath ?? '', '');
    }
    expect(exe, path);
    final call = args.join(' ');
    calls.add(call);
    if (call == fail) {
      return ProcessResult(0, 1, '{"outcome":"failed","message":"Plugin \\"pocketterm\\" not found"}\n', '✘ Failed');
    }
    if (call == '--version') return ProcessResult(0, 0, '$version\n', '');
    if (args.take(2).join(' ') == 'plugin test' && modsOff) {
      return ProcessResult(
        0,
        1,
        '',
        'claude plugin test: hooks modules are turned off in this process: the rollout switch was saved off '
            'by an earlier session and is not refreshed yet.\n',
      );
    }
    if (call == 'plugin list --json') return ProcessResult(0, 0, jsonEncode(list), '');
    return ProcessResult(0, 0, '{"outcome":"ok"}\n', '');
  }
}

/// Tailscale's CLI as a test sets it up, recording every command in [calls]
/// (without the CLI's path). Not installed by default.
class FakeTailscale {
  FakeTailscale({
    this.installed = false,
    this.daemon = true,
    this.backendState = 'Running',
    this.dnsName = 'mac.tail1234.ts.net',
    this.https = true,
  });

  bool installed;

  /// The Tailscale service runs (else the CLI can't reach it).
  bool daemon;
  String backendState;
  String dnsName;

  /// HTTPS certificates (and Serve) are on for the tailnet.
  bool https;

  static const enableLink = 'https://login.tailscale.com/f/serve?node=nTEST123';

  /// What `tailscale serve status --json` prints: what Serve publishes now.
  /// `serve --bg` sets it, `serve --https=443 off` clears it.
  Map<String, Object?> serveConfig = {};

  /// Serve publishing [proxy] on 443, as `tailscale serve --bg <proxy>` leaves it.
  void serving(String proxy) => serveConfig = {
    'TCP': {
      '443': {'HTTPS': true},
    },
    'Web': {
      '$dnsName:443': {
        'Handlers': {
          '/': {'Proxy': proxy},
        },
      },
    },
  };

  final calls = <String>[];

  /// `tailscale serve status` fails (exits non-zero) while set.
  bool statusFails = false;

  /// `tailscale serve --bg` waits for this before it publishes, when set.
  Completer<void>? serveGate;

  /// `serve` processes still running (one that asks for HTTPS waits until killed).
  final running = <FakeProcess>[];

  late final tailscale = Tailscale(start: _start, locate: () => installed ? '/fake/bin/tailscale' : null);

  Future<Process> _start(String exe, List<String> args) async {
    calls.add(args.join(' '));
    if (args.firstOrNull == 'status') {
      if (!daemon) {
        return FakeProcess.done(1, err: 'failed to connect to local Tailscale service; is Tailscale running?\n');
      }
      return FakeProcess.done(
        0,
        out: jsonEncode({
          'BackendState': backendState,
          'Self': {
            'DNSName': '$dnsName.',
            'TailscaleIPs': ['100.101.102.103'],
          },
          'CertDomains': https ? [dnsName] : null,
        }),
      );
    }
    if (args.take(2).join(' ') == 'serve status') {
      if (statusFails) return FakeProcess.done(1, err: 'failed to connect to local Tailscale service\n');
      return FakeProcess.done(0, out: serveConfig.isEmpty ? 'null\n' : jsonEncode(serveConfig));
    }
    if (args.firstOrNull == 'serve' && args.last != 'off' && !https) {
      // What the CLI prints, then it waits for HTTPS to be turned on.
      final p = FakeProcess.waiting(
        out: 'Serve is not enabled on your tailnet.\nTo enable, visit:\n\n         $enableLink\n\n',
      );
      running.add(p);
      return p;
    }
    if (args.firstOrNull == 'serve' && args.last != 'off') {
      await serveGate?.future;
      serving(args.last);
      return FakeProcess.done(0, out: 'Available within your tailnet:\n\nhttps://$dnsName/\n|-- proxy ${args.last}\n');
    }
    if (args.firstOrNull == 'serve') serveConfig = {};
    return FakeProcess.done(0);
  }
}

/// A process that prints what it's given, then exits with its code, or
/// keeps running until killed.
class FakeProcess implements Process {
  FakeProcess.done(int code, {String out = '', String err = ''}) {
    _print(out, err);
    _end(code);
  }

  FakeProcess.waiting({String out = ''}) {
    _print(out, '');
  }

  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  void _print(String out, String err) {
    if (out.isNotEmpty) _out.add(utf8.encode(out));
    if (err.isNotEmpty) _err.add(utf8.encode(err));
  }

  void _end(int code) {
    unawaited(_out.close());
    unawaited(_err.close());
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    _end(-15);
    return true;
  }

  @override
  int get pid => 4242;

  @override
  IOSink get stdin => throw UnimplementedError();
}

/// Installs as a test sets them up: Homebrew at [brew] (none when null),
/// MacPorts at [macPorts], winget on a [windows] PC, each command recorded
/// in [calls] (with its environment in [envs]) and answered with [result];
/// it waits for [gate] when one is set.
class FakeCommands {
  FakeCommands({this.brew, this.macPorts, this.windows = false});

  String? brew;
  String? macPorts;
  final bool windows;
  CommandResult result = (code: 0, output: '');
  Completer<void>? gate;
  final calls = <String>[];
  final envs = <Map<String, String>>[];

  /// What sudo's password script said while each run that had one ran
  /// (it is deleted after).
  final askpass = <String>[];

  late final commands = Commands(
    brew: () => brew,
    macPorts: () => macPorts,
    windows: windows,
    run: (exe, args, env) async {
      calls.add([exe, ...args].join(' '));
      envs.add(env);
      if (env['SUDO_ASKPASS'] case final path?) askpass.add(File(path).readAsStringSync());
      await gate?.future;
      return result;
    },
  );
}

/// [child] as main.dart hosts a window: a [MaterialApp] with PocketTerm's theme and
/// a [Toaster].
Widget window(Widget child) => MaterialApp(
  theme: appTheme(C.t),
  home: Material(
    type: MaterialType.transparency,
    child: Toaster(child: child),
  ),
);
