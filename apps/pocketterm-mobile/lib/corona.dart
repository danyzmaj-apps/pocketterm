import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:pocketterm_core/ui.dart';
import 'package:pocketterm_mobile/motion.dart';

/// How loud the voice is, as a star of a few thousand specks in the theme's colours: a breathing shell that the voice
/// lifts into spikes, streams flaring off their tips, and a faint ring of dust. The recognizer only says how loud, so
/// the shell shows the last second of it: what's said now rises at the equator and travels to the poles. Red while a
/// held press is slid away to cancel; dim and slow while it isn't listening yet or is stopping. With reduced motion it
/// holds still and only swells.
///
/// Built for the phone's frame budget: the specks are simulated in preallocated buffers (nothing is allocated per
/// frame), drawn with one [Canvas.drawRawAtlas] call together with the glow behind them, and repainted without a
/// rebuild.
class Corona extends StatefulWidget {
  const Corona({required this.level, required this.away, required this.busy, required this.link, super.key});
  final ValueListenable<double> level;
  final bool away;
  final bool busy;
  final CoronaLink link;

  @override
  State<Corona> createState() => _CoronaState();
}

/// The star's state, kept by the voice sheet: a cross-fade builds the widget anew, and it carries on from here rather
/// than starting over. It never just appears: after [reset] it waits, hidden, for [assemble] to say where its specks
/// gather from. Once [gone], it bursts outward and fades while the sheet's motes fly off.
class CoronaLink {
  final _cloud = _Cloud();

  /// How loud, eased: 0 to 1.
  double level = 0;

  /// Rises on the start of a word, then decays: a kick on top of [level].
  double beat = 0;
  double _slow = 0;

  /// Its clocks: [t] runs faster as the voice is louder, what everything flows with; [clock] is plain seconds.
  double t = 0;
  double clock = 0;

  /// Eased toward 1 while busy or away, so it dims or reddens rather than switching.
  double busy = 0;
  double away = 0;

  /// 1 while it shows, falling to 0 once [gone].
  double shown = 1;
  bool gone = false;

  /// How far it has gathered: 0 as its specks set off, 1 once every one is in place.
  double formed = 1;

  /// Reset and not yet told where to gather from: nothing is drawn.
  bool waiting = false;

  /// Where its specks gather from (in the widget's box), or null to gather out of the dark around it.
  List<Offset>? _from;

  /// The specks' starts, worked out on the first frame of a gathering, from where each then belongs.
  bool _startsPending = false;

  /// How long a gathering takes, the specks' stagger included.
  static const gathering = Duration(milliseconds: 1100);

  /// [level] over the last second, newest at [_head]: what the shell shows from the equator (now) to the poles.
  final _history = Float32List(_historyLength);
  int _head = 0;
  double _sinceSample = 0;
  static const _historyLength = 64;
  static const double _historyStep = 1 / 60;

  /// Whole again but hidden, to listen once [assemble] says where it gathers from.
  void reset() {
    gone = false;
    shown = 1;
    waiting = true;
  }

  /// Gathers it: its specks fly in from [from] (points in the widget's box: the buttons it broke into, so Keep
  /// talking puts it back together from them), or with none, spiral in out of the dark around it.
  void assemble(List<Offset>? from) {
    _from = from == null || from.isEmpty ? null : from;
    waiting = false;
    formed = 0;
    _startsPending = true;
  }

  /// Moves it on by [dt] seconds, hearing [heard] (0 to 1, as the recognizer says). [still]: reduced motion, so it
  /// only swells.
  void step(double dt, {required double heard, required bool busy, required bool away, required bool still}) {
    if (gone) {
      shown = math.max(0, shown - dt / .3);
      return;
    }
    if (!waiting && formed < 1) {
      formed = still ? 1 : math.min(1, formed + dt * 1e6 / Motion.themed(gathering).inMicroseconds);
    }
    double ease(double from, double to, double rate) => from + (to - from) * (1 - math.exp(-rate * dt));
    // A curve that lifts quiet speech, so normal talking stirs it well, not just shouting. It rises quickly and
    // settles more slowly, so words read as pulses rather than flicker, at any frame rate.
    final target = busy ? 0.0 : math.min(1, math.pow(heard, .5) * 1.2).toDouble();
    level = ease(level, target, target > level ? 24 : 7);
    _slow = ease(_slow, level, 1.8);
    final onset = level - _slow;
    if (onset > .08) beat = math.max(beat, math.min(1, (onset - .08) * 4));
    beat *= math.exp(-5 * dt);
    this.busy = ease(this.busy, busy ? 1 : 0, 10);
    this.away = ease(this.away, away ? 1 : 0, 14);
    _sinceSample += dt;
    while (_sinceSample >= _historyStep) {
      _sinceSample -= _historyStep;
      _head = (_head + 1) % _historyLength;
      _history[_head] = level;
    }
    clock += dt;
    if (still) return;
    t += dt * (1 - .65 * this.busy) * (.35 + 2.4 * level + 1.5 * beat);
  }

