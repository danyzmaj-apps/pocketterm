import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pocketterm_core/logo.dart';
import 'package:pocketterm_core/theme.dart';

/// The launch intro over [child], in the active theme: the app icon sits
/// large in the middle of the theme's background (what the native side
/// paints before Flutter's first frame), the phone ducks into the pocket and
/// springs up out of it, stands upright, and the view zooms into its screen
/// until the screen (the theme's background) fills the display, which then
/// cross-fades into [child]. [child] is built underneath from the start. A
/// tap skips it; with animations turned off (MediaQuery.disableAnimations)
/// it's a short fade.
class PocketTermIntro extends StatefulWidget {
  const PocketTermIntro({required this.child, this.play = true, this.theme, super.key});
  final Widget child;

  /// Plays the first time this is true (the desktop's window, hidden at
  /// launch, when it first shows); until then [child] shows as is. Once.
  final bool play;

  /// Played in this theme rather than the active one.
  final PtTheme? theme;

  /// How long it takes when nobody taps.
  static const duration = Duration(milliseconds: 1750);

  /// With animations turned off: the icon, then a fade.
  static const reducedDuration = Duration(milliseconds: 350);

  @override
  State<PocketTermIntro> createState() => _PocketTermIntroState();
}

class _PocketTermIntroState extends State<PocketTermIntro> with TickerProviderStateMixin {
  AnimationController? _run;
  late final _skip = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
    ..addStatusListener(_ended);
  bool _reduced = false;
  bool _done = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _start();
  }

  @override
  void didUpdateWidget(PocketTermIntro oldWidget) {
    super.didUpdateWidget(oldWidget);
    _start();
  }

  void _start() {
    if (!widget.play || _run != null || _done) return;
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _run =
        AnimationController(
            vsync: this,
            duration: _reduced ? PocketTermIntro.reducedDuration : PocketTermIntro.duration,
          )
          ..addStatusListener(_ended)
          ..forward();
  }

  void _ended(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_done) {
      setState(() => _done = true);
      _run?.stop();
      _skip.stop();
    }
  }

  void _tap() {
    if (!_skip.isAnimating) _skip.forward();
  }

  @override
  void dispose() {
    _run?.dispose();
    _skip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    textDirection: TextDirection.ltr,
    // [child] keeps its place in the tree, so the app's state lives on when
    // the intro goes.
    children: [widget.child, if (_run case final run? when !_done) _overlay(run)],
  );

  Widget _overlay(AnimationController run) {
    final style = LogoStyle.of(widget.theme ?? appearance.theme);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _tap,
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: Listenable.merge([run, _skip]),
          builder: (context, _) {
            final ms = run.value * run.duration!.inMilliseconds;
            final frame = _reduced ? _Frame.reduced(ms) : _Frame.at(ms);
            return Opacity(
              opacity: (frame.opacity * (1 - _skip.value)).clamp(0, 1),
              child: CustomPaint(painter: _IntroPainter(style, frame), size: Size.infinite),
            );
          },
        ),
      ),
    );
  }
}

/// Where the intro is at one moment: the choreography, in milliseconds.
///
/// | ms        | what                                                              |
/// |-----------|-------------------------------------------------------------------|
/// | 0–150     | the icon (42% of the display's short side) fades and grows in     |
/// | 150–300   | the phone ducks into the pocket, which squashes                   |
/// | 300–820   | it springs up out of it, nearly whole (overshoots, settles); the  |
/// |           | pocket bounces back                                               |
/// | 480–900   | it stands upright                                                 |
/// | 820–      | the prompt's cursor blinks                                        |
/// | 920–1480  | the view zooms into the phone's screen until it fills it all      |
/// | 1320–1500 | the prompt fades: the screen is the theme's plain background      |
/// | 1480–1750 | that cross-fades into the app                                     |
@immutable
class _Frame {
  const _Frame({
    required this.icon,
    required this.lift,
    required this.squash,
    required this.tilt,
    required this.zoom,
    required this.cursor,
    required this.prompt,
    required this.opacity,
  });

  factory _Frame.at(double ms) {
    double span(double from, double to) => ((ms - from) / (to - from)).clamp(0.0, 1.0);
    final duck = Curves.easeInOut.transform(span(150, 300));
    final pop = span(300, 820);
    return _Frame(
      icon: Curves.easeOutCubic.transform(span(0, 150)),
      lift: ms < 300 ? -duckDepth * duck : -duckDepth + (popHeight + duckDepth) * _spring(pop),
      squash: ms < 300 ? duck : _bounce(span(300, 560)),
      tilt: logoTilt * (1 - Curves.easeInOutCubic.transform(span(480, 900))),
      zoom: Curves.easeInOutCubic.transform(span(920, 1480)),
      cursor: ms < 820 || ((ms - 820) ~/ 210).isEven,
      prompt: 1 - span(1320, 1500),
      opacity: 1 - Curves.easeOut.transform(span(1480, 1750)),
    );
  }

