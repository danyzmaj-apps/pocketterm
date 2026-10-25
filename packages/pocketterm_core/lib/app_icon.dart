import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pocketterm_core/theme.dart';

/// The app icon that goes with [choice]: `default` (the bundle's own icon,
/// Catppuccin Mocha's) for [ThemeChoice.mocha], else `dawn`, `tokyoNight` or
/// `gruvbox`, the alternates the native sides know by these names
/// (apps/pocketterm-desktop/tool/make_icon.swift draws them all).
String appIconFor(ThemeChoice choice) => choice == ThemeChoice.mocha ? 'default' : choice.name;

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
