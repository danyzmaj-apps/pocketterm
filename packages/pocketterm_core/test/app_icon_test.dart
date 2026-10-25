import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/app_icon.dart';
import 'package:pocketterm_core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the icon follows the picked theme, and Auto keeps the default whatever the system does', (tester) async {
    SharedPreferences.setMockInitialValues({Appearance.prefsKey: 'tokyoNight'});
    final prefs = await SharedPreferences.getInstance();
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final appearance = Appearance()..load(prefs);
    addTearDown(appearance.dispose);
    final applied = <String>[];
    final stop = followAppIcon(appearance, (icon) async => applied.add(icon));
    addTearDown(stop);

    // The kept choice's at launch.
    expect(applied, ['tokyoNight']);

    await appearance.choose(ThemeChoice.auto);
    expect(applied, ['tokyoNight', 'default']);

    // Each switch costs an iOS alert: day and night under Auto change nothing.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    expect(applied, ['tokyoNight', 'default']);

    await appearance.choose(ThemeChoice.gruvbox);
    expect(applied, ['tokyoNight', 'default', 'gruvbox']);
  });

  testWidgets('a platform without the switch does not break the theme change', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final appearance = Appearance()..load(await SharedPreferences.getInstance());
    addTearDown(appearance.dispose);
    addTearDown(followAppIcon(appearance, (_) async => throw UnimplementedError('no icons here')));

    await appearance.choose(ThemeChoice.dawn);
    expect(appearance.theme, same(PtTheme.dawn));
  });
}
