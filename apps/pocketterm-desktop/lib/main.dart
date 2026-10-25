import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:pocketterm_core/app_icon.dart';
import 'package:pocketterm_core/intro.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/desktop_host.dart';
import 'package:pocketterm_desktop/local_api.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:pocketterm_desktop/test_hooks.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A throwaway profile (tool/smoke) is driven through macOS accessibility:
  // its whole tree, whether or not an assistive app asked yet.
  if (testHooks()['POCKETTERM_PROFILE']?.isNotEmpty ?? false) SemanticsBinding.instance.ensureSemantics();
  final prefs = await SharedPreferences.getInstance();
  appearance.load(prefs);
  final host = DesktopHost();
  followAppIcon(appearance, host.setAppIcon);
  final app = AppController(prefs, await host.deviceName(), host);
  final api = LocalApi(app.live);
  try {
    await api.start();
    app.onQuit = api.stop;
  } on Object catch (e) {
    debugPrint('PocketTerm: terminal API unavailable: $e');
  }
  runApp(
    // PocketTerm starts in the menu bar or the tray: the intro plays when the
    // window first shows.
    ValueListenableBuilder(
      valueListenable: app.mainShown,
      builder: (_, shown, child) => PocketTermIntro(play: shown > 0, child: child!),
      child: Themed(
        builder: (context, theme) => MaterialApp(
          title: 'PocketTerm',
          debugShowCheckedModeBanner: false,
          theme: appTheme(theme),
          // Every part changes at once: what reads [C] has no theme animation.
          themeAnimationStyle: AnimationStyle.noAnimation,
          // Built inside the builder, so every change to [app] rebuilds the
          // window's content.
          home: Material(
            color: C.win,
            child: Toaster(
              child: ListenableBuilder(
                listenable: app,
                builder: (_, _) => MainWindow(app: app),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await app.start();
}
