import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Socket;
import 'dart:io' as io show Socket;

import 'package:pocketterm_server/pocketterm_server.dart';
import 'package:pocketterm_server/src/hub.dart' show maxSocketsPerDevice;
import 'package:pocketterm_server/src/relay.dart';
import 'package:pocketterm_server/src/secrets.dart' show newPairingCode, normalizePairingCode, sha256Hex;
import 'package:pocketterm_server/src/server.dart' show callerKey;
import 'package:test/test.dart';

import 'harness.dart';

/// A computer's push tag and a session's (pocketterm_core's pushTag, sessionTag).
const _tag = 'RJM0r7AxRLM';
const _ref = 'yMPqtkm1TA3-r0AeuNDSHg';

void main() {
  late Harness h;
  setUp(() async => h = await Harness.start());
  tearDown(() => h.close());

  final enc = base64.encode(List<int>.generate(40, (i) => i));

  group('state on disk', () {
    File state() => File('${h.dir.path}/state.json');

    test('a state.json that no longer reads is set aside and the one before it takes over', () async {
      final mac = await h.desktop();
      // A second save: the backup now holds the computer too.
      await h.call('PUT', '/v1/desktops/aaaa1111', token: mac.token, body: {'name': 'Mac', 'platform': 'macos'});
      await h.server.stop();
      state().writeAsStringSync('{"server_id": "abc", "devi');

      final logged = <String>[];
      await h.restart(log: logged.add);
      expect((await h.call('GET', '/v1/me', token: mac.token)).status, 200);
      final kept = h.dir.listSync().whereType<File>().where((f) => f.path.contains('state.json.corrupt-'));
      expect(kept.single.readAsStringSync(), '{"server_id": "abc", "devi');
      expect(logged.join('\n'), contains('state.json.corrupt-'));
    });

    test('without a usable backup the server refuses to start and leaves state.json alone', () async {
      final mac = await h.desktop();
      await h.server.stop();
      state().writeAsStringSync('not json');
      File('${h.dir.path}/state.json.bak').writeAsStringSync('not json either');

      await expectLater(h.restart(), throwsA(isA<StorageException>()));
      expect(state().readAsStringSync(), 'not json');
      // Nothing was made in its place: a second try fails the same way.
      await expectLater(h.restart(), throwsA(isA<StorageException>()));
      expect(mac.token, isNotEmpty);
    });

    test('a save cut off between its renames is picked up from the new file', () async {
      final mac = await h.desktop();
      await h.server.stop();
      state().renameSync('${state().path}.tmp');
      File('${state().path}.bak').deleteSync();

      await h.restart();
      expect((await h.call('GET', '/v1/me', token: mac.token)).status, 200);
    });

    test('a second server on the same data folder does not start', () async {
      await h.server.stop();
      final holder = await Process.start(Platform.resolvedExecutable, ['run', 'test/lock_holder.dart', h.dir.path]);
      try {
        expect(await holder.stdout.transform(utf8.decoder).first, contains('held'));
        await expectLater(h.restart(), throwsA(isA<StorageException>()));
      } finally {
        await holder.stdin.close();
        await holder.exitCode;
      }
      await h.restart();
      expect((await h.call('GET', '/v1/health')).status, 200);
    });

    test(
      'a data folder that stops taking writes answers 507, and reads keep working',
      () async {
        final mac = await h.desktop();
        final phone = await h.phone(mac.token);
        Process.runSync('chmod', ['500', h.dir.path]);
        try {
          final res = await h.call('POST', '/v1/push/register', token: phone.token, body: {'token': 'ab' * 32});
          expect(res.status, 507);
          expect(res.error, 'storage');
          expect(res.map['message'], isA<String>());
          // A redeem that can't be saved signs nobody in.
          final code = await h.call('POST', '/v1/pair', token: mac.token);
          expect(code.status, 507);
          // The seen stamp can't be saved either; the request still works.
          h.now = h.now.add(const Duration(minutes: 5));
          expect((await h.call('GET', '/v1/me', token: mac.token)).status, 200);
        } finally {
          Process.runSync('chmod', ['700', h.dir.path]);
        }
        expect((await h.call('POST', '/v1/pair', token: mac.token)).status, 200);
      },
      skip: Platform.isWindows || Process.runSync('id', ['-u']).stdout.toString().trim() == '0'
          ? 'needs POSIX permissions as a non-root user'
          : null,
    );

    test(
      'a revoke or an erase that cannot be saved changes nothing: tokens and sockets keep working',
      () async {
        final mac = await h.desktop();
        final phone = await h.phone(mac.token);
        final ws = await h.socket(phone.token);
        await ws.join('aaaa1111');
        Process.runSync('chmod', ['500', h.dir.path]);
        try {
          expect((await h.call('DELETE', '/v1/devices/${phone.id}', token: mac.token)).status, 507);
          expect((await h.call('POST', '/v1/erase', token: mac.token)).status, 507);
          expect((await h.call('GET', '/v1/me', token: phone.token)).status, 200);
          expect((await h.call('GET', '/v1/me', token: mac.token)).status, 200);
          ws.send({'t': 'ping'});
          expect((await ws.next())['t'], 'pong');
        } finally {
          Process.runSync('chmod', ['700', h.dir.path]);
        }
        // Once the disk takes writes, the same revoke goes through.
        expect((await h.call('DELETE', '/v1/devices/${phone.id}', token: mac.token)).status, 200);
        expect(await ws.closed, 4003);
        await h.restart();
        expect((await h.call('GET', '/v1/me', token: phone.token)).status, 401);
      },
      skip: Platform.isWindows || Process.runSync('id', ['-u']).stdout.toString().trim() == '0'
          ? 'needs POSIX permissions as a non-root user'
          : null,
    );

    test('a computer that signs out takes its unused pairing codes with it', () async {
      final mac = await h.desktop();
      final other = await h.desktop('Other');
      final gone = (await h.call('POST', '/v1/pair', token: mac.token)).map['code'] as String;
      final kept = (await h.call('POST', '/v1/pair', token: other.token)).map['code'] as String;
      expect((await h.call('DELETE', '/v1/devices/me', token: mac.token)).status, 200);
      Future<int> redeem(String code) async =>
          (await h.call('POST', '/v1/pair/redeem', body: {'code': code, 'platform': 'ios'})).status;
      expect(await redeem(gone), 400);
      expect(await redeem(kept), 200);
    });

    test('a state.json whose pairing codes do not name their computer still loads, codes working', () async {
      final mac = await h.desktop();
      await h.server.stop();
      final code = newPairingCode();
      final j = jsonDecode(state().readAsStringSync()) as Map<String, dynamic>;
      j['pairing_codes'] = [
        {
          'hash': sha256Hex(normalizePairingCode(code)),
          'expires': h.now.add(const Duration(minutes: 5)).toUtc().toIso8601String(),
        },
      ];
      state().writeAsStringSync(jsonEncode(j));

      await h.restart();
      expect((await h.call('GET', '/v1/me', token: mac.token)).status, 200);
      final res = await h.call('POST', '/v1/pair/redeem', body: {'code': code, 'platform': 'ios'});
      expect(res.status, 200);
    });

    test('an upload cut off midway leaves nothing behind', () async {
      final mac = await h.desktop();
      final socket = await io.Socket.connect(InternetAddress.loopbackIPv4, h.server.port);
      socket.write(
        'PUT /v1/blobs/cut HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer ${mac.token}\r\n'
        'Content-Length: 100000\r\n\r\n${'x' * 1000}',
      );
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(Directory('${h.dir.path}/blobs').listSync(), isEmpty);
      expect((await h.call('GET', '/v1/blobs/cut', token: mac.token)).status, 404);
    });
  });

  group('relay', () {
    test('a relay that never answers holds up no request', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      await h.call('POST', '/v1/push/register', token: phone.token, body: {'token': 'ab' * 32});
      h.relay.hang = true;
      final watch = Stopwatch()..start();
      final res = await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': enc});
      expect(res.map['sent'], 1);
      expect((await h.call('DELETE', '/v1/devices/${phone.id}', token: mac.token)).status, 200);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('a push the relay turns away for a moment (5xx, 429) arrives once it takes it', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      final token = 'ab' * 32;
      await h.call('POST', '/v1/push/register', token: phone.token, body: {'token': token});
      h.relay.script[token] = [503, 429];
      await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': enc});
      expect(h.relay.attempts, hasLength(3));
      expect(h.relay.received.single['token'], token);
    });

    test('a phone the relay says is gone gets nothing more, its followed sessions included', () async {
      final mac = await h.desktop();
      final pixel = await h.phone(mac.token);
      final fcm = 'f' * 120;
      await h.call('POST', '/v1/push/register', token: pixel.token, body: {'token': fcm, 'platform': 'android'});
      await h.call(
        'POST',
        '/v1/push/activity_register',
        token: pixel.token,
        body: {'token': fcm, 'session': 'aaaa1111/s1', 'platform': 'android', 'ref': _ref},
      );
      h.relay.statusFor[fcm] = 410;
      await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': enc});
      h.relay.attempts.clear();
      final after = await h.call(
        'POST',
        '/v1/push/activity',
        token: mac.token,
        body: {'session': 'aaaa1111/s1', 'state': 'working', 'tag': _tag, 'enc': enc},
      );
      expect(after.map['sent'], 0);
      expect(h.relay.attempts, isEmpty);
    });
  });

  group('relay queue', () {
    late HttpServer relay;
    late List<Map<String, dynamic>> got;
    late List<int> publicKey;
    var status = 200;
    var delay = Duration.zero;

    setUp(() async {
      final fake = h.relay;
      publicKey = await fake.publicKey;
      got = [];
      status = 200;
      delay = Duration.zero;
      relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        ..listen((req) async {
          final sealed = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
          got.add(jsonDecode(utf8.decode(await openSealed(fake.keyPair, sealed))) as Map<String, dynamic>);
          await Future<void>.delayed(delay);
          req.response.statusCode = status;
          await req.response.close();
        });
    });
    tearDown(() => relay.close(force: true));

    Relay client() =>
        Relay(Uri.parse('http://127.0.0.1:${relay.port}/'), publicKey, firstRetry: const Duration(milliseconds: 10));

    test('a newer state replaces one still waiting and never overtakes one on its way', () async {
      final r = client();
      delay = const Duration(milliseconds: 200);
      r.send({'token': 't', 'state': 'working'}, key: 'a|t|s');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      r
        ..send({'token': 't', 'state': 'needs'}, key: 'a|t|s')
        ..send({'token': 't', 'state': 'done'}, key: 'a|t|s');
      await r.idle();
      expect([for (final b in got) b['state']], ['working', 'done']);
      r.close();
    });

    test('at most maxQueued wait; the oldest go first', () async {
      final r = client();
      delay = const Duration(seconds: 5);
      for (var i = 0; i < Relay.maxQueued + 100; i++) {
        r.send({'token': '$i'});
      }
      expect(r.pending, Relay.maxQueued + Relay.concurrency);
      r.close();
    });

    test('a relay that keeps failing is given up on after maxAttempts; a 4xx is never retried', () async {
      final r = client();
      status = 503;
      r.send({'token': 'a'});
      await r.idle();
      expect(got, hasLength(Relay.maxAttempts));

      got.clear();
      status = 501;
      r.send({'token': 'b'});
      await r.idle();
      expect(got, hasLength(1));
      r.close();
    });
  });

  group('push tokens', () {
    test("a phone's new push token replaces its old one and takes over its followed sessions, tags and all", () async {
      final mac = await h.desktop();
      final pixel = await h.phone(mac.token);
      final old = 'f' * 120;
      final fresh = 'g' * 120;
      await h.call('POST', '/v1/push/register', token: pixel.token, body: {'token': old, 'platform': 'android'});
      await h.call(
        'POST',
        '/v1/push/activity_register',
        token: pixel.token,
        body: {'token': old, 'session': 'aaaa1111/s1', 'platform': 'android', 'ref': _ref},
      );
      await h.call(
        'POST',
        '/v1/push/activity_register',
        token: pixel.token,
        body: {'token': old, 'session': 'aaaa1111/s2', 'platform': 'android', 'ref': 'r' * 22},
      );
      // Android hands the new token to both at once: the session may be followed anew before the token registers.
      await h.call(
        'POST',
        '/v1/push/activity_register',
        token: pixel.token,
        body: {'token': fresh, 'session': 'aaaa1111/s1', 'platform': 'android', 'ref': _ref},
      );
      await h.call('POST', '/v1/push/register', token: pixel.token, body: {'token': fresh, 'platform': 'android'});

      await h.call('POST', '/v1/push/notify', token: mac.token, body: {'tag': _tag, 'enc': enc});
      await h.call(
        'POST',
        '/v1/push/activity',
        token: mac.token,
        body: {'session': 'aaaa1111/s1', 'state': 'working', 'tag': _tag, 'enc': enc},
      );
      expect([for (final b in h.relay.received) (b['kind'], b['token'])], [('terminal', fresh), ('activity', fresh)]);
      expect(h.relay.received.last['ref'], _ref);

      h.relay.received.clear();
      await h.call(
        'POST',
        '/v1/push/activity',
        token: mac.token,
        body: {'session': 'aaaa1111/s2', 'state': 'working', 'tag': _tag, 'enc': enc},
      );
      expect((h.relay.received.single['token'], h.relay.received.single['ref']), (fresh, 'r' * 22));
    });

    test('a phone with notifications off follows no session', () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      final res = await h.call(
        'POST',
        '/v1/push/activity_register',
        token: phone.token,
        body: {'token': 'cd' * 80, 'session': 'aaaa1111/s1'},
      );
      expect(res.status, 409);
      expect(res.error, 'push_off');
      final sent = await h.call(
        'POST',
        '/v1/push/activity',
        token: mac.token,
        body: {'session': 'aaaa1111/s1', 'state': 'working'},
      );
      expect(sent.map['sent'], 0);
    });

    test("erasing, or revoking a phone, ends the phones' Live Activities", () async {
      final mac = await h.desktop();
      final phone = await h.phone(mac.token);
      final lost = await h.phone(mac.token, 'Lost');
      for (final (p, activity) in [(phone, 'c1' * 80), (lost, 'c2' * 80)]) {
        await h.call('POST', '/v1/push/register', token: p.token, body: {'token': activity.substring(0, 64)});
        await h.call(
          'POST',
          '/v1/push/activity_register',
          token: p.token,
          body: {'token': activity, 'session': 'aaaa1111/s1'},
        );
      }
      // The lost phone's computer still checks in: only the revoke ends its activity.
      await h.call('PUT', '/v1/desktops/aaaa1111', token: mac.token, body: {'name': 'Mac', 'platform': 'macos'});

      await h.call('DELETE', '/v1/devices/${lost.id}', token: mac.token);
      expect([for (final b in h.relay.received) (b['token'], b['event'])], [('c2' * 80, 'end')]);

      h.relay.received.clear();
      await h.call('POST', '/v1/erase', token: mac.token);
      expect([for (final b in h.relay.received) (b['token'], b['event'])], [('c1' * 80, 'end')]);
    });
  });

  group('callers and connections', () {
    test('an IPv6 caller counts by its /64; an IPv4-mapped one as its IPv4 address', () {
      expect(callerKey('2001:db8:1:2:aaaa::1'), callerKey('2001:db8:1:2:bbbb::9'));
      expect(callerKey('2001:db8:1:2::1'), isNot(callerKey('2001:db8:1:3::1')));
      expect(callerKey('::ffff:192.0.2.7'), '192.0.2.7');
      expect(callerKey('192.0.2.7'), '192.0.2.7');
    });

    test('a guesser hopping addresses within one IPv6 /64 is locked out all the same', () async {
      await h.restart(trustLoopbackProxy: true);
      Future<int> redeem(String from) async => (await h.call(
        'POST',
        '/v1/pair/redeem',
        body: {'code': 'AAAA-0000', 'platform': 'ios'},
        headers: {'x-forwarded-for': from},
      )).status;
      for (var i = 0; i < 10; i++) {
        expect(await redeem('2001:db8:1:2::${i + 1}'), 400);
      }
      expect(await redeem('2001:db8:1:2:ffff::1'), 429);
      expect(await redeem('2001:db8:9:9::1'), 400);
    });

    test('one device holds at most maxSocketsPerDevice live connections', () async {
      final mac = await h.desktop();
      final open = [for (var i = 0; i < maxSocketsPerDevice; i++) await h.socket(mac.token)];
      await expectLater(h.socket(mac.token), throwsA(isA<WebSocketException>()));
      await open.first.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final again = await h.socket(mac.token);
      await again.join('aaaa1111');
      for (final s in [...open.skip(1), again]) {
        await s.close();
      }
    });

    test("health tells the server's time, for apps to spot a wrong clock", () async {
      final time = DateTime.parse((await h.call('GET', '/v1/health')).map['time'] as String);
      expect(time.difference(DateTime.now()).abs(), lessThan(const Duration(seconds: 5)));
    });
  });
}
