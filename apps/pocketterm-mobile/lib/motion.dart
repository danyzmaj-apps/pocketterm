import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pocketterm_core/theme.dart';

/// The app's motion, one vocabulary everywhere: something appearing, moving or changing size eases out ([ease]) over
/// [fast]; something leaving eases in ([exit]); a section folding open or shut eases in and out ([fold]). Motion
/// explains a change, it never decorates: nothing overshoots, nothing lasts longer than [slow].
abstract final class Motion {
  /// A small part changing in place: a check appearing, an icon swapping.
  static const quick = Duration(milliseconds: 120);

  /// Something appearing, going or changing size.
  static const fast = Duration(milliseconds: 200);

  /// Something travelling across the screen: a row moving to another place, the whole app changing theme.
  static const slow = Duration(milliseconds: 280);

  static const Curve ease = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve fold = Curves.easeInOut;

  /// The person asked for less motion (iOS Reduce Motion, Android Remove animations): what moves or scales should
  /// only fade, or change at once.
  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [duration] as the person and the theme want it: none with reduced motion, a quarter shorter in a boxy theme
  /// (Gruvbox), whose retro look snaps rather than glides.
  static Duration of(BuildContext context, [Duration duration = fast]) =>
      reduced(context) ? Duration.zero : themed(duration);

  /// [duration] in the active theme's pace: a quarter shorter when it's boxy.
  static Duration themed(Duration duration) => appearance.theme.shape == ThemeShape.boxy ? duration * .75 : duration;

  /// [duration] for an [AnimatedSize]: as [of], but with reduced motion the shortest there is rather than none, which
  /// AnimatedSize can't take (it finishes inside its own layout and asks for another).
  static Duration resize(BuildContext context, [Duration duration = fast]) =>
      reduced(context) ? const Duration(microseconds: 1) : themed(duration);
}

/// The light taps that confirm something happened: never on scrolling, only on a meaningful moment.
abstract final class Haptics {
  /// A prompt went, an answer was sent: the action is done.
  static void done() => HapticFeedback.lightImpact();

  /// One of several was picked, or a dragged row was dropped in its new place.
  static void picked() => HapticFeedback.selectionClick();
}

/// [child] while [visible], else nothing; it grows in and fades in, and shrinks away and fades out, instead of
/// shoving what's around it in one frame. With reduced motion it comes and goes at once.
class Reveal extends StatelessWidget {
  const Reveal({required this.visible, required this.child, this.curve = Motion.ease, super.key});
  final bool visible;
  final Widget child;
  final Curve curve;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.of(context),
    switchInCurve: curve,
    switchOutCurve: curve,
    // Each one grows or shrinks from its top edge as it fades, so what's below slides along with it.
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SizeTransition(sizeFactor: animation, alignment: Alignment.topCenter, child: child),
    ),
    layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
    // Keyed: the switcher tells the one going from the one coming by key, and unkeyed it drops the one going at once.
    child: visible
        ? KeyedSubtree(key: ValueKey((true, child.key)), child: child)
        : const SizedBox(key: ValueKey(false), width: double.infinity),
  );
}

/// One of several things in the same place, swapped by a cross-fade where the one coming also grows from a little
/// smaller ([scale]) and turns in by [turns], and the one going shrinks and turns away: an icon becoming another, a
/// row of buttons becoming another. Tell them apart by [child]'s key. [resize]: the two differ in size, and the room
/// they take changes with the cross-fade (the one going overlaid at [alignment]'s edge, clipped as the room changes)
/// rather than after it. With reduced motion it only cross-fades.
class FadeSwap extends StatelessWidget {
  const FadeSwap({
    required this.child,
    this.duration = Motion.fast,
    this.scale = .9,
    this.turns = 0,
    this.alignment = Alignment.center,
    this.resize = false,
    super.key,
  });
  final Widget child;
  final Duration duration;

  /// Where the one coming starts, as a fraction of its size; 1 doesn't scale.
  final double scale;

  /// How far the one coming turns in (a fraction of a full turn, from that much back); 0 doesn't turn.
  final double turns;

  /// Where the two are laid over each other.
  final Alignment alignment;

  final bool resize;

  @override
  Widget build(BuildContext context) {
    final reduced = Motion.reduced(context);
    final switcher = AnimatedSwitcher(
      duration: reduced ? Motion.quick : Motion.of(context, duration),
      switchInCurve: Motion.ease,
      switchOutCurve: Motion.exit,
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        clipBehavior: resize ? Clip.none : Clip.hardEdge,
        children: [
          for (final p in previous)
            // Sized by the one coming only: the one going doesn't hold the room open.
            if (resize)
              Positioned(
                left: 0,
                right: 0,
                top: alignment.y > 0 ? null : 0,
                bottom: alignment.y > 0 ? 0 : null,
                child: p,
              )
            else
              p,
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) {
        var shown = child;
        if (!reduced && turns != 0) {
          shown = RotationTransition(
            turns: Tween<double>(begin: -turns, end: 0).animate(animation),
            child: shown,
          );
        }
        if (!reduced && scale != 1) {
          shown = ScaleTransition(
            scale: Tween<double>(begin: scale, end: 1).animate(animation),
            child: shown,
          );
        }
        return FadeTransition(opacity: animation, child: shown);
      },
      child: child,
    );
    if (!resize) return switcher;
    return AnimatedSize(
      duration: Motion.resize(context, duration),
      curve: Motion.fold,
      alignment: alignment,
      child: switcher,
    );
  }
}

