import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'own_server.dart';

void main() {
  group('Backend.parse', () {
    test('normalizes the server URL', () {
      for (final url in ['https://pt.example.com', ' https://pt.example.com/ ', 'https://pt.example.com/v1/']) {
        expect(Backend.parse(url).backend?.url, 'https://pt.example.com', reason: url);
      }
    });

    test('allows plain http only to this machine; Tailscale and the local network need https', () {
      for (final url in ['http://127.0.0.1:47900', 'http://localhost:47900', 'https://mac.tail1234.ts.net']) {
        expect(Backend.parse(url).backend, isNotNull, reason: url);
      }
      for (final url in [
        'http://pt.example.com',
        'http://192.168.1.20:47900',
        'http://mac.local:47900',
        'http://100.64.0.1:47900',
        'http://mac.tail1234.ts.net:47900',
      ]) {
        expect(Backend.parse(url).error, isNotNull, reason: url);
      }
    });

    test('rejects garbage', () {
      expect(Backend.parse('').error, isNotNull);
      expect(Backend.parse('pt.example.com').error, isNotNull);
      expect(Backend.parse('https://pt.example.com/x').error, isNotNull);
    });
  });

  test('setup links round-trip', () {
    const b = Backend(url: 'https://pt.example.com');
    expect(Backend.fromLink(b.link), b);
    expect(Backend.fromLink(Uri.parse('pocketterm://todos')), isNull);
    expect(Backend.fromLink(Uri.parse('pocketterm://setup?code=K7QM')), isNull);
  });

  test('a setup link carrying a key is not one and never connects', () {
    final other = Uri.parse(
      'pocketterm://setup?url=https://abcd.supabase.co&key=sb_publishable_x&code=K7QM&d=abcd1234&k=AAAA',
    );
    expect(Backend.fromLink(other), isNull);
    expect(Backend.pairingCode(other), isNull);
    expect(Backend.computerKey(other), isNull);
  });

  test("a computer's setup token and a phone's code are read back; links without them have none", () {
    const b = Backend(url: 'https://pt.example.com');
    final computer = Uri.parse('pocketterm://setup?url=https://pt.example.com&setup=abc_DEF-123');
    expect(Backend.fromLink(computer), b);
    expect(Backend.setupToken(computer), 'abc_DEF-123');
    expect(Backend.pairingCode(computer), isNull);
    final phone = b.linkWithCode('K7QM-3XRT-AB12');
    expect(Backend.pairingCode(phone), 'K7QM-3XRT-AB12');
    expect(Backend.setupToken(phone), isNull);
    expect(Backend.pairingCode(b.link), isNull);
    expect(Backend.pairingCode(Uri.parse('pocketterm://setup?url=https://pt.example.com&code=')), isNull);
    expect(Backend.pairingCode(Uri.parse('pocketterm://todos?code=K7QM')), isNull);
    // A link with a code but no usable server is no link at all.
    expect(Backend.pairingCode(Uri.parse('pocketterm://setup?url=ftp://x&code=K7QM')), isNull);
  });

  test("a computer's QR carries its id and key next to the code; a link without them still signs in", () {
    const b = Backend(url: 'https://pt.example.com');
    final key = ChannelKey.generate();
    final link = b.linkWithCode('K7QM-3XRT-AB12', computer: (desktop: 'abcd1234', key: key));
    expect(Backend.pairingCode(link), 'K7QM-3XRT-AB12');
    expect(Backend.computerKey(link), (desktop: 'abcd1234', key: key));
    // Its key is a secret; it rides the link as is, URL-safe.
    expect(link.queryParameters['k'], key.toBase64Url());
    expect(Backend.computerKey(b.linkWithCode('K7QM-3XRT-AB12')), isNull);
    expect(Backend.pairingCode(b.linkWithCode('K7QM-3XRT-AB12')), 'K7QM-3XRT-AB12');
    // A key cut short, or an id that isn't a computer's, is no key.
    final good = link.queryParameters;
    expect(Backend.computerKey(link.replace(queryParameters: {...good, 'k': 'AAAA'})), isNull);
    expect(Backend.computerKey(link.replace(queryParameters: {...good, 'd': '../etc'})), isNull);
  });

  test("a Supabase project's links say so, and every link made from it keeps saying so", () {
    const b = Backend(url: 'https://abcdefghijklmnop.supabase.co', kind: BackendKind.supabase);
    expect(b.api, 'https://abcdefghijklmnop.supabase.co/functions/v1/pocketterm');
    final key = ChannelKey.generate();
    for (final link in [
      b.link,
      b.linkWithSetup('abc'),
      b.linkWithCode('K7QM', computer: (desktop: 'abcd1234', key: key)),
    ]) {
      expect(Backend.fromLink(link), b, reason: '$link');
    }
    expect(Backend.setupToken(b.linkWithSetup('abc')), 'abc');
    // The same URL as a PocketTerm server is another server.
    expect(Backend.fromLink(Uri.parse('pocketterm://setup?url=https://abcdefghijklmnop.supabase.co')), isNot(b));
    // The function's own URL, pasted, is the project.
    expect(
      Backend.parse(
        'https://abcdefghijklmnop.supabase.co/functions/v1/pocketterm/v1',
        kind: BackendKind.supabase,
      ).backend,
      b,
    );
    // A kind this app doesn't know is no link it can use.
    final unknown = Uri.parse('pocketterm://setup?kind=firebase&url=https://x.example.com&setup=abc');
    expect(Backend.fromLink(unknown), isNull);
    expect(Backend.setupToken(unknown), isNull);
  });

  group('check', () {
    test('a PocketTerm server passes; anything else answering is named', () async {
      final own = await OwnServer.start();
      addTearDown(own.stop);
      expect(await own.backend.check(), isNull);

      final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(other.close);
      other.listen((req) async {
        req.response.write('<html>hello</html>');
        await req.response.close();
      });
      expect(await Backend(url: 'http://127.0.0.1:${other.port}').check(), contains('No PocketTerm server'));
    });

    test('a server that drops the connection mid-answer is a message, not a throw', () async {
      // Answers half a status line, then hangs up: HttpException, not SocketException.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((socket) async {
        socket.write('HTTP/1.1 200');
        await socket.flush();
        await socket.close();
      });
      final problem = await Backend(url: 'http://127.0.0.1:${server.port}').check();
      expect(problem, contains("Couldn't reach"));
    });

    test('a server that sends its headers and then stalls the body times out with a message', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        req.response
          ..contentLength = 100
          ..write('{"pocketterm":');
        await req.response.flush();
      });
      final health = await Backend(url: 'http://127.0.0.1:${server.port}')
          .health(wait: const Duration(milliseconds: 300))
          .timeout(const Duration(seconds: 5));
      expect(health.error, contains('took too long to answer'));
    });

    /// A server on a free port that answers every request with [answer].
    Future<Backend> answering(void Function(HttpResponse res) answer) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        answer(req.response);
        await req.response.close();
      });
      return Backend(url: 'http://127.0.0.1:${server.port}');
    }

    test("a device whose clock is off the server's is told; one close enough is not", () async {
      final own = await OwnServer.start();
      addTearDown(own.stop);
      final ok = await own.backend.health();
      expect(ok.error, isNull);
      expect(Backend.clockWarning(ok.clockOffset), isNull);

      final ahead = await answering(
        (res) => res.write(
          jsonEncode({
            'pocketterm': 1,
            'version': Backend.minServer,
            'time': DateTime.now().add(const Duration(minutes: 10)).toUtc().toIso8601String(),
          }),
        ),
      );
      final skewed = await ahead.health();
      expect(skewed.error, isNull);
      expect(skewed.clockOffset!.inMinutes, inInclusiveRange(9, 10));
      expect(Backend.clockWarning(skewed.clockOffset), contains('10 minutes behind'));
      expect(Backend.clockWarning(const Duration(minutes: -3)), contains('ahead of'));
      expect(Backend.clockWarning(const Duration(seconds: 90)), isNull);
    });

    test('a server older than this app needs says to update it', () async {
      final old = await answering((res) => res.write(jsonEncode({'pocketterm': 1, 'version': '0.0.9'})));
      expect(await old.check(), contains('Update the server'));
      final newer = await answering((res) => res.write(jsonEncode({'pocketterm': 1, 'version': '0.10.0'})));
      expect(await newer.check(), isNull);
    });

    test("Cloudflare that can't reach the server, and a redirect loop, are named as such", () async {
      final cloudflare = await answering(
        (res) => res
          ..statusCode = 521
          ..headers.set('cf-ray', '8a1b2c3d4e5f-FRA'),
      );
      expect(await cloudflare.check(), contains('Cloudflare'));

      late final Backend loop;
      loop = await answering(
        (res) => res
          ..statusCode = 301
          ..headers.set('location', '${loop.url}/v1/health'),
      );
      expect(await loop.check(), contains('redirecting'));
    });
  });

  group('where the backend is kept', () {
    const backend = Backend(url: 'https://pt.example.com');
    const supabase = Backend(url: 'https://abcdefghijklmnop.supabase.co', kind: BackendKind.supabase);

    test("a computer's is in its shared preferences; one saved for a Supabase project isn't a server", () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      expect(await Backend.load(desktop: true), isNull);
      await backend.save(desktop: true);
      expect(await Backend.load(desktop: true), backend);
      await supabase.save(desktop: true);
      expect(await Backend.load(desktop: true), supabase);
      await backend.save(desktop: true);
      expect(await Backend.load(desktop: true), backend, reason: 'a server after a Supabase project is no project');
      await Backend.clear(desktop: true);
      expect(await Backend.load(desktop: true), isNull);

      SharedPreferences.setMockInitialValues({'backend_url': 'https://abc.supabase.co', 'backend_key': 'sb_x'});
      expect(await Backend.load(desktop: true), isNull);
    });

    test("a phone's is where its native side reads it", () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      Map<Object?, Object?>? native;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('pocketterm/native'),
        (call) async => switch (call.method) {
          'setBackend' => native = call.arguments as Map<Object?, Object?>,
          'getBackend' => native?['url'] == null ? null : native,
          _ => null,
        },
      );
      await backend.save(desktop: false);
      expect(native, {'url': backend.url, 'kind': null});
      expect(await Backend.load(desktop: true), isNull);
      expect(await Backend.load(desktop: false), backend);
      await supabase.save(desktop: false);
      expect(native, {'url': supabase.url, 'kind': 'supabase'});
      expect(await Backend.load(desktop: false), supabase);
      native = {'url': 'https://abc.supabase.co', 'key': 'sb_x'};
      expect(await Backend.load(desktop: false), isNull, reason: 'a Supabase project from an app before');
      await Backend.clear(desktop: false);
      expect(await Backend.load(desktop: false), isNull);
    });
  });
}
