import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui' show Size;

import 'package:ffi/ffi.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:pocketterm_core/terminal.dart' show mergeWindowsPath;
import 'package:pocketterm_desktop/desktop_host.dart';
import 'package:pocketterm_desktop/update_check.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:url_launcher/url_launcher.dart';
import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';
import 'package:window_manager/window_manager.dart';

/// The PATH a new login would have now ([mergeWindowsPath]): the system's
/// and the user's `Path` from the registry, expanded, then this process's
/// own. An app installed while PocketTerm runs (Claude Code, Node) is on it;
/// PocketTerm's own environment is the one Explorer gave it at start.
String freshWindowsPath() {
  String? read(RegistryHive hive, String path) {
    try {
      final key = Registry.openPath(hive, path: path);
      try {
        return key.getStringValue('Path', expandPaths: true);
      } finally {
        key.close();
      }
    } on WindowsException {
      return null;
    }
  }

  return mergeWindowsPath(
    machine: read(RegistryHive.localMachine, r'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'),
    user: read(RegistryHive.currentUser, 'Environment'),
    current: Platform.environment['PATH'] ?? '',
  );
}

/// The Windows side: the tray item, the main window (closing hides it),
/// launch at login (`--hidden`: the window stays hidden), the `pocketterm://`
/// link and keeping the computer awake. The runner (windows/runner/) starts
/// the window hidden and keeps one PocketTerm per user.
class WindowsHost with WindowListener implements DesktopHost {
  FutureOr<void> Function(String event)? _onEvent;

  /// Kept for as long as the item should show: a collected one is removed.
  tray.TrayIcon? _tray;

  UpdateInfo? _update;

  @override
  Future<void> start({required FutureOr<void> Function(String event) onEvent}) async {
    _onEvent = onEvent;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    await windowManager.setMinimumSize(const Size(480, 360));
    await windowManager.center();
    launchAtStartup.setup(appName: 'PocketTerm', appPath: '"${Platform.resolvedExecutable}"', args: ['--hidden']);
    _ensureStartupApproved();
    _registerLink();
    _startTray();
    if (!_startedHidden()) await showMain();
  }

  /// Started at login: the command line has `--hidden`.
  static bool _startedHidden() => GetCommandLine().toDartString().split(' ').contains('--hidden');

  void _startTray() {
    final item = tray.TrayIcon.create();
    if (item == null) {
      debugPrint('PocketTerm: no tray icon');
      return;
    }
    item
      ..icon = tray.ImageAsset.fromAsset('assets/tray.ico')
      ..setTooltip('PocketTerm')
      ..setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked)
      ..addListener((e) {
        if (e is tray.TrayIconClickedEvent || e is tray.TrayIconDoubleClickedEvent) _emit('openMain');
      })
      ..setVisible(true);
    _tray = item;
    _setMenu();
  }

  /// The tray item's menu: Open PocketTerm, Settings…, Update available…
  /// (while [setUpdate] has one), Quit.
  void _setMenu() {
    final item = _tray;
    final menu = tray.Menu.create();
    if (item == null || menu == null) return;
    void add(String label, void Function() onClick) {
      final entry = tray.MenuItem.createWithLabelAndType(label, tray.MenuItemType.normal);
      if (entry == null) return;
      entry.addListener((e) {
        if (e is tray.MenuItemClickedEvent) onClick();
      });
      menu.addItem(entry);
    }

    add('Open PocketTerm', () => _emit('openMain'));
    add('Settings…', () => _emit('openSettings'));
    if (_update case final u?) {
      add('Update available…', () => unawaited(launchUrl(u.url, mode: LaunchMode.externalApplication)));
    }
    menu.addSeparator();
    add('Quit', () => unawaited(quit()));
    item.setContextMenu(menu);
  }

  /// Shows the tray's Update available… item while [update] is a newer
  /// release (lib/update_check.dart), hides it at null.
  void setUpdate(UpdateInfo? update) {
    if (update == _update) return;
    _update = update;
    _setMenu();
  }

  void _emit(String event) => unawaited(Future.sync(() => _onEvent?.call(event)));

  @override
  void onWindowClose() {
    unawaited(() async {
      await hideMain();
      _emit('mainClosed');
    }());
  }

  @override
  Future<void> showMain() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  Future<void> hideMain() => windowManager.hide();

  /// Removes the tray item, gives quitting up to a second, then exits.
  @override
  Future<void> quit() async {
    _tray?.dispose();
    _tray = null;
    try {
      await Future.any([
        Future.sync(() => _onEvent?.call('quitting')),
        Future<void>.delayed(const Duration(seconds: 1)),
      ]);
    } on Object catch (e) {
      debugPrint('PocketTerm: quitting: $e');
    }
    exit(0);
  }

  @override
  Future<String> deviceName() async => Platform.localHostname;

  @override
  Future<int> idleSeconds() async {
    final info = calloc<LASTINPUTINFO>()..ref.cbSize = sizeOf<LASTINPUTINFO>();
    try {
      if (GetLastInputInfo(info) == 0) return 0;
      // Both are milliseconds since boot as 32 bits; the mask survives the
      // wrap after 49.7 days.
      return ((GetTickCount() - info.ref.dwTime) & 0xFFFFFFFF) ~/ 1000;
    } finally {
      calloc.free(info);
    }
  }

  @override
  Future<bool> launchAtLogin() async {
    try {
      return await launchAtStartup.isEnabled();
    } on WindowsException catch (e) {
      debugPrint('PocketTerm: launch at login: $e');
      return false;
    }
  }

  @override
  Future<void> setLaunchAtLogin({required bool on}) async {
    await (on ? launchAtStartup.enable() : launchAtStartup.disable());
  }

  @override
  Future<List<String>> pickFolders() async => (await getDirectoryPaths()).whereType<String>().toList();

  /// System sleep stays off while this (the UI) thread asks.
  @override
  Future<void> setKeepAwake({required bool on}) async {
    SetThreadExecutionState(on ? ES_CONTINUOUS | ES_SYSTEM_REQUIRED : ES_CONTINUOUS);
  }

  @override
  Future<void> startDrag() => windowManager.startDragging();

  /// launch_at_startup reads and writes `Explorer\StartupApproved\Run`
  /// (Task Manager's Startup apps switch) and throws when that key is
  /// missing, as on a profile where no app ever asked to start at login;
  /// made here, empty, so the Launch at login switch works there too.
  static void _ensureStartupApproved() {
    try {
      final user = Registry.currentUser;
      try {
        user.createKey(r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run').close();
      } finally {
        user.close();
      }
    } on WindowsException catch (e) {
      debugPrint('PocketTerm: StartupApproved: $e');
    }
  }

  /// Points `pocketterm://` (setup links, session links) at this
  /// executable, unless it already is. The installer writes the same keys;
  /// this follows a moved install or a development build.
  static void _registerLink() {
    final command = '"${Platform.resolvedExecutable}" "%1"';
    try {
      final user = Registry.currentUser;
      try {
        final open = user.createKey(r'Software\Classes\pocketterm\shell\open\command');
        try {
          if (open.getStringValue('') == command) return;
          final scheme = user.createKey(r'Software\Classes\pocketterm');
          try {
            scheme
              ..createValue(const RegistryValue.string('', 'URL:PocketTerm'))
              ..createValue(const RegistryValue.string('URL Protocol', ''));
          } finally {
            scheme.close();
          }
          open.createValue(RegistryValue.string('', command));
        } finally {
          open.close();
        }
      } finally {
        user.close();
      }
    } on WindowsException catch (e) {
      debugPrint('PocketTerm: pocketterm:// not registered: $e');
    }
  }
}
