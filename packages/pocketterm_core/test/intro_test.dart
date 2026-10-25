import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/intro.dart';

void main() {
  const display = Size(390, 844);
  final full = Offset.zero & display;
  final middle = full.center;

  /// The intro over a screen that counts the taps reaching it.
  Future<ValueNotifier<int>> pumpIntro(
    WidgetTester tester, {
    bool play = true,
    bool reduced = false,
    Size size = display,
  }) async {
    final taps = ValueNotifier(0);
    addTearDown(taps.dispose);
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: reduced),
        child: PocketTermIntro(play: play, child: _App(taps)),
      ),
    );
    // The intro's clock starts at the first frame after.
    await tester.pump();
    return taps;
  }

  /// Where the app is drawn on the display.
  Rect app(WidgetTester tester) => tester.getRect(find.byType(_App));

  /// Whether a tap in the middle would reach the app (rather than the intro).
  bool reachesApp(WidgetTester tester) {
    final box = tester.renderObject(find.byType(_App));
    return tester.hitTestOnBinding(middle).path.any((entry) => entry.target == box);
  }

  void expectRect(Rect actual, Rect expected, {double within = .01, String? reason}) {
    for (final (a, e) in [
      (actual.left, expected.left),
      (actual.top, expected.top),
      (actual.right, expected.right),
      (actual.bottom, expected.bottom),
    ]) {
      expect(
        a,
        moreOrLessEquals(e, epsilon: within),
        reason: '$actual vs $expected${reason == null ? '' : ': $reason'}',
      );
    }
  }

  testWidgets('plays the app on the phone, zooms in until it fills the display and hands it over as it is', (
    tester,
  ) async {
    final taps = await pumpIntro(tester);
    final state = tester.state(find.byType(_App));
    expect(reachesApp(tester), isFalse);

    // On the phone's screen, small, in the middle of the display, while the
    // view zooms in: at the display's size all along, only drawn smaller.
    await tester.pump(const Duration(milliseconds: 1100));
    final small = app(tester);
    expect(small.width, lessThan(display.width / 2));
    expect(small.height, lessThan(display.height / 2));
    expect(full.contains(small.center), isTrue);
    expect(tester.getSize(find.byType(_App)), display);
    await tester.pump(const Duration(milliseconds: 300));
    final larger = app(tester);
    expect(larger.width, greaterThan(small.width));
    expect(larger.width / larger.height, moreOrLessEquals(display.aspectRatio));
    expect(reachesApp(tester), isFalse, reason: 'mid-zoom');
    await tester.tapAt(middle);
    expect(taps.value, 0);

    // Nearly at the end it already all but fills the display: no jump.
    await tester.pump(PocketTermIntro.duration - const Duration(milliseconds: 1420));
    expectRect(app(tester), full, within: 1, reason: 'a frame before the end');
    await tester.pumpAndSettle();
    expectRect(app(tester), full);
    expect(tester.state(find.byType(_App)), same(state));
    await tester.tapAt(middle);
    expect(taps.value, 1);
  });

  testWidgets('ends exactly on the display of a desktop window too', (tester) async {
    const window = Size(1200, 760);
    await pumpIntro(tester, size: window);
    await tester.pump(const Duration(milliseconds: 1300));
    final mid = app(tester);
    expect(mid.width, lessThan(window.width));
    await tester.pump(PocketTermIntro.duration - const Duration(milliseconds: 1320));
    expectRect(app(tester), Offset.zero & window, within: 1);
    await tester.pumpAndSettle();
    expectRect(app(tester), Offset.zero & window);
    expect(reachesApp(tester), isTrue);
  });

  testWidgets('accessibility gets the app once it is handed over, where it is: full screen', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpIntro(tester);
    await tester.pump(const Duration(milliseconds: 1300));
    // Drawn small and moving on the phone: nothing to read or tap yet.
    expect(find.bySemanticsLabel('app'), findsNothing);
    await tester.pumpAndSettle();

    // Where VoiceOver, TalkBack and UI tests (Maestro, tapping by text) see it.
    final node = tester.getSemantics(find.bySemanticsLabel('app'));
    var rect = node.rect;
    for (SemanticsNode? n = node; n != null; n = n.parent) {
      if (n.transform case final transform?) rect = MatrixUtils.transformRect(transform, rect);
    }
    expectRect(rect, full);
    semantics.dispose();
  });

  testWidgets('ends on its own after its duration', (tester) async {
    await pumpIntro(tester);
    await tester.pump(PocketTermIntro.duration - const Duration(milliseconds: 50));
    expect(reachesApp(tester), isFalse);
    await tester.pump(const Duration(milliseconds: 51));
    expect(reachesApp(tester), isTrue);
  });

  testWidgets('a tap skips it, without reaching the app', (tester) async {
    final taps = await pumpIntro(tester);
    final state = tester.state(find.byType(_App));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tapAt(middle);
    expect(taps.value, 0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(reachesApp(tester), isTrue, reason: 'gone long before the whole intro would end');
    expectRect(app(tester), full);
    expect(tester.state(find.byType(_App)), same(state));
    await tester.tapAt(middle);
    expect(taps.value, 1);
  });

  testWidgets('with animations off, the app as it is under a short fade', (tester) async {
    final taps = await pumpIntro(tester, reduced: true);
    expectRect(app(tester), full);
    await tester.tapAt(middle);
    expect(taps.value, 0);
    await tester.pump(PocketTermIntro.reducedDuration + const Duration(milliseconds: 1));
    expect(reachesApp(tester), isTrue);
    await tester.tapAt(middle);
    expect(taps.value, 1);
  });

  testWidgets('waits for play (the desktop window showing), then plays once', (tester) async {
    final taps = await pumpIntro(tester, play: false);
    expectRect(app(tester), full);
    await tester.tapAt(middle);
    expect(taps.value, 1);

    await pumpIntro(tester);
    expect(reachesApp(tester), isFalse);
    await tester.pumpAndSettle();
    expect(reachesApp(tester), isTrue);
    // Shown again: no second intro.
    await pumpIntro(tester);
    expect(reachesApp(tester), isTrue);
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
  Widget build(BuildContext context) => Semantics(
    label: 'app',
    textDirection: TextDirection.ltr,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.taps.value++,
      child: const SizedBox.expand(),
    ),
  );
}
