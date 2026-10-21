import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketterm_core/account.dart' show Avatar;
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/live.dart';
import 'package:pocketterm_core/live_activity.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
import 'package:pocketterm_mobile/coach.dart';
import 'package:pocketterm_mobile/links.dart';
import 'package:pocketterm_mobile/setup_page.dart';
import 'package:pocketterm_mobile/terminal_view.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

/// The phone side of [Session]: registers this phone for the computer's
/// terminal pushes, and ends the sessions it follows when the account
/// leaves it. The push key travels through what the native side shares
/// (ios/Shared/PocketTermShared.swift, android/…/PocketTermShared.kt).
class MobileSession extends Session {
  MobileSession(this._prefs, super.device);

  final SharedPreferences _prefs;

  /// A phone signs in only with a code from the computer (functions/pair).
  @override
  bool get signsInWithGithub => false;

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
      client,
      cached: cached,
      saved: _prefs.getString(_desktopKey),
      onChanged: (all, selected) {
        unawaited(_prefs.setString(_desktopsKey, jsonEncode([for (final d in all) d.toJson()])));
        unawaited(selected == null ? _prefs.remove(_desktopKey) : _prefs.setString(_desktopKey, selected));
      },
    );
  }

  @override
  Future<void> onSignedIn(User user) => _registerPush(user.id);

  static const _pushTokenKey = 'pocketterm_push_token';

  /// Hands this phone's push token (APNs on iOS, FCM on Android) and push
  /// key to the user's server, which from then on pushes the computer's
  /// terminal news (functions/push).
  Future<void> _registerPush(String userId) async {
    try {
      final push = await Native.registerPush();
      if (push == null || user?.id != userId) return;
      await client.functions.invoke(
        'push',
        body: {'action': 'register', 'token': push.token, 'key': push.key, 'label': device, 'platform': pushPlatform},
      );
      await _prefs.setString(_pushTokenKey, push.token);
    } on Object catch (e) {
      debugPrint('PocketTerm: push registration failed: $e');
    }
  }

  /// Android: FCM handed over a new token (`pushToken`); the server needs it.
  Future<void> pushTokenChanged() async {
    final user = this.user;
    if (user != null) await _registerPush(user.id);
  }

  @override
  Future<void> onSigningOut({required bool accountDeleted}) async {
    final pushToken = _prefs.getString(_pushTokenKey);
    final activities = await _forgetHere();
    // The followed sessions are this account's: the server stops updating
    // them too (iOS gives each its own token, which 'unregister' below
    // doesn't know).
    for (final a in activities) {
      if (a.token case final activityToken? when !accountDeleted) {
        await _tryServer(
          'activity end',
          () => client.functions.invoke(
            'push',
            body: {'action': 'activity_end', 'token': activityToken, 'session': a.key},
          ),
        );
      }
    }
    // A deleted account took its tokens with it.
    if (accountDeleted || pushToken == null) return;
    await _tryServer(
      'push unregister',
      () => client.functions.invoke('push', body: {'action': 'unregister', 'token': pushToken}),
    );
  }

  /// However the account went, also without [signOut] here (the server
  /// refused a refresh, the account was deleted on another device, the
  /// reviewer access ended): its followed sessions leave this phone.
  @override
  Future<void> onSignedOut() async {
    await _forgetHere();
  }

  /// Drops what this phone keeps for the account: the push registration's
  /// record, and the followed sessions, ended at once. Returns those
  /// sessions.
  Future<List<({String key, String? token})>> _forgetHere() async {
    await _prefs.remove(_pushTokenKey);
    await _prefs.remove(_desktopKey);
    await _prefs.remove(_desktopsKey);
    final activities = await Native.liveActivities();
    for (final a in activities) {
      await Native.endActivity(a.key, immediate: true);
    }
    return activities;
  }

  /// One server call of the sign-out; a failed one (offline) doesn't stop
  /// the rest.
  Future<void> _tryServer(String what, Future<Object?> Function() call) async {
    try {
      await call();
    } on Object catch (e) {
      debugPrint('PocketTerm: $what at sign-out failed: $e');
    }
  }
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
  final TerminalRemote Function(String desktopId)? remoteFor;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PocketTerm',
    debugShowCheckedModeBanner: false,
    theme: _theme(appTheme()),
    builder: (context, child) => Coach(controller: session.tips, child: child!),
    // No session, no app: only the computer's code gets a phone in.
    home: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final user = session.user;
        if (user == null) {
          return Scaffold(
            body: SafeArea(child: SetupPage(session: session)),
          );
        }
        return HomePage(session: session, userId: user.id, desktops: desktops, remoteFor: remoteFor);
      },
    ),
  );

  static ThemeData _theme(ThemeData base) => base.copyWith(
    scaffoldBackgroundColor: C.win,
    // Rows show they were pressed: on iPhone a soft highlight with no ripple, as iOS's cells do; on Android
    // Material's ink. Either way it's clipped to the card, pill or circle it presses.
    splashFactory: isIos ? NoSplash.splashFactory : InkSparkle.splashFactory,
    highlightColor: const Color(0x14FFFFFF),
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
  /// server.
  final TerminalRemote Function(String desktopId)? remoteFor;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  StreamSubscription<Uri>? _links;

  late final Desktops _desktops = widget.desktops ?? widget.session.desktops();

  /// While the Terminal list is in front, the list of computers is fetched
  /// this often (and on coming to the front).
  static const _refreshEvery = Duration(seconds: 30);
  Timer? _refreshTimer;

  /// Where remotes keep their caches; null until known.
  Directory? _supportDir;

  /// The selected computer's coding sessions and terminal windows, through
  /// PocketTerm there; live while the app is in front. Null with no
  /// computer, and until its cache folder is known.
  TerminalRemote? _terminal;
  bool _terminalAttached = false;

  /// A tapped push's or link's session, waiting for its computer's remote.
  ({String desktop, String key})? _sessionToOpen;

  bool get _resumed {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// One remote, for the selected computer: another computer selected, the
  /// old one goes (with any page on it) and a new one comes.
  void _syncRemote() {
    final d = _desktops.selected;
    final old = _terminal;
    if (old != null && old.desktopId == d?.id) {
      old.desktopName = d?.name;
      return;
    }
    TerminalRemote? next;
    if (d != null) {
      if (widget.remoteFor case final make?) {
        next = make(d.id);
      } else if (_supportDir case final dir?) {
        next = TerminalRemote(widget.session.client, widget.userId, dir, desktopId: d.id);
        next.activities = LiveActivities(widget.session.client, next);
      } else {
        return; // Made once the cache folder is known.
      }
      next.desktopName = d.name;
    }
    if (old != null) {
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      _dropRemote(old);
    }
    _terminal = next;
    if (mounted) setState(() {});
    if (next == null) return;
    if (_resumed) _attachTerminal(attach: true);
    if (_sessionToOpen case (:final desktop, :final key) when desktop == next.desktopId) {
      _sessionToOpen = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openSession(desktop, key);
      });
    }
  }

  void _dropRemote(TerminalRemote t) {
    _terminalAttached = false;
    if (widget.remoteFor != null) return;
    t.activities?.dispose();
    t.dispose();
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

  /// A session of one of the computers ([routed]: a tapped push or Live
  /// Activity), over the Terminal list of that computer. One on no computer
  /// listed opens nothing.
  Future<void> _openRouted(String routed) async {
    final r = splitRoutedKey(routed);
    if (r == null) return;
    if (!_desktops.all.any((d) => d.id == r.desktop)) await _desktops.refresh();
    if (!mounted || !_desktops.all.any((d) => d.id == r.desktop)) return;
    _desktops.select(r.desktop);
    _openSession(r.desktop, r.key);
  }

  void _openSession(String desktop, String key) {
    final t = _terminal;
    if (t == null || t.desktopId != desktop) {
      _sessionToOpen = (desktop: desktop, key: key);
      return;
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
    openSession(context, t, key);
  }

  /// Opens the session whose terminal push was tapped, if one was.
  Future<void> _openTappedSession() async {
    final key = await Native.takeTappedSession();
    if (key != null && mounted) await _openRouted(key);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A followed session (Live Activity, Android's ongoing notification)
    // opens pocketterm://session?key=…. The stream also carries the link
    // that cold-started the app, so getInitialLink() would handle it twice.
    _links = AppLinks().uriLinkStream.listen(_onLink);
    Native.listen(_onNative);
    // A terminal push tap that launched the app.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_openTappedSession()));
    _desktops.addListener(_syncRemote);
    if (widget.remoteFor != null) {
      _syncRemote();
    } else {
      unawaited(_findSupportDir());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshIfInFront();
    });
    _refreshTimer = Timer.periodic(_refreshEvery, (_) => _refreshIfInFront());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_links?.cancel());
    _refreshTimer?.cancel();
    _desktops.removeListener(_syncRemote);
    if (_terminal case final t?) _dropRemote(t);
    if (widget.desktops == null) _desktops.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _attachTerminal(attach: true);
        _refreshIfInFront();
        unawaited(_openTappedSession());
      case AppLifecycleState.hidden || AppLifecycleState.paused:
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

  void _onLink(Uri? uri) {
    if (uri == null || uri.scheme != 'pocketterm' || uri.host != 'session' || !mounted) return;
    final key = uri.queryParameters['key'];
    if (key != null && key.isNotEmpty) unawaited(_openRouted(key));
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
                IconButton(
                  tooltip: 'Account',
                  onPressed: () => unawaited(_openAccount()),
                  icon: Avatar(url: widget.session.avatarUrl, name: widget.session.userName, size: 30),
                ),
              ],
            ),
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
                null => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      selected != null
                          ? 'Reaching ${selected.name}…'
                          : _desktops.loaded
                          ? _noDesktop
                          : 'Looking for your computers…',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: C.dim, height: 1.5),
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

  /// Why the account lists no computer: the store reviewers' demo account
  /// has none by design; anyone else's computer isn't registering.
  String get _noDesktop => widget.session.user?.appMetadata['pocketterm_demo'] == true
      ? 'This is a demo account for App Store and Google Play review. It has no computer; '
            "on a real account your computer's coding sessions show here."
      : "Your computer isn't reporting to this account. "
            'Open PocketTerm on it and turn on Terminal from phone in its Settings.';

  /// The account's computers, to show another one's sessions.
  Future<void> _pickDesktop() {
    if (widget.desktops == null) unawaited(_desktops.refresh());
    return showAppSheet<void>(
      context,
      builder: (sheet) => SafeArea(
        child: ListenableBuilder(
          listenable: _desktops,
          builder: (_, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, sheetTop, 20, 8),
                child: Text('Computers', style: sheetTitleStyle),
              ),
              if (_desktops.all.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                  child: Text(_noDesktop, style: const TextStyle(color: C.dim, height: 1.5)),
                ),
              for (final d in _desktops.all)
                ListTile(
                  key: ValueKey('desktop-${d.id}'),
                  leading: Icon(d.windows ? Icons.desktop_windows : Icons.laptop_mac, color: C.dim),
                  title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    d.online ? 'Online' : 'Seen ${ago(d.seenAt)}',
                    style: TextStyle(color: d.online ? C.accent : C.dim),
                  ),
                  trailing: d.id == _desktops.selected?.id ? const Icon(Icons.check, color: C.accent) : null,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    _desktops.select(d.id);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAccount() => showAppSheet<void>(
    context,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, sheetTop, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Avatar(url: widget.session.avatarUrl, name: widget.session.userName, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.session.userName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const Text('Signed in with your computer\u2019s code', style: TextStyle(color: C.dim)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () {
                Navigator.of(sheet).pop();
                unawaited(widget.session.signOut());
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFCA5A5),
                side: const BorderSide(color: C.line2),
              ),
              child: const Text('Sign out'),
            ),
            TextButton(
              onPressed: () async {
                if (!await confirmDeleteAccount(sheet)) return;
                if (sheet.mounted) Navigator.of(sheet).pop();
                try {
                  await widget.session.deleteAccount();
                } on Object catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Account not deleted: $e')));
                  }
                }
              },
              style: TextButton.styleFrom(foregroundColor: C.dim2),
              child: const Text('Delete account…'),
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
