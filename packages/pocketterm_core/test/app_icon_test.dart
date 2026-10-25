import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/app_icon.dart';
import 'package:pocketterm_core/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('the icon follows the picked theme, Catppuccin Mocha being the app’s own', (tester) async {
    SharedPreferences.setMockInitialValues({Appearance.prefsKey: 'tokyoNight'});
    final appearance = Appearance()..load(await SharedPreferences.getInstance());
    addTearDown(appearance.dispose);
    final applied = <String>[];
    addTearDown(followAppIcon(appearance, (icon) async => applied.add(icon)));

    // The kept choice's at launch.
    expect(applied, ['tokyoNight']);

    await appearance.choose(ThemeChoice.mocha);
    expect(applied, ['tokyoNight', 'default']);

    await appearance.choose(ThemeChoice.gruvbox);
    expect(applied, ['tokyoNight', 'default', 'gruvbox']);
  });

  testWidgets('a fresh install keeps the app’s own icon: nothing to switch, so no iOS alert', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final appearance = Appearance()..load(await SharedPreferences.getInstance());
    addTearDown(appearance.dispose);
    final applied = <String>[];
    addTearDown(followAppIcon(appearance, (icon) async => applied.add(icon)));
    expect(applied, ['default']);
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
