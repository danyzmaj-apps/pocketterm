import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/timing.dart';

/// The connected server ([Backend]) and signing in to it (the server's
/// setup link on a computer, a computer's code on a phone): what the
/// desktop and the phone apps share. Signed in is holding a device token
/// ([PocketTermServerClient.account]), kept in [deviceTokens].
abstract class Session extends ChangeNotifier {
  Session(this.device);

  /// What this device is to the server: a computer, unless a phone says so.
  /// A computer signs in with the server's setup token, a phone only with a
  /// computer's pairing code.
  DeviceRole get role => DeviceRole.desktop;

  /// This device's platform, as the server takes it: `macos`, `windows`,
  /// `linux`, `ios` or `android`.
  String get platform => Platform.operatingSystem;

  /// Where this device keeps its sign-in: the Keychain or Credential
  /// Manager on a computer, the phone's own secure storage.
  @protected
  DeviceTokens get deviceTokens;

  /// The server this device connects through; null until one is set up
  /// (the setup screen shows then).
  Backend? get backend => _backend;
  Backend? _backend;

  /// Only while [backend] is set.
  PocketTermServerClient? get server => _server;
  PocketTermServerClient? _server;

  /// This machine's name: its label on the server and of its push
  /// registration.
  final String device;

  /// This device, signed in; null while signed out.
  Account? get user => _user;
  Account? _user;
  StreamSubscription<void>? _ended;

  /// Why the last sign-in or connect didn't happen, for the signed-out
  /// pages; null once one did, and after signing out.
  String? authError;

  /// What a link says to this device while it's signed in, once: one it
  /// can't use as is (a code for another server, a computer's key that
  /// wasn't scanned, a code that didn't work). The page in front shows it;
  /// [authError] stays the signed-out pages'.
  Stream<String> get notices => _notices.stream;
  final _notices = StreamController<String>.broadcast(sync: true);

  void _notice(String message) {
    _notices.add(message);
    onNotice(message);
  }

  /// A notice went out ([notices]): the computer brings its window up.
  @protected
  void onNotice(String message) {}

  /// The key this device holds for [desktopId], if any (a phone's, from a
  /// scanned code).
  ChannelKey? computerKey(String desktopId) => null;

  /// The link whose sign-in failed only because the Keychain couldn't keep
  /// it ([keychainProblem]): [retry] tries it again.
  Uri? retryLink;

  /// What a sign-in says when the Keychain (locked, or missing) didn't let
  /// PocketTerm keep it.
  static const keychainProblem =
      'PocketTerm can\u2019t use your keychain (it may be locked or missing). Unlock it in Keychain Access, then '
      'try again.';

  /// The Keychain's own error (flutter_secure_storage's "Unexpected security
  /// result code", e.g. -60006 when its dialog was cancelled, -25308 locked).
  @visibleForTesting
  static bool keychainFailure(PlatformException e) => '${e.code} ${e.message}'.contains('security result code');

  /// Signs in again with [retryLink].
  Future<void> retry() async {
    final link = retryLink;
    if (link != null) await connectLink(link);
  }

  /// Why the last sign-in is gone, once it is (signed out here, the server
  /// ended it); null after a sign-in. The phone shows it on its scan screen.
  String? get signedOutReason => _signedOutReason;
  String? _signedOutReason;

  /// Set by [signOut] and [eraseServer] just before the sign-in goes.
  String? _leaving;

