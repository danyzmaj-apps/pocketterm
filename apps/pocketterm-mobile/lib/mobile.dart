import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketterm_core/account.dart' show Avatar;
import 'package:pocketterm_core/live_activity.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/chrome.dart';
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
  const MobileApp({required this.session, @visibleForTesting this.terminal, super.key});
  final MobileSession session;

  /// See [HomePage.terminal].
  final TerminalRemote? terminal;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PocketTerm',
    debugShowCheckedModeBanner: false,
    theme: _theme(appTheme()),
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
        return HomePage(session: session, userId: user.id, terminal: terminal);
      },
    ),
  );

  static ThemeData _theme(ThemeData base) => base.copyWith(
    scaffoldBackgroundColor: screenColor,
    // Rows show they were pressed: the iOS cell highlight, Android's ink.
    splashFactory: isIos ? NoSplash.splashFactory : InkSparkle.splashFactory,
    highlightColor: const Color(0x14FFFFFF),
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

/// The signed-in phone: the computer's coding sessions and terminal
/// windows, with a + for a new session.
class HomePage extends StatefulWidget {
  const HomePage({required this.session, required this.userId, @visibleForTesting this.terminal, super.key});
  final MobileSession session;
  final String userId;

  /// A remote fed by hand (tests, screenshots); otherwise the home page
  /// joins the computer over the session's server.
  final TerminalRemote? terminal;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  StreamSubscription<Uri>? _links;

  /// The computer's coding sessions and terminal windows, through PocketTerm
  /// there; live while the app is in front. Null until its cache folder is
  /// known.
  TerminalRemote? _terminal;
  bool _terminalAttached = false;

  /// A tapped terminal push's session, waiting for [_terminal].
  String? _sessionToOpen;

  Future<void> _startTerminal() async {
    final dir = await getApplicationSupportDirectory();
    if (!mounted) return;
    final remote = TerminalRemote(widget.session.client, widget.userId, Directory('${dir.path}/terminal'));
    remote.activities = LiveActivities(widget.session.client, remote);
    setState(() => _terminal = remote);
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) _attachTerminal(attach: true);
    final key = _sessionToOpen;
    _sessionToOpen = null;
    if (key != null) _openSession(key);
  }

  void _attachTerminal({required bool attach}) {
    final t = _terminal;
    if (t == null || attach == _terminalAttached || widget.terminal != null) return;
    _terminalAttached = attach;
    attach ? t.attach() : t.detach();
  }

  /// Coding session [key] (from a tapped push or Live Activity), over the
  /// Terminal list.
  void _openSession(String key) {
    final t = _terminal;
    if (t == null) {
      _sessionToOpen = key;
      return;
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
    openSession(context, t, key);
  }

  /// Opens the session whose terminal push was tapped, if one was.
  Future<void> _openTappedSession() async {
    final key = await Native.takeTappedSession();
    if (key != null && mounted) _openSession(key);
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
    if (widget.terminal case final t?) {
      _terminal = t;
    } else {
      unawaited(_startTerminal());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_links?.cancel());
    if (widget.terminal == null) {
      _terminal?.activities?.dispose();
      _terminal?.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _attachTerminal(attach: true);
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
    if (key != null && key.isNotEmpty) _openSession(key);
  }

  @override
  Widget build(BuildContext context) {
    final terminal = _terminal;
    return Scaffold(
      backgroundColor: screenColor,
      floatingActionButton: AddButton(
        tooltip: 'New session',
        onPressed: terminal == null ? null : () => unawaited(openNewSession(context, terminal)),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageTitle(
              'Terminal',
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
                  remote: t,
                  folded: widget.session.collapsedProjects,
                  onFolded: (f) => unawaited(widget.session.setCollapsedProjects(f)),
                ),
                null => const Center(
                  child: Text('Reaching your computer…', style: TextStyle(color: C.dim)),
                ),
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAccount() => showAppSheet<void>(
    context,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
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
          ],
        ),
      ),
    ),
  );
}
