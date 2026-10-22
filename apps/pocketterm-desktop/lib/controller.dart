import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pocketterm_core/agent.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/terminal.dart' show TermWindow;
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_desktop/channel_keys.dart';
import 'package:pocketterm_desktop/commands.dart';
import 'package:pocketterm_desktop/desktop_host.dart';
import 'package:pocketterm_desktop/hosting/built_in_server.dart';
import 'package:pocketterm_desktop/hosting/tailscale.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/live_hub.dart';
import 'package:pocketterm_desktop/terminal_bridge.dart';
import 'package:pocketterm_desktop/update_check.dart';
import 'package:pocketterm_desktop/windows_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The desktop app: [Session] plus its main window and the terminal bridge.
class AppController extends Session {
  AppController(
    this._prefs,
    super.device,
    this.host, {
    Integrations? integrations,
    SecretStore? secrets,
    Tailscale? tailscale,
    Future<Directory> Function()? serverDir,
    Commands? commands,
  }) : integrations = integrations ?? Integrations(),
       _keys = ChannelKeys(secrets ?? SystemSecrets()),
       deviceTokens = SecretDeviceTokens(secrets ?? SystemSecrets()),
       tailscale = tailscale ?? Tailscale(),
       commands = commands ?? Commands(),
       _serverDir = serverDir ?? _appServerDir;

  @override
  final DeviceTokens deviceTokens;

  final SharedPreferences _prefs;

  /// The computer's side: the window, the menu-bar or tray item, launch at
  /// login, keeping awake.
  final DesktopHost host;

  /// Installs PocketTerm into the coding agents (lib/integrations.dart).
  final Integrations integrations;

  /// Installs the setup offers to run (Homebrew's tmux and Tailscale),
  /// each once the person confirmed it.
  final Commands commands;

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

  /// Whose `<desktop id>` topic [_bridge] is on: the server's id.
  String? _bridgeUser;

  /// How far a phone's clock is off this computer's while it's too far for
  /// anything from it to be taken (TerminalBridge.clockOff); null otherwise.
  Duration? get phoneClockOff => _bridge?.clockOff;

  /// [_startBridge] calls, one after the other.
  Future<void> _bridging = Future.value();

  /// While the bridge runs: this computer tells the server it's there
  /// ([_seen]) every [_seenEvery], so the phone lists it.
  Timer? _seenTimer;
  Future<void> _seenOut = Future.value();
  static const _seenEvery = Duration(seconds: 60);

  static const _idChars = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// This computer on server [userId] (its desktops list): made up the
  /// first time, then kept.
  String desktopId(String userId) {
    final key = 'desktop_id_$userId';
    if (_prefs.getString(key) case final id?) return id;
    final r = Random.secure();
    final id = String.fromCharCodes([for (var i = 0; i < 8; i++) _idChars.codeUnitAt(r.nextInt(_idChars.length))]);
    unawaited(_prefs.setString(key, id));
    return id;
  }

  final ChannelKeys _keys;

  /// This computer's channel key for the signed-in account (lib/channel_keys.dart).
  Future<ChannelKey> channelKey() => _keys.of(desktopId(user!.id));

  @override
  Future<ComputerKey?> pairingComputer() async => (desktop: desktopId(user!.id), key: await channelKey());

  /// A new channel key (Settings → Phone → Reset key): every phone has to
  /// scan this computer's code again. The bridge starts over with it.
  Future<void> resetChannelKey() async {
    await _keys.reset(desktopId(user!.id));
    _bridgeUser = null;
    await _startBridge();
  }

  /// What the phone calls this computer: its name, as the server takes it.
  @visibleForTesting
  static String desktopName(String device) {
    final name = device.trim();
    if (name.isEmpty) return 'Computer';
    return name.length <= 80 ? name : name.substring(0, 80);
  }

  /// This computer's terminals (on a Mac, kitty's sockets are in [kittyDir];
  /// on Windows the WezTerm it starts gets the PATH a new login has).
  late final Terminals terminals = Terminals.standard(
    kittyDir: kittyDir(Platform.environment),
    windowsPath: Platform.isWindows ? freshWindowsPath : null,
  );

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

  static const _setupStepKey = 'setup_step';
  static const _setupAddressKey = 'setup_address';

  /// Where the first-run setup (lib/setup_page.dart) was left: the screen's
  /// name, null on the first one. It opens there again.
  String? get setupStep => _prefs.getString(_setupStepKey);

  Future<void> setSetupStep(String? step) =>
      step == null ? _prefs.remove(_setupStepKey) : _prefs.setString(_setupStepKey, step);

  /// The VPS address typed in the first-run setup, as typed.
  String get setupAddress => _prefs.getString(_setupAddressKey) ?? '';

