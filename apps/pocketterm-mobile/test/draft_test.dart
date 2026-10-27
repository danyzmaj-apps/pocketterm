import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screenshots/fakes.dart';

const _one = 'kitty-1/2';
const _two = 'kitty-1/3';

void main() {
  late Directory dir;
  late TerminalRemote remote;
  late List<Map<String, dynamic>> runs;

  Map<String, dynamic> session(String key) => {
    'key': key,
    'id': 's-$key',
    'agent': 'omp',
    'window': key,
    'title': 'The session',
    'cwd': '/Users/me/a',
    'at': DateTime.now().millisecondsSinceEpoch,
  };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('pocketterm_draft');
    runs = [];
    remote =
        TerminalRemote(
          offlineServer(),
          dir,
          desktopId: 'abcd1234',
          key: ChannelKey(List.filled(32, 9)),
          from: 'phone',
          send: (event, payload) {
            if (event == 'run') runs.add(payload);
          },
        )..handle('state', {
          'windows': [
            for (final k in [_one, _two])
              {'key': k, 'title': 'omp', 'cwd': '/Users/me/a', 'program': 'omp', 'app': 'kitty'},
          ],
          'sessions': [session(_one), session(_two)],
          'home': '/Users/me',
          'agent': 'omp',
        });
  });
  tearDown(() {
    remote.flush();
    dir.deleteSync(recursive: true);
  });

  final input = find.byKey(const ValueKey('session-input'));
  String field(WidgetTester tester) => tester.widget<TextField>(input).controller!.text;

  final nav = GlobalKey<NavigatorState>();

  Future<void> start(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1179, 2556)
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('pocketterm/native'),
      (_) async => null,
    );
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const Scaffold()));
  }

  Future<void> open(WidgetTester tester, String key) async {
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(remote: remote, sessionKey: key),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    nav.currentState!.pop();
    await tester.pumpAndSettle();
  }

  testWidgets('unsent text stays with its session until it is sent', (tester) async {
    await start(tester);
    await open(tester, _one);
    await tester.enterText(input, 'half a thought');
    await tester.pump();
    await close(tester);

    await open(tester, _two);
    expect(field(tester), '', reason: 'another session has its own draft');
    await close(tester);

    await open(tester, _one);
    expect(field(tester), 'half a thought');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pocketterm_draft_abcd1234/$_one'), contains('half a thought'));

    await tester.tap(find.byKey(const ValueKey('session-send')));
    await tester.pump(Duration.zero);
    final prompt = runs.where((r) => r['op'] == 'prompt').toList();
    expect(prompt, hasLength(1));
    remote.handle('ran', {'id': prompt.single['id']});
    await close(tester);

    await open(tester, _one);
    expect(field(tester), '');
    expect(prefs.getKeys(), isNot(contains('pocketterm_draft_abcd1234/$_one')));
    await close(tester);
  });
}
