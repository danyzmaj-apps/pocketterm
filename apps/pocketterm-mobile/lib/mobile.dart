import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketterm_core/account.dart' show Avatar;
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/live_activity.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/timing.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/demo/demo.dart';
import 'package:pocketterm_mobile/links.dart';
import 'package:pocketterm_mobile/onboarding/scan.dart';
import 'package:pocketterm_mobile/push_consent.dart';
import 'package:pocketterm_mobile/setup_page.dart';
import 'package:pocketterm_mobile/terminal_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The phone side of [Session]: keeps the computers' channel keys (from
/// their QR codes; packages/pocketterm_core/lib/e2e.dart) where the native
/// side reads them too (ios/Shared/PocketTermShared.swift, android/…/
/// PocketTermShared.kt: the push extension opens a computer's pushes with
/// its key), registers this phone for the computer's terminal pushes, and
/// ends the sessions it follows when it leaves the server.
class MobileSession extends Session {
  MobileSession(this._prefs, super.device);

  final SharedPreferences _prefs;

  /// A phone signs in only with a code from the computer.
  @override
  DeviceRole get role => DeviceRole.phone;

  @override
  DeviceTokens get deviceTokens => const NativeDeviceTokens();

  /// The phone opens on what it had (its computers, their sessions, from
  /// cache) while the server is asked whether the sign-in still holds.
  @override
  bool get signInAtOnce => true;

  final _computerKeys = <String, ChannelKey>{};

  /// Computer [desktopId]'s channel key; null while this phone hasn't
  /// scanned that computer's code: the computer is locked, nothing from it
  /// shows and nothing goes to it.
  @override
  ChannelKey? computerKey(String desktopId) => switch (_demo) {
    final d? when user == null && desktopId == demoDesktopId => d.remote.key,
    _ => _computerKeys[desktopId],
  };

  /// Until [start] has read what this phone kept (its server, sign-in and
  /// computer keys): nothing shows yet, rather than setup for a moment.
  bool get launching => _launching;
  bool _launching = false;

  @override
  Future<void> start() async {
    _launching = true;
    try {
      await forgetOldApp();
      await loadComputerKeys();
      await super.start();
    } finally {
      _launching = false;
      notifyListeners();
    }
  }

  /// A followed session's link (`pocketterm://session?key=<routed key>`, a
  /// Live Activity's or Android's ongoing notification's), kept until the
  /// home page takes it ([takeOpenedSession]): the one that launched the app
  /// comes before there's a home page.
  @override
  void onOtherLink(Uri uri) {
    if (uri.scheme != 'pocketterm' || uri.host != 'session') return;
    final key = uri.queryParameters['key'];
    if (key == null || key.isEmpty) return;
    _openedSession = key;
    notifyListeners();
  }

  String? _openedSession;

  /// The routed key of the session a link opened, once.
  String? takeOpenedSession() {
    final key = _openedSession;
    _openedSession = null;
    return key;
  }

  /// PocketTerm 0.1 connected through a Supabase project (its URL kept with
  /// that project's key): no server this app talks to. What it left goes,
  /// so the phone starts at setup: the project, a sign-in and computer
  /// keys if any, the Supabase session and the computers list it cached,
  /// and the sessions it followed. The tips seen and the list's order stay.
  @visibleForTesting
  Future<void> forgetOldApp() async {
    try {
      if (!((await Native.getBackend())?.legacy ?? false)) return;
      await Native.setBackend();
      await Native.setDeviceToken(null);
      await Native.removeAllChannelKeys();
    } on Object catch (e) {
      debugPrint('PocketTerm: the old app’s data not removed: $e');
      return;
    }
    for (final k in _prefs.getKeys().where(
      (k) =>
          k.startsWith('sb-') ||
          k.startsWith('supabase') ||
          // Written by older versions, never read.
          k == 'pocketterm_push_token' ||
          k == _desktopKey ||
          k == _desktopsKey,
    )) {
      await _prefs.remove(k);
    }
    await _endActivities();
  }

  /// The keys the native side keeps.
  Future<void> loadComputerKeys() async {
    try {
      for (final MapEntry(:key, :value) in (await Native.channelKeys()).entries) {
        if (ChannelKey.tryParse(value) case final k?) _computerKeys[key] = k;
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: computer keys not read: $e');
    }
    notifyListeners();
  }

  /// The computer whose code was last scanned, until the home page shows it
  /// ([takeScannedComputer]).
  String? _scanned;

  /// The computer just scanned, once: the home page shows it rather than
  /// whichever was seen last.
  String? takeScannedComputer() {
    final id = _scanned;
    _scanned = null;
    return id;
  }

  @override
  Future<void> addComputerKey(ComputerKey computer) async {
    _scanned = computer.desktop;
    if (_computerKeys[computer.desktop] != computer.key) {
      await Native.setChannelKey(desktop: computer.desktop, key: computer.key.toBase64());
      _computerKeys[computer.desktop] = computer.key;
    }
    notifyListeners();
  }

  /// "Try the demo": a made-up computer answered on this phone (lib/demo/demo.dart),
  /// shown while signed out; null otherwise.
  DemoComputer? get demo => _demo;
  DemoComputer? _demo;

  void enterDemo() {
    if (user != null || _demo != null) return;
    _demo = DemoComputer(Directory.systemTemp.createTempSync('pocketterm_demo'));
    notifyListeners();
  }

  /// Back to the setup screen (or on, once signed in). The demo goes after
  /// the frame that stops showing it.
  void exitDemo() {
    final d = _demo;
    if (d == null) return;
    _demo = null;
    notifyListeners();
    SchedulerBinding.instance
      ..addPostFrameCallback((_) => d.dispose())
      ..scheduleFrame();
  }

  static const _foldedKey = 'pocketterm_terminal_folded';

  /// The Terminal list's projects (folders) showing only their heading.
  Set<String> get collapsedProjects => {...?_prefs.getStringList(_foldedKey)};

  Future<void> setCollapsedProjects(Set<String> cwds) => _prefs.setStringList(_foldedKey, [...cwds]);

  static const _sortKey = 'pocketterm_terminal_sort';

  /// How the Terminal list orders its projects; by name until chosen.
  ProjectSort get projectSort =>
      ProjectSort.values.where((s) => s.name == _prefs.getString(_sortKey)).firstOrNull ?? ProjectSort.name;

  Future<void> setProjectSort(ProjectSort sort) => _prefs.setString(_sortKey, sort.name);

  /// The first-use tips this phone has shown; kept across sign-outs, they're the phone's.
  late final CoachController tips = CoachController(_prefs);

  static const _desktopKey = 'pocketterm_desktop';
  static const _desktopsKey = 'pocketterm_desktops';

  /// The account's computers, starting from the list and the choice this
  /// phone kept, and keeping them as they change.
  Desktops desktops() {
    var cached = const <Desktop>[];
    try {
      cached = [
        for (final d in jsonDecode(_prefs.getString(_desktopsKey) ?? '[]') as List) Desktop.fromJson((d as Map).cast()),
      ];
    } on Object catch (e) {
      debugPrint('PocketTerm: computers cache: $e');
    }
    return Desktops(
      server!,
      cached: cached,
      saved: _prefs.getString(_desktopKey),
      onChanged: (all, selected) {
        unawaited(_prefs.setString(_desktopsKey, jsonEncode([for (final d in all) d.toJson()])));
        unawaited(selected == null ? _prefs.remove(_desktopKey) : _prefs.setString(_desktopKey, selected));
      },
    );
  }

  @override
  Future<void> onSignedIn(Account user) async {
    exitDemo();
    if (pushEnabled ?? false) await _registerPush(user.device.id);
    await checkNotifications();
  }

  /// Whether the phone lets PocketTerm's notifications show; null until
  /// known. Notifications on here but off in the phone's Settings (turned
  /// off there after saying yes) show nothing: the account sheet says so.
  bool? get notificationsAllowed => _notificationsAllowed;
  bool? _notificationsAllowed;

  /// Asks the phone again (at sign-in, coming back to the app, after a
  /// change here).
  Future<void> checkNotifications() async {
    bool? allowed;
    try {
      allowed = await Native.notificationsAllowed();
    } on Object catch (e) {
      debugPrint('PocketTerm: notification permission not read: $e');
    }
    if (allowed == _notificationsAllowed) return;
    _notificationsAllowed = allowed;
    notifyListeners();
  }

  /// How long the phone may take to hand over its push token before
  /// [setPushEnabled] gives up (no network, APNs never answering).
  static const pushTokenWait = Duration(seconds: 15);

  static const _pushChoiceKey = 'pocketterm_push_on';

  /// The person's push choice on the signed-in server (kept per server id):
  /// null until asked (PushConsentPage), and while signed out. Nothing
  /// registers for push before it's true.
  bool? get pushEnabled => switch (user) {
    final u? => _prefs.getBool('${_pushChoiceKey}_${u.id}'),
    null => null,
  };

  /// Turns push on (the system's permission, then this phone's token to the
  /// server) or off (the server forgets this phone's tokens, followed
  /// sessions end and Follow goes away). False: [on], but the phone didn't
  /// allow notifications, so it stays off.
  Future<bool> setPushEnabled({required bool on}) async {
    final u = user;
    if (u == null) return false;
    final key = '${_pushChoiceKey}_${u.id}';
    // A later choice (Not now while Turn on still waits) wins.
    final choice = ++_pushChoice;
    if (!on) {
      final was = pushEnabled ?? false;
      _pushUnsent = false;
      await _prefs.setBool(key, false);
      notifyListeners();
      // Not now, the first time: nothing was registered.
      if (was) await _pushOff();
      return true;
    }
    final registered = await _registerPush(u.device.id);
    if (choice != _pushChoice) return true;
    await _prefs.setBool(key, registered);
    await checkNotifications();
    notifyListeners();
    return registered;
  }

  int _pushChoice = 0;

  /// Push is on, but the server missed this phone's token (offline): it is
  /// sent again ([retryPush]) when the app comes back, when the computer's
  /// connection is back, and when the account sheet opens.
  bool get pushUnsent => _pushUnsent;
  bool _pushUnsent = false;

  /// A missed token is on its way to the server again: the account sheet
  /// shows that instead of the old warning.
  bool get pushRegistering => _pushRegistering;
  bool _pushRegistering = false;
  DateTime? _pushTried;

  /// Sends a token the server missed again, one try at a time. [force] (the
  /// app coming back, the account sheet opening) tries at once; otherwise
  /// (the connection back) not within 30 s of the last try, so a server that
  /// keeps refusing isn't asked on every state.
  Future<void> retryPush({bool force = false}) async {
    final user = this.user;
    if (!_pushUnsent || _pushRegistering || user == null || !(pushEnabled ?? false)) return;
    final tried = _pushTried;
    if (!force && tried != null && DateTime.now().difference(tried) < const Duration(seconds: 30)) return;
    _pushTried = DateTime.now();
    _pushRegistering = true;
    notifyListeners();
    try {
      await _registerPush(user.device.id);
    } finally {
      _pushRegistering = false;
      notifyListeners();
    }
  }

  /// Hands this phone's push token (APNs on iOS, FCM on Android) to the
  /// server, which from then on relays the computer's terminal news
  /// (POST /v1/push/notify), sealed by each computer with its key. False:
  /// not allowed, no token, or none within [pushTokenWait]. A server that
  /// missed it (offline) leaves [pushUnsent] for [retryPush].
  Future<bool> _registerPush(String deviceId) async {
    final String? token;
    try {
      token = await Native.registerPush().timeout(pushTokenWait);
    } on Object catch (e) {
      debugPrint('PocketTerm: no push token: $e');
      return false;
    }
    if (token == null) return false;
    if (user?.device.id != deviceId) return true;
    var unsent = false;
    try {
      await server!.push('register', {'token': token, 'label': device, 'platform': pushPlatform});
    } on Object catch (e) {
      debugPrint('PocketTerm: push registration failed: $e');
      unsent = true;
    }
    if (unsent != _pushUnsent) {
      _pushUnsent = unsent;
      notifyListeners();
    }
    return true;
  }

  /// Push off: followed sessions end here, and the server forgets every
  /// token of this phone (its push token and its followed sessions').
  Future<void> _pushOff() async {
    await _endActivities();
    await _tryServer('push unregister', () => server!.push('unregister', {}));
  }

  /// Android: FCM handed over a new token (`pushToken`); the server needs it,
  /// if push is on.
  Future<void> pushTokenChanged() async {
    final user = this.user;
    if (user != null && (pushEnabled ?? false)) await _registerPush(user.device.id);
  }

  @override
  Future<void> onSigningOut() async {
    final push = pushEnabled ?? false;
    await _forgetHere();
    // The server forgets this phone's push token and its followed sessions'.
    if (push) await _tryServer('push unregister', () => server!.push('unregister', {}));
  }

  /// However the sign-in went, also without [signOut] here (the computer
  /// signed this phone out, the server was erased): its followed sessions
  /// leave this phone.
  @override
  Future<void> onSignedOut() async {
    await _forgetHere();
  }

  /// Drops what this phone keeps for the server: the push registration's
  /// record and the push choice (the next sign-in asks again), every
  /// computer's key (the next sign-in scans a code, which brings its
  /// computer's), and the followed sessions, ended at once.
  Future<void> _forgetHere() async {
    _openedSession = null;
    _pushUnsent = false;
    _pushRegistering = false;
    _pushTried = null;
    // Every server's: the sign-in may already be gone, and with it its id.
    for (final k in _prefs.getKeys().where((k) => k.startsWith('${_pushChoiceKey}_'))) {
      await _prefs.remove(k);
    }
    await _prefs.remove(_desktopKey);
    await _prefs.remove(_desktopsKey);
    try {
      await Native.removeAllChannelKeys();
      _computerKeys.clear();
    } on Object catch (e) {
      debugPrint('PocketTerm: computer keys not removed: $e');
    }
    await _endActivities();
  }

  /// The followed sessions (Live Activities, Android's ongoing
  /// notifications) end at once.
  Future<void> _endActivities() async {
    try {
      for (final a in await Native.liveActivities()) {
        await Native.endActivity(a.key, immediate: true);
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: followed sessions not ended: $e');
    }
  }

  /// One server call of a clean-up; a failed one (offline) doesn't stop the
  /// rest.
  Future<void> _tryServer(String what, Future<Object?> Function() call) async {
    try {
      await call();
    } on Object catch (e) {
      debugPrint('PocketTerm: $what failed: $e');
    }
  }
}

/// The phone's sign-in, where its native side keeps it (Native.deviceToken):
/// the Keychain on iOS, Keystore-wrapped on Android.
class NativeDeviceTokens implements DeviceTokens {
  const NativeDeviceTokens();

  @override
  Future<String?> read() => Native.deviceToken();

  @override
  Future<void> write(String? value) => Native.setDeviceToken(value);
}

class MobileApp extends StatelessWidget {
  const MobileApp({
    required this.session,
    @visibleForTesting this.desktops,
    @visibleForTesting this.remoteFor,
    super.key,
  });
  final MobileSession session;

  /// See [HomePage.desktops].
  final Desktops? desktops;

  /// See [HomePage.remoteFor].
  final TerminalRemote Function(String desktopId, ChannelKey key)? remoteFor;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PocketTerm',
    debugShowCheckedModeBanner: false,
    theme: _theme(appTheme()),
    navigatorObservers: [SemanticsRefresh()],
    builder: (context, child) => Coach(controller: session.tips, child: child!),
    // No session, no app: only the computer's code gets a phone in, or the
    // demo shows a made-up computer. Signed in, push waits for a yes.
    home: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final user = session.user;
        // What this phone kept is still being read: setup only once it's known there's none.
        if (user == null && session.launching) return const Scaffold(backgroundColor: C.win);
        if (user == null) {
          if (session.demo case final demo?) {
            return _HomeSwitch(
              id: 'demo',
              child: HomePage(
                key: const ValueKey('demo'),
                session: session,
                userId: demoDesktopId,
                desktops: demo.desktops,
                remoteFor: (_, _) => demo.remote,
              ),
            );
          }
          return _HomeSwitch(
            id: 'setup',
            child: Scaffold(
              body: SafeArea(
                child: SetupPage(session: session, onDemo: session.enterDemo),
              ),
            ),
          );
        }
        if (session.pushEnabled == null) {
          return _HomeSwitch(
            id: 'consent',
            child: PushConsentPage(session: session),
          );
        }
        return _HomeSwitch(
          id: user.id,
          child: HomePage(
            key: ValueKey(user.id),
            session: session,
            userId: user.id,
            desktops: desktops,
            remoteFor: remoteFor,
          ),
        );
      },
    ),
  );

  static ThemeData _theme(ThemeData base) => base.copyWith(
    scaffoldBackgroundColor: C.win,
    // Rows show they were pressed: on iPhone a soft highlight with no ripple, as iOS's cells do; on Android
    // Material's ink. Either way it's clipped to the card, pill or circle it presses.
    splashFactory: isIos ? NoSplash.splashFactory : InkSparkle.splashFactory,
    highlightColor: const Color(0x14FFFFFF),
    // No button shows a tooltip on iPhone (iOS has none), so a press held long, or that came in late, still
    // presses: a long press showed the label and the tap went nowhere. The label stays for VoiceOver.
    tooltipTheme: isIos ? base.tooltipTheme.copyWith(triggerMode: TooltipTriggerMode.manual) : null,
    // A sheet's rows line up with its title, 20 in.
    listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 20)),
    appBarTheme: AppBarTheme(
      backgroundColor: C.win,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      // The theme's own font (a bare style would drop its family).
      titleTextStyle: base.textTheme.titleMedium!.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: C.text),
      actionsIconTheme: const IconThemeData(color: C.dim, size: 22),
    ),
    // A button turning on goes all at once: animated, its fill flips at
    // once while its label takes 200ms to darken, unreadable meanwhile.
    filledButtonTheme: const FilledButtonThemeData(style: ButtonStyle(animationDuration: Duration.zero)),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Color(0xFF1F2A22),
      contentTextStyle: TextStyle(color: Color(0xFFBBF7D0)),
      actionTextColor: Colors.white,
    ),
  );
}

