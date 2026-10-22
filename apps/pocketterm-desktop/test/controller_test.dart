// kitty's /tmp sockets.
@Tags(['posix'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_desktop/controller.dart';

import 'app_fakes.dart';

void main() {
  test("kitty's sockets are in /tmp unless POCKETTERM_KITTY_DIR names another directory", () {
    expect(AppController.kittyDir({}), '/tmp');
    expect(AppController.kittyDir({'POCKETTERM_KITTY_DIR': ''}), '/tmp');
    expect(AppController.kittyDir({'POCKETTERM_KITTY_DIR': '/tmp/pocketterm-e2e'}), '/tmp/pocketterm-e2e');
  });

  testWidgets('signed out, nothing goes to the phone, and the computer is not even asked', (tester) async {
    final app = await FakeApp.create();
    app.fakeUser = null;
    expect(await app.notifyPhone('omp finished · app', 'Done.', session: 'kitty:/tmp/k/1'), isFalse);
    expect(app.host.calls, isEmpty);
  });

  testWidgets('at the desk (input within the minute), nothing goes to the phone', (tester) async {
    final app = await FakeApp.create();
    app.host.idle = 59;
    expect(await app.notifyPhone('omp finished · app', 'Done.'), isFalse);
    expect(app.host.calls, ['idleSeconds']);
  });

  testWidgets("a push goes sealed: outside the seal only tags that mean nothing without this computer's key", (
    tester,
  ) async {
    await tester.runAsync(() async {
      final app = await FakeApp.create();
      app.host.idle = 600;
      expect(
        await app.notifyPhone('omp finished · secret-project', 'Fixed the login bug.', session: 'kitty-1/2'),
        isTrue,
      );

      final body = app.pushes.single;
      final desktop = app.desktopId(app.fakeUser!.id);
      final key = Backend.computerKey(await app.pairingLink())!.key;
      expect(body.keys, unorderedEquals(['action', 'tag', 'enc', 'collapse']));
      expect(body['action'], 'notify');
      // The phone finds this computer's key by its tag; a newer push for the session replaces this one.
      expect(body['tag'], await pushTag(key));
      expect(body['collapse'], await sessionTag(key, '$desktop/kitty-1/2'));
      expect(
        jsonEncode(body),
        isNot(anyOf(contains('secret-project'), contains('login'), contains('finished'), contains(desktop))),
      );
      expect(jsonEncode(body), isNot(contains('kitty-1/2')));

      // A phone that scanned this computer's code opens it.
      final opened = await openBytes(key, base64Decode(body['enc']! as String), pushAad(desktop));
      final notice = jsonDecode(utf8.decode(opened!)) as Map<String, dynamic>;
      expect(notice, {
        'title': 'omp finished · secret-project',
        'body': 'Fixed the login bug.',
        'session': '$desktop/kitty-1/2',
        // A phone refuses an old or repeated notice.
        'ts': isA<int>().having((t) => DateTime.now().millisecondsSinceEpoch - t, 'age (ms)', lessThan(60000)),
        'id': isA<String>(),
      });
      expect(await openBytes(key, base64Decode(body['enc']! as String), pushAad('zzzz9999')), isNull);
    });
  });

  testWidgets("Reset key: the code carries a new key, and a phone with the old one can't open what comes next", (
    tester,
  ) async {
    await tester.runAsync(() async {
      final app = await FakeApp.create();
      app.host.idle = 600;
      final old = Backend.computerKey(await app.pairingLink())!;
      expect(Backend.computerKey(await app.pairingLink()), old, reason: 'the key stays until reset');

      await app.resetChannelKey();
      final fresh = Backend.computerKey(await app.pairingLink())!;
      expect(fresh.desktop, old.desktop);
      expect(fresh.key, isNot(old.key));

      await app.notifyPhone('Claude Code needs you · app', 'Allow?');
      final enc = base64Decode(app.pushes.single['enc']! as String);
      expect(await openBytes(old.key, enc, pushAad(old.desktop)), isNull);
      expect(await openBytes(fresh.key, enc, pushAad(old.desktop)), isNotNull);
    });
  });

  group('the first sign-in on this computer', () {
    testWidgets('turns on Terminal from phone, once, and never adds a login item on its own', (tester) async {
      final app = await FakeApp.create();
      await app.signedIn();
      expect(app.terminalOn, isTrue);
      expect(app.host.loginItem, isFalse);
      expect(app.host.calls, isNot(contains('setLaunchAtLogin(true)')));

      // Turned off again, it stays off at the next sign-in.
      await app.setTerminal(on: false);
      app.host.calls.clear();
      await app.signedIn();
      expect(app.terminalOn, isFalse);
      expect(app.host.calls, isEmpty);
    });

    testWidgets('a computer that had its first sign-in keeps its settings', (tester) async {
      final app = await FakeApp.create(prefs: {'first_sign_in_done': true});
      await app.signedIn();
      expect(app.terminalOn, isFalse);
      expect(app.host.calls, isEmpty);
    });
  });

  group('at launch', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
        ..setMockStreamHandler(
          const EventChannel('com.llfbandit.app_links/events'),
          MockStreamHandler.inline(onListen: (_, _) {}),
        );
    });

    testWidgets('a computer not set up yet shows its window (the first-run setup)', (tester) async {
      final app = await FakeApp.create();
      app
        ..fakeBackend = null
        ..fakeUser = null;
      await app.start();
      expect(app.host.calls, ['start', 'showMain']);
    });

    testWidgets('signed in, it starts in the background', (tester) async {
      final app = await FakeApp.create();
      await app.start();
      expect(app.host.calls, ['start']);
    });

    testWidgets("the host's menu items open the window; quitting waits for onQuit", (tester) async {
      final app = await FakeApp.create();
      await app.start();
      final quit = Completer<void>();
      app.onQuit = () => quit.future;
      app.host.calls.clear();

      app.host.onEvent!('openSettings');
      app.host.onEvent!('mainClosed');
      expect(app.host.calls, ['showMain']);

      var quitting = false;
      unawaited(Future.sync(() => app.host.onEvent!('quitting')).then((_) => quitting = true));
      await tester.pump();
      expect(quitting, isFalse);
      quit.complete();
      await tester.pump();
      expect(quitting, isTrue);
    });
  });

  testWidgets("this computer's id is made once per user, in the form the server takes", (tester) async {
    final app = await FakeApp.create();
    final id = app.desktopId('user-1');
    expect(id, matches(RegExp(r'^[a-z0-9]{8}$')));
    expect(app.desktopId('user-1'), id);
    expect(app.desktopId('user-2'), isNot(id));
  });

  test("the computer's name fits the server's 1 to 80 characters", () {
    expect(AppController.desktopName('  Ana’s MacBook  '), 'Ana’s MacBook');
    expect(AppController.desktopName(' '), 'Computer');
    expect(AppController.desktopName('x' * 100), 'x' * 80);
  });
}
