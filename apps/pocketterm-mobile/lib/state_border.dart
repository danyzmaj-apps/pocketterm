import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/motion.dart';

/// Where a session stands, as its row's border shows it at a glance, like a terminal tab's colour.
enum TileState {
  /// Nothing to tell: no border.
  idle,

  /// The agent is working: a light runs round the border, chasing its own tail.
  working,

  /// It asks something, or waits on a plan or an approval.
  needsYou,

  /// Its last run broke off on an error.
  failed,

  /// Stopped with prompts still queued: nothing goes until Resume.
  paused,

  /// It finished a run the person hasn't opened since.
  done;

  /// The border's colour in the theme now; null for none.
  Color? get color => switch (this) {
    idle => null,
    working => C.accent,
    needsYou => C.warn,
    failed => C.error,
    paused => C.dim,
    done => C.ok,
  };
}

/// [child] inside a rounded border in [state]'s colour, cross-fading when the state changes. While working, a bright
/// arc runs round a faint full border, its tail fading behind it. With reduced motion the arc holds still as a
/// steady border.
class StateBorder extends StatefulWidget {
  const StateBorder({required this.state, required this.radius, required this.child, super.key});
  final TileState state;
  final double radius;
  final Widget child;

  /// False in widget tests (test/flutter_test_config.dart): a loop that never ends would keep pumpAndSettle from
  /// ever settling, as a spinner would. The snake then shows as its steady border.
  @visibleForTesting
  static bool runs = true;

  @override
  State<StateBorder> createState() => _StateBorderState();
}

class _StateBorderState extends State<StateBorder> with SingleTickerProviderStateMixin {
  // Only a working row ticks; the others repaint only when their state changes.
  late final Ticker _ticker = createTicker(_tick);
  final _lap = ValueNotifier<double>(0);

  /// One lap of the snake. It loops like a progress indicator does, for as long as the work goes on: the one motion
  /// in the list that isn't a change happening (Motion's rule), so it stays a thin line and holds still with reduced
  /// motion. In the theme's pace: a quarter quicker on a boxy theme.
  static const _lapTime = Duration(milliseconds: 1600);

  void _tick(Duration elapsed) {
    _lap.value = (elapsed.inMicroseconds / Motion.themed(_lapTime).inMicroseconds) % 1;
  }

  void _sync() {
    final run =
        StateBorder.runs &&
        widget.state == TileState.working &&
        !Motion.reduced(context) &&
        TickerMode.valuesOf(context).enabled;
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(StateBorder old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _lap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final reduced = Motion.reduced(context);
    return TweenAnimationBuilder<Color?>(
      // To no border, it fades out in its own colour.
      tween: ColorTween(end: state.color ?? Colors.transparent),
      duration: Motion.of(context),
      builder: (context, color, child) => CustomPaint(
        foregroundPainter: _BorderPainter(
          color: color ?? Colors.transparent,
          radius: widget.radius,
          width: C.t.shape == ThemeShape.boxy ? 2 : 1.5,
          lap: state == TileState.working && !reduced && StateBorder.runs ? _lap : null,
        ),
        child: child,
      ),
      child: widget.child,
    );
  }
}

class _BorderPainter extends CustomPainter {
  _BorderPainter({required this.color, required this.radius, required this.width, required this.lap})
    : super(repaint: lap);
  final Color color;
  final double radius;
  final double width;

  /// How far round the snake is, 0 to 1; null for a steady border.
  final ValueListenable<double>? lap;

  // The border's outline, measured once per size: the snake is a stretch of it.
  static Size? _for;
  static double? _forRadius;
  static late ui.PathMetric _metric;

