import 'package:flutter/material.dart';

/// Optimizer's mark: a round field of dots that grow from the bottom-left
/// to the top-right, like a halftone of something going up. Also rendered
/// into the app and browser icons (see test/tool/make_icons_test.dart).
class OptimizerLogo extends StatelessWidget {
  const OptimizerLogo({super.key, this.size = 32, this.color = Colors.white});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: CustomPaint(painter: OptimizerLogoPainter(color)));
}

class OptimizerLogoPainter extends CustomPainter {
  OptimizerLogoPainter(this.color);

  final Color color;

  static const _n = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()..color = color;
    final step = s / _n;
    final mid = (_n - 1) / 2;
    for (var row = 0; row < _n; row++) {
      for (var col = 0; col < _n; col++) {
        // Round overall: leave out the four corners.
        final dx = col - mid, dy = row - mid;
        if (dx * dx + dy * dy > mid * mid + 1.5) continue;
        // 0 at the bottom-left, 1 at the top-right.
        final t = (col + (_n - 1 - row)) / (2 * (_n - 1));
        final r = step * (0.12 + 0.34 * t);
        canvas.drawCircle(Offset(step * (col + 0.5), step * (row + 0.5)), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant OptimizerLogoPainter old) => old.color != color;
}
