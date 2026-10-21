import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/apple_terminal.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/ghostty.dart';
import 'package:pocketterm_core/iterm.dart';
import 'package:pocketterm_core/kitty.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/tmux.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/channel_keys.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/desktop_host.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

/// An [AppController] signed in as [fakeUser], its computer's side [host].
class FakeApp extends AppController {
  FakeApp._(SharedPreferences prefs, this._givenTerminals, Integrations integrations)
    : super(prefs, 'Mac', FakeDesktopHost(), integrations: integrations, secrets: MemorySecrets());

  /// [terminals] stand in for the computer's; none found by default.
  /// [prefs]: what this computer had saved. [integrations]: the coding
  /// agents', in a home of their own; by default no agent is found.
  static Future<FakeApp> create({
    Terminals? terminals,
    Map<String, Object> prefs = const {},
    Integrations? integrations,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    return FakeApp._(
      await SharedPreferences.getInstance(),
      terminals,
      integrations ?? noAgents('/nonexistent-pocketterm-test'),
    );
  }

  /// Integrations in [home] with neither omp nor `claude` around.
  static Integrations noAgents(String home) => Integrations(
    home: home,
    run: (_, _) async => ProcessResult(0, 1, '', ''),
    claudePaths: const [],
    ompPaths: const [],
  );

  /// Whether a phone has signed in with a code from here (the server's
  /// answer to [phoneCodeUsed]).
  bool phoneUsedCode = false;

  @override
  Future<bool> phoneCodeUsed() async => phoneUsedCode;

  /// Codes the pairing QR made.
  int pairingLinks = 0;

  @override
  Future<Uri> pairingLink() async =>
      backend!.linkWithCode('PAIR-${++pairingLinks}AAA-BBBB-CCCC-DDDD-EEEE-FFFF', computer: await pairingComputer());

  /// What went to functions/push, in order.
  final pushes = <Map<String, Object>>[];

  @override
  Future<Object?> invokePush(Map<String, Object> body) async {
    pushes.add(body);
    return {'sent': 1};
  }

  @override
  FakeDesktopHost get host => super.host as FakeDesktopHost;

  /// The signed-in user's name; Session's own when null.
  String? name;

  @override
  String get userName => name ?? super.userName;

  /// Who is signed in; null signs out.
  User? fakeUser = const User(
    id: 'user-1',
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-10-01T10:00:00Z',
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
  Backend? fakeBackend = const Backend(url: 'https://example.supabase.co', key: 'test');

  @override
  Backend? get backend => fakeBackend;

  @override
  User? get user => fakeUser;

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
    iterm: ITerm(appPath: '/nonexistent-pocketterm-test/iTerm.app'),
    terminal: AppleTerminal(appPath: '/nonexistent-pocketterm-test/Terminal.app'),
    ghostty: Ghostty(appPath: '/nonexistent-pocketterm-test/Ghostty.app'),
    recency: () async => const [],
    snapshot: () async => Procs(const []),
  );

  /// The server's active reviewer codes, newest first, without links (the
  /// server keeps hashes); what was asked of it in [madeCodes] and [revoked].
  final reviewer = <ReviewerCode>[];
  final madeCodes = <({int days, String label})>[];
  final revoked = <String>[];

  /// Makes [createReviewerCode] and [revokeReviewerCode] fail with this.
  String? reviewerFailure;

  @override
  Future<ReviewerCode> createReviewerCode({required int days, String label = ''}) async {
    if (reviewerFailure case final f?) throw PairingException(f);
    madeCodes.add((days: days, label: label));
    final id = 'code-${madeCodes.length}';
    final expiresAt = DateTime.now().add(Duration(days: days));
    reviewer.insert(0, ReviewerCode(id: id, label: label, expiresAt: expiresAt));
    return ReviewerCode(
      id: id,
      label: label,
      expiresAt: expiresAt,
      link: backend!.linkWithCode('REVW-${madeCodes.length}AAA-BBBB-CCCC-DDDD-EEEE-FFFF'),
    );
  }

  @override
  Future<List<ReviewerCode>> reviewerCodes() async => [...reviewer];

  @override
  Future<void> revokeReviewerCode(String id) async {
    if (reviewerFailure case final f?) throw PairingException(f);
    revoked.add(id);
    reviewer.removeWhere((c) => c.id == id);
  }
}

/// Secrets kept in memory, as the Keychain would keep them.
class MemorySecrets implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String name) async => values[name];

  @override
  Future<void> write(String name, String value) async => values[name] = value;
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

/// [child] as main.dart hosts a window: a [MaterialApp] with PocketTerm's theme and
/// a [Toaster].
Widget window(Widget child) => MaterialApp(
  theme: appTheme(),
  home: Material(
    type: MaterialType.transparency,
    child: Toaster(child: child),
  ),
);
