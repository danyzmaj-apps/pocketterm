import 'package:flutter/material.dart';
import 'package:pocketterm_core/app_icon.dart';
import 'package:pocketterm_core/intro.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/theme.dart';
import 'package:pocketterm_core/timing.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  timing('launch');
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  appearance.load(prefs);
  followAppIcon(appearance, Native.setAppIcon);
  final device = await Native.deviceName();
  final session = MobileSession(prefs, device);
  // Started first: the app's first frame shows it's still reading what it kept, not setup.
  final started = session.start();
  runApp(PocketTermIntro(child: MobileApp(session: session)));
  await started;
}
