import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/session.dart';
import 'package:pocketterm_desktop/onboarding/pair.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A session whose codes come from [next]; [made] counts them.
class _Codes implements Session {
  _Codes(this.next);
  Future<Uri> Function(int n) next;
  int made = 0;

  @override
  Future<Uri> pairingLink() => next(++made);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> pump(WidgetTester tester, Session session) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: PairingQr(session: session)),
        ),
      ),
    );
    await tester.pump();
  }

  Uri code(int n) => Uri.parse('pocketterm://pair?code=$n');

  testWidgets('a code runs out after its lifetime, and Make a new one asks for a fresh one', (tester) async {
    final codes = _Codes((n) async => code(n));
    await pump(tester, codes);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(codes.made, 1);

    await tester.pump(pairingLifetime - const Duration(seconds: 1));
    expect(find.byType(QrImageView), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('This code ran out.'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    await tester.tap(find.text('Make a new one'));
    await tester.pump();
    await tester.pump();
    expect(codes.made, 2);
    expect(find.byType(QrImageView), findsOneWidget);

    // The new code has a lifetime of its own.
    await tester.pump(pairingLifetime);
    expect(find.text('This code ran out.'), findsOneWidget);
  });

  testWidgets("a code that can't be made says why, and Retry makes one", (tester) async {
    final codes = _Codes((n) async => n == 1 ? throw const PairingException('The server said no.') : code(n));
    await pump(tester, codes);
    expect(find.text('The server said no.'), findsOneWidget);
    expect(find.byType(QrImageView), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(codes.made, 2);
    expect(find.byType(QrImageView), findsOneWidget);
  });

  testWidgets('any other failure is shown as such, with Retry', (tester) async {
    final codes = _Codes((n) async => n == 1 ? throw StateError('offline') : code(n));
    await pump(tester, codes);
    expect(find.textContaining("Couldn't make a code"), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(QrImageView), findsOneWidget);
  });
}
