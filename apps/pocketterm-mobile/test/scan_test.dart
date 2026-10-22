import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_mobile/onboarding/scan.dart';

const _key = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';
const _signIn = 'pocketterm://setup?url=http://127.0.0.1:8787&code=K7QM-3XRT&d=abcd1234&k=$_key';

void main() {
  /// Opens the scanner ([signedIn]: for one more computer's key) on a fresh
  /// app and keeps what it pops.
  Future<List<Uri?>> openScanner(WidgetTester tester, {bool signedIn = false}) async {
    final popped = <Uri?>[];
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => popped.add(await scanSetupCode(context, signedIn: signedIn, pasteCode: true)),
            child: const Text('Scan'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    return popped;
  }

  Future<void> paste(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const ValueKey('paste-code')), code);
    await tester.tap(find.byKey(const ValueKey('paste-code-use')));
    await tester.pumpAndSettle();
  }

  // E2E debug builds take a pasted code as if the camera read it: the
  // Simulator has no camera.
  testWidgets('a pasted sign-in code comes back as a scanned one', (tester) async {
    final popped = await openScanner(tester);
    await paste(tester, '  $_signIn ');
    expect(popped, [Uri.parse(_signIn)]);
  });

  testWidgets('a pasted code is held to what the camera is: no sign-in, no key, not ours', (tester) async {
    final popped = await openScanner(tester);
    await paste(tester, 'pocketterm://setup?url=http://127.0.0.1:8787');
    expect(find.textContaining('That code has no sign-in in it'), findsOneWidget);
    await paste(tester, 'https://example.com');
    expect(find.textContaining("That's not a PocketTerm code"), findsOneWidget);
    expect(popped, isEmpty);

    final adding = await openScanner(tester, signedIn: true);
    await paste(tester, 'pocketterm://setup?url=http://127.0.0.1:8787&code=K7QM-3XRT');
    expect(find.textContaining('That code has no key for a computer'), findsOneWidget);
    await paste(tester, _signIn);
    expect(adding, [Uri.parse(_signIn)]);
  });

  testWidgets("a code from PocketTerm 0.1 (a Supabase project) says to update the computer's app", (tester) async {
    final popped = await openScanner(tester);
    await paste(tester, 'pocketterm://setup?url=https://abcd.supabase.co&key=sb_publishable_x&code=K7QM');
    expect(find.textContaining('older PocketTerm'), findsOneWidget);
    expect(popped, isEmpty);
  });

  testWidgets('a camera the person refused says where to allow it and opens Settings', (tester) async {
    final native = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('dev.steenbakker.mobile_scanner/scanner/method'), (call) async {
        return switch (call.method) {
          'state' => 2, // denied
          'request' => false,
          _ => null,
        };
      })
      ..setMockMethodCallHandler(const MethodChannel('pocketterm/native'), (call) async {
        native.add(call);
        return null;
      });
    addTearDown(() {
      messenger
        ..setMockMethodCallHandler(const MethodChannel('dev.steenbakker.mobile_scanner/scanner/method'), null)
        ..setMockMethodCallHandler(const MethodChannel('pocketterm/native'), null);
    });
    await openScanner(tester);
    expect(find.textContaining('needs the camera'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('camera-settings')));
    expect(native.map((c) => c.method), ['openSettings']);
    expect(native.single.arguments, {'notifications': false});
  });
}
