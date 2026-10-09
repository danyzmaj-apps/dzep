import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The Džep mark: a pocket with a note tucked in, as on the app icon
/// (tool/make_icon.swift draws the same shapes).
class DzepLogo extends StatelessWidget {
  const DzepLogo({this.size = 48, super.key});
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: const _LogoPainter());
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter();

  static const _note = Color(0xFFFFD15C);
  static const _noteLines = Color(0xFFCC9933);
  static const _pocketTop = Color(0xFF8C9EFF);
  static const _pocketBottom = Color(0xFF5C6BDB);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    // The icon's unit geometry (y up) spans about 0.15–0.89 in both axes once
    // the note is tilted; map that square onto the canvas, y down.
    Offset p(double x, double y) => Offset((x - 0.13) / 0.75 * w, (0.895 - y) / 0.75 * w);
    final u = w / 0.75;
    canvas
      ..save()
      ..translate(p(0.53, 0.66).dx, p(0.53, 0.66).dy)
      ..rotate(9 * math.pi / 180)
      ..drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(-0.19 * u, -0.20 * u, 0.38 * u, 0.36 * u), Radius.circular(0.03 * u)),
        Paint()..color = _note,
      );
    final lines = Paint()..color = _noteLines;
    for (var i = 0; i < 2; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(-0.12 * u, (-0.115 + i * 0.07) * u, (i == 0 ? 0.24 : 0.17) * u, 0.026 * u),
          Radius.circular(0.013 * u),
        ),
        lines,
      );
    }
    canvas.restore();

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
      ..color = _note.withValues(alpha: 0.9)
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
