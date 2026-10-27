import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/e2e.dart';
import 'package:pocketterm_core/speech.dart';
import 'package:pocketterm_core/terminal_remote.dart';
import 'package:pocketterm_mobile/session_view.dart';
import 'package:pocketterm_mobile/voice.dart';

import 'screenshots/fakes.dart';

const _session = 'kitty-1/2';

/// The phone's recognizer, played by the test: it says what [say] is given and settles it on [stop].
class FakeSpeech implements SpeechSource {
  SpeechCheck status = const SpeechCheck(SpeechStatus.ready);
  final fixes = <SpeechFix>[];
  StreamController<SpeechEvent>? _out;
  String _said = '';
  int stops = 0;
  bool _ended = false;

  /// The sheet let go of the stream before it ended: what was heard was discarded.
  bool discarded = false;

  bool get listening => _out != null && !_out!.isClosed;

  @override
  Future<SpeechCheck> check() async => status;

  @override
  Stream<SpeechEvent> listen() {
    _said = '';
    _ended = false;
    discarded = false;
    final out = _out = StreamController<SpeechEvent>(
      onCancel: () {
        if (!_ended) discarded = true;
      },
    );
    return out.stream;
  }

  void say(String text) {
    _said = text;
    _out!.add(SpeechHeard(text));
  }

  void level(double v) => _out!.add(SpeechLevel(v));

  Future<void> end(SpeechEnd why, {String? message, SpeechStatus? status}) async {
    _ended = true;
    _out!.add(SpeechEnded(why, message: message, status: status));
    await _out!.close();
  }

  @override
  Future<void> stop() async {
    stops++;
    _out!.add(SpeechHeard(_said));
    await end(SpeechEnd.stopped);
  }

  @override
  Future<void> fix(SpeechFix fix) async {
    fixes.add(fix);
    if (fix == SpeechFix.download) status = const SpeechCheck(SpeechStatus.ready);
  }
}

