import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pocketterm_core/app_icon.dart';
import 'package:pocketterm_core/intro.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/theme.dart';
import 'package:pocketterm_core/timing.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/voice.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  timing('launch');
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  appearance.load(prefs);
  voiceLanguage.load(prefs);
  followAppIcon(appearance, Native.setAppIcon);
  final device = await Native.deviceName();
  final session = MobileSession(prefs, device);
  // Started first: the app's first frame shows it's still reading what it kept, not setup.
  final started = session.start();
  // The iPhone's launch screen shows the icon where the intro starts (LaunchImage, made by
  // test/screenshots/launch_image_test.dart): no fade-in after it. Android's splash is the plain background.
  runApp(
    PocketTermIntro(
      fromSplash: defaultTargetPlatform == TargetPlatform.iOS,
      child: MobileApp(session: session),
    ),
  );
  await started;
}