  Future<void> setSetupAddress(String address) => _prefs.setString(_setupAddressKey, address);

  static const _getReadyKey = 'get_ready_done';

  /// The setup checklist (lib/onboarding/get_ready.dart) was finished or
  /// skipped on this computer; until then the signed-in window shows it.
  bool get getReadyDone => _prefs.getBool(_getReadyKey) ?? false;

  Future<void> setGetReadyDone({required bool done}) async {
    await _prefs.setBool(_getReadyKey, done);
    notifyListeners();
  }

  // ---------------------------------------------------------------- agents

  /// The coding agents found on this computer and PocketTerm in each, as of
  /// the last [checkAgents]; null before the first one ends.
  Map<Agent, AgentCheck>? get agents => _agents;
  Map<Agent, AgentCheck>? _agents;
  Future<void>? _checkingAgents;
  DateTime? _agentsAt;

  /// Looks for the coding agents and PocketTerm in them. One look at a time:
  /// a call while one runs waits for it.
  Future<void> checkAgents() => _checkingAgents ??= _lookForAgents().whenComplete(() => _checkingAgents = null);

  Future<void> _lookForAgents() async {
    final found = <Agent, AgentCheck>{};
    for (final agent in Agent.values) {
      try {
        if (!await integrations.found(agent)) continue;
        final state = await integrations.state(agent);
        final modsOff = agent == Agent.claude && state.installed && await integrations.claudeModsOff();
        found[agent] = (state: state, modsOff: modsOff);
      } on Object catch (e) {
        found[agent] = (state: (installed: false, current: false, problem: '$e'), modsOff: false);
      }
    }
    _agents = found;
    _agentsAt = DateTime.now();
    notifyListeners();
  }

  /// Installs (or updates) PocketTerm in [agent], then looks again. Throws
  /// what went wrong.
  Future<void> installAgent(Agent agent) async {
    try {
      await integrations.install(agent);
    } finally {
      await checkAgents();
    }
  }

  /// What the phone hears ([TerminalBridge]): looked at again when the last
  /// look is older than [_agentsEvery], since it runs `claude`.
  Future<Map<Agent, AgentIntegration>> _agentsForPhone() async {
    final at = _agentsAt;
    if (at == null || DateTime.now().difference(at) > _agentsEvery) await checkAgents();
    return {for (final MapEntry(:key, :value) in (_agents ?? const {}).entries) key: integrationOf(value)};
  }

  static const _agentsEvery = Duration(seconds: 30);

  /// The terminal windows running a coding agent that no live session
  /// claims: started before PocketTerm was in it (or with it off), so they
  /// reach the phone only as screens.
  List<TermWindow> unreportedAgentWindows(List<TermWindow> windows) {
    final claimed = {for (final s in live.sessions) ?s.window};
    return [
      for (final w in windows)
        if (w.agent != null && !claimed.contains(w.key)) w,
    ];
  }

  // ---------------------------------------------------------------- phone

  /// A phone has signed in to this server: it's among the server's devices
  /// ([phoneCodeUsed]) or said hello to this computer. Kept per server on this
  /// computer once seen. Null until known.
  bool? get phoneSignedIn => _phoneSignedIn ?? (_phoneKept ? true : null);
  bool? _phoneSignedIn;

  String get _phoneKey => 'phone_signed_in_${user?.id ?? ''}';
  bool get _phoneKept => user != null && (_prefs.getBool(_phoneKey) ?? false);

  /// Asks the server, until the answer is yes.
  Future<void> checkPhone() async {
    if (phoneSignedIn ?? false) return;
    try {
      final used = await phoneCodeUsed();
      if (used) return _phoneHeard();
      if (used == _phoneSignedIn) return;
      _phoneSignedIn = used;
      notifyListeners();
    } on Object catch (e) {
      debugPrint('PocketTerm: phone sign-in unknown: $e');
    }
  }

  /// A phone is signed in to this server (GET /v1/devices).
  @protected
  Future<bool> phoneCodeUsed() async => (await server!.devices()).any((d) => d.role == DeviceRole.phone);

  void _phoneHeard() {
    if (user != null) unawaited(_prefs.setBool(_phoneKey, true));
    if (_phoneSignedIn ?? false) return;
    _phoneSignedIn = true;
    notifyListeners();
  }

