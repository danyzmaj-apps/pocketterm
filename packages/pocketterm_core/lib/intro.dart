import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:pocketterm_core/logo.dart';
import 'package:pocketterm_core/theme.dart';

/// The launch intro over [child], in the active theme: the app icon sits
/// large in the middle of the theme's background (what the native side
/// paints before Flutter's first frame), the phone ducks into the pocket and
/// springs up out of it, stands upright, its prompt gives way to [child] on
/// its screen, and the view zooms into that screen until [child] fills the
/// display. [child] is built and laid out at the display's size from the
/// start, only drawn smaller in the phone, and stays where it is in the tree
/// (its state lives on); it gets no taps until the intro ends. A tap skips
/// it (a quick zoom to [child]); with animations turned off
/// (MediaQuery.disableAnimations) it's a short fade.
class PocketTermIntro extends StatefulWidget {
  const PocketTermIntro({required this.child, this.play = true, this.theme, this.fromSplash = false, super.key});
  final Widget child;

  /// Plays the first time this is true (the desktop's window, hidden at
  /// launch, when it first shows); until then [child] shows as is. Once.
  final bool play;

  /// Played in this theme rather than the active one.
  final PtTheme? theme;

  /// The native launch screen already shows the icon where and as large as the intro's first frame does
  /// ([paintLaunchIcon]; the phone's): it starts there, without the icon's fade-in, and holds it while the launch
  /// screen fades away over it, so the hand-over can't be seen.
  final bool fromSplash;

  /// How long it takes when nobody taps.
  static const duration = Duration(milliseconds: 1750);

  /// The icon fading in, which [fromSplash] leaves out, and how long it holds the icon instead: as long as Flutter's
  /// iOS splash takes to fade out (SplashScreenManager's 0.2 s).
  static const _fadeIn = 150;
  static const _hold = 200;

  /// With animations turned off: the icon, then a fade.
  static const reducedDuration = Duration(milliseconds: 350);

  @override
  State<PocketTermIntro> createState() => _PocketTermIntroState();
}

