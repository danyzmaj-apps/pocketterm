import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Backend.parse', () {
    test('normalizes the project URL', () {
      for (final url in [
        'https://abc.supabase.co',
        ' https://abc.supabase.co/ ',
        'https://abc.supabase.co/rest/v1/',
        'https://abc.supabase.co/auth/v1',
      ]) {
        expect(Backend.parse(url, 'sb_publishable_x').backend?.url, 'https://abc.supabase.co', reason: url);
      }
    });

    test('allows plain http only for local servers', () {
      expect(Backend.parse('http://127.0.0.1:54321', 'k').backend, isNotNull);
      expect(Backend.parse('http://192.168.1.20:54321', 'k').backend, isNotNull);
      expect(Backend.parse('http://abc.supabase.co', 'k').error, isNotNull);
    });

    test('rejects secret keys', () {
      expect(Backend.parse('https://abc.supabase.co', 'sb_secret_abc').error, contains('secret'));
      // A legacy service_role JWT: {"role":"service_role"}.
      const serviceRole = 'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.sig';
      expect(Backend.parse('https://abc.supabase.co', serviceRole).error, contains('secret'));
      const anon = 'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.sig';
      expect(Backend.parse('https://abc.supabase.co', anon).backend, isNotNull);
    });

    test('rejects garbage', () {
      expect(Backend.parse('', 'k').error, isNotNull);
      expect(Backend.parse('abc.supabase.co', 'k').error, isNotNull);
      expect(Backend.parse('https://abc.supabase.co/x', 'k').error, isNotNull);
      expect(Backend.parse('https://abc.supabase.co', ' ').error, isNotNull);
    });
  });

  test('setup links round-trip', () {
    const b = Backend(url: 'https://abc.supabase.co', key: 'sb_publishable_x');
    expect(Backend.fromLink(b.link), b);
    expect(Backend.fromLink(Uri.parse('pocketterm://todos')), isNull);
    expect(Backend.fromLink(Uri.parse('pocketterm://setup?url=https://abc.supabase.co')), isNull);
  });

  test("a setup link's sign-in code is read back; links without one, or not setup links, have none", () {
    const b = Backend(url: 'https://abc.supabase.co', key: 'sb_publishable_x');
    final link = b.linkWithCode('K7QM-3XRT-AB12');
    expect(Backend.fromLink(link), b);
    expect(Backend.pairingCode(link), 'K7QM-3XRT-AB12');
    expect(Backend.pairingCode(b.link), isNull);
    expect(Backend.pairingCode(Uri.parse('pocketterm://setup?url=https://abc.supabase.co&key=k&code=')), isNull);
    expect(Backend.pairingCode(Uri.parse('pocketterm://todos?code=K7QM')), isNull);
    // A link with a code but no usable server is no link at all.
    expect(Backend.pairingCode(Uri.parse('pocketterm://setup?url=ftp://x&key=k&code=K7QM')), isNull);
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
    final problem = await Backend(url: 'http://127.0.0.1:${server.port}', key: 'k').check();
    expect(problem, contains("Couldn't reach"));
  });

  group('where the backend is kept', () {
    const backend = Backend(url: 'https://abc.supabase.co', key: 'sb_publishable_x');

    test("a computer's is in its shared preferences", () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      expect(await Backend.load(desktop: true), isNull);
      await backend.save(desktop: true);
      expect(await Backend.load(desktop: true), backend);
      await Backend.clear(desktop: true);
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
      expect(native, {'url': backend.url, 'key': backend.key});
      expect(await Backend.load(desktop: true), isNull);
      expect(await Backend.load(desktop: false), backend);
      await Backend.clear(desktop: false);
      expect(await Backend.load(desktop: false), isNull);
    });
  });
}
