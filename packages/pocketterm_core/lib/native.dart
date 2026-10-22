import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// What the server (POST /v1/push/register) calls this phone's push
/// service: APNs on iOS, FCM on Android.
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

  /// Phone: whether the system lets PocketTerm's notifications show now; the
  /// person can turn them off in the phone's Settings after saying yes.
  /// iOS's quiet (provisional) delivery counts.
  static Future<bool> notificationsAllowed() async =>
      await _channel.invokeMethod<bool>('notificationsAllowed') ?? false;

  /// Phone: opens PocketTerm's page in the phone's Settings: its
  /// [notifications] settings, else the app's (camera and the rest).
  static Future<void> openSettings({bool notifications = false}) =>
      _channel.invokeMethod('openSettings', {'notifications': notifications});

  /// Phone: the computers' channel keys (lib/e2e.dart), by computer id, kept
  /// where the push extension reads them too: the Keychain (App Group,
  /// this device only) on iOS, Keystore-backed storage on Android.
  static Future<Map<String, String>> channelKeys() async =>
      await _channel.invokeMapMethod<String, String>('channelKeys') ?? const {};

  /// [key]: standard base64.
  static Future<void> setChannelKey({required String desktop, required String key}) =>
      _channel.invokeMethod('setChannelKey', {'desktop': desktop, 'key': key});

  /// Every computer's key goes, also ones Dart never loaded (sign-out). On
  /// Android the Keystore key that wraps them goes too, and with it the
  /// sign-in ([deviceToken]) it also wraps.
  static Future<void> removeAllChannelKeys() => _channel.invokeMethod('removeAllChannelKeys');

  // Phone: followed coding sessions, as Live Activities on iOS
  // (apps/pocketterm-mobile/ios/Shared/SessionActivity.swift) and ongoing notifications on Android
  // (SessionActivities.kt); lib/live_activity.dart. [since]: when it got into
  // [state].

  /// Starts one for session [key], or updates the one it has; false when
  /// Live Activities (iOS) or notifications (Android) are off for PocketTerm.
  /// Throws [TooManyActivities] when iOS already shows as many as it allows.
  static Future<bool> startActivity({
    required String key,
    required String title,
    required String project,
    required String state,
    required DateTime since,
    String? kind,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('startActivity', {
            'key': key,
            'title': title,
            'project': project,
            'state': state,
            'kind': ?kind,
            'since': since.millisecondsSinceEpoch,
          }) ??
          false;
    } on PlatformException catch (e) {
      if (e.code == 'too-many') throw const TooManyActivities();
      rethrow;
    }
  }

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

  /// The server (lib/backend.dart) kept where the native side reads it too
  /// (apps/pocketterm-mobile/ios/Shared/PocketTermShared.swift, android/…/PocketTermShared.kt).
  /// [legacy]: an app from before saved a Supabase project there (it came
  /// with a key).
  static Future<({String url, bool legacy})?> getBackend() async {
    final m = await _channel.invokeMapMethod<String, String>('getBackend');
    final url = m?['url'];
    return url == null ? null : (url: url, legacy: (m?['key'] ?? '').isNotEmpty);
  }

  /// Null forgets it.
  static Future<void> setBackend({String? url}) => _channel.invokeMethod('setBackend', {'url': url});

  /// This phone's sign-in on its server (lib/server_client.dart): the device
  /// token and what came with it, one opaque string kept in the Keychain
  /// (this device only) on iOS, Keystore-wrapped on Android. Null: none.
  static Future<String?> deviceToken() => _channel.invokeMethod<String>('deviceToken');

  /// Null forgets it.
  static Future<void> setDeviceToken(String? value) => _channel.invokeMethod('setDeviceToken', {'value': value});

  /// This phone's name: the label of its push registration.
  static Future<String> deviceName() async => await _channel.invokeMethod<String>('deviceName') ?? 'Phone';

  /// Keeps the screen from dimming and locking while [on].
  static Future<void> setKeepAwake({required bool on}) => _channel.invokeMethod('setKeepAwake', {'on': on});
}

/// iOS shows only so many Live Activities at once, per app and in all: one
/// more is refused until another ends.
class TooManyActivities implements Exception {
  const TooManyActivities();

  @override
  String toString() => 'Too many Live Activities';
}
