import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The PocketTerm mark: a terminal window leaning out of a pocket, as on the
/// app icon (tool/make_icon.swift draws the same shapes).
class PocketTermLogo extends StatelessWidget {
  const PocketTermLogo({this.size = 48, super.key});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: const _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter();

  static const _yellow = Color(0xFFFFD15C);
  static const _window = Color(0xFF0E1018);
  static const _titleBar = Color(0xFFE8E9EE);
  static const List<Color> _dots = [Color(0xFFFF6B6B), _yellow, Color(0xFF5EE6A8)];
  static const _pocketTop = Color(0xFF8C9EFF);
  static const _pocketBottom = Color(0xFF5C6BDB);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // The icon's unit geometry (y up) spans about 0.15–0.89 in both axes once
    // the window is tilted; map that square onto the canvas, y down.
    Offset p(double x, double y) => Offset((x - 0.13) / 0.75 * w, (0.895 - y) / 0.75 * w);
    final u = w / 0.75;
    // Window coordinates: centred, y down here (the icon's are y up).
    canvas
      ..save()
      ..translate(p(0.53, 0.665).dx, p(0.53, 0.665).dy)
      ..rotate(-9 * math.pi / 180);
    final window = RRect.fromRectAndRadius(
      Rect.fromLTWH(-0.22 * u, -0.20 * u, 0.44 * u, 0.40 * u),
      Radius.circular(0.035 * u),
    );
    canvas
      ..drawRRect(window, Paint()..color = _window)
      ..save()
      ..clipRRect(window)
      ..drawRect(Rect.fromLTWH(-0.22 * u, -0.20 * u, 0.44 * u, 0.075 * u), Paint()..color = _titleBar)
      ..restore();
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(Offset((-0.17 + i * 0.045) * u, -0.1625 * u), 0.014 * u, Paint()..color = _dots[i]);
    }
    final prompt = Paint()
      ..color = _yellow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.024 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas
      ..drawPath(
        Path()
          ..moveTo(-0.165 * u, -0.085 * u)
          ..lineTo(-0.115 * u, -0.05 * u)
          ..lineTo(-0.165 * u, -0.015 * u),
        prompt,
      )
      ..drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(-0.095 * u, -0.03 * u, 0.07 * u, 0.024 * u), Radius.circular(0.012 * u)),
        Paint()..color = _yellow,
      )
      ..restore();

    final pocket = Path()
      ..moveTo(p(0.22, 0.60).dx, p(0.22, 0.60).dy)
      ..lineTo(p(0.78, 0.60).dx, p(0.78, 0.60).dy)
      ..lineTo(p(0.78, 0.33).dx, p(0.78, 0.33).dy)
      ..lineTo(p(0.50, 0.17).dx, p(0.50, 0.17).dy)
      ..lineTo(p(0.22, 0.33).dx, p(0.22, 0.33).dy)
      ..close();
    canvas.drawPath(
      pocket,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_pocketTop, _pocketBottom],
        ).createShader(pocket.getBounds()),
    );

    // Dashed stitching just inside the edge, and the hem.
    final stitch = Paint()
      ..color = _yellow.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, 0.011 * u)
      ..strokeCap = StrokeCap.round;
    final outline = [p(0.255, 0.565), p(0.745, 0.565), p(0.745, 0.35), p(0.50, 0.21), p(0.255, 0.35), p(0.255, 0.565)];
    for (var i = 0; i < outline.length - 1; i++) {
      _dash(canvas, outline[i], outline[i + 1], 0.022 * u, 0.02 * u, stitch);
    }
    _dash(canvas, p(0.255, 0.535), p(0.745, 0.535), 0.022 * u, 0.02 * u, stitch);
  }

  void _dash(Canvas canvas, Offset a, Offset b, double on, double off, Paint paint) {
    final d = b - a;
    final len = d.distance;
    final dir = d / len;
    for (var t = 0.0; t < len; t += on + off) {
      canvas.drawLine(a + dir * t, a + dir * math.min(t + on, len), paint);
    }
  }

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) => false;
}
