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
  _Device(super.device, {this.phone = false, MemoryDeviceTokens? tokens}) : tokens = tokens ?? MemoryDeviceTokens();
  final bool phone;
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
  Future<void> addComputerKey(ComputerKey computer, {required bool replace}) async => keys.add(computer);

  @override
  Future<ComputerKey?> pairingComputer() async => computer;
}

/// A signed-out phone that records which setup links it acts on.
class _LinkSession extends _Device {
  _LinkSession() : super('iPhone', phone: true);
  final connected = <Uri>[];

  @override
  Future<void> connectLink(Uri uri, {bool external = false}) async => connected.add(uri);
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
    await phone.connectLink(await mac.pairingLink());
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

    test("goes ahead for the device's own server: the computer's code scanned with the camera", () {
      final session = _LinkSession();
      final link = mine.linkWithCode('ABCD-1234');
      session.openedLink(link, mine);
      expect(session.connected, [link]);
      expect(session.linkToConfirm, isNull);
    });
  });
}
