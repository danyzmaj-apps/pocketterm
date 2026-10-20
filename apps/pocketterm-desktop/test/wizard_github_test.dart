import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_desktop/onboarding/flow.dart';
import 'package:pocketterm_desktop/onboarding/wizard.dart';

void main() {
  testWidgets("the GitHub step can't go on until wildcard matching is confirmed off", (tester) async {
    tester.view
      ..physicalSize = const Size(1080, 2400)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final flow = SetupFlow()
      ..step = WizardStep.github
      ..ref = 'demoprojectrefabcdef';
    addTearDown(flow.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SetupWizard(flow: flow, onConnect: (_) async {}, onExisting: () {}),
        ),
      ),
    );

    FilledButton setUp() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Set up my server'));
    expect(setUp().onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('github-strict-callback')));
    await tester.pump();
    expect(setUp().onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('github-strict-callback')));
    await tester.pump();
    expect(setUp().onPressed, isNull, reason: 'unticking the confirmation disables it again');
  });
}