// ==================================================================== home

/// The signed-in phone: the selected computer's coding sessions and
/// terminal windows, with a + for a new session; the title picks the
/// computer.
class HomePage extends StatefulWidget {
  const HomePage({
    required this.session,
    required this.userId,
    @visibleForTesting this.desktops,
    @visibleForTesting this.remoteFor,
    super.key,
  });
  final MobileSession session;
  final String userId;

  /// Computers handed in (tests, screenshots), never refreshed from a
  /// server; otherwise the session's.
  final Desktops? desktops;

  /// Makes the remotes fed by hand (tests, screenshots), never attached or
  /// disposed here; otherwise each joins its computer over the session's
  /// server, sealed with that computer's key.
  final TerminalRemote Function(String desktopId, ChannelKey key)? remoteFor;

  /// How long a tapped session (a push, a followed session's link) may take
  /// to come before the phone gives up on it.
  static const routedWait = Duration(seconds: 20);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final Desktops _desktops = widget.desktops ?? widget.session.desktops();

  /// While the Terminal list is in front, the list of computers is fetched
  /// this often (and on coming to the front).
  static const _refreshEvery = Duration(seconds: 30);
  Timer? _refreshTimer;

  /// Where remotes keep their caches; null until known.
  Directory? _supportDir;

  /// The selected computer's coding sessions and terminal windows, through
  /// PocketTerm there; live while the app is in front. Null with no
  /// computer, with a locked one (no key), and until its cache folder is
  /// known.
  TerminalRemote? _terminal;
  bool _terminalAttached = false;

