import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The PocketTerm mark: a phone showing a terminal prompt, leaning
/// out of a pocket, as on the app icon (tool/make_icon.swift draws the same shapes).
class PocketTermLogo extends StatelessWidget {
  const PocketTermLogo({this.size = 48, super.key});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: const _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter();

  static const _yellow = Color(0xFFFFD15C);
  static const _screen = Color(0xFF0E1018);
  static const _frame = Color(0xFFE8E9EE);
  static const _pocketTop = Color(0xFF8C9EFF);
  static const _pocketBottom = Color(0xFF5C6BDB);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // The icon's unit geometry (y up) spans about 0.13–0.87 across and
    // 0.17–0.91 up once the phone is tilted; map that square onto the canvas, y down.
    Offset p(double x, double y) => Offset((x - 0.12) / 0.76 * w, (0.92 - y) / 0.76 * w);
    final u = w / 0.76;
    // Phone coordinates: centred on its pivot, y down here (the icon's are y up).
    canvas
      ..save()
      ..translate(p(0.5, 0.64).dx, p(0.5, 0.64).dy)
      ..rotate(10 * math.pi / 180);
    final phone = RRect.fromRectAndRadius(
      Rect.fromLTWH(-0.15 * u, -0.24 * u, 0.30 * u, 0.50 * u),
      Radius.circular(0.056 * u),
    );
    canvas
      ..drawRRect(phone, Paint()..color = _screen)
      ..drawRRect(
        phone,
        Paint()
          ..color = _frame
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.018 * u,
      );
    final prompt = Paint()
      ..color = _yellow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.034 * u
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas
      ..drawPath(
        Path()
          ..moveTo(-0.085 * u, -0.14 * u)
          ..lineTo(-0.019 * u, -0.0896 * u)
          ..lineTo(-0.085 * u, -0.0392 * u),
        prompt,
      )
      ..drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0.01 * u, -0.06 * u, 0.08 * u, 0.032 * u), Radius.circular(0.016 * u)),
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
