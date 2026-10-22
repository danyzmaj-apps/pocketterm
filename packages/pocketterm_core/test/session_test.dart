import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'own_server.dart';

/// A computer, or with [phone] a phone, keeping its sign-in in [tokens] and
/// the computer keys from links in [keys].
class _Device extends Session {
  _Device(super.device, {this.phone = false, this.atOnce = false, MemoryDeviceTokens? tokens})
    : tokens = tokens ?? MemoryDeviceTokens();
  final bool phone;
  final bool atOnce;
  final MemoryDeviceTokens tokens;
  final keys = <ComputerKey>[];

  /// What a computer puts in its phone codes.
  ComputerKey? computer;

  @override
  DeviceRole get role => phone ? DeviceRole.phone : DeviceRole.desktop;

  @override
  String get platform => phone ? 'ios' : 'macos';

  @override
  DeviceTokens get deviceTokens => tokens;

  @override
  bool get signInAtOnce => atOnce;

  @override
  Future<void> addComputerKey(ComputerKey computer) async => keys.add(computer);

  @override
  Future<ComputerKey?> pairingComputer() async => computer;
}

/// A signed-out phone that records which setup links it acts on.
class _LinkSession extends _Device {
  _LinkSession() : super('iPhone', phone: true);
  final connected = <Uri>[];
  final scans = <bool>[];

  @override
  Future<void> connectLink(Uri uri, {bool scanned = false}) async {
    connected.add(uri);
    scans.add(scanned);
  }
}

/// A Keychain that refuses until [locked] is turned off, as a locked or
/// missing one does.
class _LockedKeychain extends MemoryDeviceTokens {
  bool locked = true;

  @override
  Future<void> write(String? value) async {
    if (locked) {
      throw PlatformException(code: 'Unexpected security result code', message: 'Code: -25308, Message: locked');
    }
    await super.write(value);
  }
}