  /// A tapped push's or followed session's session, until it shows
  /// ([_openRouted]).
  _Routed? _routed;

  /// What a link said while signed in ([MobileSession.notices]): a SnackBar.
  late final StreamSubscription<String> _notices;

  /// Whether [_tell] spoke since [_scanComputer] asked.
  bool _told = false;

  void _tell(String message) {
    _told = true;
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Showing "Try the demo"'s made-up computer.
  bool get _demo => widget.session.demo != null && widget.session.user == null;

  bool get _resumed {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// One remote, for the selected computer while this phone has its key:
  /// another computer selected, or a new key scanned, the old one goes (with
  /// any page on it) and a new one comes.
  void _syncRemote() {
    // A code just scanned: that computer, not the one seen last.
    if (widget.session.takeScannedComputer() case final id?) {
      _desktops.show(id);
      if (!_desktops.all.any((d) => d.id == id)) unawaited(_desktops.refresh());
    }
    final d = _desktops.selected;
    final key = d == null ? null : widget.session.computerKey(d.id);
    final old = _terminal;
    if (old != null && old.desktopId == d?.id && old.key == key) {
      old
        ..desktopName = d?.name
        ..desktopSeenAt = d?.seenAt;
      _syncFollow(old);
      return _advanceRouted();
    }
    TerminalRemote? next;
    if (d != null && key != null) {
      if (widget.remoteFor case final make?) {
        next = make(d.id, key);
      } else if (_supportDir case final dir?) {
        next = TerminalRemote(widget.session.server!, dir, desktopId: d.id, key: key);
      } else {
        return; // Made once the cache folder is known.
      }
      next
        ..desktopName = d.name
        ..desktopSeenAt = d.seenAt;
      _syncFollow(next);
      next.addListener(_pushWhenOnline);
    }
    if (old != null) {
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      _dropRemote(old);
    }
    _terminal = next;
    if (mounted) setState(() {});
    if (next != null && _resumed) _attachTerminal(attach: true);
    _advanceRouted();
  }

  /// Following sessions (Live Activities, Android's ongoing notifications)
  /// needs push: with it off there's no Follow, and nothing registers.
  void _syncFollow(TerminalRemote t) {
    final server = widget.session.server;
    final on = (widget.session.pushEnabled ?? false) && server != null;
    if (on && t.activities == null) {
      t.activities = LiveActivities(server, t);
    } else if (!on && t.activities != null) {
      t.activities!.dispose();
      t.activities = null;
    }
  }

  void _dropRemote(TerminalRemote t) {
    _terminalAttached = false;
    t.removeListener(_pushWhenOnline);
    t.activities?.dispose();
    t.activities = null;
    if (widget.remoteFor != null) return;
    t.dispose();
  }

  /// The computer's connection is back: a push token the server missed goes again.
  void _pushWhenOnline() {
    final t = _terminal;
    if (t != null && t.online && widget.session.pushUnsent && !_demo) unawaited(widget.session.retryPush());
  }

  Future<void> _findSupportDir() async {
    final dir = await getApplicationSupportDirectory();
    if (!mounted) return;
    _supportDir = dir;
    _syncRemote();
  }

  void _attachTerminal({required bool attach}) {
    final t = _terminal;
    if (t == null || attach == _terminalAttached || widget.remoteFor != null) return;
    _terminalAttached = attach;
    attach ? t.attach() : t.detach();
  }

  /// The list of computers, unless a session or a sheet is over it or the
  /// app is away.
  void _refreshIfInFront() {
    if (widget.desktops != null || !_resumed || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    unawaited(_desktops.refresh());
  }

  /// A session of one of the computers ([routed]: a tapped push or followed
  /// session, also one that launched the app), over that computer's list:
  /// the computer is selected as soon as it's listed, the session's page
  /// opens at once (with what this phone has of it, and the link's note:
  /// connecting…) and fills in as the computer answers. If the session
  /// isn't there after [HomePage.routedWait], or the computer says it's gone, the
  /// page goes, the list stays and a message says why.
  void _openRouted(String routed) {
    final r = splitRoutedKey(routed);
    if (r == null || !mounted) return;
    timing('deep link');
    _dropRouted();
    _routed = _Routed(r.desktop, r.key, Timer(HomePage.routedWait, _routedTimedOut));
    if (!_desktops.all.any((d) => d.id == r.desktop)) unawaited(_desktops.refresh());
    _advanceRouted();
  }

  /// The routed session one step on, as far as what's known allows: its
  /// computer selected, its page open, done once the computer lists it.
  void _advanceRouted() {
    final r = _routed;
    if (r == null || !mounted) return;
    final desktop = _desktops.all.where((d) => d.id == r.desktop).firstOrNull;
    if (desktop == null) return; // Until the list has it.
    if (r.page == null) {
      if (widget.session.computerKey(desktop.id) == null) {
        _desktops.select(desktop.id);
        return _giveUpRouted('Scan ${desktop.name}’s code to open its sessions.');
      }
      if (_desktops.selected?.id != desktop.id) return _desktops.select(desktop.id); // Comes back here.
      final t = _terminal;
      if (t == null || t.desktopId != desktop.id) return; // Until its remote is made.
      Navigator.of(context).popUntil((route) => route.isFirst);
      timing('session page');
      final page = r.page = openSession(context, t, r.key);
      r.remote = t..addListener(_advanceRouted);
      unawaited(
        page.popped.then((_) {
          if (identical(_routed, r)) _dropRouted();
        }),
      );
    }
    final t = r.remote!;
    // What the computer says now, not what this phone kept.
    if (!t.online || t.fromCache) return;
    if (t.session(r.key) != null) {
      timing('session shown');
      return _dropRouted();
    }
    _giveUpRouted('That session isn’t on ${desktop.name} anymore.');
  }

  void _routedTimedOut() {
    final r = _routed;
    if (r == null || !mounted) return;
    final name = _desktops.all.where((d) => d.id == r.desktop).firstOrNull?.name;
    _giveUpRouted(switch (r.remote?.link) {
      _ when name == null => 'That session’s computer isn’t on this server.',
      TerminalLink.unreachable => "Can't reach ${widget.session.userName}, so that session didn't open.",
      _ => "$name didn't answer in time, so that session didn't open. It opens from the list once $name answers.",
    });
  }

  /// Stops waiting for the routed session: its page goes (the list stays)
  /// and [why] shows.
  void _giveUpRouted(String why) {
    final page = _routed?.page;
    _dropRouted();
    timing('deep link gave up');
    if (page != null && page.isActive) Navigator.of(context).removeRoute(page);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
  }

  void _dropRouted() {
    final r = _routed;
    if (r == null) return;
    _routed = null;
    r.timer.cancel();
    r.remote?.removeListener(_advanceRouted);
  }

  /// Opens the session whose terminal push was tapped, if one was.
  Future<void> _openTappedSession() async {
    final key = await Native.takeTappedSession();
    if (key != null && mounted) _openRouted(key);
  }

  /// Opens the session a followed session's link named, if one did
  /// ([MobileSession.takeOpenedSession]).
  void _openLinkedSession() {
    if (widget.session.takeOpenedSession() case final key?) _openRouted(key);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Native.listen(_onNative);
    // A terminal push tap that launched the app.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_openTappedSession()));
    _desktops.addListener(_syncRemote);
    // A computer's key scanned.
    widget.session.addListener(_syncRemote);
    // A followed session's link, also the one that launched the app (before this page was there).
    widget.session.addListener(_openLinkedSession);
    WidgetsBinding.instance.addPostFrameCallback((_) => _openLinkedSession());
    _notices = widget.session.notices.listen(_tell);
    if (widget.remoteFor != null) {
      _syncRemote();
    } else {
      unawaited(_findSupportDir());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      timing('home');
      if (mounted) _refreshIfInFront();
    });
    _refreshTimer = Timer.periodic(_refreshEvery, (_) => _refreshIfInFront());
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_askForTour()));
  }

