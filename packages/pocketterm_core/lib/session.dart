import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/live.dart' show imageBucket;
import 'package:supabase_flutter/supabase_flutter.dart';

/// The connected [Backend] and signing in (GitHub on the computer, the
/// computer's code on a phone): what the desktop and the phone apps share.
class Session extends ChangeNotifier {
  Session(this.device);

  static const _redirect = 'pocketterm://login-callback';

  /// Whether this device signs in with GitHub (the computer). A phone doesn't:
  /// it signs in only with a code from the computer (functions/pair), so it neither
  /// needs GitHub on its server nor handles OAuth callbacks.
  bool get signsInWithGithub => true;

  /// The Supabase project this device connects through; null until one is set
  /// up (the setup screen shows then).
  Backend? get backend => _backend;
  Backend? _backend;

  /// Only while [backend] is set.
  SupabaseClient get client => Supabase.instance.client;

  /// This machine's name: the label of its push registration.
  final String device;

  /// The signed-in user; null while signed out.
  User? get user => _user;
  User? _user;
  StreamSubscription<AuthState>? _auth;

  String? authError;

  /// Why the last user is gone, once they are (signed out here, the server
  /// ended the session, the account was deleted); null after a sign-in. The
  /// phone shows it on its scan screen.
  String? get signedOutReason => _signedOutReason;
  String? _signedOutReason;

  /// Set by [signOut] and [deleteAccount] just before the user goes.
  String? _leaving;

  /// Launch: opens the backend this device was set up with, if any, and
  /// listens for setup links (`pocketterm://setup?url=…&key=…[&code=…]`).
  Future<void> start() async {
    final saved = Backend.load();
    _links = AppLinks().uriLinkStream.listen((uri) async => openedLink(uri, await saved));
    final backend = await saved;
    if (backend != null) await connect(backend);
  }

  StreamSubscription<Uri>? _links;

  /// A setup link opened from outside the app (a web page, a message, the
  /// camera app). One that would connect this signed-out device to a server
  /// other than its own ([saved] until [connect] is done) waits for the
  /// person ([linkToConfirm]): anyone can send a link, and this device's
  /// sessions would then go through that server.
  @visibleForTesting
  void openedLink(Uri uri, Backend? saved) {
    final backend = Backend.fromLink(uri);
    if (backend == null) return;
    if (_user == null && backend != (_backend ?? saved)) {
      _linkToConfirm = uri;
      notifyListeners();
      onLinkToConfirm();
      return;
    }
    unawaited(connectLink(uri));
  }

  /// A setup link to another server, waiting for [answerLink].
  Uri? get linkToConfirm => _linkToConfirm;
  Uri? _linkToConfirm;

  /// The person's answer to [linkToConfirm]: [connect] goes on with it.
  Future<void> answerLink({required bool connect}) async {
    final uri = _linkToConfirm;
    _linkToConfirm = null;
    notifyListeners();
    if (connect && uri != null) await connectLink(uri);
  }

  /// A link now waits in [linkToConfirm]: the computer brings its window up.
  @protected
  void onLinkToConfirm() {}

  /// A setup link: connects to its server and, with a sign-in code (the
  /// computer's QR), signs in too. A phone takes only links with a code. Problems
  /// land in [authError].
  Future<void> connectLink(Uri uri) async {
    final backend = Backend.fromLink(uri);
    if (backend == null) return;
    final code = Backend.pairingCode(uri);
    if (_user != null) {
      if (backend != _backend) authError = 'Sign out before switching to ${backend.host}.';
      notifyListeners();
      return;
    }
    if (code == null && !signsInWithGithub) {
      authError = 'That link has no sign-in code. On your computer, open PocketTerm: Settings → Set up phone…';
      notifyListeners();
      return;
    }
    if (backend != _backend) {
      final problem = await backend.check(github: signsInWithGithub);
      if (problem != null) {
        authError = problem;
        notifyListeners();
        return;
      }
      await connect(backend);
    }
    if (code == null) return;
    authError = null;
    notifyListeners();
    try {
      final data = (await client.functions.invoke('pair', body: {'action': 'redeem', 'code': code})).data;
      if (data case {'token_hash': final String hash}) {
        await client.auth.verifyOTP(type: OtpType.magiclink, tokenHash: hash);
        return;
      }
      authError = _serverTooOld;
    } on FunctionException catch (e) {
      authError = switch (e) {
        // A server from before codes: no function, or the old one that
        // wanted a signed-in caller.
        FunctionException(status: 404 || 401) => _serverTooOld,
        _ => pairingProblem(e),
      };
    } on AuthException {
      authError = 'That code was used up while signing in. Make a new one on your computer (Settings → Set up phone…).';
    } on Object catch (e) {
      authError = 'Sign-in failed: $e';
    }
    notifyListeners();
  }

