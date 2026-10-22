import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/desktops.dart';
import 'package:pocketterm_core/server_client.dart';

import 'own_server.dart';

void main() {
  final client = PocketTermServerClient(const Backend(url: 'http://localhost:1'), tokens: MemoryDeviceTokens());

  Map<String, dynamic> row(String id, Duration ago, {String platform = 'macos'}) => {
    'id': id,
    'name': 'Computer $id',
    'platform': platform,
    'seen_at': DateTime.now().subtract(ago).toUtc().toIso8601String(),
  };

  test('the computer last shown stays shown while it is listed, even when another was seen since', () {
    final changes = <String?>[];
    final d = Desktops(client, saved: 'bbbbbbbb', onChanged: (_, id) => changes.add(id))
      ..apply([row('aaaaaaaa', Duration.zero), row('bbbbbbbb', const Duration(hours: 2))]);
    expect(d.selected?.id, 'bbbbbbbb');
    expect(changes, ['bbbbbbbb']);
  });

  test('with the last one gone, the newest seen is shown and kept as the computers take turns', () {
    final d = Desktops(client, saved: 'gone0000')
      ..apply([row('aaaaaaaa', Duration.zero), row('bbbbbbbb', const Duration(minutes: 1))]);
    expect(d.selected?.id, 'aaaaaaaa');
    d.apply([row('bbbbbbbb', Duration.zero), row('aaaaaaaa', const Duration(minutes: 1))]);
    expect(d.selected?.id, 'aaaaaaaa');
  });

  test('none listed, none shown; a computer not seen for 30 days is not listed', () {
    final d = Desktops(client)..apply([]);
    expect(d.selected, isNull);
    d.apply([row('aaaaaaaa', const Duration(days: 31))]);
    expect(d.all, isEmpty);
    expect(d.selected, isNull);
  });

  test('the person picks a listed computer only', () {
    final changes = <String?>[];
    final d = Desktops(client, onChanged: (_, id) => changes.add(id))
      ..apply([row('aaaaaaaa', Duration.zero), row('bbbbbbbb', Duration.zero, platform: 'windows')])
      ..select('bbbbbbbb')
      ..select('cccccccc');
    expect(d.selected?.id, 'bbbbbbbb');
    expect(d.selected?.windows, isTrue);
    expect(changes, ['aaaaaaaa', 'bbbbbbbb']);
  });

  test('a computer asked for (its code scanned) is shown once listed, over one seen later', () {
    final d = Desktops(client)
      ..apply([row('aaaaaaaa', Duration.zero)])
      ..show('bbbbbbbb');
    expect(d.selected?.id, 'aaaaaaaa', reason: 'not listed yet');
    d.apply([row('cccccccc', Duration.zero), row('bbbbbbbb', const Duration(minutes: 1))]);
    expect(d.selected?.id, 'bbbbbbbb');
    d.apply([row('aaaaaaaa', Duration.zero), row('bbbbbbbb', const Duration(minutes: 1))]);
    expect(d.selected?.id, 'bbbbbbbb', reason: 'asked for once, then kept like any choice');
    d.show('aaaaaaaa');
    expect(d.selected?.id, 'aaaaaaaa');
  });

  test('the cached list shows the computer last shown before the server answers', () {
    final cached = Desktop.fromJson(row('bbbbbbbb', const Duration(minutes: 5)));
    final d = Desktops(client, cached: [cached], saved: 'bbbbbbbb');
    expect(d.loaded, isFalse);
    expect(d.selected, cached);
    expect(Desktop.fromJson(cached.toJson()), cached);
  });

  test('online means seen within two and a half minutes', () {
    expect(Desktop.fromJson(row('aaaaaaaa', const Duration(seconds: 140))).online, isTrue);
    expect(Desktop.fromJson(row('aaaaaaaa', const Duration(seconds: 160))).online, isFalse);
  });

  test('a server that stops answering keeps the list there is and says why, until a list comes', () async {
    final own = await OwnServer.start();
    final phone = await own.phone(await own.desktop());
    final cached = Desktop.fromJson(row('bbbbbbbb', const Duration(minutes: 5)));
    final d = Desktops(phone, cached: [cached], saved: 'bbbbbbbb');
    var told = 0;
    d.addListener(() => told++);
    await own.stop();
    await d.refresh();
    expect(d.error, phone.backend.unreachable);
    expect(d.selected, cached);
    expect(told, 1);
    await d.refresh();
    expect(told, 1, reason: 'the same problem again is no news');
    d.apply([row('aaaaaaaa', Duration.zero)]);
    expect(d.error, isNull);
  });

  test("a list that comes after the phone left the server isn't kept for the next sign-in", () async {
    final own = await OwnServer.start();
    addTearDown(own.stop);
    final phone = await own.phone(await own.desktop());
    final kept = <List<Desktop>>[];
    final d = Desktops(phone, onChanged: (all, _) => kept.add(all));
    final refreshed = d.refresh();
    d.dispose();
    await refreshed;
    expect(kept, isEmpty);
  });

  test('a Tailscale address that gets no answer says to connect Tailscale on this device', () async {
    const tailnet = Backend(url: 'https://my-mac.tail1234.ts.net');
    expect(tailnet.onTailnet, isTrue);
    expect(tailnet.unreachable, contains('open Tailscale on this device'));
    const vps = Backend(url: 'https://pocketterm.example.com');
    expect(vps.onTailnet, isFalse);
    expect(vps.unreachable, isNot(contains('Tailscale')));
    // Nothing listens there: the client's offline answer is the backend's.
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final client = PocketTermServerClient(Backend(url: 'http://127.0.0.1:$port'), tokens: MemoryDeviceTokens());
    await expectLater(
      client.redeemCode('K7QM', label: 'iPhone', platform: 'ios'),
      throwsA(isA<ServerException>().having((e) => e.message, 'message', client.backend.unreachable)),
    );
  });
}
