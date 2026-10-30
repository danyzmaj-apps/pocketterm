import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/terminal_view.dart';
import 'package:pocketterm_mobile/voice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screenshots/fakes.dart';
import 'voice_test.dart' show FakeSpeech;

class _Phone extends MobileSession {
  _Phone(SharedPreferences prefs) : super(prefs, 'iPhone');
}

const _a = '/Users/me/a';
const _b = '/Users/me/b';
const _orch = '/x/orchestrator';

void main() {
  late Directory dir;
  late List<(String, Map<String, dynamic>)> sent;
  late TerminalRemote remote;
  late SharedPreferences prefs;
  late FakeSpeech speech;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('pocketterm_orchestrator');
    sent = [];
    speech = FakeSpeech();
    voiceSource = speech;
    remote = TerminalRemote(
      offlineServer(),
      dir,
      desktopId: 'abcd1234',
      key: ChannelKey(List.filled(32, 9)),
      from: 'phone',
      send: (event, payload) => sent.add((event, payload)),
    );
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() {
    remote.flush();
    dir.deleteSync(recursive: true);
  });

  /// Two sessions in projects a and b, and (with [orchestrator]) the orchestrator in its own window; PocketTerm in
  /// omp stands as [omp].
  void state({bool orchestrator = false, String omp = 'installed'}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    Map<String, dynamic> window(String key, String cwd) => {
      'key': key,
      'title': 'omp',
      'cwd': cwd,
      'program': 'omp',
      'app': 'kitty',
    };
    Map<String, dynamic> session(String key, String cwd, {bool orch = false}) => {
      'key': key,
      'id': 's-$key',
      'agent': 'omp',
      'window': key,
      'title': 'Session $key',
      'cwd': cwd,
      if (orch) 'orch': true,
      'at': now,
    };
    remote.handle('state', {
      'windows': [window('kitty-1/1', _a), window('kitty-1/2', _b), if (orchestrator) window('kitty-1/9', _orch)],
      'sessions': [
        session('kitty-1/1', _a),
        session('kitty-1/2', _b),
        if (orchestrator) session('kitty-1/9', _orch, orch: true),
      ],
      'home': '/Users/me',
      'agent': 'omp',
      'agents': {'omp': omp},
    });
  }

  Future<void> pumpList(WidgetTester tester) async {
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
        home: Scaffold(
          body: TerminalList(
            remote: remote,
            folded: _Phone(prefs).collapsedProjects,
            onFolded: _Phone(prefs).setCollapsedProjects,
            sort: _Phone(prefs).projectSort,
            onSort: _Phone(prefs).setProjectSort,
            looks: _Phone(prefs).tileLooks('mac00001'),
            onLooks: (l) => _Phone(prefs).setTileLooks('mac00001', l),
            computer: 'Studio',
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> runs(String op) => [
    for (final (event, p) in sent)
      if (event == 'run' && p['op'] == op) p,
  ];

  final bar = find.byKey(const ValueKey('orchestrator-bar'));
  final input = find.byKey(const ValueKey('orchestrator-input'));
  String typed(WidgetTester tester) => tester.widget<TextField>(input).controller!.text;

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(bar);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('orchestrator-sheet')), findsOneWidget);
  }

  testWidgets('the orchestrator has its bar, not a project, and its window is no other window', (tester) async {
    state(orchestrator: true);
    await pumpList(tester);
    expect(find.byKey(const ValueKey('project-$_a')), findsOneWidget);
    expect(find.byKey(const ValueKey('project-$_orch')), findsNothing);
    expect(find.byKey(const ValueKey('windows-heading')), findsNothing);
    expect(bar, findsOneWidget);

    state(omp: 'missing');
    await tester.pump();
    expect(bar, findsNothing, reason: "omp can't run one, and none runs");
    remote.flush();
  });

  testWidgets('sending with none running starts the orchestrator, then prompts it', (tester) async {
    state();
    await pumpList(tester);
    await openSheet(tester);
    await tester.enterText(input, 'what is running?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('orchestrator-send')));
    await tester.pump();
    await tester.pump(Duration.zero);
    final start = runs('orchestrator').single;
    expect(runs('prompt'), isEmpty);
    expect(find.text('Starting the orchestrator on Studio…'), findsOneWidget);
    remote.handle('ran', {'id': start['id'], 'window': 'kitty-1/9'});
    await tester.pump();
    state(orchestrator: true);
    await tester.pump();
    await tester.pump(Duration.zero);

    final prompt = runs('prompt').single;
    expect(prompt, allOf(containsPair('session', 'kitty-1/9'), containsPair('text', 'what is running?')));
    remote.handle('ran', {'id': prompt['id']});
    await tester.pump();
    expect(typed(tester), isEmpty);
    expect(find.byKey(const ValueKey('orchestrator-error')), findsNothing);
    remote.flush();
  });

  testWidgets('closing the sheet while it starts the orchestrator still sends the prompt', (tester) async {
    state();
    await pumpList(tester);
    await openSheet(tester);
    await tester.enterText(input, 'what is running?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('orchestrator-send')));
    await tester.pump();
    await tester.pump(Duration.zero);
    final start = runs('orchestrator').single;
    await tester.tap(find.byKey(const ValueKey('orchestrator-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('orchestrator-sheet')), findsNothing);

    remote.handle('ran', {'id': start['id'], 'window': 'kitty-1/9'});
    await tester.pump();
    state(orchestrator: true);
    await tester.pump();
    await tester.pump(Duration.zero);
    final prompt = runs('prompt').single;
    expect(prompt, containsPair('text', 'what is running?'));
    remote.handle('ran', {'id': prompt['id'], 'error': 'The computer went away.'});
    await tester.pump();
    expect(tester.takeException(), isNull);
    remote.flush();
  });

  testWidgets('the microphone listens while held and puts what it heard after what was typed, unsent', (tester) async {
    state(orchestrator: true);
    await pumpList(tester);
    await openSheet(tester);
    await tester.enterText(input, 'Please');
    await tester.pump();

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('orchestrator-mic'))));
    await tester.pump();
    await tester.pump();
    expect(speech.listening, isTrue);
    speech.say('list my sessions');
    await tester.pump();
    expect(
      find.descendant(of: find.byKey(const ValueKey('orchestrator-live')), matching: find.text('list my sessions')),
      findsOneWidget,
    );

    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(speech.stops, 1);
    expect(find.byKey(const ValueKey('orchestrator-live')), findsNothing);
    expect(typed(tester), 'Please list my sessions');
    expect(runs('prompt'), isEmpty);
    remote.flush();
  });
}
