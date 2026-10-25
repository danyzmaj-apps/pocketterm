import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/theme.dart';

/// The app icon that goes with [choice]: `mocha`, `dawn`, `tokyoNight`,
/// `gruvbox`, or `default` (the bundle's own icon) for [ThemeChoice.auto].
/// Auto keeps the default rather than following the system's light or dark:
/// iOS asks the person about every icon change, and Android's launcher
/// drops pinned shortcuts with it, which a change at every sunset would make
/// a nuisance. The native sides know the icons by these names
/// (apps/pocketterm-desktop/tool/make_icon.swift draws them).
String appIconFor(ThemeChoice choice) => choice == ThemeChoice.auto ? 'default' : choice.name;

/// Keeps the app icon on [appearance]'s choice: [apply] gets [appIconFor]'s
/// name now and after each change of choice. Returns what stops it.
VoidCallback followAppIcon(Appearance appearance, Future<void> Function(String icon) apply) {
  String? shown;
  void sync() {
    final icon = appIconFor(appearance.choice);
    if (icon == shown) return;
    shown = icon;
    unawaited(
      apply(icon).catchError((Object e) {
        debugPrint('PocketTerm: app icon $icon: $e');
      }),
    );
  }

  appearance.addListener(sync);
  sync();
  return () => appearance.removeListener(sync);
}