  /// How loud it was [age] (0 to 1 of the history) ago.
  double _ago(double age) => _history[(_head - (age * (_historyLength - 1)).round() + _historyLength) % _historyLength];

  /// [count] specks as last drawn (in the widget's box), with their colours: the brightest of the shell's near side
  /// and of the streams, for the motes the sheet flies into its buttons.
  List<(Offset, Color)> sample(int count) => _cloud.sample(count, math.Random(5));
}

class _CoronaState extends State<Corona> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _frame = _Frame();
  Duration _last = Duration.zero;
  bool _reduced = false;

  void _tick(Duration now) {
    final dt = math.min((now - _last).inMicroseconds / 1e6, .05);
    _last = now;
    widget.link.step(dt, heard: widget.level.value, busy: widget.busy, away: widget.away, still: _reduced);
    _frame.tick();
  }

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = Motion.reduced(context);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.link;
    final t = C.t;
    // No grow-in: the star gathers itself as it comes (see [CoronaLink.assemble]).
    return Semantics(
      label: 'Listening',
      child: LayoutBuilder(
        builder: (context, box) {
          final d = math.min(box.maxWidth * .68, 260).toDouble();
          return SizedBox(
            key: const ValueKey('voice-level'),
            width: d * 1.3,
            height: d * 1.3,
            child: RepaintBoundary(
              child: CustomPaint(painter: _CoronaPainter(link, _atlasFor(t.shape), t, repaint: _frame)),
            ),
          );
        },
      ),
    );
  }
}

class _Frame extends ChangeNotifier {
  void tick() => notifyListeners();
}

/// The sprites, side by side in one 96×32 image: a speck in the theme's shape (a soft glow, a crisp dot or a square
/// pixel), the round glow behind the star, and a flare's streak, bright at its outer end. Made once per shape.
final _atlases = <ThemeShape, ui.Image>{};

ui.Image _atlasFor(ThemeShape shape) => _atlases[shape] ??= _makeAtlas(shape);

ui.Image _makeAtlas(ThemeShape shape) {
  const s = _Cloud.sprite;
  const c = Offset(s / 2, s / 2);
  const white = Color(0xFFFFFFFF);
  Color a(double alpha) => white.withValues(alpha: alpha);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  switch (shape) {
    case ThemeShape.soft:
      canvas.drawCircle(
        c,
        s / 2,
        Paint()..shader = ui.Gradient.radial(c, s / 2, [white, a(.5), a(.12), a(0)], [0, .18, .45, 1]),
      );
    case ThemeShape.crisp:
      canvas
        ..drawCircle(c, s / 2, Paint()..shader = ui.Gradient.radial(c, s / 2, [a(.18), a(0)]))
        ..drawCircle(c, s * .17, Paint()..color = white);
    case ThemeShape.boxy:
      canvas
        ..drawRect(Rect.fromCenter(center: c, width: s * .7, height: s * .7), Paint()..color = a(.12))
        ..drawRect(Rect.fromCenter(center: c, width: s * .38, height: s * .38), Paint()..color = white);
  }
  const g = Offset(s * 1.5, s / 2);
  canvas.drawCircle(
    g,
    s / 2,
    Paint()..shader = ui.Gradient.radial(g, s / 2, [white, a(.55), a(.18), a(0)], [0, .25, .5, 1]),
  );
  // Drawn along +x: the painter turns it to point away from the centre.
  const tail = Offset(s * 2 + 3, s / 2);
  const head = Offset(s * 3 - 5, s / 2);
  final streak = Paint()
    ..shader = ui.Gradient.linear(tail, head, [a(0), white])
    ..strokeWidth = switch (shape) {
      ThemeShape.soft => 4,
      ThemeShape.crisp => 2,
      ThemeShape.boxy => 3,
    }
    ..strokeCap = shape == ThemeShape.boxy ? StrokeCap.butt : StrokeCap.round;
  if (shape == ThemeShape.soft) streak.maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2);
  canvas.drawLine(tail, head, streak);
  return recorder.endRecording().toImageSync(s.toInt() * 3, s.toInt());
}

