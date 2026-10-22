import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/account.dart';
import 'package:pocketterm_core/backend.dart';
import 'package:pocketterm_core/server_client.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_mobile/mobile.dart';
import 'package:pocketterm_mobile/setup_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phone with no session: [known], the server it knows from before, if
/// any; [reason], why it lost the last one.
class _Phone extends MobileSession {
  _Phone(SharedPreferences prefs, {this.known, this.reason}) : super(prefs, 'iPhone');
  final Backend? known;
  final String? reason;

  @override
  Backend? get backend => known;

  @override
  String? get signedOutReason => reason;
}

/// A [Session] whose [connectLink] signs in (or fails with [failure])
/// without a server, keeping what it was handed.
class _FakeSession extends Session {
  _FakeSession({this.failure}) : super('iPhone');
  final String? failure;

  @override
  DeviceRole get role => DeviceRole.phone;

  @override
  DeviceTokens get deviceTokens => MemoryDeviceTokens();
  final links = <(Uri, bool)>[];
  bool signedIn = false;

  @override
  Future<void> connectLink(Uri uri, {bool scanned = false}) async {
    links.add((uri, scanned));
    if (failure case final f?) {
      authError = f;
    } else {
      signedIn = true;
    }
    notifyListeners();
  }
}

const _server = 'https://pt.example.com';
final Uri _link = Uri.parse('pocketterm://setup?url=$_server&code=K7QM-3XRT-AB12-CD34-EF56-GH78-JK90&d=abcd1234&k=a');

void main() {
  void phoneSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// The setup page whose camera reads [read] (null: cancelled).
  Future<_FakeSession> pumpSetup(WidgetTester tester, {String? failure, Uri? read}) async {
    phoneSize(tester);
    final session = _FakeSession(failure: failure);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: session,
            builder: (_, _) =>
                session.signedIn ? const Text('Signed in') : SetupPage(session: session, scan: (_) async => read),
          ),
        ),
      ),
    );
    return session;
  }

  Future<void> scan(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('scan-code')));
    await tester.pump();
  }

  for (final (name, known) in [('a new phone', null), ('a phone that knows its server', const Backend(url: _server))]) {
    testWidgets('$name without a session offers scanning the computer’s code and the demo, nothing else', (
      tester,
    ) async {
      phoneSize(tester);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(MobileApp(session: _Phone(await SharedPreferences.getInstance(), known: known)));
      expect(find.text('Scan the code from your computer'), findsOneWidget);
      expect(find.byKey(const ValueKey('try-demo')), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'no server address, no pasted code');
      expect(find.byType(SignInPage), findsNothing);
      expect(find.textContaining('GitHub'), findsNothing);
    });
  }

  testWidgets('a phone that lost its session says why on the scan screen', (tester) async {
    phoneSize(tester);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MobileApp(session: _Phone(await SharedPreferences.getInstance(), reason: 'You signed out.')),
    );
    expect(find.text('You signed out.'), findsOneWidget);
    expect(find.text('Scan the code from your computer'), findsOneWidget);
  });

  testWidgets('a scanned code signs in, as scanned: its computer key is taken', (tester) async {
    final session = await pumpSetup(tester, read: _link);
    await scan(tester);
    expect(session.links, [(_link, true)]);
    expect(find.text('Signed in'), findsOneWidget);
  });

  testWidgets('a cancelled scan sends nothing', (tester) async {
    final session = await pumpSetup(tester);
    await scan(tester);
    expect(session.links, isEmpty);
    expect(find.text('Scan the code from your computer'), findsOneWidget);
  });

  testWidgets('a code the server turns down says why and stays', (tester) async {
    const why = "That code doesn't work: it may have run out, been used already or been revoked.";
    final session = await pumpSetup(tester, failure: why, read: _link);
    await scan(tester);
    expect(session.links, [(_link, true)]);
    expect(find.text(why), findsOneWidget);
    expect(find.text('Scan the code from your computer'), findsOneWidget);
  });
}
