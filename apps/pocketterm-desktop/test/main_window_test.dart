import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/account.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/integrations.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:pocketterm_desktop/setup_page.dart';

import 'app_fakes.dart';

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('pocketterm-window'));
  tearDown(() => home.deleteSync(recursive: true));

  Future<FakeApp> pumpWindow(WidgetTester tester, void Function(FakeApp app) given, {Terminals? terminals}) async {
    tester.view
      ..physicalSize = const Size(1000, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = await FakeApp.create(terminals: terminals);
    given(app);
    final integrations = Integrations(home: home.path, run: (_, _) async => ProcessResult(0, 1, '', ''));
    await tester.pumpWidget(
      window(
        ListenableBuilder(
          listenable: app,
          builder: (_, _) => MainWindow(app: app, integrations: integrations),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('with no server, the window is the setup wizard', (tester) async {
    await pumpWindow(
      tester,
      (app) => app
        ..fakeBackend = null
        ..fakeUser = null,
    );
    expect(find.byType(SetupPage), findsOneWidget);
    expect(find.byType(SignInPage), findsNothing);
    expect(find.byType(SettingsPage), findsNothing);
  });

  testWidgets('set up but signed out, the window is sign-in', (tester) async {
    await pumpWindow(tester, (app) => app.fakeUser = null);
    expect(find.byType(SignInPage), findsOneWidget);
    expect(find.byType(SetupPage), findsNothing);
  });

  testWidgets('signed in, the window is Settings, which can quit PocketTerm', (tester) async {
    final app = await pumpWindow(tester, (_) {});
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Done'), findsNothing);
    await tester.tap(find.text('Quit PocketTerm'));
    expect(app.host.calls.last, 'quit');
  });

  testWidgets('the hidden window looks at the terminals again each time it is shown', (tester) async {
    var looks = 0;
    final terminals = Terminals(
      home: home.path,
      wezterm: WezTerm(executable: '${home.path}/wezterm', socketDir: home.path),
      recency: () async => const [],
      snapshot: () async {
        looks++;
        return Procs(const []);
      },
    );
    final app = await pumpWindow(tester, (_) {}, terminals: terminals);
    final before = looks;
    expect(before, greaterThan(0));

    await app.openMain();
    await tester.pumpAndSettle();
    expect(looks, greaterThan(before));
    expect(app.host.calls.last, 'showMain');
  });

  testWidgets('Launch at login shows how the system has it, and switches it', (tester) async {
    final app = await pumpWindow(tester, (app) => app.host.loginItem = true);
    final toggle = find.descendant(
      of: find.ancestor(of: find.text('Launch at login'), matching: find.byType(Row)).first,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(toggle).value, isTrue);

    app.host.loginItemRefused = 'Operation not permitted';
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Operation not permitted'), findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    app.host.loginItemRefused = null;
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Operation not permitted'), findsNothing);
    expect(tester.widget<Switch>(toggle).value, isFalse);
  });
}