  /// The first time on the list (also the demo's), whether to have the first-use tips. Not answered (the list went
  /// with the question on it), it asks again next time.
  Future<void> _askForTour() async {
    final tips = widget.session.tips;
    if (!mounted || tips.answered) return;
    final tour = await askForTour(context);
    if (tour != null && mounted) await tips.answer(tour: tour);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _dropRouted();
    _desktops.removeListener(_syncRemote);
    widget.session
      ..removeListener(_syncRemote)
      ..removeListener(_openLinkedSession);
    unawaited(_notices.cancel());
    // After the frame that sends the pages on it away (_HomeSwitch).
    if (_terminal case final t?) SchedulerBinding.instance.addPostFrameCallback((_) => _dropRemote(t));
    if (widget.desktops == null) _desktops.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        timing('resumed');
        // Before anything asks the server: connections from before may have died while away.
        widget.session.server?.freshConnections();
        _attachTerminal(attach: true);
        _refreshIfInFront();
        unawaited(_openTappedSession());
        // Notifications may have been turned off or on in Settings meanwhile.
        if (!_demo) {
          unawaited(widget.session.checkNotifications());
          // A push token the server missed while it was unreachable.
          unawaited(widget.session.retryPush(force: true));
        }
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        if (state == AppLifecycleState.paused) timing('paused');
        _attachTerminal(attach: false);
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// From the native side (ios/Runner/AppDelegate.swift, android/…/
  /// MainActivity.kt): a terminal push was tapped, or a followed session
  /// has news, or (Android) FCM changed this phone's token.
  void _onNative(String event, Map<Object?, Object?> args) {
    if (!mounted) return;
    switch (event) {
      case 'openTerminal':
        // The session comes through takeTappedSession, once, whichever of
        // this and the resume asks first.
        unawaited(_openTappedSession());
      case 'activityToken' || 'activityEnded':
        _terminal?.activities?.onNative(event, args);
      case 'pushToken':
        unawaited(widget.session.pushTokenChanged());
    }
  }

  @override
  Widget build(BuildContext context) {
    final terminal = _terminal;
    final selected = _desktops.selected;
    return Scaffold(
      backgroundColor: C.win,
      // Nothing to start a session on until a computer answers.
      floatingActionButton: terminal == null
          ? null
          : CoachTarget(
              tip: Tip.newSession,
              radius: isIos ? 32 : 20,
              child: AddButton(tooltip: 'New session', onPressed: () => unawaited(openNewSession(context, terminal))),
            ),
      // The list runs on under the home indicator.
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageTitle(
              selected?.name ?? 'Terminal',
              onTap: () => unawaited(_pickDesktop()),
              trailing: [
                if (_demo)
                  TextButton(
                    key: const ValueKey('exit-demo'),
                    onPressed: widget.session.exitDemo,
                    child: const Text('Exit demo'),
                  )
                else
                  IconButton(
                    tooltip: 'Account',
                    onPressed: () => unawaited(_openAccount()),
                    // Reads as Account, not as the avatar's letter too ("1, Account" for 127.0.0.1).
                    icon: ExcludeSemantics(child: Avatar(name: widget.session.userName, size: 30)),
                  ),
              ],
            ),
            if (_demo) const _DemoBanner(),
            Expanded(
              child: switch (terminal) {
                final t? => TerminalList(
                  // A new list for each computer: what it scrolled and
                  // folded is that computer's.
                  key: ObjectKey(t),
                  remote: t,
                  folded: widget.session.collapsedProjects,
                  onFolded: (f) => unawaited(widget.session.setCollapsedProjects(f)),
                  sort: widget.session.projectSort,
                  onSort: (s) => unawaited(widget.session.setProjectSort(s)),
                  computer: selected?.name,
                ),
                null when selected != null && widget.session.computerKey(selected.id) == null => _Locked(
                  computer: selected.name,
                  onScan: () => unawaited(_scanComputer()),
                ),
                null => Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          selected != null
                              ? 'Reaching ${selected.name}…'
                              : _desktops.loaded
                              ? _noDesktop
                              : _desktopsError ?? 'Looking for your computers…',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: C.dim, height: 1.5),
                        ),
                        // The list didn't come: asked again now, not at the next 30-second refresh.
                        if (selected == null && _desktops.error != null && widget.desktops == null)
                          TextButton(
                            key: const ValueKey('computers-retry'),
                            onPressed: () {
                              widget.session.server?.freshConnections();
                              unawaited(_desktops.refresh());
                            },
                            child: const Text('Retry'),
                          ),
                      ],
                    ),
                  ),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Why the list of computers didn't come, if it didn't: a server the phone
  /// can't reach says what to do.
  String? get _desktopsError => switch ((_desktops.error, widget.session.backend)) {
    (final e?, final b?) when e == b.unreachable => serverUnreachable(b),
    (final e, _) => e,
  };

