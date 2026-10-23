import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pocketterm_desktop/windows_host.dart';

/// What the computer's own side does for the app: the main window, the
/// menu-bar (macOS) or tray (Windows) item, launch at login, keeping the
/// computer awake. [MacHost] on macOS, [WindowsHost] on Windows.
abstract class DesktopHost {
  factory DesktopHost() => Platform.isWindows ? WindowsHost() : MacHost();

  /// Starts listening. [onEvent]: openMain (the menu-bar or tray item, the
  /// Dock icon), openSettings (its Settings… item, ⌘,), mainClosed (the
  /// window was closed: hidden, the app keeps running) and quitting (the
  /// app is about to quit: it waits up to a second for what [onEvent]
  /// returns).
  Future<void> start({required FutureOr<void> Function(String event) onEvent});

  Future<void> showMain();
  Future<void> hideMain();

  /// Quits the app, after quitting has run.
  Future<void> quit();

  /// What this computer calls itself.
  Future<String> deviceName();

  /// Seconds since the last keyboard or mouse input.
  Future<int> idleSeconds();

  Future<bool> launchAtLogin();
  Future<void> setLaunchAtLogin({required bool on});

  /// A folder picker; the folders chosen, none if cancelled.
  Future<List<String>> pickFolders();

  /// Keeps the computer from idle sleep while [on] (the lid or the power
  /// button still sleep it).
  Future<void> setKeepAwake({required bool on});

  /// Moves the window with the drag in progress (the transparent title bar).
  Future<void> startDrag();
}

/// The Mac's side: apps/pocketterm-desktop/macos/Runner/MainFlutterWindow.swift (the main
/// window, the menu-bar item, launch at login).
class MacHost implements DesktopHost {
  static const _channel = MethodChannel('pocketterm/native');

  /// `caffeinate` while kept awake.
  Process? _awake;

  @override
  Future<void> start({required FutureOr<void> Function(String event) onEvent}) async {
    _channel.setMethodCallHandler((call) async => await onEvent(call.method));
  }

  @override
  Future<void> showMain() => _channel.invokeMethod('showMain');

  @override
  Future<void> hideMain() => _channel.invokeMethod('hideMain');

  @override
  Future<void> quit() => _channel.invokeMethod('quit');

  @override
  Future<String> deviceName() async => await _channel.invokeMethod<String>('deviceName') ?? 'Mac';

  @override
  Future<int> idleSeconds() async => (await _channel.invokeMethod<double>('idleSeconds') ?? 0).floor();

  @override
  Future<bool> launchAtLogin() async => await _channel.invokeMethod<bool>('launchAtLogin') ?? false;

  /// What to do when macOS keeps PocketTerm out of the login items.
  static const loginItemsHint = 'Allow PocketTerm in System Settings > General > Login Items.';

  /// Throws when the system didn't make it so (a login item it wants the
  /// person to allow first), saying where to allow it.
  @override
  Future<void> setLaunchAtLogin({required bool on}) async {
    final now = await _channel.invokeMethod<bool>('setLaunchAtLogin', {'enabled': on});
    if (now != null && now != on) {
      throw PlatformException(
        code: 'launch_at_login',
        message: on
            ? loginItemsHint
            : 'macOS still starts PocketTerm at login. Turn it off in System Settings > '
                  'General > Login Items.',
      );
    }
  }

  @override
  Future<List<String>> pickFolders() async => await _channel.invokeListMethod<String>('pickFolders') ?? const [];

  /// `caffeinate -i`; `-w`: it goes when PocketTerm does.
  @override
  Future<void> setKeepAwake({required bool on}) async {
    if (!on) {
      _awake?.kill();
      _awake = null;
      return;
    }
    if (_awake != null) return;
    try {
      _awake = await Process.start('/usr/bin/caffeinate', ['-i', '-w', '$pid']);
    } on Object catch (e) {
      debugPrint('PocketTerm: caffeinate: $e');
    }
  }

  @override
  Future<void> startDrag() => _channel.invokeMethod('startDrag');
}
