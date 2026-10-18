import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// What functions/push calls this phone's push service: APNs on iOS, FCM on
/// Android.
String get pushPlatform => Platform.isAndroid ? 'android' : 'ios';

/// The native side: the Mac's (apps/pocketterm-desktop/macos/Runner/MainFlutterWindow.swift: the
/// main window, menu-bar icon, launch at login), the iPhone's (apps/pocketterm-mobile/ios/Runner/AppDelegate.swift) and Android's
/// (apps/pocketterm-mobile/android/app/src/main/kotlin/com/danyzmaj/pocketterm/MainActivity.kt).
class Native {
  static const _channel = MethodChannel('pocketterm/native');

  /// Events from the native side: openMain, openSettings, mainClosed (⌘W),
  /// openTerminal ({session}: a terminal push was tapped; see
  /// [takeTappedSession]), activityToken ({key, token}: a followed
  /// session's push token, new or changed), activityEnded ({key, token?}: it
  /// ended or was swiped away), pushToken (Android: FCM changed this
  /// phone's token; register again) and quitting (the Mac app is about to
  /// quit: it waits up to a second for what [onEvent] returns).
  static void listen(FutureOr<void> Function(String event, Map<Object?, Object?> args) onEvent) {
    _channel.setMethodCallHandler((call) async {
      await onEvent(call.method, call.arguments as Map<Object?, Object?>? ?? const {});
    });
  }

  static Future<void> showMain() => _channel.invokeMethod('showMain');
  static Future<void> quit() => _channel.invokeMethod('quit');
  static Future<void> startDrag() => _channel.invokeMethod('startDrag');

  /// Mac: seconds since the last keyboard or mouse input.
  static Future<double> idleSeconds() async => await _channel.invokeMethod<double>('idleSeconds') ?? 0;

  /// Mac: a folder picker (sheet on the main window); the folders chosen,
  /// none if cancelled.
  static Future<List<String>> pickFolders() async => await _channel.invokeListMethod<String>('pickFolders') ?? const [];

  /// Phone: the coding session (its key) whose terminal push was tapped,
  /// once (a tap that launched the app lands before Dart listens, so
  /// openTerminal only says "look").
  static Future<String?> takeTappedSession() => _channel.invokeMethod<String>('takeTappedSession');

  /// Phone: asks for notification permission and this phone's push token
  /// (APNs on iOS, FCM on Android), with its push key. Null: not allowed, or
  /// no token (APNs didn't answer; an Android build without Firebase).
  static Future<({String token, String key})?> registerPush() async {
    final m = await _channel.invokeMapMethod<String, String>('registerPush');
    final token = m?['token'];
    final key = m?['key'];
    return token == null || key == null ? null : (token: token, key: key);
  }

  // Phone: followed coding sessions, as Live Activities on iOS
  // (apps/pocketterm-mobile/ios/Shared/SessionActivity.swift) and ongoing notifications on Android
  // (SessionActivities.kt); lib/live_activity.dart. [since]: when it got into
  // [state].

  /// Starts one for session [key], or updates the one it has; false when
  /// Live Activities (iOS) or notifications (Android) are off for PocketTerm.
  static Future<bool> startActivity({
    required String key,
    required String title,
    required String project,
    required String state,
    required DateTime since,
    String? kind,
  }) async =>
      await _channel.invokeMethod<bool>('startActivity', {
        'key': key,
        'title': title,
        'project': project,
        'state': state,
        'kind': ?kind,
        'since': since.millisecondsSinceEpoch,
      }) ??
      false;

  static Future<void> updateActivity({
    required String key,
    required String state,
    required DateTime since,
    String? kind,
  }) => _channel.invokeMethod('updateActivity', {
    'key': key,
    'state': state,
    'kind': ?kind,
    'since': since.millisecondsSinceEpoch,
  });

  /// [immediate]: gone at once (the person ended it), else Ended shows for
  /// a few minutes.
  static Future<void> endActivity(String key, {bool immediate = false}) =>
      _channel.invokeMethod('endActivity', {'key': key, 'immediate': immediate});

  /// The running ones: their session keys and push tokens (if iOS has
  /// handed one over yet; on Android, the phone's FCM token).
  static Future<List<({String key, String? token})>> liveActivities() async => [
    for (final m
        in await _channel.invokeListMethod<Map<Object?, Object?>>('liveActivities') ?? const <Map<Object?, Object?>>[])
      (key: m['key']! as String, token: m['token'] as String?),
  ];

  /// The backend (lib/backend.dart) kept where the native side reads it too
  /// (apps/pocketterm-mobile/ios/Shared/PocketTermShared.swift, android/…/PocketTermShared.kt).
  static Future<({String url, String key})?> getBackend() async {
    final m = await _channel.invokeMapMethod<String, String>('getBackend');
    final url = m?['url'];
    final key = m?['key'];
    return url == null || key == null ? null : (url: url, key: key);
  }

  /// Null for both forgets it.
  static Future<void> setBackend({String? url, String? key}) =>
      _channel.invokeMethod('setBackend', {'url': url, 'key': key});

  static Future<String> deviceName() async => await _channel.invokeMethod<String>('deviceName') ?? 'Mac';

  /// Phone: keeps the screen from dimming and locking while [on].
  static Future<void> setKeepAwake({required bool on}) => _channel.invokeMethod('setKeepAwake', {'on': on});
  static Future<bool> launchAtLogin() async => await _channel.invokeMethod<bool>('launchAtLogin') ?? false;
  static Future<bool> setLaunchAtLogin({required bool enabled}) async =>
      await _channel.invokeMethod<bool>('setLaunchAtLogin', {'enabled': enabled}) ?? false;
}
