// kitty's /tmp sockets.
@Tags(['posix'])
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('the first sign-in on this computer', () {
    testWidgets('turns on Terminal from phone and Launch at login, once', (tester) async {
      final app = await FakeApp.create();
      await app.signedIn();
      expect(app.terminalOn, isTrue);
      expect(app.launchAtLogin, isTrue);
      expect(app.host.loginItem, isTrue);

      // Turned off again, they stay off at the next sign-in.
      await app.setTerminal(on: false);
      await app.setLaunchAtLogin(on: false);
      app.host.calls.clear();
      await app.signedIn();
      expect(app.terminalOn, isFalse);
      expect(app.host.loginItem, isFalse);
      expect(app.host.calls, isEmpty);
    });

    testWidgets('a computer that had its first sign-in keeps its settings', (tester) async {
      final app = await FakeApp.create(prefs: {'first_sign_in_done': true});
      await app.signedIn();
      expect(app.terminalOn, isFalse);
      expect(app.host.calls, isEmpty);
    });

    testWidgets('Launch at login refused still turns on Terminal from phone', (tester) async {
      final app = await FakeApp.create();
      app.host.loginItemRefused = 'Operation not permitted';
      await app.signedIn();
      expect(app.terminalOn, isTrue);
      expect(app.launchAtLogin, isFalse);
      expect((await SharedPreferences.getInstance()).getBool('first_sign_in_done'), isTrue);
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

    testWidgets('a computer not set up yet shows its window (the wizard)', (tester) async {
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