  static const _serverTooOld =
      'Your server is older than this app. Update it from your computer (docs/SELF_HOSTING.md), then make a new code.';

  /// A setup link that also signs a new device in (functions/pair, action
  /// create): works once, for 10 minutes. Only while signed in. Fails with a
  /// [PairingException] that says why.
  Future<Uri> pairingLink() async {
    final data = await _pair({'action': 'create'});
    if (data case {'code': final String code}) return _backend!.linkWithCode(code);
    throw const PairingException("The server didn't send a code. Update it (docs/SELF_HOSTING.md), then retry.");
  }

  /// A reusable code for App Store / Play review (functions/pair, action
  /// reviewer): signs into this server's separate demo account, not this
  /// user's, for [days]. Its [ReviewerCode.link] is known only now.
  Future<ReviewerCode> createReviewerCode({required int days, String label = ''}) async {
    final data = await _pair({'action': 'reviewer', 'days': days, 'label': label});
    if (data case {'code': final String code} when data is Map<String, dynamic>) {
      return ReviewerCode.fromJson(data, link: _backend!.linkWithCode(code));
    }
    throw const PairingException("The server didn't send a code. Update it (docs/SELF_HOSTING.md), then retry.");
  }

  /// This user's reviewer codes that still work, newest first.
  Future<List<ReviewerCode>> reviewerCodes() async {
    final data = await _pair({'action': 'list'});
    if (data case {'codes': final List<dynamic> codes}) {
      return [for (final c in codes.whereType<Map<String, dynamic>>()) ReviewerCode.fromJson(c)];
    }
    throw const PairingException("The server didn't list the codes. Update it (docs/SELF_HOSTING.md), then retry.");
  }

  /// Stops reviewer code [id] from working.
  Future<void> revokeReviewerCode(String id) => _pair({'action': 'revoke', 'id': id});

  Future<Object?> _pair(Map<String, Object> body) async {
    try {
      return (await client.functions.invoke('pair', body: body)).data;
    } on Object catch (e) {
      throw PairingException(pairingProblem(e));
    }
  }

  /// Opens [backend] (and remembers it): the one saved at launch, the setup
  /// screen's, or a setup link's. Switching needs the user signed out.
  Future<void> connect(Backend backend) async {
    if (_user != null) throw StateError('Sign out before switching projects.');
    await _close();
    await Supabase.initialize(
      url: backend.url,
      publishableKey: backend.key,
      // A phone never takes an OAuth callback: it signs in with codes only.
      authOptions: FlutterAuthClientOptions(detectSessionInUri: signsInWithGithub),
    );
    await backend.save();
    _backend = backend;
    authError = null;
    notifyListeners();
    _auth = client.auth.onAuthStateChange.listen(
      (s) {
        // The server refused to refresh the session (signed out elsewhere,
        // account deleted, refresh token revoked or expired).
        if (s.signOutReason case SignOutReason.sessionExpired || SignOutReason.sessionMissing) {
          _leaving ??= 'Your sign-in ended on the server. Scan a new code from PocketTerm on your computer.';
        }
        _setUser(s.session?.user);
      },
      // A failed OAuth callback (expired code, sign-up refused) lands here.
      onError: (Object e) {
        authError = e is AuthException ? e.message : 'Sign-in failed: $e';
        notifyListeners();
      },
    );
    final hadSession = client.auth.currentSession != null;
    await _freshSession();
    // Refused while restoring at launch, before anything was listening.
    if (hadSession && client.auth.currentSession == null) {
      _leaving ??= 'Your sign-in ended on the server. Scan a new code from PocketTerm on your computer.';
    }
    _setUser(client.auth.currentUser);
  }