  static final _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  /// How much of the lap the snake covers, and in how many steps its tail fades.
  static const _length = .35;
  static const _steps = 10;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    final rrect = RRect.fromRectAndRadius((Offset.zero & size).deflate(width / 2), Radius.circular(radius));
    _stroke.strokeWidth = width;
    final at = lap?.value;
    if (at == null) {
      canvas.drawRRect(rrect, _stroke..color = color);
      return;
    }
    if (_for != size || _forRadius != radius) {
      _for = size;
      _forRadius = radius;
      _metric = (Path()..addRRect(rrect)).computeMetrics().first;
    }
    final metric = _metric;
    final total = metric.length;
    // The track it runs on, faint, so the row reads as framed all round.
    canvas.drawRRect(rrect, _stroke..color = color.withValues(alpha: color.a * .22));
    // Tail to head in steps, each a little brighter; across the start of the outline it wraps.
    final head = at * total;
    final step = _length * total / _steps;
    for (var i = 0; i < _steps; i++) {
      final from = head - (_steps - i) * step;
      final alpha = color.a * (.15 + .85 * (i + 1) / _steps);
      _stroke.color = color.withValues(alpha: alpha);
      _segment(canvas, metric, total, from, from + step + .5);
    }
  }

  static void _segment(Canvas canvas, ui.PathMetric metric, double total, double from, double to) {
    var a = from % total;
    var b = to % total;
    if (a < 0) a += total;
    if (b < 0) b += total;
    if (a <= b) {
      canvas.drawPath(metric.extractPath(a, b), _stroke);
    } else {
      canvas
        ..drawPath(metric.extractPath(a, total), _stroke)
        ..drawPath(metric.extractPath(0, b), _stroke);
    }
  }

  @override
  bool shouldRepaint(_BorderPainter old) =>
      old.color != color || old.radius != radius || old.width != width || old.lap != lap;
}

/// What the person made of a row: their own [name] for it, and a [color] it's tinted with (ARGB), each null when
/// they haven't set one.
@immutable
class TileLook {
  const TileLook({this.name, this.color});
  factory TileLook.fromJson(Map<String, dynamic> j) => TileLook(
    name: j['name'] is String ? j['name'] as String : null,
    color: j['color'] is int ? j['color'] as int : null,
  );

  final String? name;
  final int? color;

  TileLook withName(String? name) =>
      TileLook(name: name == null || name.trim().isEmpty ? null : name.trim(), color: color);
  TileLook withColor(int? color) => TileLook(name: name, color: color);

  Map<String, dynamic> toJson() => {'name': ?name, 'color': ?color};

  @override
  bool operator ==(Object other) => other is TileLook && other.name == name && other.color == color;

  @override
  int get hashCode => Object.hash(name, color);
}

/// The colours a row can be tinted with: bright enough to read on Rosé Pine Dawn's paper and the dark themes alike.
const tileColors = [
  Color(0xFFE5484D),
  Color(0xFFF76B15),
  Color(0xFFFFC53D),
  Color(0xFF46A758),
  Color(0xFF12A594),
  Color(0xFF0090FF),
  Color(0xFF8E4EC6),
  Color(0xFFD6409F),
];

/// What [tileColors] are called, in the same order: what VoiceOver and TalkBack read for each swatch.
const tileColorNames = ['Red', 'Orange', 'Yellow', 'Green', 'Teal', 'Blue', 'Purple', 'Pink'];

/// A colour to pick for a row: round, square on a boxy theme; the picked one ringed.
class TileSwatch extends StatelessWidget {
  const TileSwatch({required this.color, required this.name, required this.picked, required this.onTap, super.key});
  final Color color;
  final String name;
  final bool picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final boxy = C.t.shape == ThemeShape.boxy;
    final shape = boxy ? BoxShape.rectangle : BoxShape.circle;
    return Semantics(
      button: true,
      selected: picked,
      label: name,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.of(context),
          curve: Motion.ease,
          width: 40,
          height: 40,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: shape,
            borderRadius: boxy ? C.round(C.t.shape.maxRadius) : null,
            border: Border.all(color: picked ? C.text : Colors.transparent, width: 2),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: color,
              shape: shape,
              borderRadius: boxy ? C.round(C.t.shape.maxRadius) : null,
            ),
          ),
        ),
      ),
    );
  }
}
