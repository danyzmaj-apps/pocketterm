import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Catppuccin Mocha until a theme is picked, the picked one kept, whatever the system does', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    final first = Appearance()..load(prefs);
    addTearDown(first.dispose);
    expect(first.choice, ThemeChoice.mocha);
    expect(first.theme, same(PtTheme.mocha));
    var changes = 0;
    first.addListener(() => changes++);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    expect(changes, 0);

    await first.choose(ThemeChoice.gruvbox);
    expect(changes, 1);
    expect(first.theme, same(PtTheme.gruvbox));
    expect(prefs.getString(Appearance.prefsKey), 'gruvbox');

    // The next launch reads it back.
    final next = Appearance()..load(prefs);
    addTearDown(next.dispose);
    expect(next.choice, ThemeChoice.gruvbox);
  });

  for (final kept in ['auto', 'solarized']) {
    testWidgets('a kept "$kept" (0.1.2’s Auto, or a theme since removed) reads as Catppuccin Mocha', (tester) async {
      SharedPreferences.setMockInitialValues({Appearance.prefsKey: kept});
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final appearance = Appearance()..load(await SharedPreferences.getInstance());
      addTearDown(appearance.dispose);
      expect(appearance.choice, ThemeChoice.mocha);
      expect(appearance.theme, same(PtTheme.mocha));
    });
  }
}
