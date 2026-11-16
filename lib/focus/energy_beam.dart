import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme.dart';

/// Two black rings, seen only by the white light around their edges, with a
/// beam of light flowing slowly from the top one (you) down into the bottom
/// one (what you're working on), whose light spreads as you near your goal.
/// Paused, the flow stops and dims; with nothing going, it barely glows.
class EnergyBeam extends StatefulWidget {
  const EnergyBeam({super.key, required this.running, this.idle = false, this.progress, this.top, this.bottom});

  /// The beam flows.
  final bool running;

  /// No session: everything faint and slow.
  final bool idle;

  /// How full the bottom ring is (0 to 1), or null for no goal.
  final double? progress;

  /// Shown inside the top and bottom rings.
  final Widget? top;
  final Widget? bottom;

  @override
  State<EnergyBeam> createState() => _EnergyBeamState();
}

class _EnergyBeamState extends State<EnergyBeam> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _time = 0; // always moves, for the rings' shimmer
  double _flow = 0; // moves only while running, for the beam
  late double _energy = _target;

  double get _target => widget.idle ? 0.22 : (widget.running ? 1.0 : 0.38);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
      _last = elapsed;
      setState(() {
        _time += dt * (widget.idle ? 0.35 : 1);
        if (widget.running) _flow += dt;
        _energy += (_target - _energy) * math.min(1, dt * 3); // ease in and out
      });
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final g = BeamGeometry(Size(c.maxWidth, c.maxHeight));
      Widget inside(Offset center, Widget? child) => Positioned.fromRect(
            rect: Rect.fromCircle(center: center, radius: g.radius * 0.78),
            child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: child)),
          );
      return Stack(children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _BeamPainter(g: g, time: _time, flow: _flow, energy: _energy, progress: widget.progress?.clamp(0.0, 1.0)),
            ),
          ),
        ),
        if (widget.top != null) inside(g.top, widget.top),
        if (widget.bottom != null) inside(g.bottom, widget.bottom),
      ]);
    });
  }
}

/// Where the two rings sit in a box of [size].
class BeamGeometry {
  BeamGeometry(Size size) {
    radius = math.max(24, math.min(size.width * 0.3, size.height / 5.6));
    final gap = math.max(size.height - 4.8 * radius, radius * 0.8);
    top = Offset(size.width / 2, size.height / 2 - gap / 2 - radius);
    bottom = Offset(size.width / 2, size.height / 2 + gap / 2 + radius);
  }

  late final double radius;
  late final Offset top;
  late final Offset bottom;
}

class _BeamPainter extends CustomPainter {
  _BeamPainter({required this.g, required this.time, required this.flow, required this.energy, required this.progress});

  final BeamGeometry g;
  final double time;
  final double flow;
  final double energy;
  final double? progress;

  static Color _a(Color c, double opacity) => c.withValues(alpha: (c.a * opacity).clamp(0.0, 1.0));
  static Paint _glow(double sigma) => Paint()..maskFilter = sigma > 0 ? MaskFilter.blur(BlurStyle.normal, sigma) : null;
  static Paint _line(double width, double sigma, Color color) => _glow(sigma)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeWidth = width
    ..color = color;

  static const _top = -math.pi / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final e = energy;
    final r = g.radius;
    final s = r / 100; // everything scales with the rings
    final cx = g.top.dx;
    final y0 = g.top.dy + r;
    final y1 = g.bottom.dy - r;
    final breathe = 0.93 + 0.07 * math.sin(time * 1.1);