class _PocketTermIntroState extends State<PocketTermIntro> with TickerProviderStateMixin {
  AnimationController? _run;
  late final _skip = AnimationController(vsync: this, duration: const Duration(milliseconds: 180))
    ..addListener(_tick)
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
            duration: _reduced
                ? PocketTermIntro.reducedDuration
                : PocketTermIntro.duration +
                      Duration(milliseconds: widget.fromSplash ? PocketTermIntro._hold - PocketTermIntro._fadeIn : 0),
          )
          ..addListener(_tick)
          ..addStatusListener(_ended)
          ..forward();
  }

  void _tick() => setState(() {});

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

  _Frame? get _frame {
    final run = _run;
    if (run == null || _done) return null;
    final raw = run.value * run.duration!.inMilliseconds;
    final ms = widget.fromSplash && !_reduced
        ? math.max(PocketTermIntro._fadeIn, raw - PocketTermIntro._hold + PocketTermIntro._fadeIn).toDouble()
        : raw;
    final skip = Curves.easeOut.transform(_skip.value);
    return _reduced ? _Frame.reduced(ms, skip) : _Frame.at(ms).skipped(skip);
  }

  // The same widgets throughout, the intro over or not: [child] is never
  // rebuilt or moved by it.
  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    return GestureDetector(
      excludeFromSemantics: true,
      onTap: frame == null ? null : _tap,
      child: _Stage(
        frame: frame,
        style: LogoStyle.of(widget.theme ?? appearance.theme),
        // Drawn once per change of its own, then only moved about.
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}

/// Where the intro is at one moment: the choreography, in milliseconds.
///
/// | ms        | what                                                              |
/// |-----------|-------------------------------------------------------------------|
/// | 0–150     | the icon (42% of the display's short side, at most 360) fades and |
/// |           | grows in; from the launch screen (fromSplash) it's already there  |
/// | 150–300   | the phone ducks into the pocket, which squashes                   |
/// | 300–820   | it springs up out of it, nearly whole (overshoots, settles); the  |
/// |           | pocket bounces back                                               |
/// | 480–900   | it stands upright                                                 |
/// | 820–      | the prompt's cursor blinks                                        |
/// | 880–1120  | the prompt fades into the app, on the phone's screen              |
/// | 900–1750  | the view zooms into the screen, which takes the display's shape,  |
/// |           | until the app on it fills the display                             |
@immutable
class _Frame {
  const _Frame({
    required this.icon,
    required this.lift,
    required this.squash,
    required this.tilt,
    required this.zoom,
    required this.cursor,
    required this.app,
    this.fade,
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
      zoom: Curves.easeInOutCubic.transform(span(900, 1750)),
      cursor: ms < 820 || ((ms - 820) ~/ 210).isEven,
      app: Curves.easeInOut.transform(span(880, 1120)),
    );
  }

  /// Animations turned off: the icon as it is over the app, then a fade.
  factory _Frame.reduced(double ms, double skip) => _Frame(
    icon: 1,
    lift: 0,
    squash: 0,
    tilt: logoTilt,
    zoom: 0,
    cursor: true,
    app: 0,
    fade: (1 - ((ms - 150) / 200).clamp(0.0, 1.0)) * (1 - skip),
  );

  /// Tapped, [skip] of the way (0 to 1) to the end: upright, the app on the
  /// screen and the view zoomed in.
  _Frame skipped(double skip) => skip == 0
      ? this
      : _Frame(
          icon: icon + (1 - icon) * skip,
          lift: lift,
          squash: squash * (1 - skip),
          tilt: tilt * (1 - skip),
          zoom: zoom + (1 - zoom) * skip,
          cursor: cursor,
          app: app + (1 - app) * skip,
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

  /// 0: the icon as it is; 1: the phone's screen is the display.
  final double zoom;
  final bool cursor;

  /// The app's opacity on the phone's screen, over the prompt.
  final double app;

  /// With animations turned off: the intro's opacity over the app, which is
  /// as it is underneath (null otherwise).
  final double? fade;

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
      other.app == app &&
      other.fade == fade;

  @override
  int get hashCode => Object.hash(icon, lift, squash, tilt, zoom, cursor, app, fade);
}

/// The intro at one [frame] on the display, with the app as [child]: laid
/// out at the display's size, drawn on the phone's screen; as is when
/// [frame] is null.
class _Stage extends SingleChildRenderObjectWidget {
  const _Stage({required this.frame, required this.style, required super.child});
  final _Frame? frame;
  final LogoStyle style;

  @override
  _RenderStage createRenderObject(BuildContext context) => _RenderStage(frame, style);

  @override
  void updateRenderObject(BuildContext context, _RenderStage renderObject) => renderObject
    ..frame = frame
    ..style = style;
}

class _RenderStage extends RenderProxyBox {
  _RenderStage(this._frame, this._style);

  _Frame? _frame;
  _Frame? get frame => _frame;
  set frame(_Frame? value) {
    if (value == _frame) return;
    if ((value == null) != (_frame == null)) {
      markNeedsCompositingBitsUpdate();
      // The app's semantics come (or go) with it, placed as it is then.
      markNeedsSemanticsUpdate();
    }
    _frame = value;
    markNeedsPaint();
  }

  LogoStyle _style;
  LogoStyle get style => _style;
  set style(LogoStyle value) {
    if (value == _style) return;
    _style = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _frame != null;

  /// Until the intro ends the app gets no taps; they're the intro's.
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (_frame == null) return super.hitTest(result, position: position);
    if (!size.contains(position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  /// Until the intro ends the app is out of the semantics tree too: drawn
  /// small and moving, nothing on it can be read or tapped where it shows.
  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_frame == null) super.visitChildrenForSemantics(visitor);
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    if (_frame case final frame? when frame.fade == null) transform.multiply(_Scene(size, _style, frame).app);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final frame = _frame;
    final child = this.child;
    if (frame == null || child == null) return super.paint(context, offset);
    final scene = _Scene(size, _style, frame);

    if (frame.fade case final fade?) {
      context.paintChild(child, offset);
      context.canvas
        ..saveLayer(offset & size, Paint()..color = Color.fromRGBO(0, 0, 0, fade))
        ..translate(offset.dx, offset.dy);
      scene.paint(context.canvas);
      context.canvas.restore();
      return;
    }

    context.canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    scene.paint(context.canvas);
    context.canvas.restore();
    if (frame.app <= 0) return;
    context.pushOpacity(
      offset,
      (frame.app * 255).round(),
      (context, offset) => context.pushTransform(
        needsCompositing,
        offset,
        scene.app,
        (context, offset) => context.pushClipRRect(
          needsCompositing,
          offset,
          Offset.zero & size,
          scene.clip,
          (context, offset) => context.paintChild(child, offset),
        ),
      ),
    );
  }
}

/// Where everything is at one frame on a display of [size].
///
/// The camera: the phone's screen glides to the display's centre while the
/// scale grows (evenly, in log scale) to where the screen is the display;
/// meanwhile the screen takes the display's shape (its sides' ratio goes
/// over evenly, in log scale, its area kept), its corners square off and
/// the frame's line thins away. The app is drawn on it as large as covers
/// it, clipped to it: at the end exactly the display.
class _Scene {
  factory _Scene(Size size, LogoStyle style, _Frame frame) {
    final side = math.min(size.shortestSide * .42, 360).toDouble();
    final display = size.center(Offset.zero);
    final tile = Rect.fromCenter(center: display, width: side, height: side);
    Offset p(double x, double y) => Offset(tile.left + x * side, tile.top + (1 - y) * side);

    // The screen, around the phone's pivot (y down): inside the frame's line.
    final rest = logoPhone(side, style).outerRect.deflate(logoFrameLine / 2 * side);
    final restAspect = rest.width / rest.height;
    final area = rest.width * rest.height;
    final aspect = restAspect * math.pow(size.aspectRatio / restAspect, frame.zoom);
    final screen = Rect.fromCenter(
      center: rest.center,
      width: math.sqrt(area * aspect),
      height: math.sqrt(area / aspect),
    );
    final corner = math.max(0, (style.phoneRadius - logoFrameLine / 2) * side) * (1 - frame.zoom);
    final frameLine = logoFrameLine * (1 - frame.zoom);
    final inset = frameLine / 2 * side;
    final body = RRect.fromRectAndRadius(screen.inflate(inset), Radius.circular(corner + inset));

    final pivot = p(.5, .64 + frame.lift);
    final phone = Matrix4.translationValues(pivot.dx, pivot.dy, 0)..rotateZ(frame.tilt);
    final center = MatrixUtils.transformPoint(phone, rest.center);
    final scale = math.pow(size.height / math.sqrt(area / size.aspectRatio), frame.zoom).toDouble();
    final shown = Offset.lerp(center, display, frame.zoom)!;
    final camera = Matrix4.translationValues(shown.dx, shown.dy, 0)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);

    final fit = math.max(screen.width / size.width, screen.height / size.height);
    return _Scene._(
      size: size,
      style: style,
      frame: frame,
      side: side,
      tile: tile,
      p: p,
      body: body,
      frameLine: frameLine,
      camera: camera,
      app: camera.multiplied(phone)
        ..translateByDouble(rest.center.dx, rest.center.dy, 0, 1)
        ..scaleByDouble(fit, fit, 1, 1)
        ..translateByDouble(-display.dx, -display.dy, 0, 1),
      clip: RRect.fromRectAndRadius(
        Rect.fromCenter(center: display, width: screen.width / fit, height: screen.height / fit),
        Radius.circular(corner / fit),
      ),
    );
  }

  _Scene._({
    required this.size,
    required this.style,
    required this.frame,
    required this.side,
    required this.tile,
    required this.p,
    required this.body,
    required this.frameLine,
    required this.camera,
    required this.app,
    required this.clip,
  });

  final Size size;
  final LogoStyle style;
  final _Frame frame;
  final double side;
  final Rect tile;
  final Offset Function(double x, double y) p;

  /// The phone's body around its pivot.
  final RRect body;

  /// The frame's line, in icon units.
  final double frameLine;
  final Matrix4 camera;

  /// From the app's coordinates to the display's.
  final Matrix4 app;

  /// The screen, in the app's coordinates.
  final RRect clip;

  /// The background, the icon and the phone, without the app.
  void paint(Canvas canvas) {
    canvas
      ..drawRect(Offset.zero & size, Paint()..color = style.tileBottom)
      ..save()
      ..transform(camera.storage);

    // Fading in: smaller, growing to size.
    final fading = frame.icon < 1;
    if (fading) {
      final grow = .9 + .1 * frame.icon;
      final display = tile.center;
      canvas
        ..save()
        ..translate(display.dx, display.dy)
        ..scale(grow)
        ..translate(-display.dx, -display.dy)
        ..saveLayer(tile.inflate(side), Paint()..color = Color.fromRGBO(0, 0, 0, frame.icon));
    }
    // The tile fades away as the phone takes over the display.
    final tileFade = 1 - (frame.zoom * 2).clamp(0.0, 1.0);
    if (tileFade > 0) _paintTile(canvas, style, tile, fade: tileFade);
    paintLogo(
      canvas,
      style,
      p: p,
      u: side,
      lift: frame.lift,
      tilt: frame.tilt,
      squash: frame.squash,
      cursor: frame.cursor,
      // The prompt gives way to the app (and stays off the screen as it
      // takes the display's shape).
      prompt: 1 - frame.app,
      phone: body,
      frameLine: frameLine,
    );
    if (fading) {
      canvas
        ..restore()
        ..restore();
    }
    canvas.restore();
  }
}

/// The icon's tile: [tile]'s rounded square, [LogoStyle.tileTop] at its top left (lerped to its bottom colour as
/// [fade] goes to 0) to [LogoStyle.tileBottom].
void _paintTile(Canvas canvas, LogoStyle style, Rect tile, {double fade = 1}) => canvas.drawRRect(
  RRect.fromRectAndRadius(tile, Radius.circular(style.tileRadius * tile.width)),
  Paint()
    ..shader = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color.lerp(style.tileBottom, style.tileTop, fade)!, style.tileBottom],
    ).createShader(tile),
);

/// The intro's first frame without its background: the icon's tile and mark, [side] across, at the canvas' origin.
/// What the iPhone's launch screen shows (apps/pocketterm-mobile's LaunchImage), so the intro takes over from it
/// pixel for pixel ([PocketTermIntro.fromSplash]).
void paintLaunchIcon(Canvas canvas, LogoStyle style, double side) {
  _paintTile(canvas, style, Offset.zero & Size.square(side));
  paintLogo(canvas, style, p: (x, y) => Offset(x * side, (1 - y) * side), u: side);
}
