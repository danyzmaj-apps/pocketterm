import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'harness.dart';

/// A computer's push tag and a session's (pocketterm_core's pushTag, sessionTag): opaque to the server.
const _tag = 'RJM0r7AxRLM';
const _ref = 'yMPqtkm1TA3-r0AeuNDSHg';

void main() {
  late Harness h;
  setUp(() async => h = await Harness.start());
  tearDown(() => h.close());

  test('health answers without a token', () async {
    final res = await h.call('GET', '/v1/health');
    expect(res.status, 200);
    expect(res.map['pocketterm'], 1);
  });

  group('setup', () {
    test('the setup link carries the public URL and a token that signs a computer in', () async {
      final link = h.server.setupLink();
      expect(link.scheme, 'pocketterm');
      expect(link.queryParameters['url'], 'https://pt.example.com');

      final res = await h.call(
        'POST',
        '/v1/setup/redeem',
        body: {'setup': h.setupToken, 'label': 'Studio', 'platform': 'macos'},
      );
      expect(res.status, 200);
      final device = res.map['device'] as Map<String, dynamic>;
      expect(device['role'], 'desktop');
      expect(device['label'], 'Studio');

      final me = await h.call('GET', '/v1/me', token: res.map['token'] as String);
      expect(me.status, 200);
      expect((me.map['device'] as Map)['id'], device['id']);
    });

    test('a wrong setup token signs nobody in', () async {
      final res = await h.call('POST', '/v1/setup/redeem', body: {'setup': 'nope', 'platform': 'macos'});
      expect(res.status, 400);
      expect(res.error, 'invalid_code');
    });

    test('a new setup token retires the old link and keeps computers signed in', () async {
      final old = h.setupToken;
      final mac = await h.desktop();
      final fresh = h.server.newSetupToken().queryParameters['setup'];
      expect(fresh, isNot(old));

      final res = await h.call('POST', '/v1/setup/redeem', body: {'setup': old, 'platform': 'macos'});
      expect(res.error, 'invalid_code');
      expect((await h.call('GET', '/v1/me', token: mac.token)).status, 200);
      expect((await h.call('POST', '/v1/setup/redeem', body: {'setup': fresh, 'platform': 'linux'})).status, 200);
    });
  });

  group('auth', () {
    test('endpoints need a known token', () async {
      for (final (method, path) in [
        ('GET', '/v1/me'),
        ('GET', '/v1/desktops'),
        ('GET', '/v1/devices'),
        ('POST', '/v1/pair'),
        ('POST', '/v1/push/notify'),
        ('GET', '/v1/blobs/abc'),
      ]) {
        expect((await h.call(method, path)).status, 401, reason: '$method $path without a token');
        expect((await h.call(method, path, token: 'forged')).status, 401, reason: '$method $path forged');
      }
      await expectLater(h.socket('forged'), throwsA(isA<WebSocketException>()));
    });

    test('a phone can neither make pairing codes nor list itself as a computer nor erase', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      expect((await h.call('POST', '/v1/pair', token: phone.token)).error, 'forbidden');
      final put = await h.call(
        'PUT',
        '/v1/desktops/abcd1234',
        token: phone.token,
        body: {'name': 'x', 'platform': 'macos'},
      );
      expect(put.status, 403);
      expect((await h.call('POST', '/v1/erase', token: phone.token)).status, 403);
      expect((await h.call('DELETE', '/v1/devices/${mac.id}', token: phone.token)).status, 403);
    });
  });

  group('pairing', () {
    test('a code signs one phone in, once', () async {
      final mac = await h.desktop();
      final code = (await h.call('POST', '/v1/pair', token: mac.token)).map['code'] as String;
      expect(code, matches(RegExp(r'^([0-9A-Z]{4}-){6}[0-9A-Z]{4}$')));

      // Typed in lower case without dashes still works.
      final typed = code.replaceAll('-', '').toLowerCase();
      final first = await h.call(
        'POST',
        '/v1/pair/redeem',
        body: {'code': typed, 'label': 'Pixel', 'platform': 'android'},
      );
      expect(first.status, 200);
      expect((first.map['device'] as Map)['role'], 'phone');

      final again = await h.call('POST', '/v1/pair/redeem', body: {'code': code, 'platform': 'android'});
      expect(again.status, 400);
      expect(again.error, 'invalid_code');
    });

    test('a code runs out after 10 minutes', () async {
      final mac = await h.desktop();
      final code = (await h.call('POST', '/v1/pair', token: mac.token)).map['code'] as String;
      h.now = h.now.add(const Duration(minutes: 10, seconds: 1));
      final res = await h.call('POST', '/v1/pair/redeem', body: {'code': code, 'platform': 'ios'});
      expect(res.error, 'invalid_code');
    });

    test('10 failed redeems lock the address out of both redeem endpoints for 10 minutes', () async {
      final mac = await h.desktop();
      final early = (await h.call('POST', '/v1/pair', token: mac.token)).map['code'] as String;
      for (var i = 0; i < 10; i++) {
        final res = await h.call('POST', '/v1/pair/redeem', body: {'code': 'AAAA-$i', 'platform': 'ios'});
        expect(res.status, 400);
      }
      final locked = await h.call('POST', '/v1/pair/redeem', body: {'code': early, 'platform': 'ios'});
      expect(locked.status, 429);
      expect(locked.error, 'rate_limited');
      expect(int.parse(locked.headers.value('retry-after')!), greaterThan(0));
      final setup = await h.call('POST', '/v1/setup/redeem', body: {'setup': h.setupToken, 'platform': 'macos'});
      expect(setup.status, 429);

      h.now = h.now.add(const Duration(minutes: 10));
      final code = (await h.call('POST', '/v1/pair', token: mac.token)).map['code'] as String;
      expect((await h.call('POST', '/v1/pair/redeem', body: {'code': code, 'platform': 'ios'})).status, 200);
    });

    test(
      'behind a loopback proxy each forwarded caller has its own throttle; otherwise the header is ignored',
      () async {
        Future<int> redeem(String from) async => (await h.call(
          'POST',
          '/v1/pair/redeem',
          body: {'code': 'AAAA-0000', 'platform': 'ios'},
          headers: {'x-forwarded-for': from},
        )).status;
        for (var i = 0; i < 10; i++) {
          await redeem('100.64.0.$i');
        }
        expect(await redeem('100.64.0.99'), 429, reason: 'without the option every caller is 127.0.0.1');

        await h.restart(trustLoopbackProxy: true);
        for (var i = 0; i < 10; i++) {
          expect(await redeem('100.64.0.1'), 400);
        }
        expect(await redeem('100.64.0.1'), 429);
        expect(await redeem('100.64.0.2'), 400);
      },
    );
  });

  group('desktops and devices', () {
    test('only the computer that added a computer can remove it; never a phone', () async {
      final mac = await h.desktop();
      final other = await h.desktop();
      final phone = await h.phone(mac.token, 'iPhone');
      await h.call('PUT', '/v1/desktops/aaaa1111', token: mac.token, body: {'name': 'Mac', 'platform': 'macos'});
      expect((await h.call('DELETE', '/v1/desktops/aaaa1111', token: phone.token)).status, 403);
      expect((await h.call('DELETE', '/v1/desktops/aaaa1111', token: other.token)).status, 403);
      expect((await h.call('GET', '/v1/desktops', token: mac.token)).list, hasLength(1));
      expect((await h.call('DELETE', '/v1/desktops/aaaa1111', token: mac.token)).status, 200);
      expect((await h.call('GET', '/v1/desktops', token: mac.token)).list, isEmpty);
    });

    test(
      'another computer can neither change nor remove a computer that checks in, only take over a silent one',
      () async {
        final mac = await h.desktop();
        final other = await h.desktop('Other');
        Future<int> put(String token, String name) async => (await h.call(
          'PUT',
          '/v1/desktops/aaaa1111',
          token: token,
          body: {'name': name, 'platform': 'macos'},
        )).status;
        Future<List<Object?>> names() async => [
          for (final d in (await h.call('GET', '/v1/desktops', token: mac.token)).list) (d as Map)['name'],
        ];

        expect(await put(mac.token, 'Mac'), 200);
        expect(await put(other.token, 'Taken'), 403);
        expect((await h.call('DELETE', '/v1/desktops/aaaa1111', token: other.token)).status, 403);
        expect(await names(), ['Mac']);

        // The computer stopped checking in (it signed in again under a new device, keeping its id): it can be taken.
        h.now = h.now.add(const Duration(seconds: 150));
        expect(await put(other.token, 'Again'), 200);
        expect(await names(), ['Again']);
        expect(await put(mac.token, 'Mac'), 403);
        expect((await h.call('DELETE', '/v1/desktops/aaaa1111', token: mac.token)).status, 403);
      },
    );

    test('computers are listed newest first and go offline when they stop checking in', () async {
      final mac = await h.desktop();
      await h.call('PUT', '/v1/desktops/aaaa1111', token: mac.token, body: {'name': 'Old', 'platform': 'macos'});
      h.now = h.now.add(const Duration(minutes: 3));
      await h.call('PUT', '/v1/desktops/bbbb2222', token: mac.token, body: {'name': 'New', 'platform': 'windows'});

      final list = (await h.call('GET', '/v1/desktops', token: mac.token)).list.cast<Map<String, dynamic>>();
      expect([for (final d in list) d['id']], ['bbbb2222', 'aaaa1111']);
      expect([for (final d in list) d['online']], [true, false]);

      expect((await h.call('DELETE', '/v1/desktops/aaaa1111', token: mac.token)).status, 200);
      expect((await h.call('GET', '/v1/desktops', token: mac.token)).list, hasLength(1));
      final bad = await h.call('PUT', '/v1/desktops/NOPE', token: mac.token, body: {'name': 'x', 'platform': 'macos'});
      expect(bad.status, 400);
    });

    test('the device list marks the caller', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token, 'iPhone');
      final list = (await h.call('GET', '/v1/devices', token: phone.token)).list.cast<Map<String, dynamic>>();
      expect(
        [for (final d in list) (d['label'], d['role'], d['current'])],
        [('Mac', 'desktop', false), ('iPhone', 'phone', true)],
      );
    });

    test('revoking a phone closes its socket and its token stops working', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      final ws = await h.socket(phone.token);
      await ws.join('aaaa1111');

      expect((await h.call('DELETE', '/v1/devices/${phone.id}', token: mac.token)).status, 200);
      expect(await ws.closed, 4003);
      expect((await h.call('GET', '/v1/me', token: phone.token)).status, 401);
      expect((await h.call('DELETE', '/v1/devices/${phone.id}', token: mac.token)).status, 404);
    });

    test('a phone that leaves is signed out', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      expect((await h.call('DELETE', '/v1/devices/me', token: phone.token)).status, 200);
      expect((await h.call('GET', '/v1/me', token: phone.token)).status, 401);
      expect((await h.call('GET', '/v1/me', token: mac.token)).status, 200);
    });

    test('erase signs everyone out and forgets everything but the setup link', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      final ws = await h.socket(phone.token);
      await h.call('PUT', '/v1/desktops/aaaa1111', token: mac.token, body: {'name': 'Mac', 'platform': 'macos'});
      await h.call('PUT', '/v1/blobs/img-1', token: phone.token, bytes: [1, 2, 3]);

      expect((await h.call('POST', '/v1/erase', token: mac.token)).status, 200);
      expect(await ws.closed, 4003);
      expect((await h.call('GET', '/v1/me', token: mac.token)).status, 401);
      final again = await h.desktop();
      expect((await h.call('GET', '/v1/desktops', token: again.token)).list, isEmpty);
      expect((await h.call('GET', '/v1/devices', token: again.token)).list, hasLength(1));
      expect((await h.call('GET', '/v1/blobs/img-1', token: again.token)).status, 404);
    });
  });

  group('live channel', () {
    test('a message reaches the other sockets on its topic, not the sender, not other topics', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      final other = await h.phone(mac.token);
      final desk = await h.socket(mac.token);
      final p1 = await h.socket(phone.token);
      final p2 = await h.socket(other.token);
      final elsewhere = await h.socket(other.token);
      await desk.join('aaaa1111');
      await p1.join('aaaa1111');
      await p2.join('aaaa1111');
      await elsewhere.join('bbbb2222');

      final payload = {
        'v': 1,
        'n': 'bm9uY2U=',
        'c': 'Y2lwaGVy',
        'nested': [1, 'two', null],
      };
      desk.send({'t': 'send', 'topic': 'aaaa1111', 'event': 'state', 'payload': payload});
      for (final s in [p1, p2]) {
        expect(await s.next(), {'t': 'msg', 'topic': 'aaaa1111', 'event': 'state', 'payload': payload});
      }

      // The first thing the sender and the other topic get is what's sent after: nothing reached them before.
      p1.send({'t': 'send', 'topic': 'aaaa1111', 'event': 'hello', 'payload': 1});
      expect((await desk.next())['event'], 'hello');
      expect((await p2.next())['event'], 'hello');
      final p3 = await h.socket(phone.token);
      await p3.join('bbbb2222');
      p3.send({'t': 'send', 'topic': 'bbbb2222', 'event': 'other', 'payload': 2});
      expect((await elsewhere.next())['event'], 'other');

      // After leaving, nothing more arrives.
      p2
        ..send({'t': 'leave', 'topic': 'aaaa1111'})
        ..send({'t': 'ping'});
      expect((await p2.next())['t'], 'pong');
      desk.send({'t': 'send', 'topic': 'aaaa1111', 'event': 'after', 'payload': 3});
      expect((await p1.next())['event'], 'after');
      p2.send({'t': 'ping'});
      expect((await p2.next())['t'], 'pong');

      for (final s in [desk, p1, p2, p3, elsewhere]) {
        await s.close();
      }
    });

    test('sending to a topic not joined is an error and reaches nobody', () async {
      final mac = await h.desktop();
      final a = await h.socket(mac.token);
      final b = await h.socket(mac.token);
      await b.join('aaaa1111');
      a.send({'t': 'send', 'topic': 'aaaa1111', 'event': 'state', 'payload': 1});
      expect(await a.next(), containsPair('error', 'not_joined'));
      a.send({'t': 'nonsense'});
      expect(await a.next(), containsPair('error', 'bad_frame'));
      b.send({'t': 'ping'});
      expect((await b.next())['t'], 'pong');
      await a.close();
      await b.close();
    });

    test('a frame over 256 KiB closes the socket with 1009', () async {
      final mac = await h.desktop();
      final s = await h.socket(mac.token);
      await s.join('aaaa1111');
      s.send({'t': 'send', 'topic': 'aaaa1111', 'event': 'big', 'payload': 'x' * (256 * 1024)});
      expect(await s.closed, WebSocketStatus.messageTooBig);
    });

    test('a socket joins at most 32 topics; the 33rd is refused and the socket stays open', () async {
      final mac = await h.desktop();
      final s = await h.socket(mac.token);
      for (var i = 0; i < 32; i++) {
        await s.join('topic-$i');
      }
      s.send({'t': 'join', 'topic': 'topic-32'});
      expect(await s.next(), containsPair('error', 'too_many_topics'));
      // A topic it holds can still be joined again, and one left makes room.
      await s.join('topic-0');
      s.send({'t': 'leave', 'topic': 'topic-1'});
      await s.join('topic-32');
      await s.close();
    });
  });

  group('blobs', () {
    test('a blob downloads once, then is gone', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      final bytes = List<int>.generate(70000, (i) => i % 256);
      final put = await h.call('PUT', '/v1/blobs/0f1e2d3c-aaaa', token: phone.token, bytes: bytes);
      expect(put.status, 201);
      expect(put.map['path'], '0f1e2d3c-aaaa');
      expect((await h.call('PUT', '/v1/blobs/0f1e2d3c-aaaa', token: phone.token, bytes: [1])).error, 'conflict');

      final got = await h.call('GET', '/v1/blobs/0f1e2d3c-aaaa', token: mac.token);
      expect(got.status, 200);
      expect(got.bytes, bytes);
      expect((await h.call('GET', '/v1/blobs/0f1e2d3c-aaaa', token: mac.token)).status, 404);
    });

    test('a deleted blob is gone', () async {
      final mac = await h.desktop();
      await h.call('PUT', '/v1/blobs/x1', token: mac.token, bytes: [1, 2]);
      expect((await h.call('DELETE', '/v1/blobs/x1', token: mac.token)).status, 200);
      expect((await h.call('GET', '/v1/blobs/x1', token: mac.token)).status, 404);
      expect((await h.call('DELETE', '/v1/blobs/x1', token: mac.token)).status, 200);
    });

    test('a blob nobody downloads is gone after an hour, from disk too', () async {
      final mac = await h.desktop();
      await h.call('PUT', '/v1/blobs/late', token: mac.token, bytes: [1, 2, 3]);
      h.now = h.now.add(const Duration(hours: 1, minutes: 1));
      expect((await h.call('GET', '/v1/blobs/late', token: mac.token)).status, 404);
      expect(File('${h.dir.path}/blobs/late').existsSync(), isFalse);
    });

    test('a blob over 20 MiB is refused', () async {
      final mac = await h.desktop();
      final res = await h.call(
        'PUT',
        '/v1/blobs/huge',
        token: mac.token,
        bytes: List<int>.filled(20 * 1024 * 1024 + 1, 0),
      );
      expect(res.status, 413);
      expect((await h.call('GET', '/v1/blobs/huge', token: mac.token)).status, 404);
    });

    test('a bad path is refused', () async {
      final mac = await h.desktop();
      expect((await h.call('PUT', '/v1/blobs/a.b', token: mac.token, bytes: [1])).status, 400);
    });

    test('uploads stop at the per-device quota (429) and the server-wide one (507) until blobs go', () async {
      await h.restart(deviceBlobQuota: 10, blobQuota: 15);
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      Future<Res> put(String token, String path, int size) =>
          h.call('PUT', '/v1/blobs/$path', token: token, bytes: List<int>.filled(size, 7));

      expect((await put(phone.token, 'p1', 8)).status, 201);
      final mine = await put(phone.token, 'p2', 4);
      expect(mine.status, 429);
      expect(mine.error, 'rate_limited');
      expect(mine.headers.value('retry-after'), isNotNull);
      expect((await put(mac.token, 'm1', 7)).status, 201);
      final full = await put(mac.token, 'm2', 1);
      expect(full.status, 507);
      expect(full.error, 'storage_full');

      // An upload without a length is counted as it arrives.
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final req = await client.openUrl('PUT', h.url('/v1/blobs/p3'));
      req.headers.set('authorization', 'Bearer ${phone.token}');
      req.add(List<int>.filled(4, 7));
      expect((await req.close()).statusCode, 429);
      expect((await h.call('GET', '/v1/blobs/p3', token: mac.token)).status, 404);

      // Downloaded, a blob makes room again.
      expect((await h.call('GET', '/v1/blobs/p1', token: mac.token)).status, 200);
      expect((await put(phone.token, 'p2', 4)).status, 201);
      expect((await h.call('DELETE', '/v1/blobs/m1', token: mac.token)).status, 200);
      expect((await put(mac.token, 'm2', 1)).status, 201);
    });

    test('blobs left from before a restart count toward the server-wide quota', () async {
      final mac = await h.desktop();
      expect((await h.call('PUT', '/v1/blobs/old', token: mac.token, bytes: List<int>.filled(10, 1))).status, 201);
      await h.restart(blobQuota: 12);
      final res = await h.call('PUT', '/v1/blobs/new', token: mac.token, bytes: List<int>.filled(3, 1));
      expect(res.status, 507);
      expect((await h.call('GET', '/v1/blobs/old', token: mac.token)).status, 200);
      expect((await h.call('PUT', '/v1/blobs/new', token: mac.token, bytes: List<int>.filled(3, 1))).status, 201);
    });
  });

  group('push', () {
    final iosToken = 'ab' * 32;
    final androidToken = 'f' * 120;

    Future<void> optIn(String phoneToken) async {
      final res = await h.call('POST', '/v1/push/register', token: phoneToken, body: {'token': 'ee' * 32});
      expect(res.status, 200);
    }

    test('a notification goes to every phone through the relay, and a gone phone is forgotten', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      expect(
        (await h.call(
          'POST',
          '/v1/push/register',
          token: phone.token,
          body: {'token': iosToken, 'label': 'iPhone'},
        )).status,
        200,
      );
      final pixel = await h.phone(mac.token, 'Pixel');
      await h.call(
        'POST',
        '/v1/push/register',
        token: pixel.token,
        body: {'token': androidToken, 'platform': 'android'},
      );

      final enc = base64.encode(List<int>.generate(40, (i) => i));
      h.relay.statusFor[iosToken] = 410;
      final first = await h.call(
        'POST',
        '/v1/push/notify',
        token: mac.token,
        body: {'tag': _tag, 'enc': enc, 'collapse': _ref},
      );
      // Queued for both phones; the relay says the iPhone is gone.
      expect(first.map['sent'], 2);
      expect(
        h.relay.attempts,
        unorderedEquals([
          {'token': iosToken, 'kind': 'terminal', 'enc': enc, 'tag': _tag, 'collapse': _ref},
          {'platform': 'android', 'token': androidToken, 'kind': 'terminal', 'enc': enc, 'tag': _tag, 'collapse': _ref},
        ]),
      );

      h.relay.received.clear();
      final second = await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': enc});
      expect(second.map['sent'], 1);
      expect([for (final b in h.relay.received) b['token']], [androidToken]);
      expect(h.relay.received.single.containsKey('collapse'), isFalse);

      // The relay sees neither the computer's id nor a session key.
      Future<int> notify(Map<String, Object> body) async =>
          (await h.call('POST', '/v1/push/notify', token: mac.token, body: {'enc': enc, ...body})).status;
      expect(await notify({'desktop': 'aaaa1111'}), 400);
      expect(await notify({'tag': 'aaaa1111'}), 400);
      expect(await notify({'tag': _tag, 'collapse': 'aaaa1111/kitty-1/2'}), 400);
    });

    test('a notification that is not sealed is refused', () async {
      final mac = await h.desktop();
      final short = base64.encode(List<int>.filled(28, 0));
      final res = await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': short});
      expect(res.status, 400);
      final badToken = await h.call('POST', '/v1/push/register', token: mac.token, body: {'token': 'xyz'});
      expect(badToken.status, 400);
    });

    test('iPhones get the state alone, Android phones the sealed state, until the session ends; no ids', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      await optIn(phone.token);
      final activity = 'cd' * 80;
      await h.call(
        'POST',
        '/v1/push/activity_register',
        token: phone.token,
        body: {'token': activity, 'session': 'aaaa1111/s1'},
      );
      await h.call(
        'POST',
        '/v1/push/activity_register',
        token: phone.token,
        body: {'token': androidToken, 'session': 'aaaa1111/s1', 'platform': 'android', 'ref': _ref},
      );

      final enc = base64.encode(List<int>.generate(40, (i) => i));
      final needs = await h.call(
        'POST',
        '/v1/push/activity',
        token: mac.token,
        body: {'session': 'aaaa1111/s1', 'state': 'needs', 'kind': 'question', 'tag': _tag, 'enc': enc},
      );
      expect(needs.map['sent'], 2);
      final since = h.now.millisecondsSinceEpoch ~/ 1000;
      final live = {'state': 'needs', 'since': since, 'kind': 'question'};
      expect(
        h.relay.received,
        unorderedEquals([
          {'token': activity, 'kind': 'liveactivity', 'event': 'update', 'state': live},
          {'platform': 'android', 'token': androidToken, 'kind': 'activity', 'enc': enc, 'tag': _tag, 'ref': _ref},
        ]),
      );

      // Without the sealed state an Android phone gets nothing: its state never travels in the clear.
      h.relay.received.clear();
      final plain = await h.call(
        'POST',
        '/v1/push/activity',
        token: mac.token,
        body: {'session': 'aaaa1111/s1', 'state': 'working'},
      );
      expect(plain.map['sent'], 1);
      expect([for (final b in h.relay.received) b['token']], [activity]);

      h.relay.received.clear();
      await h.call('POST', '/v1/push/activity', token: mac.token, body: {'session': 'aaaa1111/s1', 'state': 'ended'});
      final ended = {'state': 'ended', 'since': since};
      expect(
        h.relay.received,
        unorderedEquals([
          {'token': activity, 'kind': 'liveactivity', 'event': 'end', 'state': ended},
          {'platform': 'android', 'token': androidToken, 'kind': 'activity', 'ref': _ref, 'state': ended},
        ]),
      );
      // Nothing on its way to the relay names the computer or the session.
      expect(jsonEncode(h.relay.attempts), isNot(contains('aaaa1111')));
      h.relay.received.clear();
      final after = await h.call(
        'POST',
        '/v1/push/activity',
        token: mac.token,
        body: {'session': 'aaaa1111/s1', 'state': 'done', 'tag': _tag, 'enc': enc},
      );
      expect(after.map['sent'], 0);
      expect(h.relay.received, isEmpty);
    });

    test("a sealed state without its computer's tag, or one not sealed, is refused", () async {
      final mac = await h.desktop();
      final enc = base64.encode(List<int>.generate(40, (i) => i));
      Future<int> activity(Map<String, Object> body) async =>
          (await h.call('POST', '/v1/push/activity', token: mac.token, body: {'state': 'working', ...body})).status;
      expect(await activity({'session': 'aaaa1111/s1', 'desktop': 'aaaa1111', 'enc': enc}), 400);
      expect(await activity({'session': 'aaaa1111/s1', 'enc': enc}), 400);
      expect(await activity({'session': 'aaaa1111/s1', 'tag': 'aaaa1111', 'enc': enc}), 400);
      expect(await activity({'session': 'aaaa1111/s1', 'tag': _tag, 'enc': 'AAAA'}), 400);
      expect(await activity({'session': 's1'}), 400);
    });

    test("an Android phone follows a session only with the session's tag", () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      await optIn(phone.token);
      Future<int> register(Map<String, Object> extra) async => (await h.call(
        'POST',
        '/v1/push/activity_register',
        token: phone.token,
        body: {'token': androidToken, 'session': 'aaaa1111/s1', 'platform': 'android', ...extra},
      )).status;
      expect(await register({}), 400);
      expect(await register({'ref': 'aaaa1111/s1'}), 400);
      expect(await register({'ref': _ref}), 200);
    });

    Future<void> follow(String phoneToken, String session, String token, [String platform = 'ios']) async {
      final res = await h.call(
        'POST',
        '/v1/push/activity_register',
        token: phoneToken,
        body: {'token': token, 'session': session, 'platform': platform, if (platform == 'android') 'ref': _ref},
      );
      expect(res.status, 200);
    }

    Future<int> sentTo(String macToken, String session) async =>
        (await h.call(
              'POST',
              '/v1/push/activity',
              token: macToken,
              body: {'session': session, 'state': 'working'},
            )).map['sent']
            as int;

    test('a computer silent for 3 minutes has its Live Activities ended', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      await optIn(phone.token);
      final quiet = 'c1' * 80;
      final busy = 'c2' * 80;
      final start = h.now;
      await h.call('PUT', '/v1/desktops/aaaa1111', token: mac.token, body: {'name': 'Quiet', 'platform': 'macos'});
      await h.call('PUT', '/v1/desktops/bbbb2222', token: mac.token, body: {'name': 'Busy', 'platform': 'macos'});
      await follow(phone.token, 'aaaa1111/s1', quiet);
      await follow(phone.token, 'aaaa1111/s2', androidToken, 'android');
      await follow(phone.token, 'bbbb2222/s1', busy);

      h.now = start.add(const Duration(minutes: 2, seconds: 59));
      await h.sweep();
      expect(h.relay.received, isEmpty);

      await h.call('PUT', '/v1/desktops/bbbb2222', token: mac.token, body: {'name': 'Busy', 'platform': 'macos'});
      h.now = start.add(const Duration(minutes: 3));
      await h.sweep();
      final ended = {'state': 'ended', 'since': h.now.millisecondsSinceEpoch ~/ 1000};
      expect(
        h.relay.received,
        unorderedEquals([
          {'token': quiet, 'kind': 'liveactivity', 'event': 'end', 'state': ended},
          {'platform': 'android', 'token': androidToken, 'kind': 'activity', 'ref': _ref, 'state': ended},
        ]),
      );

      h.relay.received.clear();
      await h.sweep();
      expect(h.relay.received, isEmpty);
      expect(await sentTo(mac.token, 'aaaa1111/s1'), 0);
      expect(await sentTo(mac.token, 'bbbb2222/s1'), 1);
    });

    test('removing a computer, or signing it out, ends its Live Activities', () async {
      final mac = await h.desktop();
      final other = await h.desktop('Other');
      final phone = await h.phone(mac.token);
      await optIn(phone.token);
      await h.call('PUT', '/v1/desktops/aaaa1111', token: mac.token, body: {'name': 'Mac', 'platform': 'macos'});
      await h.call('PUT', '/v1/desktops/bbbb2222', token: other.token, body: {'name': 'Other', 'platform': 'macos'});
      await follow(phone.token, 'aaaa1111/s1', 'c1' * 80);
      await follow(phone.token, 'bbbb2222/s1', 'c2' * 80);

      expect((await h.call('DELETE', '/v1/desktops/aaaa1111', token: mac.token)).status, 200);
      expect([for (final b in h.relay.received) (b['token'], b['event'])], [('c1' * 80, 'end')]);

      h.relay.received.clear();
      expect((await h.call('DELETE', '/v1/devices/me', token: other.token)).status, 200);
      expect([for (final b in h.relay.received) (b['token'], b['event'])], [('c2' * 80, 'end')]);
      expect((await h.call('GET', '/v1/desktops', token: phone.token)).list, isEmpty);
    });

    test('turning notifications off forgets the phone token and every Live Activity it follows', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      final otherPhone = await h.phone(mac.token);
      await h.call('POST', '/v1/push/register', token: phone.token, body: {'token': iosToken});
      await h.call('POST', '/v1/push/register', token: otherPhone.token, body: {'token': 'ef' * 32});
      await follow(phone.token, 'aaaa1111/s1', 'c1' * 80);
      await follow(otherPhone.token, 'aaaa1111/s1', 'c2' * 80);

      expect((await h.call('POST', '/v1/push/unregister', token: phone.token, body: {'token': iosToken})).status, 200);
      final enc = base64.encode(List<int>.filled(40, 1));
      await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': enc});
      await sentTo(mac.token, 'aaaa1111/s1');
      expect([for (final b in h.relay.received) b['token']], unorderedEquals(['ef' * 32, 'c2' * 80]));

      h.relay.received.clear();
      expect((await h.call('POST', '/v1/push/unregister', token: otherPhone.token)).status, 200);
      await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': enc});
      expect(await sentTo(mac.token, 'aaaa1111/s1'), 0);
      expect(h.relay.received, isEmpty);
    });

    test('revoking a phone forgets its push tokens', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      await h.call('POST', '/v1/push/register', token: phone.token, body: {'token': iosToken});
      await h.call('DELETE', '/v1/devices/${phone.id}', token: mac.token);
      final enc = base64.encode(List<int>.filled(40, 1));
      final res = await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': enc});
      expect(res.map['sent'], 0);
      expect(h.relay.received, isEmpty);
    });

    test("only the session's computer moves its Live Activities; a phone stops following only for itself", () async {
      final mac = await h.desktop();
      final other = await h.desktop('Other');
      final phone = await h.phone(mac.token);
      final pad = await h.phone(mac.token, 'iPad');
      await optIn(phone.token);
      await h.call('POST', '/v1/push/register', token: pad.token, body: {'token': 'ef' * 32});
      await h.call('PUT', '/v1/desktops/aaaa1111', token: mac.token, body: {'name': 'Mac', 'platform': 'macos'});
      await follow(phone.token, 'aaaa1111/s1', 'c1' * 80);
      await follow(pad.token, 'aaaa1111/s1', 'c2' * 80);

      for (final caller in [other.token, phone.token]) {
        for (final state in ['working', 'ended']) {
          final res = await h.call(
            'POST',
            '/v1/push/activity',
            token: caller,
            body: {'session': 'aaaa1111/s1', 'state': state},
          );
          expect(res.status, 403);
        }
      }
      expect(h.relay.received, isEmpty);
      expect(await sentTo(mac.token, 'aaaa1111/s1'), 2);

      // Another phone naming this phone's token ends nothing; the phone itself can.
      Future<int> end(String phoneToken) async => (await h.call(
        'POST',
        '/v1/push/activity_end',
        token: phoneToken,
        body: {'token': 'c1' * 80, 'session': 'aaaa1111/s1'},
      )).status;
      expect(await end(pad.token), 200);
      expect(await sentTo(mac.token, 'aaaa1111/s1'), 2);
      expect(await end(phone.token), 200);
      expect(await sentTo(mac.token, 'aaaa1111/s1'), 1);
    });
  });

  test('a restart keeps devices, computers, push tokens, the server id and the setup link', () async {
    final mac = await h.desktop();
    final phone = await h.phone(mac.token);
    await h.call('PUT', '/v1/desktops/aaaa1111', token: mac.token, body: {'name': 'Mac', 'platform': 'macos'});
    await h.call('POST', '/v1/push/register', token: phone.token, body: {'token': 'ab' * 32});
    await h.call('PUT', '/v1/blobs/kept', token: phone.token, bytes: [9]);
    final id = ((await h.call('GET', '/v1/me', token: mac.token)).map['server'] as Map)['id'];
    final link = h.server.setupLink();

    await h.restart();

    final me = await h.call('GET', '/v1/me', token: phone.token);
    expect(me.status, 200);
    expect((me.map['server'] as Map)['id'], id);
    expect(h.server.setupLink(), link);
    expect((await h.call('GET', '/v1/desktops', token: phone.token)).list.single, containsPair('name', 'Mac'));
    expect((await h.call('GET', '/v1/blobs/kept', token: mac.token)).bytes, [9]);
    final enc = base64.encode(List<int>.filled(40, 1));
    final res = await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': enc});
    expect(res.map['sent'], 1);
  });
}
