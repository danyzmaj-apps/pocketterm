import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pocketterm_core/theme.dart';

/// The PocketTerm mark: a phone showing a terminal prompt, leaning out of a
/// pocket, as on the app icon (apps/pocketterm-desktop/tool/make_icon.swift
/// draws the same shapes), in the active theme's colors and corners.
class PocketTermLogo extends StatelessWidget {
  const PocketTermLogo({this.size = 48, this.theme, super.key});
  final double size;

  /// Drawn in this theme rather than the active one.
  final PtTheme? theme;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _LogoPainter(LogoStyle.of(theme ?? appearance.theme)));
}

/// The mark's colors and corners, from a theme: the frame in its text
/// color, the screen its background, the prompt and stitching its warning
/// color, the pocket a gradient of its accent; corners rounded (soft),
/// small (crisp) or square (boxy) like the theme's.
@immutable
class LogoStyle {
  const LogoStyle({
    required this.frame,
    required this.screen,
    required this.prompt,
    required this.pocketTop,
    required this.pocketBottom,
    required this.tileTop,
    required this.tileBottom,
    required this.shape,
  });

  factory LogoStyle.of(PtTheme t) => LogoStyle(
    frame: t.text,
    screen: t.win,
    prompt: t.warn,
    pocketTop: t.accent,
    pocketBottom: Color.lerp(t.accent, t.win, .35)!,
    tileTop: Color.lerp(t.win, t.accent, .2)!,
    tileBottom: t.win,
    shape: t.shape,
  );

  final Color frame;
  final Color screen;
  final Color prompt;
  final Color pocketTop;
  final Color pocketBottom;

  /// The app icon's background behind the mark: [tileTop] at the top left
  /// to [tileBottom] at the bottom right.
  final Color tileTop;
  final Color tileBottom;
  final ThemeShape shape;

  /// The phone's corner radius, in icon units (the icon is 1 across).
  double get phoneRadius => switch (shape) {
    ThemeShape.soft => .056,
    ThemeShape.crisp => .03,
    ThemeShape.boxy => .012,
  };

  /// The icon tile's corner radius, as a fraction of its side.
  double get tileRadius => switch (shape) {
    ThemeShape.soft => .225,
    ThemeShape.crisp => .14,
    ThemeShape.boxy => .05,
  };

  bool get square => shape == ThemeShape.boxy;

  @override
  bool operator ==(Object other) =>
      other is LogoStyle &&
      other.frame == frame &&
      other.screen == screen &&
      other.prompt == prompt &&
      other.pocketTop == pocketTop &&
      other.pocketBottom == pocketBottom &&
      other.tileTop == tileTop &&
      other.tileBottom == tileBottom &&
      other.shape == shape;

  @override
  int get hashCode => Object.hash(frame, screen, prompt, pocketTop, pocketBottom, tileTop, tileBottom, shape);
}

/// The phone's lean on the icon, clockwise, in radians.
const double logoTilt = 10 * math.pi / 180;