/// [child], coming in once as it first shows when [animate]: it fades in and rises the last [rise] pixels into its
/// place. Built again (an answer streaming in, a scroll bringing it back), it stays put. With reduced motion it only
/// fades.
class Entrance extends StatefulWidget {
  const Entrance({required this.child, this.animate = true, this.rise = 12, this.duration = Motion.fast, super.key});
  final Widget child;
  final bool animate;
  final double rise;
  final Duration duration;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, value: widget.animate ? 0 : 1);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: Motion.ease);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.value == 0 && !_c.isAnimating) {
      _c.duration = Motion.reduced(context) ? Motion.quick : Motion.themed(widget.duration);
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rise = Motion.reduced(context) ? 0.0 : widget.rise;
    return FadeTransition(
      opacity: _t,
      child: AnimatedBuilder(
        animation: _t,
        builder: (_, child) => Transform.translate(offset: Offset(0, rise * (1 - _t.value)), child: child),
        child: widget.child,
      ),
    );
  }
}

/// [child] in a scrolling list, gliding from where it was to where it is now when the list's order changes (a row
/// moved to the top, a gap closing after a delete, room opening for one coming back) instead of jumping there. Its
/// place is read in the list's own terms, so scrolling never moves it, and when it paints after a build (before the
/// frame shows), so it never flashes at its new place first. [glide] false only notes the new place (a row the
/// person just dropped there by hand). With reduced motion it jumps.
class Glide extends SingleChildRenderObjectWidget {
  const Glide({required Widget super.child, this.glide = true, super.key});
  final bool glide;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderGlide(glide: glide, duration: Motion.of(context, Motion.slow));

  @override
  void updateRenderObject(BuildContext context, RenderGlide renderObject) => renderObject
    ..glide = glide
    ..duration = Motion.of(context, Motion.slow)
    // Built again: the list may have changed, so it looks where it is now. (A list wraps each row in a repaint
    // boundary, which moves without painting its row again.)
    ..markNeedsPaint();
}

/// What a [Glide] lays out: its child, painted (and hit) where it's gliding from until it gets to its place.
class RenderGlide extends RenderProxyBox {
  RenderGlide({required this.glide, required this.duration});
  bool glide;
  Duration duration;

  /// Its place along the list when it last painted.
  double? _at;

  /// How far it was from its new place when it started gliding there, and when that was.
  double _from = 0;
  Duration? _start;

  /// How far it's painted from its place now.
  double _shift = 0;

  double _shiftAt(Duration now) {
    final start = _start;
    if (start == null || duration == Duration.zero) return 0;
    final t = (now - start).inMicroseconds / duration.inMicroseconds;
    if (t >= 1) {
      _start = null;
      return 0;
    }
    return _from * (1 - Motion.ease.transform(t));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    final viewport = RenderAbstractViewport.maybeOf(this);
    if (viewport != null && hasSize) {
      final at = viewport.getOffsetToReveal(this, 0).offset;
      final was = _at;
      _at = at;
      if (was != null && (at - was).abs() >= .5) {
        if (glide && duration > Duration.zero) {
          // From where it shows now (mid-glide too) to its new place.
          _from = was + _shiftAt(now) - at;
          _start = now;
        } else {
          _start = null;
        }
      }
    }
    _shift = _shiftAt(now);
    if (_shift != 0) {
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        if (attached) markNeedsPaint();
      });
    }
    super.paint(context, offset + Offset(0, _shift));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
    offset: Offset(0, _shift),
    position: position,
    hitTest: (result, position) => super.hitTestChildren(result, position: position),
  );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(Matrix4.translationValues(0, _shift, 0));
  }
}

/// Above the app: a change of theme cross-fades the whole screen from the old colors to the new instead of cutting.
/// Every part reads the theme from [C] and is built again at once, so the old look is kept as a picture of the
/// screen, laid over the new one and faded out. With reduced motion the theme changes at once.
class ThemeCrossfade extends StatefulWidget {
  const ThemeCrossfade({required this.child, super.key});
  final Widget child;

  @override
  State<ThemeCrossfade> createState() => _ThemeCrossfadeState();
}

class _ThemeCrossfadeState extends State<ThemeCrossfade> with SingleTickerProviderStateMixin {
  final GlobalKey _screen = GlobalKey();
  late final AnimationController _fade = AnimationController(vsync: this, duration: Motion.slow)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _drop();
    });
  ui.Image? _old;

  /// The theme showing, to tell a change of it from another notification.
  PtTheme _theme = appearance.theme;

  @override
  void initState() {
    super.initState();
    appearance.addListener(_changed);
  }

  @override
  void dispose() {
    appearance.removeListener(_changed);
    _fade.dispose();
    _old?.dispose();
    super.dispose();
  }

  void _drop() {
    if (_old == null) return;
    setState(() {
      _old?.dispose();
      _old = null;
    });
  }

  void _changed() {
    if (appearance.theme == _theme) return;
    _theme = appearance.theme;
    // Not before the first frame, and not when asked for less motion.
    final box = _screen.currentContext?.findRenderObject();
    // A boundary waiting to paint has nothing to show yet (a debug build asserts so; a release one shows its last
    // picture, which is the old theme anyway).
    if (box is! RenderRepaintBoundary || !box.hasSize || (kDebugMode && box.debugNeedsPaint)) return;
    if (WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations) return;
    // The screen as it still shows: the new theme's frame comes next.
    final picture = box.toImageSync(pixelRatio: View.of(context).devicePixelRatio);
    setState(() {
      _old?.dispose();
      _old = picture;
    });
    _fade
      ..duration = Motion.themed(Motion.slow)
      ..forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => Stack(
    textDirection: TextDirection.ltr,
    fit: StackFit.passthrough,
    children: [
      RepaintBoundary(key: _screen, child: widget.child),
      if (_old case final old?)
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: ReverseAnimation(CurvedAnimation(parent: _fade, curve: Motion.fold)),
              child: RawImage(image: old, fit: BoxFit.fill),
            ),
          ),
        ),
    ],
  );
}
