import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/terminal_channel.dart';

import 'own_server.dart';

void main() {
  late OwnServer own;
  late PocketTermServerClient mac;
  late PocketTermServerClient phone;

  setUp(() async {
    own = await OwnServer.start();
    mac = await own.desktop();
    phone = await own.phone(mac);
  });

  tearDown(() async {
    mac.close();
    phone.close();
    await own.stop();
  });

  Future<void> until(bool Function() check) async {
    for (var i = 0; i < 500 && !check(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(check(), isTrue);
  }

  test("a phone's code signs it in once; a wrong one or a wrong setup token signs nobody in", () async {
    expect(mac.account?.device.role, DeviceRole.desktop);
    expect(phone.account?.device.role, DeviceRole.phone);
    expect(phone.account?.id, mac.account?.id);

    final code = await mac.createPairingCode();
    await own.client().redeemCode(code, label: 'iPad', platform: 'ios');
    final late = own.client();
    await expectLater(
      late.redeemCode(code, label: 'Pixel', platform: 'android'),
      throwsA(isA<ServerException>().having((e) => e.code, 'code', 'invalid_code')),
    );
    expect(late.account, isNull);
    await expectLater(
      own.client().redeemSetup('not-the-token', label: 'Mac mini', platform: 'macos'),
      throwsA(isA<ServerException>().having((e) => e.code, 'code', 'invalid_code')),
    );
    await expectLater(phone.createPairingCode(), throwsA(isA<ServerException>()), reason: 'only computers make codes');
  });

  test('the live channel carries sealed messages between the computer and the phone, both ways', () async {
    final key = ChannelKey.generate();
    final atMac = <Map<String, dynamic>>[];
    final atPhone = <Map<String, dynamic>>[];
    final desk = TerminalChannel(mac, 'abcd1234', {'hello': atMac.add}, key: key, name: 'mac');
    final remote = TerminalChannel(phone, 'abcd1234', {'state': atPhone.add}, key: key, name: 'phone');
    // Someone on the same server without the key hears nothing it can open.
    final stranger = <Map<String, dynamic>>[];
    final other = TerminalChannel(
      await own.phone(mac),
      'abcd1234',
      {'hello': stranger.add, 'state': stranger.add},
      key: ChannelKey.generate(),
      name: 'stranger',
    );
    addTearDown(() async {
      await desk.close();
      await remote.close();
      await other.close();
    });
    desk.open();
    remote.open();
    other.open();
    await until(() => desk.joined && remote.joined && other.joined);

    await remote.send('hello', {'from': 'phone-1'});
    await desk.send('state', {'windows': <Object>[]});
    await until(() => atMac.isNotEmpty && atPhone.isNotEmpty);
    expect(atMac.single, {'from': 'phone-1'});
    expect(atPhone.single, {'windows': <Object>[]});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(stranger, isEmpty);
  });

  test('a blob goes up once at a path of its own, comes down once, and is gone after', () async {
    final path = phone.newBlobPath();
    expect(PocketTermServerClient.isBlobPath(path), isTrue);
    expect(PocketTermServerClient.isBlobPath('../etc/passwd'), isFalse);
    final bytes = Uint8List.fromList(List.generate(70000, (i) => i % 251));
    await phone.putBlob(path, bytes);
    await expectLater(
      phone.putBlob(path, Uint8List(1)),
      throwsA(isA<ServerException>().having((e) => e.status, 'status', 409)),
    );
    expect(await mac.getBlob(path), bytes);
    await expectLater(mac.getBlob(path), throwsA(isA<ServerException>().having((e) => e.status, 'status', 404)));

    final unused = phone.newBlobPath();
    await phone.putBlob(unused, Uint8List(4));
    await phone.deleteBlob(unused);
    await expectLater(mac.getBlob(unused), throwsA(isA<ServerException>()));
  });

  test('an image over the limit is refused with its reason, not as a lost connection', () async {
    final path = phone.newBlobPath();
    await expectLater(
      phone.putBlob(path, Uint8List(PocketTermServerClient.maxBlobBytes + 1)),
      throwsA(isA<ServerException>().having((e) => e.status, 'status', 413)),
    );
    await expectLater(mac.getBlob(path), throwsA(isA<ServerException>().having((e) => e.status, 'status', 404)));
  });

  test('a computer lists itself for the phones and takes itself off', () async {
    await mac.putDesktop('abcd1234', name: 'MacBook Pro', platform: 'macos');
    final rows = await phone.desktops();
    expect(rows.single, containsPair('id', 'abcd1234'));
    expect(rows.single, containsPair('name', 'MacBook Pro'));
    expect(
      DateTime.parse(rows.single['seen_at'] as String).difference(DateTime.now()).abs(),
      lessThan(const Duration(minutes: 1)),
    );
    await expectLater(phone.putDesktop('zzzz9999', name: 'Fake', platform: 'macos'), throwsA(isA<ServerException>()));

    await mac.deleteDesktop('abcd1234');
    expect(await phone.desktops(), isEmpty);
  });

  test("a computer's push reaches each phone the relay knows, and stops once it unregisters", () async {
    const token = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
    await phone.push('register', {'token': token, 'label': 'iPhone', 'platform': 'ios'});
    final key = ChannelKey.generate();
    final enc = base64Encode(await sealBytes(key, utf8.encode('{"title":"done"}'), pushAad('abcd1234')));
    final sent = await mac.push('notify', {
      'tag': await pushTag(key),
      'enc': enc,
      'collapse': await sessionTag(key, 'abcd1234/s1'),
    });
    expect(sent['sent'], 1);
    await until(() => own.relayed.isNotEmpty);
    // One request for the one phone, sealed to the relay on its way.
    expect(own.relayed, hasLength(1));
    expect(jsonEncode(own.relayed.single), isNot(contains(token)));

    await phone.push('unregister', {'token': token});
    expect((await mac.push('notify', {'tag': await pushTag(key), 'enc': enc}))['sent'], 0);
  });

  test('a phone that leaves, or that the computer signs out, can do nothing more', () async {
    final ended = <void>[];
    phone.ended.listen(ended.add);
    await mac.revokeDevice(phone.account!.device.id);
    await expectLater(phone.desktops(), throwsA(isA<ServerException>().having((e) => e.status, 'status', 401)));
    await pumpEventQueue();
    expect(ended, hasLength(1));
    expect(phone.account, isNull);

    final other = await own.phone(mac);
    await other.leave();
    expect(other.account, isNull);
    expect((await mac.devices()).where((d) => d.role == DeviceRole.phone), isEmpty);
  });

  test('erasing the server signs every device out but keeps its setup link', () async {
    await mac.putDesktop('abcd1234', name: 'MacBook Pro', platform: 'macos');
    await mac.erase();
    expect(mac.account, isNull);
    await expectLater(phone.desktops(), throwsA(isA<ServerException>()));
    final again = await own.desktop();
    addTearDown(again.close);
    expect(await again.desktops(), isEmpty);
  });
}
