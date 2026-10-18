import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_desktop/controller.dart';
import 'package:pocketterm_desktop/desktop_host.dart';
import 'package:pocketterm_desktop/local_api.dart';
import 'package:pocketterm_desktop/main_window.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final host = DesktopHost();
  final app = AppController(prefs, await host.deviceName(), host);
  final api = LocalApi(app.live);
  try {
    await api.start();
    app.onQuit = api.stop;
  } on Object catch (e) {
    debugPrint('PocketTerm: terminal API unavailable: $e');
  }
  runApp(
    MaterialApp(
      title: 'PocketTerm',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
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
  );
  await app.start();
}