void main() {
  late OwnServer own;
  late _Device mac;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    own = await OwnServer.start();
    mac = _Device('MacBook Pro')..computer = (desktop: 'abcd1234', key: ChannelKey.generate());
    await mac.connectLink(own.setupLink);
  });

  tearDown(() async {
    await mac.disconnect();
    await own.stop();
  });

  test("a computer signs in with the server's setup link; a phone with its code, keeping the computer's key", () async {
    expect(mac.authError, isNull);
    expect(mac.user?.device.role, DeviceRole.desktop);
    expect(mac.user?.device.label, 'MacBook Pro');

    final phone = _Device('iPhone', phone: true);
    addTearDown(phone.disconnect);
    await phone.connectLink(await mac.pairingLink(), scanned: true);
    expect(phone.authError, isNull);
    expect(phone.user?.device.role, DeviceRole.phone);
    expect(phone.user?.id, mac.user?.id, reason: 'the same server');
    expect(phone.keys, [mac.computer]);

    // A code works once.
    final link = await mac.pairingLink();
    final second = _Device('iPad', phone: true);
    addTearDown(second.disconnect);
    await second.connectLink(link);
    expect(second.user, isNotNull);
    final third = _Device('Pixel', phone: true);
    addTearDown(third.disconnect);
    await third.connectLink(link);
    expect(third.user, isNull);
    expect(third.authError, contains('used'));
  });

  test('a Keychain that refuses the sign-in says so plainly, and Try again signs in once it lets', () async {
    final keychain = _LockedKeychain();
    final other = _Device('Mac mini', tokens: keychain);
    addTearDown(other.disconnect);
    await other.connectLink(own.setupLink);
    expect(other.user, isNull);
    expect(other.authError, Session.keychainProblem);
    expect(other.retryLink, own.setupLink);

    keychain.locked = false;
    await other.retry();
    expect(other.authError, isNull);
    expect(other.user?.device.label, 'Mac mini');
    expect(other.retryLink, isNull);
  });

  test("a link not from the scanner signs a phone in but never gives it a computer's key", () async {
    final phone = _Device('iPhone', phone: true);
    addTearDown(phone.disconnect);
    await phone.connectLink(await mac.pairingLink());
    expect(phone.user, isNotNull);
    expect(phone.keys, isEmpty, reason: 'signed out: the sign-in goes ahead, the key does not');

    final planted = (desktop: 'zzzz9999', key: ChannelKey.generate());
    final link = mac.backend!.linkWithCode('ABCD-1234', computer: planted);
    await phone.connectLink(link);
    expect(phone.keys, isEmpty, reason: 'signed in: still no key');
    expect(phone.authError, isNotNull);

    await phone.connectLink(link, scanned: true);
    expect(phone.keys, [planted]);
  });

  test('a link without what this device signs in with says so, and a phone never takes a setup token', () async {
    final phone = _Device('iPhone', phone: true);
    addTearDown(phone.disconnect);
    await phone.connectLink(own.setupLink);
    expect(phone.user, isNull);
    expect(phone.authError, contains('no sign-in code'));

    final other = _Device('Mac mini');
    addTearDown(other.disconnect);
    await other.connectLink(own.backend.linkWithCode(await mac.server!.createPairingCode()));
    expect(other.user, isNull);
    expect(other.authError, contains('no setup token'));
  });

  test('a relaunch is signed in from what the device kept; signing out leaves the server for good', () async {
    final tokens = MemoryDeviceTokens();
    final phone = _Device('iPhone', phone: true, tokens: tokens);
    addTearDown(phone.disconnect);
    await phone.connectLink(await mac.pairingLink());
    final id = phone.user!.device.id;

    final relaunched = _Device('iPhone', phone: true, tokens: tokens);
    addTearDown(relaunched.disconnect);
    await relaunched.connect(own.backend);
    expect(relaunched.user?.device.id, id);

    await relaunched.signOut();
    expect(relaunched.user, isNull);
    expect(relaunched.signedOutReason, 'You signed out.');
    expect(tokens.value, isNull);
    expect((await mac.server!.devices()).map((d) => d.id), isNot(contains(id)), reason: 'its token works no more');
  });

  test('a phone the computer signed out hears it the next time it asks, with the reason', () async {
    final phone = _Device('iPhone', phone: true);
    addTearDown(phone.disconnect);
    await phone.connectLink(await mac.pairingLink());
    await mac.server!.revokeDevice(phone.user!.device.id);

    await expectLater(phone.server!.desktops(), throwsA(isA<ServerException>()));
    await pumpEventQueue();
    expect(phone.user, isNull);
    expect(phone.signedOutReason, contains('Scan a new code'));

    // A relaunch with the token it kept before is signed out too.
    final kept = _Device('iPhone', phone: true, tokens: MemoryDeviceTokens()..value = phone.tokens.value);
    addTearDown(kept.disconnect);
    await kept.connect(own.backend);
    expect(kept.user, isNull);
  });

  test("a signed-in phone that scans another server's computer stays where it is and says how to switch", () async {
    final phone = _Device('iPhone', phone: true);
    addTearDown(phone.disconnect);
    await phone.connectLink(await mac.pairingLink(), scanned: true);
    final before = phone.user;
    const elsewhere = Backend(url: 'https://other.example.com');
    final link = elsewhere.linkWithCode('ABCD-1234', computer: (desktop: 'zzzz9999', key: ChannelKey.generate()));
    await phone.connectLink(link, scanned: true);
    expect(phone.user, same(before));
    expect(phone.backend, own.backend);
    expect(phone.keys, [mac.computer], reason: "that computer's key isn't taken");
    expect(phone.authError, allOf(contains('other.example.com'), contains('Leave this server')));
  });

  test('signing out with the server out of reach still forgets the sign-in here', () async {
    final tokens = MemoryDeviceTokens();
    final phone = _Device('iPhone', phone: true, tokens: tokens);
    addTearDown(phone.disconnect);
    await phone.connectLink(await mac.pairingLink());
    await own.server.stop();
    await phone.signOut();
    expect(phone.user, isNull);
    expect(tokens.value, isNull);
    expect(phone.signedOutReason, 'You signed out.');
  });

  group('a phone launched with the sign-in it kept', () {
    late _Held held;
    late MemoryDeviceTokens kept;

    setUp(() async {
      held = await _Held.start();
      kept = MemoryDeviceTokens()
        ..value = jsonEncode({
          'url': held.backend.url,
          'token': 'token-1',
          'server': 'srv0000000000001',
          'device': {'id': 'dev0000000000001', 'role': 'phone', 'label': 'iPhone', 'platform': 'ios'},
        });
    });
    tearDown(() => held.stop());

    test('is signed in before the server answers, and stays so when the answer is no sign-in answer', () async {
      final phone = _Device('iPhone', phone: true, atOnce: true, tokens: kept);
      addTearDown(phone.disconnect);
      await phone.connect(held.backend).timeout(const Duration(seconds: 2));
      expect(phone.user?.device.id, 'dev0000000000001', reason: 'the server holds its answer');

      // A captive portal's page, say.
      await held.answer(200, '<html>Sign in to the Wi-Fi</html>');
      expect(phone.user, isNotNull);
      expect(kept.value, isNotNull);
    });

    test('is signed out, with the reason, once the server refuses what it kept', () async {
      final phone = _Device('iPhone', phone: true, atOnce: true, tokens: kept);
      addTearDown(phone.disconnect);
      await phone.connect(held.backend).timeout(const Duration(seconds: 2));
      expect(phone.user, isNotNull);

      await held.answer(401, jsonEncode({'error': 'unauthorized', 'message': 'Sign in again.'}));
      await pumpEventQueue();
      expect(phone.user, isNull);
      expect(phone.signedOutReason, contains('Scan a new code'));
      expect(kept.value, isNull);
    });

    test("signed out while the server is asked: the answer that comes after doesn't sign it back in", () async {
      final phone = _Device('iPhone', phone: true, atOnce: true, tokens: kept);
      addTearDown(phone.disconnect);
      await phone.connect(held.backend).timeout(const Duration(seconds: 2));
      await phone.signOut();
      await held.answer(200, jsonEncode(_Held.me));
      await pumpEventQueue();
      expect(phone.user, isNull);
      expect(kept.value, isNull, reason: "the sign-in it left isn't kept again");
      expect(phone.server!.account, isNull);
    });
  });

  group('a setup link opened from outside the app', () {
    const mine = Backend(url: 'https://mine.example.com');
    const theirs = Backend(url: 'https://theirs.example.com');

    test('connects a signed-out device to another server only once the person says so', () async {
      final session = _LinkSession();
      final link = theirs.linkWithCode('ABCD-1234');
      session.openedLink(link, mine);
      expect(session.connected, isEmpty);
      expect(session.linkToConfirm, link);
      await session.answerLink(connect: true);
      expect(session.connected, [link]);
      expect(session.linkToConfirm, isNull);
    });

    test('is dropped when the person says no, and asks on a device set up nowhere yet', () async {
      final session = _LinkSession()..openedLink(theirs.linkWithCode('ABCD-1234'), null);
      expect(session.linkToConfirm, isNotNull);
      await session.answerLink(connect: false);
      expect(session.connected, isEmpty);
      expect(session.linkToConfirm, isNull);
    });

    test("goes ahead for the device's own server, never as a scan: the computer's code from the camera", () {
      final session = _LinkSession();
      final link = mine.linkWithCode('ABCD-1234');
      session.openedLink(link, mine);
      expect(session.connected, [link]);
      expect(session.scans, [false]);
      expect(session.linkToConfirm, isNull);
    });
  });
}

