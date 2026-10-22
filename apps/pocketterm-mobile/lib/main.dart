import 'package:flutter/material.dart';
import 'package:pocketterm_core/native.dart';
import 'package:pocketterm_core/timing.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  timing('launch');
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final device = await Native.deviceName();
  final session = MobileSession(prefs, device);
  runApp(MobileApp(session: session));
  await session.start();
}
