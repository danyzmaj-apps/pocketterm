import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/account.dart';
import 'package:pocketterm_core/terminal.dart';
import 'package:pocketterm_core/terminals.dart';
import 'package:pocketterm_core/wezterm.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:pocketterm_desktop/onboarding/get_ready.dart';
import 'package:pocketterm_desktop/setup_page.dart';

import 'app_fakes.dart';

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('pocketterm-window'));
  tearDown(() => home.deleteSync(recursive: true));

  /// The window over [given]'s app; [prefs] what this computer had saved
  /// (by default the setup checklist is done).
  Future<FakeApp> pumpWindow(
    WidgetTester tester,
    void Function(FakeApp app) given, {
    Terminals? terminals,
    Map<String, Object> prefs = const {'get_ready_done': true},
  }) async {
    tester.view
      ..physicalSize = const Size(1000, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = await FakeApp.create(terminals: terminals, prefs: prefs, integrations: FakeApp.noAgents(home.path));
    given(app);
    await tester.pumpWidget(
      window(
        ListenableBuilder(
          listenable: app,
          builder: (_, _) => MainWindow(app: app),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('with no server, the window is the first-run setup', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('settings-tab-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quit PocketTerm'));
    expect(app.host.calls.last, 'quit');
  });

  testWidgets('until the setup checklist is done, it is the signed-in window; Settings opens it again', (tester) async {
    final app = await pumpWindow(tester, (_) {}, prefs: const {});
    expect(find.byType(GetReadyPage), findsOneWidget);
    expect(find.byType(SettingsPage), findsNothing);

    await tester.ensureVisible(find.text('Done'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(app.getReadyDone, isTrue);
    expect(find.byType(SettingsPage), findsOneWidget);

    await tester.tap(find.text('Open setup checklist'));
    await tester.pumpAndSettle();
    expect(find.byType(GetReadyPage), findsOneWidget);
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
    await tester.tap(find.byKey(const ValueKey('settings-tab-account')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('settings-launch-at-login'));
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
