import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:pocketterm_core/chat_images.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/session_view.dart';

import 'screenshots/fakes.dart';

/// The phone's file picker, answering with [next].
class _Files extends FileSelectorPlatform with MockPlatformInterfaceMixin {
  List<XFile> next = const [];

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => next;
}

XFile _file(String name, String text, {int? length}) =>
    XFile.fromData(Uint8List.fromList(text.codeUnits), path: '/picked/$name', length: length);

void main() {
  late Directory dir;
  late TerminalRemote remote;
  late List<Map<String, dynamic>> runs;
  late Map<String, Uint8List> uploaded;
  late _Files picker;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_attachments');
    runs = [];
    uploaded = {};
    picker = _Files();
    FileSelectorPlatform.instance = picker;
    remote = TerminalRemote(
      offlineServer(),
      dir,
      desktopId: 'abcd1234',
      key: ChannelKey(List.filled(32, 9)),
      from: 'phone',
      upload: (path, sealed) async => uploaded[path] = sealed,
      send: (event, payload) {
        if (event != 'run') return;
        runs.add(payload);
        remote.handle('ran', {'id': payload['id']});
      },
    );
    remote.handle('state', {
      'windows': [
        {'key': 'kitty-1/2', 'title': 'omp', 'cwd': '/Users/me/a', 'program': 'omp', 'app': 'kitty'},
      ],
      'sessions': [
        {
          'key': 'kitty-1/2',
          'id': 's2',
          'agent': 'omp',
          'window': 'kitty-1/2',
          'title': 'Idle one',
          'cwd': '/Users/me/a',
          'at': DateTime.now().millisecondsSinceEpoch,
        },
      ],
      'home': '/Users/me',
      'agent': 'omp',
    });
  });
  tearDown(() {
    remote.flush();
    dir.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1179, 2556)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('pocketterm/native'),
      (_) async => null,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SessionPage(remote: remote, sessionKey: 'kitty-1/2'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> chooseFiles(WidgetTester tester, List<XFile> files) async {
    picker.next = files;
    await tester.tap(find.byTooltip('Attach images or files'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose from Files'));
    await tester.pumpAndSettle();
  }

  testWidgets('files picked from Files show as chips with their name and size, each removable', (tester) async {
    await open(tester);
    await chooseFiles(tester, [_file('Q3 report.pdf', '%PDF-1.7 numbers'), _file('notes.md', '# notes')]);

    expect(find.text('Q3 report.pdf'), findsOneWidget);
    expect(find.text('16 bytes'), findsOneWidget);
    expect(find.text('notes.md'), findsOneWidget);
    expect(find.bySemanticsLabel('Remove Q3 report.pdf'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Remove notes.md'));
    await tester.pumpAndSettle();
    expect(find.text('notes.md'), findsNothing);
    expect(find.text('Q3 report.pdf'), findsOneWidget);
  });

  testWidgets('a file over 20 MB is refused with why; the rest attach', (tester) async {
    await open(tester);
    await chooseFiles(tester, [_file('movie.mov', 'x', length: maxChatFileBytes + 1), _file('small.txt', 'ok')]);

    expect(find.text('"movie.mov" is too large: files can be up to 20 MB.'), findsOneWidget);
    expect(find.text('movie.mov'), findsNothing);
    expect(find.text('small.txt'), findsOneWidget);
  });

  testWidgets('a message takes 10 files at most; then the attach button rests until one goes', (tester) async {
    await open(tester);
    await chooseFiles(tester, [for (var i = 0; i < 12; i++) _file('doc$i.txt', 'text $i')]);

    expect(find.text('At most 10 images and files per message.'), findsOneWidget);
    expect(find.text('doc9.txt'), findsOneWidget);
    expect(find.text('doc10.txt'), findsNothing);
    final button = tester.widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>));
    expect(button.enabled, isFalse);

    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Send'));
      for (var i = 0; i < 50 && runs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();

    final files = (runs.single['files'] as List).cast<Map<String, dynamic>>();
    expect(files.map((f) => f['name']), [for (var i = 0; i < 10; i++) 'doc$i.txt']);
    expect(files.map((f) => f['mime']).toSet(), {'text/plain'});
    expect(uploaded.keys, unorderedEquals(files.map((f) => f['path'])), reason: 'each one sealed and uploaded');
    expect(find.text('doc0.txt'), findsNothing, reason: 'sent, they leave the composer');
  });
}