  /// Animations turned off: the icon as it is, then a fade.
  factory _Frame.reduced(double ms) => _Frame(
    icon: 1,
    lift: 0,
    squash: 0,
    tilt: logoTilt,
    zoom: 0,
    cursor: true,
    prompt: 1,
    opacity: 1 - ((ms - 150) / 200).clamp(0.0, 1.0),
  );

  /// How far the phone ducks into the pocket, and how far above where it sits
  /// on the icon it comes to rest: nearly its whole height out of the pocket.
  /// Icon units (the phone is .5 tall).
  static const duckDepth = .06;
  static const popHeight = .24;

  /// The icon's opacity over the background, growing in with it.
  final double icon;

  /// The phone above where it sits on the icon, in icon units.
  final double lift;

  /// The pocket squashed (1), as it is (0) or stretched (below 0).
  final double squash;

  /// Its lean, clockwise, in radians.
  final double tilt;

  /// 0: the icon as it is; 1: the phone's screen fills the display.
  final double zoom;
  final bool cursor;

  /// The prompt's opacity.
  final double prompt;

  /// The whole intro's opacity over the app.
  final double opacity;

  /// A damped spring from 0 to 1: about 19% overshoot, then settles.
  static double _spring(double t) => (1 - math.exp(-5 * t) * math.cos(3 * math.pi * t)) / (1 + math.exp(-5));

  /// The pocket let go: from squashed through a stretch back to rest.
  static double _bounce(double t) => t >= 1 ? 0 : math.exp(-4 * t) * math.cos(2.5 * math.pi * t);

  @override
  bool operator ==(Object other) =>
      other is _Frame &&
      other.icon == icon &&
      other.lift == lift &&
      other.squash == squash &&
      other.tilt == tilt &&
      other.zoom == zoom &&
      other.cursor == cursor &&
      other.prompt == prompt &&
      other.opacity == opacity;

  @override
  int get hashCode => Object.hash(icon, lift, squash, tilt, zoom, cursor, prompt, opacity);
}

class _IntroPainter extends CustomPainter {
  const _IntroPainter(this.style, this.frame);
  final LogoStyle style;
  final _Frame frame;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = style.tileBottom);
    final side = math.min(size.shortestSide * .42, 360).toDouble();
    final display = size.center(Offset.zero);
    final tile = Rect.fromCenter(center: display, width: side, height: side);
    Offset p(double x, double y) => Offset(tile.left + x * side, tile.top + (1 - y) * side);

    // The camera: the phone's screen (upright, at rest) glides to the
    // display's centre while the scale grows (evenly, in log scale) to where
    // the screen covers the display, its frame and corners well outside.
    if (frame.zoom > 0) {
      final screen = logoPhone(side, style).outerRect.deflate(.009 * side).shift(p(.5, .64 + frame.lift));
      final cover = math.max(size.width / screen.width, size.height / screen.height) * 1.35;
      final scale = math.pow(cover, frame.zoom).toDouble();
      final shown = Offset.lerp(screen.center, display, frame.zoom)!;
      final focus = screen.center - (shown - display) / scale;
      canvas
        ..translate(display.dx, display.dy)
        ..scale(scale)
        ..translate(-focus.dx, -focus.dy);
    }

    // Fading in: smaller, growing to size.
    final fading = frame.icon < 1;
    if (fading) {
      final grow = .9 + .1 * frame.icon;
      canvas
        ..save()
        ..translate(display.dx, display.dy)
        ..scale(grow)
        ..translate(-display.dx, -display.dy)
        ..saveLayer(tile.inflate(side), Paint()..color = Color.fromRGBO(0, 0, 0, frame.icon));
    }
    final r = style.tileRadius * side;
    // The tile fades away as the phone takes over the display.
    final tileFade = 1 - (frame.zoom * 2).clamp(0.0, 1.0);
    if (tileFade > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(tile, Radius.circular(r)),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(style.tileBottom, style.tileTop, tileFade)!, style.tileBottom],
          ).createShader(tile),
      );
    }
    paintLogo(
      canvas,
      style,
      p: p,
      u: side,
      lift: frame.lift,
      tilt: frame.tilt,
      squash: frame.squash,
      cursor: frame.cursor,
      prompt: frame.prompt,
    );
    if (fading) {
      canvas
        ..restore()
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_IntroPainter oldDelegate) => oldDelegate.style != style || oldDelegate.frame != frame;
}
