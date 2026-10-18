import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_desktop/desktop_host.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/terminal_bridge.dart';
import 'package:pocketterm_desktop/update_check.dart';
import 'package:pocketterm_desktop/windows_host.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

/// The desktop app: [Session] plus its main window and the terminal bridge.
class AppController extends Session {
  AppController(this._prefs, super.device, this.host);

  final SharedPreferences _prefs;

  /// The computer's side: the window, the menu-bar or tray item, launch at
  /// login, keeping awake.
  final DesktopHost host;

  /// Whether PocketTerm starts at login, as the system has it; null until
  /// [refreshLaunchAtLogin] asked.
  bool? get launchAtLogin => _launchAtLogin;
  bool? _launchAtLogin;

  Future<void> refreshLaunchAtLogin() async {
    _launchAtLogin = await host.launchAtLogin();
    notifyListeners();
  }

  /// Throws what the system said when it refused; [launchAtLogin] is then
  /// how it stands still.
  Future<void> setLaunchAtLogin({required bool on}) async {
    try {
      await host.setLaunchAtLogin(on: on);
    } finally {
      await refreshLaunchAtLogin();
    }
  }

  /// Set once this computer has had its first sign-in ([onSignedIn]).
  static const _firstSignInKey = 'first_sign_in_done';

  static const _terminalKey = 'terminal_bridge';

  /// The phone may see and type into this computer's terminals and the
  /// coding sessions (lib/terminal_bridge.dart): whoever holds the account
  /// can then type here. Turned on by the first sign-in ([onSignedIn]), then
  /// as Settings has it.
  bool get terminalOn => _prefs.getBool(_terminalKey) ?? false;
  TerminalBridge? _bridge;

  /// Whose `terminal:<uid>:<desktop id>` channel [_bridge] is on.
  String? _bridgeUser;

  /// [_startBridge] calls, one after the other.
  Future<void> _bridging = Future.value();

  /// While the bridge runs: this computer tells the server it's there
  /// ([_seen]) every [_seenEvery], so the phone lists it.
  Timer? _seenTimer;
  Future<void> _seenOut = Future.value();
  static const _seenEvery = Duration(seconds: 60);

  static const _idChars = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// This computer among [userId]'s (table `desktops`): made up the first
  /// time, then kept.
  String desktopId(String userId) {
    final key = 'desktop_id_$userId';
    if (_prefs.getString(key) case final id?) return id;
    final r = Random.secure();
    final id = String.fromCharCodes([for (var i = 0; i < 8; i++) _idChars.codeUnitAt(r.nextInt(_idChars.length))]);
    unawaited(_prefs.setString(key, id));
    return id;
  }

  /// What the phone calls this computer: its name, as the server takes it.
  @visibleForTesting
  static String desktopName(String device) {
    final name = device.trim();
    if (name.isEmpty) return 'Computer';
    return name.length <= 80 ? name : name.substring(0, 80);
  }

  /// The Mac's terminals (kitty's sockets in [kittyDir]).
  late final Terminals terminals = Terminals.standard(kittyDir: kittyDir(Platform.environment));

  /// Where kitty's sockets are: /tmp, or the directory `POCKETTERM_KITTY_DIR`
  /// names, so a second PocketTerm under test talks to a kitty of its own.
  @visibleForTesting
  static String kittyDir(Map<String, String> env) {
    final dir = env['POCKETTERM_KITTY_DIR'];
    return dir != null && dir.isNotEmpty ? dir : '/tmp';
  }

  static const _terminalAppKey = 'terminal_app';

  /// The terminal app new sessions from the phone open in: an app's id
  /// (lib/terminal.dart), or `auto` (the one used last).
  String get terminalApp => _prefs.getString(_terminalAppKey) ?? 'auto';

  Future<void> setTerminalApp(String id) async {
    await _prefs.setString(_terminalAppKey, id);
    notifyListeners();
  }

  static const _projectRootsKey = 'project_roots';

  /// Folders holding the user's projects (Settings → Project folders): the
  /// phone lists the git repositories under them and makes new projects there.
  List<String> get projectRoots => _prefs.getStringList(_projectRootsKey) ?? const [];

  Future<void> setProjectRoots(List<String> roots) async {
    await _prefs.setStringList(_projectRootsKey, roots);
    notifyListeners();
  }

  static const _agentKey = 'coding_agent';

  /// The coding agent a new session from the phone starts.
  Agent get codingAgent => Agent.parse(_prefs.getString(_agentKey));

  Future<void> setCodingAgent(Agent agent) async {
    await _prefs.setString(_agentKey, agent.name);
    notifyListeners();
  }

  /// The coding sessions reporting to the local API (integrations/).
  late final live = LiveHub(locate: (term, cwd) => terminals.locate(term, cwd: cwd))
    ..events.listen((e) => unawaited(_onLive(e)));

  Future<void> setTerminal({required bool on}) async {
    await _prefs.setBool(_terminalKey, on);
    notifyListeners();
    await _startBridge();
  }