/// A server that holds GET /v1/me until [answer] says what to answer it,
/// then answers it at once; anything else gets `{}` at once.
class _Held {
  _Held._(this._http) {
    _http.listen((req) => _answer == null && req.uri.path == '/v1/me' ? _waiting.add(req) : _reply(req));
  }

  static Future<_Held> start() async => _Held._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  static const me = {
    'device': {'id': 'dev0000000000001', 'role': 'phone', 'label': 'iPhone', 'platform': 'ios'},
    'server': {'id': 'srv0000000000001'},
  };

  final HttpServer _http;
  final _waiting = <HttpRequest>[];
  ({int status, String body})? _answer;

  Backend get backend => Backend(url: 'http://127.0.0.1:${_http.port}');

  void _reply(HttpRequest r) {
    final me = r.uri.path == '/v1/me';
    r.response
      ..statusCode = me ? _answer!.status : 200
      ..write(me ? _answer!.body : '{}');
    unawaited(r.response.close());
  }

  /// Answers, once the GET /v1/me is there, with [status] and [body].
  Future<void> answer(int status, String body) async {
    for (var i = 0; i < 100 && !_waiting.any((r) => r.uri.path == '/v1/me'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _answer = (status: status, body: body);
    _waiting
      ..forEach(_reply)
      ..clear();
    // Each answer read before going on.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  Future<void> stop() => _http.close(force: true);
}