void main() {
  late Directory dir;
  late TerminalRemote remote;
  late List<Map<String, dynamic>> runs;
  late FakeSpeech speech;

  Map<String, dynamic> state({bool busy = false}) => {
    'windows': [
      {'key': _session, 'title': 'omp', 'cwd': '/Users/me/a', 'program': 'omp', 'app': 'kitty'},
    ],
    'sessions': [
      {
        'key': _session,
        'id': 's2',
        'agent': 'omp',
        'window': _session,
        'title': 'The session',
        'cwd': '/Users/me/a',
        'busy': busy,
        'at': DateTime.now().millisecondsSinceEpoch,
      },
    ],
    'home': '/Users/me',
    'agent': 'omp',
  };

  void catchUp() => remote.handle('items', {
    'to': 'phone',
    'session': _session,
    'epoch': 'e1',
    'seq': 1,
    'reset': true,
    'last': true,
    'older': false,
    'items': [
      {'id': 'u1', 'k': 'user', 't': 'hi', 'o': 1, 's': 1},
    ],
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('pocketterm_voice');
    runs = [];
    speech = FakeSpeech();
    voiceSource = speech;
    remote = TerminalRemote(
      offlineServer(),
      dir,
      desktopId: 'abcd1234',
      key: ChannelKey(List.filled(32, 9)),
      from: 'phone',
      send: (event, payload) {
        if (event == 'run') runs.add(payload);
      },
    )..handle('state', state());
    catchUp();
  });
  tearDown(() {
    remote.flush();
    dir.deleteSync(recursive: true);
  });

  final field = find.byKey(const ValueKey('session-input'));
  final mic = find.byKey(const ValueKey('session-mic'));
  final smallMic = find.byKey(const ValueKey('session-mic-small'));
  final send = find.byKey(const ValueKey('session-send'));
  final live = find.byKey(const ValueKey('voice-live'));
  final edit = find.byKey(const ValueKey('voice-edit'));
  final sheet = find.byType(VoiceSheet);

  String typed(WidgetTester tester) => tester.widget<TextField>(field).controller!.text;

  List<Map<String, dynamic>> prompts() => [
    for (final r in runs)
      if (r['op'] == 'prompt') r,
  ];

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
        home: SessionPage(remote: remote, sessionKey: _session),
      ),
    );
    catchUp();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The computer took every prompt sent.
  Future<void> answered(WidgetTester tester) async {
    for (final p in prompts()) {
      remote.handle('ran', {'id': p['id']});
    }
    await tester.pump();
  }

  /// What the recognizer said reaches the sheet, and the sheet's next frame shows it.
  Future<void> heard(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  /// Frames enough for the sheet to slide and the recognizer to answer (a working session's spinner never settles).
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Taps [target] and lets the sheet slide up and start listening.
  Future<void> tapOpen(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await settle(tester);
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('voice-stop')));
    await settle(tester);
  }

  /// A finger's touch as the platform reports it, before the framework routes it.
  void touch(WidgetTester tester, ui.PointerChange change, Offset at) {
    final ratio = tester.view.devicePixelRatio;
    tester.binding.platformDispatcher.onPointerDataPacket!(
      ui.PointerDataPacket(
        data: [
          ui.PointerData(
            viewId: tester.view.viewId,
            change: change,
            device: 7,
            pointerIdentifier: 7,
            physicalX: at.dx * ratio,
            physicalY: at.dy * ratio,
          ),
        ],
      ),
    );
  }

  testWidgets('the button is the microphone while there is nothing to send, Send once there is', (tester) async {
    await open(tester);
    expect(mic, findsOneWidget);
    expect(send, findsNothing);

    // The microphone and Send cross-fade: settled, only the one coming is there.
    await tester.enterText(field, 'fix it');
    await tester.pumpAndSettle();
    expect(send, findsOneWidget);
    expect(mic, findsNothing);
    expect(smallMic, findsOneWidget, reason: 'speaking can still add to what is typed');

    await tester.enterText(field, '/');
    await tester.pumpAndSettle();
    expect(smallMic, findsNothing, reason: 'a command name is not spoken');

    await tester.enterText(field, '  ');
    await tester.pumpAndSettle();
    expect(mic, findsOneWidget);
    expect(send, findsNothing);
  });

  testWidgets('the sheet covers the status bar and keeps its title below it', (tester) async {
    tester.view
      ..padding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3)
      ..viewPadding = const FakeViewPadding(top: 59 * 3, bottom: 34 * 3);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await open(tester);
    await tapOpen(tester, mic);
    expect(tester.getTopLeft(find.byType(VoiceSheet)).dy, greaterThan(59));
    expect(tester.getTopLeft(find.text('Listening')).dy, greaterThanOrEqualTo(59));
    expect(tester.getTopLeft(find.byType(BottomSheet)).dy, 0, reason: 'its surface runs under the status bar');
  });

  testWidgets('tap: what is said shows live until Stop, then it is edited and sent', (tester) async {
    await open(tester);
    await tapOpen(tester, mic);
    expect(sheet, findsOneWidget);
    expect(find.text('Speak now…'), findsOneWidget);

    speech
      ..say('fix the')
      ..level(.8);
    await heard(tester);
    expect(find.text('fix the'), findsOneWidget);
    speech.say('fix the tests');
    await heard(tester);
    expect(find.text('fix the tests'), findsOneWidget);

    await stop(tester);
    expect(speech.stops, 1);
    expect(sheet, findsOneWidget, reason: 'it stays to check what was heard');
    expect(tester.widget<TextField>(edit).controller!.text, 'fix the tests');

    await tester.enterText(edit, 'fix the flaky tests');
    await tester.tap(find.byKey(const ValueKey('voice-send')));
    await settle(tester);
    expect(sheet, findsNothing);
    expect(prompts().single, containsPair('text', 'fix the flaky tests'));
    expect(typed(tester), isEmpty);
    await answered(tester);
  });

  testWidgets('Keep talking listens again and adds the new words after the edited ones', (tester) async {
    await open(tester);
    await tapOpen(tester, mic);
    speech.say('fix the tests');
    await stop(tester);
    await tester.enterText(edit, 'fix the flaky tests');
    await tester.tap(find.byKey(const ValueKey('voice-more')));
    await settle(tester);
    expect(speech.listening, isTrue);
    expect(find.text('fix the flaky tests'), findsOneWidget, reason: 'what was there stays while listening');

    speech.say('and push');
    await heard(tester);
    expect(find.text('fix the flaky tests and push'), findsOneWidget);
    await stop(tester);
    expect(tester.widget<TextField>(edit).controller!.text, 'fix the flaky tests and push');
  });

  testWidgets('tapping the orb stops; Keep talking sits above Insert and Send side by side, no Cancel', (tester) async {
    await open(tester);
    await tapOpen(tester, mic);
    speech
      ..say('fix the tests')
      ..level(.6);
    await heard(tester);
    await stop(tester);
    expect(speech.stops, 1);
    expect(find.byKey(const ValueKey('voice-stop')), findsNothing);

    Rect at(String key) => tester.getRect(find.byKey(ValueKey(key)));
    final more = at('voice-more');
    final insert = at('voice-insert');
    final send = at('voice-send');
    expect(find.byKey(const ValueKey('voice-cancel')), findsNothing, reason: 'the close button does that');
    for (final b in [insert, send]) {
      expect(more.bottom, lessThanOrEqualTo(b.top), reason: 'Keep talking is on its own row above');
      expect(b.center.dy, moreOrLessEquals(send.center.dy, epsilon: 1), reason: 'one row');
      expect(b.right, lessThanOrEqualTo(393));
    }
    expect(insert.right, lessThanOrEqualTo(send.left));
  });

  testWidgets('Insert puts it in the field with the keyboard up; closing and dragging the sheet down drop it', (
    tester,
  ) async {
    await open(tester);
    await tapOpen(tester, mic);
    speech.say('update the readme');
    await stop(tester);
    await tester.tap(find.byKey(const ValueKey('voice-insert')));
    await settle(tester);
    expect(sheet, findsNothing);
    expect(typed(tester), 'update the readme');
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    expect(prompts(), isEmpty);

    await tester.enterText(field, '');
    await tester.pump();
    await tapOpen(tester, mic);
    speech.say('never mind');
    await stop(tester);
    await tester.tap(find.byKey(const ValueKey('voice-close')));
    await settle(tester);
    expect(sheet, findsNothing);
    expect(typed(tester), isEmpty);

    // Dragged down while still listening: nothing kept, the recognizer let go at once.
    await tapOpen(tester, mic);
    speech.say('half a thought');
    await heard(tester);
    await tester.drag(find.byKey(const ValueKey('voice-live')), const Offset(0, 1500));
    await settle(tester);
    expect(sheet, findsNothing);
    expect(speech.discarded, isTrue);
    expect(typed(tester), isEmpty);
    expect(prompts(), isEmpty);
  });

  testWidgets('what is said goes after what was typed, which shows dimmed above it', (tester) async {
    await open(tester);
    await tester.enterText(field, 'Run the tests');
    // The small microphone slides in beside Send.
    await tester.pumpAndSettle();
    await tapOpen(tester, smallMic);
    expect(tester.widget<Text>(find.byKey(const ValueKey('voice-existing'))).data, 'Run the tests');
    speech.say('and fix what fails');
    await stop(tester);
    await tester.tap(find.byKey(const ValueKey('voice-insert')));
    await settle(tester);
    expect(typed(tester), 'Run the tests and fix what fails');

    await tapOpen(tester, smallMic);
    speech.say('then commit');
    await stop(tester);
    await tester.tap(find.byKey(const ValueKey('voice-send')));
    await settle(tester);
    expect(prompts().single, containsPair('text', 'Run the tests and fix what fails then commit'));
    await answered(tester);
  });

  testWidgets('hold: lifting the finger stops and leaves it to check', (tester) async {
    await open(tester);
    final at = tester.getCenter(mic);
    touch(tester, ui.PointerChange.add, at);
    touch(tester, ui.PointerChange.down, at);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(sheet, findsOneWidget);
    expect(find.byKey(const ValueKey('voice-hold-hint')), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-stop')), findsNothing);

    speech.say('add a test');
    touch(tester, ui.PointerChange.move, at + const Offset(10, -20));
    await tester.pump();
    touch(tester, ui.PointerChange.up, at + const Offset(10, -20));
    await settle(tester);
    expect(speech.stops, 1);
    expect(sheet, findsOneWidget);
    expect(tester.widget<TextField>(edit).controller!.text, 'add a test');
    expect(find.byKey(const ValueKey('voice-send')), findsOneWidget);
  });

  testWidgets('hold: sliding far away before lifting cancels', (tester) async {
    await open(tester);
    final at = tester.getCenter(mic);
    touch(tester, ui.PointerChange.add, at);
    touch(tester, ui.PointerChange.down, at);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    speech.say('oops');
    touch(tester, ui.PointerChange.move, at + const Offset(0, -(voiceCancelDistance + 30)));
    await tester.pump();
    expect(find.text('Release to cancel'), findsWidgets);

    touch(tester, ui.PointerChange.up, at + const Offset(0, -(voiceCancelDistance + 30)));
    await settle(tester);
    expect(sheet, findsNothing);
    expect(speech.discarded, isTrue);
    expect(speech.stops, 0);
    expect(typed(tester), isEmpty);
  });

  testWidgets('a press the system takes back before it is a hold opens nothing', (tester) async {
    await open(tester);
    final gesture = await tester.startGesture(tester.getCenter(mic));
    await tester.pump(const Duration(milliseconds: 100));
    // A scroll or an edge swipe claims the finger: the press ends there.
    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(sheet, findsNothing, reason: 'the hold it would have become never starts');
    expect(speech.listening, isFalse);

    // The next tap still opens it.
    await tapOpen(tester, mic);
    expect(sheet, findsOneWidget);
  });

  testWidgets('a refused microphone says so and opens Settings', (tester) async {
    speech.status = const SpeechCheck(SpeechStatus.denied, fix: SpeechFix.appSettings);
    await open(tester);
    await tapOpen(tester, mic);
    expect(find.byKey(const ValueKey('voice-problem')), findsOneWidget);
    expect(speech.listening, isFalse);
    await tester.tap(find.text('Open Settings'));
    await tester.pump();
    expect(speech.fixes, [SpeechFix.appSettings]);
  });

  testWidgets('no English on the device: it says so, and once downloaded it listens', (tester) async {
    speech.status = const SpeechCheck(SpeechStatus.noEnglish, fix: SpeechFix.download);
    await open(tester);
    await tapOpen(tester, mic);
    expect(find.textContaining('English for speech recognition isn’t on this phone'), findsOneWidget);
    expect(speech.listening, isFalse);
    await tester.tap(find.text('Download'));
    await settle(tester);
    expect(speech.fixes, [SpeechFix.download]);
    expect(speech.listening, isTrue);
    expect(live, findsOneWidget);
  });

  testWidgets('English found missing only when listening starts says so too', (tester) async {
    await open(tester);
    await tapOpen(tester, mic);
    await speech.end(SpeechEnd.error, message: 'no English', status: SpeechStatus.noEnglish);
    await settle(tester);
    expect(find.byKey(const ValueKey('voice-problem')), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  testWidgets('a call taking the microphone stops listening and keeps what was said', (tester) async {
    await open(tester);
    await tapOpen(tester, mic);
    speech.say('rename the module');
    await heard(tester);
    await speech.end(SpeechEnd.interrupted);
    await settle(tester);
    expect(tester.widget<TextField>(edit).controller!.text, 'rename the module');
    expect(find.byKey(const ValueKey('voice-note')), findsOneWidget);
  });

  testWidgets('leaving the app stops listening and keeps what was said', (tester) async {
    await open(tester);
    await tapOpen(tester, mic);
    speech.say('check the logs');
    await heard(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await settle(tester);
    expect(speech.stops, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(tester.widget<TextField>(edit).controller!.text, 'check the logs');
  });

  testWidgets('Send while the agent works steers it, or queues with Queue on, as the composer would', (tester) async {
    remote.handle('state', state(busy: true));
    await open(tester);
    await tapOpen(tester, mic);
    speech.say('use the other API');
    await stop(tester);
    await tester.tap(find.byKey(const ValueKey('voice-send')));
    await settle(tester);
    expect(prompts().single, containsPair('deliver', 'steer'));
    remote.handle('ran', {'id': prompts().single['id']});
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('follow-up')));
    await tester.pump();
    await tapOpen(tester, mic);
    speech.say('then update the docs');
    await stop(tester);
    await tester.tap(find.byKey(const ValueKey('voice-send')));
    await settle(tester);
    expect(prompts().last, allOf(containsPair('deliver', 'followUp'), containsPair('text', 'then update the docs')));
    await answered(tester);
  });
}