  /// Makes the restored session good for Realtime before anything joins a
  /// channel (the terminal channel's private topic). supabase_flutter hands
  /// the token to Realtime only after `initialize` returns, and not at all
  /// when it expired while the app was closed; a channel joined before that
  /// joins as nobody, and a private one then never hears a thing (the
  /// phone's Terminal tab spun forever).
  Future<void> _freshSession() async {
    final session = client.auth.currentSession;
    if (session == null) return;
    try {
      if (session.isExpired) await client.auth.refreshSession();
      await client.realtime.setAuth(client.auth.currentSession?.accessToken);
    } on Object catch (e) {
      // Offline: the next refresh catches up.
      debugPrint('PocketTerm: session not refreshed: $e');
    }
  }

  /// Signs out and forgets the backend: the setup screen shows again.
  Future<void> disconnect() async {
    if (_user != null) await signOut();
    await _close();
    await Backend.clear();
    _backend = null;
    authError = null;
    notifyListeners();
  }

  Future<void> _close() async {
    if (_backend == null) return;
    await _auth?.cancel();
    _auth = null;
    _reviewerTimer?.cancel();
    _reviewerTimer = null;
    await Supabase.instance.dispose();
  }

  /// Runs once a user is signed in (sign-in, or launch while signed in).
  @protected
  Future<void> onSignedIn(User user) async {}

  /// Runs before signing out, while the session can still reach the server.
  /// [accountDeleted]: the server forgot this user already, so there is
  /// nothing to unregister there.
  @protected
  Future<void> onSigningOut({required bool accountDeleted}) async {}

  /// Runs once the user is gone, however that happened (signed out here,
  /// the server ended the session, the account was deleted).
  @protected
  Future<void> onSignedOut() async {}

  /// The auth stream's initial event and [connect]'s own check both arrive
  /// at launch: only a change of user runs [onSignedIn] or [onSignedOut].
  void _setUser(User? user) {
    final reason = _signedOutReason;
    if (user != null) {
      _signedOutReason = _leaving = null;
      _linkToConfirm = null;
    } else if (_user != null || _leaving != null) {
      _signedOutReason = _leaving ?? 'Your sign-in ended. Scan a new code from PocketTerm on your computer.';
      _leaving = null;
    }
    if (user?.id == _user?.id) {
      _user = user ?? _user;
      if (_signedOutReason != reason) notifyListeners();
      return;
    }
    _user = user;
    _reviewerTimer?.cancel();
    _reviewerTimer = user?.appMetadata['pocketterm_demo'] == true
        ? Timer.periodic(reviewerCheck, (_) => unawaited(checkReviewerAccess()))
        : null;
    unawaited(user != null ? onSignedIn(user) : onSignedOut());
    notifyListeners();
  }

  /// How often the reviewer demo account's device asks whether its session
  /// still exists.
  static const reviewerCheck = Duration(seconds: 30);
  Timer? _reviewerTimer;

  /// The server ends the demo account's sessions the moment its last
  /// reviewer code stops working (public.end_idle_demo_sessions), but the
  /// access token it already holds would keep it signed in here until it
  /// expires, up to an hour. Signs out here once the server no longer knows
  /// the session; no answer (offline) proves nothing.
  @visibleForTesting
  Future<void> checkReviewerAccess() async {
    try {
      await client.auth.getUser();
    } on AuthException catch (e) {
      if (e.statusCode != '401' && e.statusCode != '403') return;
      _leaving ??= "This reviewer access has ended. Ask the server's owner for a new reviewer code.";
      await client.auth.signOut();
    } on Object catch (e) {
      debugPrint('PocketTerm: reviewer access not checked: $e');
    }
  }