  /// A computer's code, scanned while signed in: this phone gets that
  /// computer's key ([Session.connectLink]); a problem with the code shows
  /// as a notice ([_tell]).
  Future<void> _scanComputer() async {
    final link = await scanSetupCode(context, signedIn: true);
    if (link == null || !mounted) return;
    _told = false;
    await widget.session.connectLink(link, scanned: true);
    if (!mounted || _told) return;
    final selected = _desktops.selected;
    if (selected != null && widget.session.computerKey(selected.id) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('That code is for another computer. Scan the one ${selected.name} shows.')),
      );
    }
  }

  /// Why the server lists no computer.
  static const _noDesktop =
      "Your computer isn't reporting to this server. Open PocketTerm on it and turn on Terminal from phone in its "
      'Settings.';

  /// The account's computers, to show another one's sessions.
  Future<void> _pickDesktop() {
    if (widget.desktops == null) unawaited(_desktops.refresh());
    return showAppSheet<void>(
      context,
      builder: (sheet) => SafeArea(
        child: ListenableBuilder(
          listenable: _desktops,
          // The title stays; many computers scroll under it.
          builder: (_, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, sheetTop, 20, 8),
                child: Text('Computers', style: sheetTitleStyle),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    if (_desktops.all.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                        child: Text(
                          _desktops.loaded ? _noDesktop : _desktopsError ?? 'Looking for your computers…',
                          style: const TextStyle(color: C.dim, height: 1.5),
                        ),
                      ),
                    for (final d in _desktops.all)
                      ListTile(
                        key: ValueKey('desktop-${d.id}'),
                        leading: Icon(d.windows ? Icons.desktop_windows : Icons.laptop_mac, color: C.dim),
                        title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: widget.session.computerKey(d.id) == null
                            ? const Text('Locked: scan its code', style: TextStyle(color: C.warn))
                            : Text(
                                d.online ? 'Online' : 'Seen ${ago(d.seenAt)}',
                                style: TextStyle(color: d.online ? C.accent : C.dim),
                              ),
                        trailing: d.id == _desktops.selected?.id ? const Icon(Icons.check, color: C.accent) : null,
                        onTap: () {
                          Navigator.of(sheet).pop();
                          _desktops.select(d.id);
                        },
                      ),
                    ListTile(
                      key: const ValueKey('scan-computer'),
                      leading: const Icon(Icons.qr_code_scanner, color: C.dim),
                      title: const Text('Scan a computer’s code'),
                      onTap: () {
                        Navigator.of(sheet).pop();
                        unawaited(_scanComputer());
                      },
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAccount() {
    // A token the server missed: try now, so the sheet shows how it stands, not how it stood.
    unawaited(widget.session.retryPush(force: true));
    return _accountSheet();
  }

  Future<void> _accountSheet() => showAppSheet<void>(
    context,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, sheetTop, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Avatar(name: widget.session.userName, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.session.userName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                      const Text('Signed in with your computer\u2019s code', style: TextStyle(color: C.dim)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ListenableBuilder(
              listenable: widget.session,
              builder: (_, _) {
                final on = widget.session.pushEnabled ?? false;
                // On here, off in the phone's Settings (changed there after saying yes): nothing shows.
                final blocked = on && widget.session.notificationsAllowed == false;
                final registering = on && !blocked && widget.session.pushRegistering;
                final unsent = on && !blocked && !registering && widget.session.pushUnsent;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey('push-toggle'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Notifications'),
                      subtitle: registering
                          ? const Row(
                              key: ValueKey('push-registering'),
                              children: [
                                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                                SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    'Registering this phone with your server…',
                                    style: TextStyle(color: C.dim),
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              blocked
                                  ? pushBlocked
                                  : unsent
                                  ? pushNotSent
                                  : on
                                  ? 'Encrypted, through the push relay at push.danyzmaj.com.'
                                  : isIos
                                  ? 'Off: no notifications and no Lock Screen sessions.'
                                  : 'Off: no notifications and no followed sessions.',
                              style: TextStyle(color: blocked || unsent ? C.warn : C.dim, height: 1.4),
                            ),
                      value: on,
                      onChanged: (on) async {
                        final messenger = ScaffoldMessenger.of(sheet);
                        if (!await widget.session.setPushEnabled(on: on) && on) {
                          messenger.showSnackBar(pushNotAllowedSnackBar(allowed: widget.session.notificationsAllowed));
                        }
                      },
                    ),
                    if (blocked)
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton(
                          key: const ValueKey('push-settings'),
                          onPressed: () => unawaited(Native.openSettings(notifications: true)),
                          child: const Text('Open Settings'),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () async {
                final go = await confirmDanger(
                  sheet,
                  title: 'Leave this server?',
                  body:
                      'This phone signs out of ${widget.session.userName} and forgets its computers\u2019 keys. '
                      'To come back, scan a computer\u2019s code again.',
                  action: 'Leave',
                );
                if (!go) return;
                if (sheet.mounted) Navigator.of(sheet).pop();
                unawaited(widget.session.signOut());
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFCA5A5),
                side: const BorderSide(color: C.line2),
              ),
              child: const Text('Leave this server'),
            ),
            const Divider(height: 20, color: C.line2),
            TextButton.icon(
              key: const ValueKey('show-tips'),
              onPressed: () {
                Navigator.of(sheet).pop();
                unawaited(widget.session.tips.reset());
              },
              style: TextButton.styleFrom(foregroundColor: C.dim),
              icon: const Icon(Icons.lightbulb_outline, size: 15),
              label: const Text('Show tips again'),
            ),
            TextButton.icon(
              key: const ValueKey('source-code'),
              onPressed: () => openExternal(repoUrl),
              style: TextButton.styleFrom(foregroundColor: C.dim),
              icon: const Icon(Icons.open_in_new, size: 15),
              label: const Text('PocketTerm is open source: GitHub'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A tapped session on its way to showing ([_HomePageState._openRouted]):
/// computer [desktop]'s session [key], given up when [timer] fires; its
/// [page] once open, on [remote].
class _Routed {
  _Routed(this.desktop, this.key, this.timer);
  final String desktop;
  final String key;
  final Timer timer;
  Route<void>? page;
  TerminalRemote? remote;
}

/// What the app shows at its root ([id]: setup, the demo, the push
/// question, a sign-in). Pages and sheets opened over one belong to it: when
/// it changes (signed out here or by the computer, the demo left) they go
/// too, instead of staying over the new one with a computer that's gone.
class _HomeSwitch extends StatefulWidget {
  const _HomeSwitch({required this.id, required this.child});
  final Object id;
  final Widget child;

  @override
  State<_HomeSwitch> createState() => _HomeSwitchState();
}

class _HomeSwitchState extends State<_HomeSwitch> {
  @override
  void didUpdateWidget(_HomeSwitch old) {
    super.didUpdateWidget(old);
    if (old.id == widget.id) return;
    final navigator = Navigator.of(context);
    // Not while building.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) navigator.popUntil((r) => r.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Says the demo is one, under the computer's title.
class _DemoBanner extends StatelessWidget {
  const _DemoBanner();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: C.accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: C.accent.withValues(alpha: 0.35)),
    ),
    child: const Row(
      children: [
        Text(
          'DEMO',
          style: TextStyle(color: C.accent, fontWeight: FontWeight.w700, fontSize: 12, letterSpacing: 1),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            'Made-up sessions on a pretend computer. Nothing leaves this phone.',
            style: TextStyle(color: C.dim, fontSize: 13, height: 1.35),
          ),
        ),
      ],
    ),
  );
}

/// The selected computer, while this phone has no key for it: nothing from
/// it shows and nothing goes to it until its code is scanned.
class _Locked extends StatelessWidget {
  const _Locked({required this.computer, required this.onScan});
  final String computer;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, color: C.dim, size: 36),
          const SizedBox(height: 14),
          const Text(
            'Scan this computer’s code to connect',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Its sessions are end-to-end encrypted with a key only its code holds. '
            'On $computer, open Settings → Phone → Add a phone…',
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.dim, height: 1.5),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('scan-locked-computer'),
            onPressed: onScan,
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('Scan'),
          ),
        ],
      ),
    ),
  );
}
