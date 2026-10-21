import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// What functions/push calls this phone's push service: APNs on iOS, FCM on
/// Android.
String get pushPlatform => Platform.isAndroid ? 'android' : 'ios';

/// The phone's native side: the iPhone's (apps/pocketterm-mobile/ios/Runner/AppDelegate.swift) and
/// Android's (apps/pocketterm-mobile/android/app/src/main/kotlin/com/danyzmaj/pocketterm/MainActivity.kt).
/// The computer's is apps/pocketterm-desktop/lib/desktop_host.dart.
class Native {
  static const _channel = MethodChannel('pocketterm/native');

  /// Events from the native side: openTerminal ({session}: a terminal push
  /// was tapped; see [takeTappedSession]), activityToken ({key, token}: a
  /// followed session's push token, new or changed), activityEnded ({key,
  /// token?}: it ended or was swiped away) and pushToken (Android: FCM
  /// changed this phone's token; register again).
  static void listen(FutureOr<void> Function(String event, Map<Object?, Object?> args) onEvent) {
    _channel.setMethodCallHandler((call) async {
      await onEvent(call.method, call.arguments as Map<Object?, Object?>? ?? const {});
    });
  }

  /// Phone: the coding session (its key) whose terminal push was tapped,
  /// once (a tap that launched the app lands before Dart listens, so
  /// openTerminal only says "look").
  static Future<String?> takeTappedSession() => _channel.invokeMethod<String>('takeTappedSession');

  /// Phone: asks for notification permission and this phone's push token
  /// (APNs on iOS, FCM on Android). Null: not allowed, or no token (APNs
  /// didn't answer; an Android build without Firebase).
  static Future<String?> registerPush() async =>
      (await _channel.invokeMapMethod<String, Object?>('registerPush'))?['token'] as String?;

  /// Phone: the computers' channel keys (lib/e2e.dart), by computer id, kept
  /// where the push extension reads them too: the Keychain (App Group,
  /// this device only) on iOS, Keystore-backed storage on Android.
  static Future<Map<String, String>> channelKeys() async =>
      await _channel.invokeMapMethod<String, String>('channelKeys') ?? const {};

  /// [key]: standard base64.
  static Future<void> setChannelKey({required String desktop, required String key}) =>
      _channel.invokeMethod('setChannelKey', {'desktop': desktop, 'key': key});

  static Future<void> removeChannelKey({required String desktop}) =>
      _channel.invokeMethod('removeChannelKey', {'desktop': desktop});

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

  /// This phone's name: the label of its push registration.
  static Future<String> deviceName() async => await _channel.invokeMethod<String>('deviceName') ?? 'Phone';

  /// Keeps the screen from dimming and locking while [on].
  static Future<void> setKeepAwake({required bool on}) => _channel.invokeMethod('setKeepAwake', {'on': on});
}