/// Draws the mark in icon units: the icon is the unit square, y up, mapped
/// onto the canvas by [p], one unit being [u] long there. [lift] raises the
/// phone out of the pocket (icon units), [tilt] leans it clockwise from
/// upright; [squash] squashes the pocket from its top edge (1: 10% shorter,
/// 6% wider; below 0 stretches it); [cursor] shows the prompt's cursor,
/// [prompt] fades the whole prompt (0 to 1); [phone] reshapes the phone's
/// body (around its pivot, as [logoPhone]) and [frameLine] its frame's line
/// (icon units).
void paintLogo(
  Canvas canvas,
  LogoStyle style, {
  required Offset Function(double x, double y) p,
  required double u,
  double lift = 0,
  double tilt = logoTilt,
  double squash = 0,
  bool cursor = true,
  double prompt = 1,
  RRect? phone,
  double frameLine = logoFrameLine,
}) {
  final cap = style.square ? StrokeCap.square : StrokeCap.round;
  final join = style.square ? StrokeJoin.miter : StrokeJoin.round;
  // Phone coordinates: centred on its pivot, y down here (the icon's are y up).
  final pivot = p(.5, .64 + lift);
  canvas
    ..save()
    ..translate(pivot.dx, pivot.dy)
    ..rotate(tilt);
  phone ??= logoPhone(u, style);
  canvas.drawRRect(phone, Paint()..color = style.screen);
  // (A width of 0 would draw a hairline.)
  if (frameLine > 0) {
    canvas.drawRRect(
      phone,
      Paint()
        ..color = style.frame
        ..style = PaintingStyle.stroke
        ..strokeWidth = frameLine * u,
    );
  }
  if (prompt > 0) {
    final color = style.prompt.withValues(alpha: style.prompt.a * prompt);
    canvas.drawPath(
      Path()
        ..moveTo(-.085 * u, -.14 * u)
        ..lineTo(-.019 * u, -.0896 * u)
        ..lineTo(-.085 * u, -.0392 * u),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = .034 * u
        ..strokeCap = cap
        ..strokeJoin = join,
    );
    if (cursor) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(.01 * u, -.06 * u, .08 * u, .032 * u),
          Radius.circular((style.square ? 0 : .016) * u),
        ),
        Paint()..color = color,
      );
    }
  }
  canvas.restore();

  if (squash != 0) {
    final top = p(.5, .60);
    canvas
      ..save()
      ..translate(top.dx, top.dy)
      ..scale(1 + .06 * squash, 1 - .1 * squash)
      ..translate(-top.dx, -top.dy);
  }
  final pocket = Path()
    ..moveTo(p(.22, .60).dx, p(.22, .60).dy)
    ..lineTo(p(.78, .60).dx, p(.78, .60).dy)
    ..lineTo(p(.78, .33).dx, p(.78, .33).dy)
    ..lineTo(p(.50, .17).dx, p(.50, .17).dy)
    ..lineTo(p(.22, .33).dx, p(.22, .33).dy)
    ..close();
  canvas.drawPath(
    pocket,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [style.pocketTop, style.pocketBottom],
      ).createShader(pocket.getBounds()),
  );

  // Dashed stitching just inside the edge, and the hem.
  final stitch = Paint()
    ..color = style.prompt.withValues(alpha: style.prompt.a * .9)
    ..style = PaintingStyle.stroke
    ..strokeWidth = math.max(1, .011 * u)
    ..strokeCap = cap;
  final outline = [p(.255, .565), p(.745, .565), p(.745, .35), p(.50, .21), p(.255, .35), p(.255, .565)];
  for (var i = 0; i < outline.length - 1; i++) {
    _dash(canvas, outline[i], outline[i + 1], .022 * u, .02 * u, stitch);
  }
  _dash(canvas, p(.255, .535), p(.745, .535), .022 * u, .02 * u, stitch);
  if (squash != 0) canvas.restore();
}

/// The phone's body around its pivot, upright, y down, [u] long per icon unit.
RRect logoPhone(double u, LogoStyle style) => RRect.fromRectAndRadius(
  Rect.fromLTWH(-.15 * u, -.24 * u, .30 * u, .50 * u),
  Radius.circular(style.phoneRadius * u),
);

/// The phone frame's line width, in icon units, centred on [logoPhone]'s
/// edge: the screen is that inset by half of it.
const double logoFrameLine = .018;

void _dash(Canvas canvas, Offset a, Offset b, double on, double off, Paint paint) {
  final d = b - a;
  final len = d.distance;
  final dir = d / len;
  for (var t = 0.0; t < len; t += on + off) {
    canvas.drawLine(a + dir * t, a + dir * math.min(t + on, len), paint);
  }
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter(this.style);
  final LogoStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // The art spans about 0.13–0.87 across and 0.17–0.91 up once the phone
    // is tilted; map that square onto the canvas, y down.
    paintLogo(canvas, style, p: (x, y) => Offset((x - .12) / .76 * w, (.92 - y) / .76 * w), u: w / .76);
  }

  @override
  bool shouldRepaint(_LogoPainter oldDelegate) => oldDelegate.style != style;
}