class _CoronaPainter extends CustomPainter {
  _CoronaPainter(this.link, this.atlas, this.theme, {required super.repaint});
  final CoronaLink link;
  final ui.Image atlas;
  final PtTheme theme;

  // Additive on a dark theme, so overlapping specks burn bright; plain ink on a light one, where adding only whitens.
  static final _glowing = Paint()
    ..blendMode = BlendMode.plus
    ..filterQuality = FilterQuality.low;
  static final _ink = Paint()..filterQuality = FilterQuality.low;

  @override
  void paint(Canvas canvas, Size size) {
    if (link.waiting) return;
    final cloud = link._cloud..place(size, link, theme);
    canvas.drawRawAtlas(
      atlas,
      cloud.transforms,
      cloud.rects,
      cloud.colors,
      BlendMode.modulate,
      // Where the sprites actually are: flares and gathering specks reach well past the box, and the engine would
      // otherwise measure every sprite itself.
      cloud.bounds,
      theme.dark ? _glowing : _ink,
    );
  }

  @override
  bool shouldRepaint(_CoronaPainter old) => old.atlas != atlas || old.theme != theme || old.link != link;
}

/// A sine table: the per-speck loop runs ~10 of these for each of thousands of specks every frame.
const _lutSize = 4096;
const int _lutMask = _lutSize - 1;
const double _toLut = _lutSize / (2 * math.pi);
final Float32List _lut = () {
  final table = Float32List(_lutSize);
  for (var i = 0; i < _lutSize; i++) {
    table[i] = math.sin(i * 2 * math.pi / _lutSize);
  }
  return table;
}();

double _sin(double x) => _lut[(x * _toLut).toInt() & _lutMask];
double _cos(double x) => _lut[((x * _toLut).toInt() + (_lutSize >> 2)) & _lutMask];

/// Every speck: where it sits (fixed, made once) and where and how it was last drawn, in buffers kept from frame to
/// frame. Entry 0 of the drawn buffers is the glow behind; the specks follow.
class _Cloud {
  _Cloud() {
    final rnd = math.Random(11);
    for (var i = 0; i < count; i++) {
      double x;
      double y;
      double z;
      if (i < shell) {
        // Evenly over the sphere (a Fibonacci spiral), so the shell reads as a surface, not clumps.
        y = 1 - 2 * (i + .5) / shell;
        final r = math.sqrt(1 - y * y);
        final a = 2.39996323 * i;
        x = r * math.cos(a);
        z = r * math.sin(a);
      } else {
        y = rnd.nextDouble() * 2 - 1;
        final r = math.sqrt(1 - y * y);
        final a = rnd.nextDouble() * 2 * math.pi;
        x = r * math.cos(a);
        z = r * math.sin(a);
      }
      _x[i] = x;
      _y[i] = y;
      _z[i] = z;
      // Projections onto a few fixed directions, frequency folded in: the noise and spike waves then cost one sine
      // each per frame.
      _n1[i] = 3.3 * (.8 * x + .6 * y);
      _n2[i] = 4.6 * (-.5 * y + .86 * z);
      _n3[i] = 6.3 * (.6 * x - .64 * y + .48 * z);
      _s1[i] = 6 * (.36 * x + .48 * y - .8 * z);
      _s2[i] = 6 * (.7 * x + .1 * y + .7 * z);
      _lat[i] = (y.abs() * (bands - 1)).round();
      _h1[i] = rnd.nextDouble();
      _h2[i] = rnd.nextDouble();
      _h3[i] = rnd.nextDouble();
    }
    for (var e = 0; e <= count; e++) {
      // Entry 0 the glow, then the shell's specks, the streams' streaks and the dust's specks.
      final cell = e == 0 ? 1 : (e > shell && e <= shell + streams ? 2 : 0);
      rects
        ..[e * 4] = cell * sprite
        ..[e * 4 + 1] = 0
        ..[e * 4 + 2] = (cell + 1) * sprite
        ..[e * 4 + 3] = sprite;
    }
  }

  static const shell = 3200;
  static const streams = 1300;
  static const dust = 400;
  static const int count = shell + streams + dust;