  Future<void> signIn() async {
    authError = null;
    notifyListeners();
    try {
      await client.auth.signInWithOAuth(
        OAuthProvider.github,
        redirectTo: _redirect,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
    } on Object catch (e) {
      authError = 'Could not start GitHub sign-in: $e';
      notifyListeners();
    }
  }

  /// Signs out here. The local session goes even when [onSigningOut] or the
  /// server fails (offline, an account deleted a moment ago): gotrue drops
  /// it before it calls the server.
  Future<void> signOut() async {
    _leaving ??= 'You signed out.';
    final accountDeleted = _accountDeleted;
    _accountDeleted = false;
    try {
      await onSigningOut(accountDeleted: accountDeleted);
    } on Object catch (e) {
      debugPrint('PocketTerm: sign-out cleanup failed: $e');
    }
    try {
      await client.auth.signOut();
    } on Object catch (e) {
      debugPrint('PocketTerm: the server missed the sign-out: $e');
    }
    _setUser(null);
  }

  /// Set by [deleteAccount] for the [signOut] that follows.
  bool _accountDeleted = false;

  /// Deletes the account on the server with everything in it (the images
  /// sent to sessions, push registrations, pairing codes), and signs out.
  /// Images that can't be removed stop it before anything else goes: once
  /// the account is gone, nobody could reach them again.
  Future<void> deleteAccount() async {
    final id = _user?.id;
    if (id == null) return;
    // Storage objects aren't tied to the user by a foreign key.
    final bucket = client.storage.from(imageBucket);
    try {
      while (true) {
        final files = await bucket.list(path: id, searchOptions: const SearchOptions(limit: 1000));
        if (files.isEmpty) break;
        await bucket.remove([for (final f in files) '$id/${f.name}']);
      }
    } on Object catch (e) {
      debugPrint('PocketTerm: $imageBucket images not removed: $e');
      throw const AccountDeletionException(
        "Your images couldn't be removed from your server, so your account stays. "
        'Check your connection and try again.',
      );
    }
    await client.rpc<void>('delete_my_account');
    _leaving = 'Your account was deleted.';
    _accountDeleted = true;
    await signOut();
  }

  String get userName {
    final meta = _user?.userMetadata ?? const {};
    return (meta['user_name'] ?? meta['preferred_username'] ?? meta['name'] ?? _user?.email ?? 'you') as String;
  }

  String? get avatarUrl => _user?.userMetadata?['avatar_url'] as String?;

  @override
  void dispose() {
    unawaited(_auth?.cancel());
    unawaited(_links?.cancel());
    super.dispose();
  }
}

/// Why [Session.deleteAccount] stopped before deleting the account, worded
/// for the person.
class AccountDeletionException implements Exception {
  const AccountDeletionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Why a pairing or reviewer code couldn't be made (or listed, or revoked),
/// worded for the person.
class PairingException implements Exception {
  const PairingException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A reusable code for App Store / Play review: signs into the server's demo
/// account, a separate account that sees none of the owner's data. [link]
/// (the setup link with the code) is known only right after it is made:
/// the server keeps a hash.
@immutable
class ReviewerCode {
  const ReviewerCode({required this.id, required this.label, required this.expiresAt, this.lastUsedAt, this.link});

  factory ReviewerCode.fromJson(Map<String, dynamic> j, {Uri? link}) => ReviewerCode(
    id: j['id'] as String,
    label: j['label'] as String? ?? '',
    expiresAt: DateTime.parse(j['expires_at'] as String).toLocal(),
    lastUsedAt: switch (j['last_used_at']) {
      final String at => DateTime.parse(at).toLocal(),
      _ => null,
    },
    link: link,
  );

  final String id;
  final String label;
  final DateTime expiresAt;
  final DateTime? lastUsedAt;
  final Uri? link;
}

/// What a failed call to functions/pair means: the function's own reason
/// (not signed in, a used-up code), an older server without it, or no
/// connection.
String pairingProblem(Object error) => switch (error) {
  FunctionsFetchException() => "Couldn't reach your server. Check your connection.",
  FunctionException(details: {'error': final String message}) => message,
  FunctionException(status: 404) => 'Your server is older than this app. Update it (docs/SELF_HOSTING.md), then retry.',
  FunctionException(:final status) => 'Your server failed ($status).',
  _ => "Couldn't make a code: $error",
};