  /// One bridge for the signed-in user while [terminalOn]: a new one when
  /// the user changes, none when they're gone however they went. Calls run
  /// one at a time, so two at once (the switch while a sign-in lands) don't
  /// both build one.
  Future<void> _startBridge() {
    final next = _bridging.then((_) => _syncBridge());
    _bridging = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _syncBridge() async {
    final want = terminalOn ? user?.id : null;
    if (want == _bridgeUser) return;
    final old = _bridge;
    _bridge = null;
    _bridgeUser = null;
    _seenTimer?.cancel();
    _seenTimer = null;
    await old?.stop();
    if (want != null) {
      _bridgeUser = want;
      final id = desktopId(want);
      await (_bridge = TerminalBridge(
        client,
        want,
        id,
        terminals,
        live,
        host,
        () => codingAgent,
        () => terminalApp,
        () => projectRoots,
      )).start();
      _seen(id);
      _seenTimer = Timer.periodic(_seenEvery, (_) => _seen(id));
    }
  }

  /// Tells the server this computer [id] is there now; a failure waits for
  /// the next beat.
  void _seen(String id) {
    _seenOut = _seenOut.then((_) async {
      try {
        await client.from('desktops').upsert({
          'id': id,
          'name': desktopName(device),
          'platform': Platform.isWindows ? 'windows' : 'macos',
          'seen_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'user_id,id');
      } on Object catch (e) {
        debugPrint('PocketTerm: computer not listed: $e');
      }
    });
  }

  /// A run ended, or the agent waits for an answer: the phones hear about
  /// it, unless it's showing that session right now.
  Future<void> _onLive(LiveEvent e) async {
    final s = e.session;
    if (_bridge?.watching(s.key) ?? false) return;
    final (title, body, state) = switch (e) {
      LiveFinished(:final summary) => ('${s.agent.label} finished · ${s.project}', summary, 'done'),
      LiveAsked(:final ask) => ('${s.agent.label} needs you · ${s.project}', ask.text, 'needs'),
    };
    await notifyPhone(title, body, session: s.key, activity: state);
  }

  /// Windows' check for a newer PocketTerm (the Mac has Sparkle): Settings
  /// and the tray offer it while there is one.
  final UpdateCheck? updates = Platform.isWindows ? UpdateCheck() : null;

  @override
  Future<void> start() async {
    await host.start(onEvent: _onHost);
    if (updates case final u?) {
      u
        ..addListener(() {
          if (host case final WindowsHost w) w.setUpdate(u.update);
          notifyListeners();
        })
        ..start();
    }
    await super.start();
    // Not set up or signed out: there's nothing to do but that, so say so.
    if (user == null) await openMain();
  }

  @override
  void dispose() {
    updates?.dispose();
    super.dispose();
  }

  /// The first sign-in on this computer turns on Terminal from phone and
  /// Launch at login (what PocketTerm is for); after that they stay as the
  /// user leaves them.
  @override
  Future<void> onSignedIn(User user) async {
    if (_prefs.getBool(_firstSignInKey) ?? false) return await _startBridge();
    try {
      await setLaunchAtLogin(on: true);
    } on Object catch (e) {
      debugPrint('PocketTerm: launch at login not turned on: $e');
    }
    try {
      await setTerminal(on: true);
    } finally {
      await _prefs.setBool(_firstSignInKey, true);
    }
  }

  /// The phone stops listing this computer (unless the account went, and
  /// the row with it).
  @override
  Future<void> onSigningOut({required bool accountDeleted}) async {
    _seenTimer?.cancel();
    _seenTimer = null;
    await _seenOut;
    final id = _prefs.getString('desktop_id_${user?.id}');
    if (accountDeleted || id == null) return;
    await client.from('desktops').delete().eq('id', id);
  }

  /// However the user went (signed out here, the server refused a refresh,
  /// the account was deleted on another device): the terminal bridge stops.
  @override
  Future<void> onSignedOut() async {
    try {
      await _startBridge();
    } on Object catch (e) {
      debugPrint('PocketTerm: terminal bridge not stopped: $e');
    }
  }

  /// A setup link to another server waits for a yes: in the main window.
  @override
  void onLinkToConfirm() => unawaited(openMain());

  // ---------------------------------------------------------------- window

  /// Runs when PocketTerm quits, before the app goes (a second at most): the
  /// local API takes itself out of cli.json (lib/main.dart).
  Future<void> Function()? onQuit;

  /// What the host says: the menu-bar or tray item, the Dock icon, quitting.
  /// A closed window (mainClosed) is only hidden: nothing changes here.
  FutureOr<void> _onHost(String event) {
    switch (event) {
      // Settings is the window while signed in.
      case 'openMain' || 'openSettings':
        unawaited(openMain());
      case 'quitting':
        return onQuit?.call();
    }
  }

  /// Shows the main window.
  Future<void> openMain() => host.showMain();

  /// Pushes [title] / [body] to the user's phones (functions/push) when
  /// nobody has touched this computer for a minute: at the desk, its own
  /// screen says it already. [session]: the coding session a tap opens,
  /// whose Live Activities move to [activity] (done, needs). False if it
  /// didn't go.
  Future<bool> notifyPhone(String title, String body, {String? session, String? activity}) async {
    if (user == null || await host.idleSeconds() < 60) return false;
    try {
      final res = await client.functions.invoke(
        'push',
        body: {
          'action': 'notify',
          'title': title,
          'body': body,
          if (session != null) 'session': routedKey(desktopId(user!.id), session),
          'state': ?activity,
        },
      );
      final data = res.data;
      return data is Map && (data['sent'] as int? ?? 0) > 0;
    } on Object catch (e) {
      debugPrint('PocketTerm: notify failed: $e');
      return false;
    }
  }
}
