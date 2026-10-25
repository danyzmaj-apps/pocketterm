import 'dart:async';

import 'package:flutter/services.dart';

/// Whether the phone can listen now, in English, on the device.
enum SpeechStatus {
  ready,

  /// The microphone (or, on an iPhone before iOS 26, speech recognition) was refused.
  denied,

  /// Turned off for this phone (Screen Time, a device profile).
  restricted,

  /// No English for recognition on the device; [SpeechCheck.fix] says whether it can be fetched.
  noEnglish,

  /// English for the device is on its way.
  downloading,

  /// This phone can't recognize speech on the device at all.
  unavailable,
}

/// What the person can do about a [SpeechStatus] that isn't ready.
enum SpeechFix {
  /// PocketTerm's page in the phone's Settings (its permissions).
  appSettings,

  /// Fetch the English model for on-device recognition (iOS 26's speech assets, Android 13's on-device
  /// recognizer). Recognition itself still never leaves the phone.
  download,

  /// The phone's own speech settings, where English for on-device recognition is turned on.
  speechSettings,
}

class SpeechCheck {
  const SpeechCheck(this.status, {this.fix});
  final SpeechStatus status;
  final SpeechFix? fix;

  bool get ready => status == SpeechStatus.ready;
}

/// What a listening session reports, in order, the last one [SpeechEnded].
sealed class SpeechEvent {
  const SpeechEvent();
}

/// Everything heard since listening started, the newest words possibly still changing.
class SpeechHeard extends SpeechEvent {
  const SpeechHeard(this.text);
  final String text;
}

/// How loud the microphone is, 0 (silence) to 1.
class SpeechLevel extends SpeechEvent {
  const SpeechLevel(this.level);
  final double level;
}

enum SpeechEnd {
  /// Stopped as asked ([SpeechSource.stop]).
  stopped,

  /// Something else took the microphone (a call, Siri, the app left the screen).
  interrupted,

  /// Recognition failed; [SpeechEnded.message] says why.
  error,
}

class SpeechEnded extends SpeechEvent {
  const SpeechEnded(this.why, {this.message, this.status});
  final SpeechEnd why;
  final String? message;

  /// When the failure is one [SpeechSource.check] would have found (Android 12 learns there's no English only
  /// when it starts).
  final SpeechStatus? status;
}

/// Speech to text on the phone, English only and on the device only.
abstract class SpeechSource {
  /// Whether it can listen; asks for the permissions it needs the first time.
  Future<SpeechCheck> check();

  /// Starts listening. Cancelling the subscription discards what was heard and stops at once; [stop] ends it
  /// with the last words settled instead. The stream closes after [SpeechEnded].
  Stream<SpeechEvent> listen();

  /// Stops listening: the last [SpeechHeard], then [SpeechEnded] with [SpeechEnd.stopped].
  Future<void> stop();

  /// Does [fix]; for [SpeechFix.download], returns once the download is done or handed to the system.
  Future<void> fix(SpeechFix fix);
}

/// The phone's own recognizer, through `pocketterm/native` (methods `speechCheck`, `speechStop`, `speechFix`)
/// and the `pocketterm/speech` event channel: apps/pocketterm-mobile/ios/Runner/Dictation.swift and
/// android/…/Dictation.kt. Events are maps: `{type: heard, text}`, `{type: level, level}`,
/// `{type: ended, why: stopped|interrupted|error, message?, status?}`.
class NativeSpeech implements SpeechSource {
  const NativeSpeech();

  static const _channel = MethodChannel('pocketterm/native');
  static const _events = EventChannel('pocketterm/speech');

  @override
  Future<SpeechCheck> check() async {
    final m = await _channel.invokeMapMethod<String, Object?>('speechCheck') ?? const {};
    return SpeechCheck(_status(m['status']) ?? SpeechStatus.unavailable, fix: SpeechFix.values.asNameMap()[m['fix']]);
  }

  static SpeechStatus? _status(Object? name) => SpeechStatus.values.asNameMap()[name];

  @override
  Stream<SpeechEvent> listen() => _events.receiveBroadcastStream().map((raw) {
    final m = raw as Map<Object?, Object?>;
    return switch (m['type']) {
      'heard' => SpeechHeard(m['text'] as String? ?? ''),
      'level' => SpeechLevel(((m['level'] as num?) ?? 0).toDouble().clamp(0, 1)),
      _ => SpeechEnded(
        SpeechEnd.values.asNameMap()[m['why']] ?? SpeechEnd.error,
        message: m['message'] as String?,
        status: _status(m['status']),
      ),
    };
  });

  @override
  Future<void> stop() => _channel.invokeMethod('speechStop');

  @override
  Future<void> fix(SpeechFix fix) => _channel.invokeMethod('speechFix', {'fix': fix.name});
}
