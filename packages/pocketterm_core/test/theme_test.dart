import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('a picked theme is kept, and Auto follows the system as it changes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    final first = Appearance()..load(prefs);
    addTearDown(first.dispose);
    expect(first.choice, ThemeChoice.auto);
    expect(first.theme, same(PtTheme.mocha));
    var changes = 0;
    first.addListener(() => changes++);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    expect(first.theme, same(PtTheme.dawn));
    expect(changes, 1);

    await first.choose(ThemeChoice.gruvbox);
    expect(changes, 2);
    expect(prefs.getString(Appearance.prefsKey), 'gruvbox');

    // The next launch reads it back, and a picked theme stays whatever the system does.
    final next = Appearance()..load(prefs);
    addTearDown(next.dispose);
    expect(next.choice, ThemeChoice.gruvbox);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    expect(next.theme, same(PtTheme.gruvbox));

    // A value this version doesn't know (a theme since removed) is Auto.
    await prefs.setString(Appearance.prefsKey, 'solarized');
    final unknown = Appearance()..load(prefs);
    addTearDown(unknown.dispose);
    expect(unknown.choice, ThemeChoice.auto);
    expect(unknown.theme, same(PtTheme.mocha));
  });
}