  /// Latitude bands the shell is split into, each showing the voice a little longer ago toward the poles.
  static const bands = 16;

  /// The sprites' side in the atlas.
  static const sprite = 32.0;

  /// Perspective: how far the eye is, in shell radii.
  static const _eye = 6.2;

  final _x = Float32List(count);
  final _y = Float32List(count);
  final _z = Float32List(count);
  final _n1 = Float32List(count);
  final _n2 = Float32List(count);
  final _n3 = Float32List(count);
  final _s1 = Float32List(count);
  final _s2 = Float32List(count);
  final _lat = Uint8List(count);
  final _h1 = Float32List(count);
  final _h2 = Float32List(count);
  final _h3 = Float32List(count);
  final _band = Float32List(bands);

  /// The drawn glow and specks: their transforms, atlas rects and colours, and where and how bright each speck was.
  final transforms = Float32List((count + 1) * 4);
  final rects = Float32List((count + 1) * 4);
  final colors = Int32List(count + 1);
  final _px = Float32List(count);
  final _py = Float32List(count);
  final _pa = Float32List(count);

  /// Where each speck sets off from while the star gathers.
  final _gx = Float32List(count);
  final _gy = Float32List(count);

  /// Where the sprites were last drawn, for the engine's cull.
  Rect bounds = Rect.zero;

  /// The most a speck waits before it sets off, as a fraction of the gathering: the stagger.
  static const _lag = .4;

  /// The palette now, as linear floats: cool, mid, hot, ember, dust.
  final _ink = Float32List(15);

  void _setInk(int at, Color c, PtTheme theme, double busy, double away) {
    var r = c.r;
    var g = c.g;
    var b = c.b;
    double mix(double v, double to, double k) => v + (to - v) * k;
    final e = theme.error;
    final k = .85 * away;
    r = mix(r, e.r, k);
    g = mix(g, e.g, k);
    b = mix(b, e.b, k);
    final dim = theme.dark ? theme.dim2 : theme.dim;
    final q = .65 * busy;
    _ink
      ..[at] = mix(r, dim.r, q)
      ..[at + 1] = mix(g, dim.g, q)
      ..[at + 2] = mix(b, dim.b, q);
  }

  int _argb(double a, double r, double g, double b) {
    int byte(double v) => v <= 0 ? 0 : (v >= 1 ? 255 : (v * 255).toInt());
    return byte(a) << 24 | byte(r) << 16 | byte(g) << 8 | byte(b);
  }