  /// Launch: opens the server this device was set up with, if any, and
  /// listens for setup links (`pocketterm://setup?url=…[&code=…|&setup=…]`).
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
  /// Any other link goes to [onOtherLink].
  @visibleForTesting
  void openedLink(Uri uri, Backend? saved) {
    final backend = Backend.fromLink(uri);
    if (backend == null) return onOtherLink(uri);
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

  /// A link opened from outside the app that isn't a setup link (the phone:
  /// a followed session's). The one that launched the app comes here too,
  /// and only here: the link stream hands it to whoever listens first.
  @protected
  void onOtherLink(Uri uri) {}

  /// A setup link: connects to its server and signs in with what it carries
  /// (a computer: the server's setup token; a phone: a computer's pairing
  /// code). A computer key in it ([Backend.computerKey]) goes to
  /// [addComputerKey] only when the link was [scanned] with the in-app
  /// scanner, also when already signed in (a phone scanning one more
  /// computer): anyone can send a link from outside the app, and a key it
  /// planted would let them read that computer's sessions. A key that would
  /// replace another one held for that computer counts only once the code's
  /// pairing code works ([_codeWorks]): only a computer signed in to this
  /// server makes one. Problems land in [authError], or in [notices] while
  /// signed in.
  Future<void> connectLink(Uri uri, {bool scanned = false}) async {
    final backend = Backend.fromLink(uri);
    if (backend == null) return;
    final phone = role == DeviceRole.phone;
    final secret = phone ? Backend.pairingCode(uri) : Backend.setupToken(uri);
    final computer = scanned ? Backend.computerKey(uri) : null;
    if (user != null) {
      if (backend != this.backend) {
        // A phone keeps one server: a computer on another needs it to leave this one first.
        _notice(
          phone
              ? 'That code is for a computer on ${backend.host}, and this phone is on $userName. To switch, leave '
                    'this server (Account → Leave this server), then scan the code again.'
              : 'Sign out before switching to ${backend.host}.',
        );
      } else if (computer != null) {
        final held = computerKey(computer.desktop);
        final problem = held == null || held == computer.key ? null : await _codeWorks(backend, secret);
        if (problem != null) {
          _notice(problem);
          return;
        }
        await addComputerKey(computer);
      } else if (phone && Backend.computerKey(uri) != null) {
        _notice("To connect to a computer, scan its code with PocketTerm's scanner.");
      }
      notifyListeners();
      return;
    }
    if (secret == null) {
      authError = phone
          ? 'That link has no sign-in code. On your computer, open PocketTerm: Settings → Phone → Add a phone…'
          : 'That link has no setup token. On your server, run `pocketterm-server setup-link` and open the link '
                'it prints.';
      notifyListeners();
      return;
    }
    if (backend != _backend) {
      final problem = await backend.check();
      if (problem != null) {
        authError = problem;
        notifyListeners();
        return;
      }
      await connect(backend);
    }
    authError = null;
    retryLink = null;
    notifyListeners();
    try {
      final s = server!;
      final account = phone
          ? await s.redeemCode(secret, label: device, platform: platform)
          : await s.redeemSetup(secret, label: device, platform: platform);
      // Before the sign-in lands, so the computer shows unlocked at once.
      if (computer != null) await addComputerKey(computer);
      _setUser(account);
      return;
    } on ServerException catch (e) {
      authError = switch (e.code) {
        'invalid_code' when phone => _codeUsed,
        'invalid_code' =>
          "That setup link doesn't work: the server has a newer one. Run `pocketterm-server setup-link` on the "
              'server and open the link it prints.',
        _ => e.message,
      };
    } on Object catch (e) {
      if (e is PlatformException && keychainFailure(e)) {
        authError = keychainProblem;
        retryLink = uri;
      } else {
        authError = 'Sign-in failed: $e';
      }
    }
    notifyListeners();
  }

  static const _codeUsed =
      "That code doesn't work: it was used, or it's more than 10 minutes old. Make a new one on your computer "
      '(Settings → Phone → Add a phone…).';

  /// Whether pairing [code] works on [backend]: it's redeemed by a sign-in
  /// of its own that leaves at once. Null when it did, else why not.
  Future<String?> _codeWorks(Backend backend, String? code) async {
    if (code == null) return _codeUsed;
    final probe = _client(backend, MemoryDeviceTokens());
    try {
      await probe.redeemCode(code, label: device, platform: platform);
      await probe.leave();
      return null;
    } on ServerException catch (e) {
      return e.code == 'invalid_code' ? _codeUsed : e.message;
    } finally {
      probe.close();
    }
  }

  /// A client for [backend] keeping its sign-in in [tokens].
  PocketTermServerClient _client(Backend backend, DeviceTokens tokens) =>
      PocketTermServerClient(backend, tokens: tokens);

  /// A computer's key from a scanned setup link: the phone keeps it, over
  /// any it held for that computer.
  @protected
  Future<void> addComputerKey(ComputerKey computer) async {}

  /// This computer and its key, for the setup link a phone scans; null where
  /// there's none (a phone).
  @protected
  Future<ComputerKey?> pairingComputer() async => null;

  /// A setup link that signs a phone in (POST /v1/pair) and carries this
  /// computer's key ([pairingComputer]): the code works once, for 10
  /// minutes; the key until reset. Only while signed in. Fails with a
  /// [PairingException] that says why.
  Future<Uri> pairingLink() async {
    final String code;
    try {
      code = await server!.createPairingCode();
    } on ServerException catch (e) {
      throw PairingException(e.message);
    }
    return _backend!.linkWithCode(code, computer: await pairingComputer());
  }

  /// Opens [backend] (and remembers it): the one saved at launch, the setup
  /// screen's, or a setup link's, with the sign-in this device kept for it.
  /// With [signInAtOnce] that's signed in before the server says it still
  /// holds; otherwise once it did (or didn't answer). A refusal signs out,
  /// with the reason. Switching needs the user signed out.
  Future<void> connect(Backend backend) async {
    if (_user != null) throw StateError('Sign out before switching servers.');
    await _close();
    final s = _server = _client(backend, deviceTokens);
    await backend.save();
    _backend = backend;
    authError = null;
    notifyListeners();
    await s.load();
    _ended = s.ended.listen((_) {
      _leaving ??= endedReason;
      _setUser(null);
    });
    final check = s.recheck();
    if (!signInAtOnce) await check;
    _setUser(s.account);
    timing('signed in');
  }

  /// A launch shows the sign-in kept here at once and asks the server about
  /// it meanwhile: a phone, which then shows what it had without waiting on
  /// the network. A computer asks first: one running the server signs in to
  /// it anew when it refused the kept one.
  @protected
  bool get signInAtOnce => false;

  /// Why the sign-in is gone when the server stopped taking it (this device
  /// was removed, the server erased), worded for the person.
  @protected
  String get endedReason => role == DeviceRole.phone
      ? 'Your sign-in ended on the server. Scan a new code from PocketTerm on your computer.'
      : "Your sign-in ended on the server. Open your server's setup link to sign in again.";

  /// Signs out and forgets the server: the setup screen shows again.
  Future<void> disconnect() async {
    if (_user != null) await signOut();
    await _close();
    await Backend.clear();
    _backend = null;
    authError = null;
    notifyListeners();
  }

  Future<void> _close() async {
    if (_server == null) return;
    await _ended?.cancel();
    _ended = null;
    _server?.close();
    _server = null;
  }

  /// Runs once a user is signed in (sign-in, or launch while signed in).
  @protected
  Future<void> onSignedIn(Account user) async {}

  /// Runs before signing out, while the token still works on the server.
  @protected
  Future<void> onSigningOut() async {}

  /// Runs once the sign-in is gone, however that happened (signed out here,
  /// the server ended it).
  @protected
  Future<void> onSignedOut() async {}

  /// [connect]'s restore and the server's answers both report the sign-in:
  /// only a change of device runs [onSignedIn] or [onSignedOut].
  void _setUser(Account? user) {
    final reason = _signedOutReason;
    if (user != null) {
      _signedOutReason = _leaving = null;
      _linkToConfirm = null;
    } else if (_user != null || _leaving != null) {
      _signedOutReason = _leaving ?? endedReason;
      _leaving = null;
    }
    if (user?.device.id == _user?.device.id) {
      _user = user ?? _user;
      if (_signedOutReason != reason) notifyListeners();
      return;
    }
    _user = user;
    unawaited(user != null ? onSignedIn(user) : onSignedOut());
    notifyListeners();
  }

  /// Signs out: this device leaves the server (its token stops working
  /// there, DELETE /v1/devices/me) and forgets it here, also when
  /// [onSigningOut] or the server fails (offline).
  Future<void> signOut() async {
    _leaving ??= 'You signed out.';
    try {
      await onSigningOut();
    } on Object catch (e) {
      debugPrint('PocketTerm: sign-out cleanup failed: $e');
    }
    try {
      await server?.leave();
    } on Object catch (e) {
      debugPrint('PocketTerm: the server missed the sign-out: $e');
    }
    _forgetError();
    _setUser(null);
  }

  /// A sign-in that went before leaves no problem behind for the next one.
  void _forgetError() {
    authError = null;
    retryLink = null;
  }

  /// This computer runs the server it's connected to (the one built into
  /// the app): only then may it erase it ([eraseServer]).
  bool get hostsServer => false;

  /// Erases everything on the server ([hostsServer] only): every computer
  /// and phone is signed out, the images and push registrations go.
  Future<void> eraseServer() async {
    if (!hostsServer) throw StateError('Only the computer running the server erases it.');
    try {
      await onSigningOut();
    } on Object catch (e) {
      debugPrint('PocketTerm: sign-out cleanup failed: $e');
    }
    await server!.erase();
    _leaving = "This server's data was erased.";
    _forgetError();
    _setUser(null);
  }

  /// What this device's sign-in is called on screen: its server.
  String get userName => _backend?.host ?? 'you';

  @override
  void dispose() {
    unawaited(_ended?.cancel());
    unawaited(_links?.cancel());
    unawaited(_notices.close());
    super.dispose();
  }
}

/// Why a pairing code couldn't be made, worded for the person.
class PairingException implements Exception {
  const PairingException(this.message);
  final String message;

  @override
  String toString() => message;
}