  /// The coding sessions reporting to the local API (integrations/).
  late final live = LiveHub(locate: terminals.locate)..events.listen((e) => unawaited(_onLive(e)));

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
      final id = desktopId(want);
      final key = await _keys.of(id);
      _bridgeUser = want;
      await (_bridge = TerminalBridge(
        server!,
        id,
        key,
        terminals,
        live,
        host,
        () => codingAgent,
        () => terminalApp,
        () => projectRoots,
        agents: _agentsForPhone,
        onPhone: _phoneHeard,
      )).start();
      _seen(id);
      _seenTimer = Timer.periodic(_seenEvery, (_) => _seen(id));
    }
  }

  /// Tells the server this computer [id] is there now (the server stamps
  /// seen_at by its own clock); a failure waits for the next beat.
  void _seen(String id) {
    _seenOut = _seenOut.then((_) async {
      try {
        await server?.putDesktop(id, name: desktopName(device), platform: Platform.isWindows ? 'windows' : 'macos');
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
    final project = live.projectName(s);
    final where = project.isEmpty ? '' : ' · $project';
    final (title, body, state) = switch (e) {
      LiveFinished(:final summary) => ('${s.agent.label} finished$where', summary, 'done'),
      LiveAsked(:final ask) => ('${s.agent.label} needs you$where', ask.text, 'needs'),
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
    if (_prefs.getBool(_hostingKey) ?? false) {
      try {
        await _startHosting();
        // Where it listens now, should the port have moved: the sign-in kept
        // for the old one doesn't count, and this computer signs in again.
        await _hosting!.backend.save();
      } on Object catch (e) {
        debugPrint('PocketTerm: built-in server not started: $e');
      }
    }
    await super.start();
    await _signInToOwnServer();
    // Not set up or signed out: there's nothing to do but that, so say so.
    if (user == null) await openMain();
  }

  // ---------------------------------------------------------------- hosting

  /// This computer runs the server ("This computer" in the first-run
  /// setup): it starts with the app, until signing out here.
  static const _hostingKey = 'hosting';

  /// The port it listened on last, tried first next time.
  static const _hostingPortKey = 'hosting_port';

  /// The Tailscale CLI, which publishes the built-in server.
  final Tailscale tailscale;

  /// Where the built-in server keeps its data.
  final Future<Directory> Function() _serverDir;

  /// App support `pocketterm-server/`.
  static Future<Directory> _appServerDir() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'pocketterm-server'));

  /// The built-in server, while this computer runs it.
  BuiltInServer? get hosting => _hosting;
  BuiltInServer? _hosting;

  @override
  bool get hostsServer => _hosting?.running ?? false;

  /// The ports this app's built-in server listens on now and listened on
  /// last: a Serve entry to one of these is this app's own.
  Set<int> get ownServerPorts => {if (_hosting case final h? when h.running) h.port, ?_prefs.getInt(_hostingPortKey)};

  /// "This computer": starts the built-in server, from now on at every
  /// launch, and signs this computer in to it. Throws what went wrong.
  Future<void> startHosting() async {
    await _startHosting();
    await _prefs.setBool(_hostingKey, true);
    await _signInToOwnServer();
  }

  Future<void> _startHosting() async {
    if (_hosting != null) return;
    final h = BuiltInServer(dataDir: await _serverDir(), tailscale: tailscale);
    try {
      final last = _prefs.getInt(_hostingPortKey);
      await h.start(port: last ?? 47900, earlier: last);
    } on Object {
      h.dispose();
      rethrow;
    }
    _hosting = h..addListener(notifyListeners);
    await _prefs.setInt(_hostingPortKey, h.port);
    notifyListeners();
  }

  /// A computer running the server signs itself in with the server's own
  /// setup token, on 127.0.0.1.
  Future<void> _signInToOwnServer() async {
    final h = _hosting;
    if (h == null || user != null) return;
    await connectLink(h.ownSetupLink());
  }

  Future<void> _stopHosting() async {
    final h = _hosting;
    if (h == null) return;
    _hosting = null;
    h.removeListener(notifyListeners);
    await _prefs.setBool(_hostingKey, false);
    await h.stop();
    h.dispose();
    notifyListeners();
  }

  /// "Add a computer…": the link another computer sets up with (through
  /// Tailscale); null until Tailscale serves this one.
  Uri? computerSetupLink() => _hosting?.setupLink();

  /// A phone's code from a computer running the server carries its
  /// Tailscale address: phones can't reach 127.0.0.1.
  @override
  Future<Uri> pairingLink() async {
    final h = _hosting;
    if (h == null) return await super.pairingLink();
    final url = h.publicUrl;
    if (url == null) throw const PairingException('Tailscale isn’t serving this computer yet. See Settings → Account.');
    final String code;
    try {
      code = await server!.createPairingCode();
    } on ServerException catch (e) {
      throw PairingException(e.message);
    }
    return Backend(url: url.toString()).linkWithCode(code, computer: await pairingComputer());
  }

  /// Every computer and phone signed in to the server.
  Future<List<Device>> serverDevices() => server!.devices();

  /// Signing out of a server this computer runs stops it, and the
  /// first-run setup shows again. Its data stays: This computer starts it
  /// again with the same phones and computers.
  @override
  Future<void> signOut() async {
    await super.signOut();
    if (_hosting != null) await disconnect();
  }

  @override
  Future<void> disconnect() async {
    await super.disconnect();
    await _stopHosting();
  }

  /// Erasing signs this computer out too; it signs in again at once, as
  /// the first computer of an empty server.
  @override
  Future<void> eraseServer() async {
    final phoneKey = _phoneKey;
    await super.eraseServer();
    await _prefs.remove(phoneKey);
    await _signInToOwnServer();
  }

  /// Stops what a quit ends with the process: the terminal bridge, the beat
  /// that lists this computer, the server connection. For a test that starts
  /// the app again in the same process (integration_test/e2e_test.dart).
  @visibleForTesting
  Future<void> shutDown() async {
    _seenTimer?.cancel();
    _seenTimer = null;
    await _seenOut;
    final bridge = _bridge;
    _bridge = null;
    _bridgeUser = null;
    await bridge?.stop();
    await _hosting?.stop();
    server?.close();
  }

  @override
  void dispose() {
    updates?.dispose();
    mainShown.dispose();
    mainHidden.dispose();
    super.dispose();
  }

  /// The first sign-in on this computer turns on Terminal from phone (what
  /// PocketTerm is for); after that it stays as the user leaves it. Launch
  /// at login stays off until the user turns it on (Settings → Account): a
  /// login item is the person's to add.
  @override
  Future<void> onSignedIn(Account user) async {
    if (_prefs.getBool(_firstSignInKey) ?? false) return await _startBridge();
    try {
      await setTerminal(on: true);
    } finally {
      await _prefs.setBool(_firstSignInKey, true);
    }
  }

  /// The phone stops listing this computer.
  @override
  Future<void> onSigningOut() async {
    _seenTimer?.cancel();
    _seenTimer = null;
    await _seenOut;
    final id = _prefs.getString('desktop_id_${user?.id}');
    if (id == null) return;
    await server?.deleteDesktop(id);
  }

  /// However the sign-in went (signed out here, the server stopped taking
  /// it): the terminal bridge stops.
  @override
  Future<void> onSignedOut() async {
    // The next account's phones are its own.
    _phoneSignedIn = null;
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
  /// A closed window (mainClosed) is only hidden: [mainHidden] says so.
  FutureOr<void> _onHost(String event) {
    switch (event) {
      // Settings is the window while signed in.
      case 'openMain' || 'openSettings':
        unawaited(openMain());
      case 'mainClosed':
        mainHidden.value = true;
      case 'quitting':
        return Future.wait([?onQuit?.call(), if (_hosting case final h?) h.stop()]).then((_) {});
    }
  }

  /// Ticks each time the main window is shown: it stays alive while hidden,
  /// so Settings checks the terminals and the agent's integration afresh.
  final mainShown = ValueNotifier<int>(0);

  /// The main window was closed (hidden) and not shown since.
  final mainHidden = ValueNotifier<bool>(false);

  /// Shows the main window.
  Future<void> openMain() {
    mainShown.value++;
    mainHidden.value = false;
    return host.showMain();
  }

  /// Pushes [title] / [body] to the phones (POST /v1/push/notify) when
  /// nobody has touched this computer for a minute: at the desk, its own
  /// screen says it already. [session]: the coding session a tap opens;
  /// [activity]: where it stands (done, needs). Sealed with this computer's
  /// key; outside the seal go only this computer's push tag and the session's
  /// (pushTag, sessionTag), which mean nothing without the key (Live
  /// Activities move by the bridge's own pushes). False if it didn't go.
  Future<bool> notifyPhone(String title, String body, {String? session, String? activity}) async {
    if (user == null || await host.idleSeconds() < 60) return false;
    try {
      final id = desktopId(user!.id);
      final key = await channelKey();
      final routed = session == null ? null : routedKey(id, session);
      final notice = {'title': title, 'body': body, 'session': ?routed, 'state': ?activity};
      final data = await invokePush('notify', {
        'tag': await pushTag(key),
        'enc': await sealNotice(key, id, notice),
        // Lets a newer push for the same session replace an older one.
        if (routed != null) 'collapse': await sessionTag(key, routed),
      });
      return (data['sent'] as int? ?? 0) > 0;
    } on Object catch (e) {
      debugPrint('PocketTerm: notify failed: $e');
      return false;
    }
  }

  /// Push [action] with [body] on the server; its answer.
  @protected
  Future<Map<String, dynamic>> invokePush(String action, Map<String, Object> body) => server!.push(action, body);
}
