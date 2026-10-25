import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/intro.dart';

void main() {
  const middle = Offset(195, 422);

  /// The intro over a screen that counts the taps reaching it.
  Future<ValueNotifier<int>> pumpIntro(WidgetTester tester, {bool play = true, bool reduced = false}) async {
    final taps = ValueNotifier(0);
    addTearDown(taps.dispose);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: const Size(390, 844), disableAnimations: reduced),
        child: PocketTermIntro(play: play, child: _App(taps)),
      ),
    );
    // The intro's clock starts at the first frame after.
    await tester.pump();
    return taps;
  }

  /// Whether the intro still covers the screen.
  bool covered(WidgetTester tester) =>
      find.descendant(of: find.byType(PocketTermIntro), matching: find.byType(CustomPaint)).evaluate().isNotEmpty;

  testWidgets('plays through and hands the screen to the app, whose state lives on', (tester) async {
    final taps = await pumpIntro(tester);
    final app = tester.state(find.byType(_App));
    expect(covered(tester), isTrue);

    expect(covered(tester), isTrue, reason: 'mid-zoom');
    await tester.pumpAndSettle();
    expect(covered(tester), isFalse);
    expect(tester.state(find.byType(_App)), same(app));
    await tester.tapAt(middle);
    expect(taps.value, 1);
  });

  testWidgets('ends on its own after its duration', (tester) async {
    await pumpIntro(tester);
    await tester.pump(PocketTermIntro.duration - const Duration(milliseconds: 50));
    expect(covered(tester), isTrue);
    await tester.pump(const Duration(milliseconds: 51));
    expect(covered(tester), isFalse);
  });

  testWidgets('a tap skips it, without reaching the app', (tester) async {
    final taps = await pumpIntro(tester);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tapAt(middle);
    expect(taps.value, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(covered(tester), isFalse, reason: 'gone long before the whole intro would end');
    await tester.tapAt(middle);
    expect(taps.value, 1);
  });

  testWidgets('with animations off, only a short fade', (tester) async {
    await pumpIntro(tester, reduced: true);
    expect(covered(tester), isTrue);
    await tester.pump(PocketTermIntro.reducedDuration + const Duration(milliseconds: 1));
    expect(covered(tester), isFalse);
  });

  testWidgets('waits for play (the desktop window showing), then plays once', (tester) async {
    final taps = await pumpIntro(tester, play: false);
    expect(covered(tester), isFalse);
    await tester.tapAt(middle);
    expect(taps.value, 1);

    await pumpIntro(tester);
    expect(covered(tester), isTrue);
    await tester.pumpAndSettle();
    expect(covered(tester), isFalse);
    // Shown again: no second intro.
    await pumpIntro(tester);
    expect(covered(tester), isFalse);
  });
}

/// Stands in for the app: counts the taps that reach it.
class _App extends StatefulWidget {
  const _App(this.taps);
  final ValueNotifier<int> taps;

  @override
  State<_App> createState() => _AppState();
}

class _AppState extends State<_App> {
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => widget.taps.value++,
    child: const SizedBox.expand(),
  );
}