    // A faint blue haze down the beam, and nothing else: the page stays black.
    if (y1 > y0) {
      final band = Rect.fromLTRB(cx - r * 0.9, y0, cx + r * 0.9, y1);
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(colors: [
            Colors.transparent,
            _a(Energy.haze, 0.35 * e),
            Colors.transparent,
          ]).createShader(band),
      );
    }

    _ring(canvas, g.top, r, s, e * breathe, null);
    _ring(canvas, g.bottom, r, s, e * breathe, progress);

    if (y1 <= y0) return;

    // The beam: white light with a cool halo, and the faintest violet and
    // pink along its edges.
    final path = Path()..moveTo(cx, y0);
    for (var y = y0; y <= y1; y += 4) {
      path.lineTo(cx + math.sin(y * 0.03 + flow * 1.6) * 0.8 * e * s, y);
    }
    path.lineTo(cx, y1);
    canvas.drawPath(path, _line(44 * s, 24 * s, _a(Energy.blue, 0.4 * e * breathe)));
    canvas.save();
    canvas.translate(-2.5 * s, 0);
    canvas.drawPath(path, _line(3 * s, 3 * s, _a(Energy.violet, 0.35 * e)));
    canvas.translate(5 * s, 0);
    canvas.drawPath(path, _line(3 * s, 3 * s, _a(Energy.pink, 0.25 * e)));
    canvas.restore();
    canvas.drawPath(path, _line(10 * s, 6 * s, _a(Energy.ice, 0.7 * e)));
    canvas.drawPath(path, _line(math.max(1.2, 1.8 * s), 0, _a(Energy.white, math.min(1, 0.35 + e * 0.65))));

    // Soft swells of light drifting slowly down it.
    final length = y1 - y0;
    for (var i = 0; i < 3; i++) {
      final p = (flow * 0.07 + i / 3) % 1.0;
      final fade = math.sin(p * math.pi) * e;
      final at = Offset(cx, y0 + p * length);
      canvas.drawOval(Rect.fromCenter(center: at, width: 16 * s, height: 90 * s), _glow(9 * s)..color = _a(Energy.ice, 0.45 * fade));
      canvas.drawOval(Rect.fromCenter(center: at, width: 5 * s, height: 60 * s), _glow(3 * s)..color = _a(Energy.white, 0.9 * fade));
    }

    // A few motes of light, drifting down with it.
    final rnd = math.Random(3);
    for (var i = 0; i < 10; i++) {
      final speed = 0.04 + rnd.nextDouble() * 0.05;
      final p = (flow * speed + rnd.nextDouble()) % 1.0;
      final x = cx + (rnd.nextDouble() - 0.5) * r * 0.22 * math.sin(p * math.pi);
      canvas.drawCircle(Offset(x, y0 + p * length), (0.8 + rnd.nextDouble()) * math.max(0.8, s),
          Paint()..color = _a(Energy.white, 0.6 * e * math.sin(p * math.pi)));
    }

    // Where it leaves one ring and lands in the other, and the thin flare of
    // light it spreads on landing.
    canvas.drawCircle(Offset(cx, y0), 10 * s, _glow(8 * s)..color = _a(Energy.ice, 0.6 * e));
    canvas.drawCircle(Offset(cx, y1), 14 * s, _glow(10 * s)..color = _a(Energy.white, 0.7 * e));
    canvas.save();
    canvas.translate(cx, y1);
    canvas.scale(1, 0.08);
    canvas.drawCircle(
      Offset.zero,
      r * 1.6,
      Paint()
        ..shader = RadialGradient(colors: [
          _a(Energy.white, 0.5 * e),
          _a(Energy.blue, 0.18 * e),
          Colors.transparent,
        ], stops: const [0, 0.35, 1]).createShader(Rect.fromCircle(center: Offset.zero, radius: r * 1.6)),
    );
    canvas.restore();
  }

  /// A black disc you only see by the light around its edge: white, with a
  /// cool halo and a hint of violet on one side and pink on the other. Light
  /// runs down both sides from the top, toward the beam. With a goal
  /// ([fill]), the bright part spreads down from the top as you get there.
  void _ring(Canvas canvas, Offset c, double r, double s, double e, double? fill) {
    canvas.drawCircle(c, r, Paint()..color = Colors.black);
    final rect = Rect.fromCircle(center: c, radius: r);

    void glow(double start, double sweep, double k) {
      canvas.drawArc(rect, start, sweep, false, _line(22 * s, 16 * s, _a(Energy.blue, 0.3 * k)));
      canvas.drawArc(rect.inflate(2.5 * s), start, sweep, false, _line(2.5 * s, 3 * s, _a(Energy.violet, 0.3 * k)));
      canvas.drawArc(rect.deflate(2.5 * s), start, sweep, false, _line(2.5 * s, 3 * s, _a(Energy.pink, 0.22 * k)));
      canvas.drawArc(rect, start, sweep, false, _line(6 * s, 4 * s, _a(Energy.ice, 0.6 * k)));
      canvas.drawArc(rect, start, sweep, false, _line(math.max(1.1, 1.6 * s), 0, _a(Energy.white, k)));
    }

    const whole = math.pi * 2;
    if (fill == null) {
      glow(_top, whole, e);
    } else {
      glow(_top, whole, 0.22 * e + 0.08);
      if (fill > 0) glow(_top - fill * math.pi, fill * whole, e);
    }

    // Light running down both sides, slowly.
    final reach = fill ?? 1.0;
    if (reach <= 0) return;
    for (var i = 0; i < 2; i++) {
      final p = (flow * 0.06 + i / 2) % 1.0;
      final a = p * math.pi * reach;
      final fade = math.sin(p * math.pi) * e;
      for (final side in [-1, 1]) {
        final angle = _top + side * a;
        canvas.drawArc(rect, angle - 0.18, 0.36, false, _line(4 * s, 3 * s, _a(Energy.white, 0.9 * fade)));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BeamPainter old) => true;
}