  /// Works out where and how every speck is drawn in a box of [size], as [link] is now, in [theme]'s colours.
  void place(Size size, CoronaLink link, PtTheme theme) {
    final dark = theme.dark;
    _setInk(0, Color.lerp(theme.accent, theme.text, dark ? .45 : .3)!, theme, link.busy, link.away);
    _setInk(3, theme.accent, theme, link.busy, link.away);
    _setInk(6, theme.warn, theme, link.busy, link.away);
    _setInk(9, Color.lerp(theme.warn, theme.error, .6)!, theme, link.busy, link.away);
    _setInk(12, Color.lerp(theme.accent, theme.dim, dark ? .3 : .4)!, theme, link.busy, link.away);
    final ink = _ink;

    final level = link.level;
    final beat = link.beat;
    final t = link.t;
    final shown = link.shown;
    // On Stop it bursts outward as it fades.
    final burst = (1 - shown) * .7;
    for (var k = 0; k < bands; k++) {
      _band[k] = link._ago(k / (bands - 1) * .85);
    }

    final cx = size.width / 2;
    // Below the box's middle: nothing sits under it now, and its flares get the room above.
    final cy = size.height * .62;
    final radius = size.shortestSide * .25 * (1 + .08 * level + .06 * beat);
    // A slow tumble: turning about the vertical, its axis tipped toward the viewer and rocking.
    final spin = t * .04 + link.clock * .06;
    final tilt = .42 + .08 * _sin(link.clock * .13);
    final cs = _cos(spin);
    final ss = _sin(spin);
    final ct = _cos(tilt);
    final st = _sin(tilt);
    final twistBy = .5 + 1.5 * level;

    final shellAlpha = (dark ? .55 : .6) * shown;
    final streamAlpha = (dark ? 1.0 : .95) * shown;
    final dustAlpha = (dark ? .28 : .3) * (.4 + .6 * level) * shown;
    final (shellSize, streamSize, dustSize) = switch (theme.shape) {
      ThemeShape.soft => (6.0, 12.0, 4.5),
      ThemeShape.crisp => (4.6, 10.0, 3.6),
      ThemeShape.boxy => (5.0, 10.0, 4.0),
    };
    const half = sprite / 2;

    // The glow behind, in the accent, swelling with the voice.
    final glowSide = radius * 3.6 * (1 + .12 * level);
    final glowScale = glowSide / sprite;
    transforms
      ..[0] = glowScale
      ..[1] = 0
      ..[2] = cx - glowScale * half
      ..[3] = cy - glowScale * half;
    colors[0] = _argb(
      (dark ? .16 + .3 * level + .2 * beat : .05 + .08 * level) * (.3 + .7 * shown) * link.formed,
      ink[3],
      ink[4],
      ink[5],
    );
    var minX = cx - glowSide / 2;
    var maxX = cx + glowSide / 2;
    var minY = cy - glowSide / 2;
    var maxY = cy + glowSide / 2;

    final formed = link.formed;
    final gathering = formed < 1;
    final setStarts = link._startsPending;
    final from = link._from;

    for (var i = 0; i < count; i++) {
      final ux = _x[i];
      final uy = _y[i];
      final uz = _z[i];
      final h1 = _h1[i];
      final h2 = _h2[i];
      double px;
      double py;
      double pz;
      double r;
      double cr;
      double cg;
      double cb;
      double alpha;
      double side;
      if (i < shell + streams) {
        final n = .5 + .22 * _sin(_n1[i] + t * .9) + .16 * _sin(_n2[i] - t * 1.3) + .12 * _sin(_n3[i] + t * .7);
        // A sparse field of peaks the voice raises into spikes: sharp, so only a few towers stand at a time.
        final q = .5 + .5 * _sin(_s1[i] + t * .8) * _sin(_s2[i] - t * .6);
        final q2 = q * q;
        final spike = q2 * q2 * q2 * 1.8;
        final bv = _band[_lat[i]];
        final tower = bv * spike;
        final lift = (n - .5) * .35 + tower * (.12 + .55 * level) + beat * .08 + burst;
        if (i < shell) {
          r = 1 + lift + (_h3[i] - .5) * .015;
          px = ux * r;
          py = uy * r;
          pz = uz * r;
          final hot = math.min(1, tower * 1.4);
          cr = ink[0] + (ink[3] - ink[0]) * n + ink[6] * hot;
          cg = ink[1] + (ink[4] - ink[1]) * n + ink[7] * hot;
          cb = ink[2] + (ink[5] - ink[2]) * n + ink[8] * hot;
          alpha = shellAlpha * (.7 + .6 * h2);
          side = shellSize * (.7 + .6 * h2);
        } else {
          // Each stream speck leaves the surface, rides out along its direction with a little wind, and fades.
          var life = h1 + t * (.08 + .08 * h2);
          life -= life.floorToDouble();
          // Streams leave the towers: elsewhere they barely show.
          final reach = (.15 + .9 * level) * (.2 + tower * 1.2);
          r = 1 + lift + reach * life * 1.2;
          final wind = life * life * (.08 + .25 * level);
          px = ux * r + _sin(_n2[i] + t * .5 + h1 * 6) * wind;
          py = uy * r + _sin(_n3[i] + t * .4) * wind;
          pz = uz * r + _sin(_n1[i] - t * .45) * wind;
          cr = ink[6] + (ink[9] - ink[6]) * life;
          cg = ink[7] + (ink[10] - ink[7]) * life;
          cb = ink[8] + (ink[11] - ink[8]) * life;
          final fadeIn = life < .05 ? life / .05 : 1.0;
          alpha = streamAlpha * (1 - life) * fadeIn * math.min(1, tower * tower * 3 + .04 * level);
          side = streamSize * (.7 + .6 * h2);
        }
      } else {
        // A thin ring of dust around the equator, slowest further out.
        final ringR = 1.45 + .6 * h2 * math.sqrt(h2);
        final a = h1 * 2 * math.pi + t * .3 / ringR + link.clock * .02;
        r = ringR + burst;
        px = _cos(a) * r;
        pz = _sin(a) * r;
        py = _sin(_n1[i] + link.clock * .6) * .05 * ringR * (1 + 2 * level);
        cr = ink[12];
        cg = ink[13];
        cb = ink[14];
        alpha = dustAlpha * (.5 + .5 * h2);
        side = dustSize * (.6 + .5 * _h3[i]);
      }
      // The bass-like twist: further out turns further, more as it's louder.
      final tw = (r - 1) * twistBy;
      final ctw = _cos(tw);
      final stw = _sin(tw);
      final x1 = px * ctw - pz * stw;
      final z1 = px * stw + pz * ctw;
      final x2 = x1 * cs - z1 * ss;
      final z2 = x1 * ss + z1 * cs;
      final y3 = py * ct - z2 * st;
      final z3 = py * st + z2 * ct;
      final s = radius * _eye / (_eye - z3);
      var sx = cx + x2 * s;
      var sy = cy - y3 * s;
      // The far side dims, so the star has depth.
      final near = .45 + .55 * ((z3 / (r < .5 ? .5 : r)) * .5 + .5);
      var a = alpha * near;
      if (gathering) {
        if (setStarts) {
          if (from != null) {
            // Many specks leave each point of the buttons, a little apart.
            final p = from[i % from.length];
            _gx[i] = p.dx + (h1 - .5) * 4;
            _gy[i] = p.dy + (h2 - .5) * 4;
          } else {
            // Out of the dark: from a wide ring around where it belongs, turned so they spiral in.
            final k = 2.4 + 2.2 * h1;
            final turn = (h2 - .5) * 2.4;
            final ox = (sx - cx) * k;
            final oy = (sy - cy) * k;
            _gx[i] = cx + ox * _cos(turn) - oy * _sin(turn);
            _gy[i] = cy + ox * _sin(turn) + oy * _cos(turn);
          }
        }
        // Each sets off after its delay, along a curve bent to one side, and lands softly.
        var e = (formed - _h3[i] * _lag) / (1 - _lag);
        e = e <= 0 ? 0 : (e >= 1 ? 1 : e * e * (3 - 2 * e));
        final u = 1 - e;
        final gx = _gx[i];
        final gy = _gy[i];
        final bend = (h1 - .5) * .7;
        final mx = (gx + sx) / 2 - (sy - gy) * bend;
        final my = (gy + sy) / 2 + (sx - gx) * bend;
        sx = u * u * gx + 2 * u * e * mx + e * e * sx;
        sy = u * u * gy + 2 * u * e * my + e * e * sy;
        // From the buttons they're already there to see; out of the dark they fade in as they come.
        a *= from != null ? .5 + .5 * e : e;
      }
      final scale = side * s / radius / sprite;
      final o = (i + 1) * 4;
      if (i >= shell && i < shell + streams) {
        // A streak points away from the centre: rotate the sprite by the speck's direction on screen.
        final dx = sx - cx;
        final dy = sy - cy;
        final inv = scale / (math.sqrt(dx * dx + dy * dy) + 1e-3);
        final sc = dx * inv;
        final sn = dy * inv;
        transforms
          ..[o] = sc
          ..[o + 1] = sn
          ..[o + 2] = sx - sc * half + sn * half
          ..[o + 3] = sy - sn * half - sc * half;
      } else {
        transforms
          ..[o] = scale
          ..[o + 1] = 0
          ..[o + 2] = sx - scale * half
          ..[o + 3] = sy - scale * half;
      }
      final ext = scale * half * 2;
      if (sx - ext < minX) minX = sx - ext;
      if (sx + ext > maxX) maxX = sx + ext;
      if (sy - ext < minY) minY = sy - ext;
      if (sy + ext > maxY) maxY = sy + ext;
      colors[i + 1] = _argb(a, cr, cg, cb);
      _px[i] = sx;
      _py[i] = sy;
      _pa[i] = a;
    }
    bounds = Rect.fromLTRB(minX, minY, maxX, maxY);
    link._startsPending = false;
  }

  /// [count] specks as last drawn, with their colours: the brighter ones of the shell and the streams.
  List<(Offset, Color)> sample(int count, math.Random rnd) {
    final out = <(Offset, Color)>[];
    var tries = 0;
    while (out.length < count) {
      final i = rnd.nextInt(shell + streams);
      // After enough misses (a silent, faint star) any speck will do.
      if (_pa[i] < .12 && tries++ < count * 20) continue;
      out.add((Offset(_px[i], _py[i]), Color(colors[i + 1]).withValues(alpha: 1)));
    }
    return out;
  }
}
