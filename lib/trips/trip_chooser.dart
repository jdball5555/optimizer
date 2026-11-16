import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'trip_models.dart';

/// The first thing a new trip asks, with the whole screen for it: three
/// scenes to pick from. Answers with a [TripHow].
class TripChooser extends StatelessWidget {
  const TripChooser({super.key});

  static const _choices = [
    (how: TripHow.fly, name: 'Fly', about: 'Flights, gates and the ride to the airport', accent: Energy.ice),
    (how: TripHow.drive, name: 'Drive', about: 'Where from, where to, and how long at that hour', accent: Color(0xFFFFB44C)),
    (how: TripHow.other, name: 'Other', about: 'Spaceship, horse, teleporter. We don’t judge.', accent: Energy.pink),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final across = box.maxWidth >= 700;
            final roomy = box.maxHeight >= 560;
            final panels = [
              for (final (i, c) in _choices.indexed) ...[
                if (i > 0) SizedBox(width: across ? 14 : 0, height: across ? 0 : 12),
                Expanded(
                  child: _Rise(
                    order: i,
                    child: _Panel(how: c.how, name: c.name, about: c.about, accent: c.accent, onTap: () => Navigator.pop(context, c.how)),
                  ),
                ),
              ],
            ];
            return Padding(
              padding: EdgeInsets.fromLTRB(across ? 24 : 16, 10, across ? 24 : 16, across ? 24 : 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  IconButton(
                    tooltip: 'Back',
                    style: IconButton.styleFrom(backgroundColor: AppColors.faint),
                    icon: const Icon(Icons.arrow_back, size: 20, color: AppColors.primaryText),
                    onPressed: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 14),
                  if (!roomy) const Expanded(child: _Heading(size: 22)),
                ]),
                if (roomy)
                  Padding(
                    padding: EdgeInsets.only(top: across ? 22 : 16, bottom: across ? 26 : 18, left: 2),
                    child: _Heading(size: across ? 44 : 30),
                  )
                else
                  const SizedBox(height: 12),
                Expanded(
                  child: across
                      ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: panels)
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: panels),
                ),
              ]),
            );
          }),
        ),
      );
}

class _Heading extends StatelessWidget {
  const _Heading({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Text(
        'How are you getting there?',
        maxLines: 2,
        style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, letterSpacing: -size * 0.03, height: 1.08),
      );
}

/// Comes up into place as the page opens, one panel after another.
class _Rise extends StatelessWidget {
  const _Rise({required this.order, required this.child});

  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: still ? 1 : 0, end: 1),
      duration: Duration(milliseconds: 420 + order * 110),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, 22 * (1 - v)), child: child),
      ),
    );
  }
}

class _Panel extends StatefulWidget {
  const _Panel({required this.how, required this.name, required this.about, required this.accent, required this.onTap});

  final TripHow how;
  final String name;
  final String about;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> with TickerProviderStateMixin {
  // The scene is still until you point at it, then it comes alive.
  late final _drift = AnimationController(vsync: this, duration: const Duration(seconds: 7));
  late final _lit = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  bool _hover = false;
  bool _focus = false;

  bool get _on => _hover || _focus;

  void _changed() {
    if (_on) {
      _lit.forward();
      if (!MediaQuery.disableAnimationsOf(context)) _drift.repeat();
    } else {
      _lit.reverse();
      _drift.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _drift.dispose();
    _lit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(26);
    return LayoutBuilder(builder: (context, box) {
      final tall = box.maxHeight >= 300;
      final showAbout = box.maxHeight >= 118;
      final nameSize = tall ? 54.0 : (box.maxHeight >= 150 ? 36.0 : 28.0);
      final inset = tall ? 26.0 : 18.0;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: _on ? widget.accent.withValues(alpha: 0.7) : const Color(0x24FFFFFF)),
          boxShadow: _on ? [BoxShadow(color: widget.accent.withValues(alpha: 0.22), blurRadius: 42, spreadRadius: -6)] : null,
        ),
        child: Material(
          color: AppColors.background,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onHover: (v) {
              _hover = v;
              _changed();
            },
            onFocusChange: (v) {
              _focus = v;
              _changed();
            },
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            highlightColor: widget.accent.withValues(alpha: 0.08),
            splashColor: widget.accent.withValues(alpha: 0.14),
            child: Stack(fit: StackFit.expand, children: [
              RepaintBoundary(
                child: CustomPaint(painter: _Scene(how: widget.how, accent: widget.accent, drift: _drift, lit: _lit)),
              ),
              // So the words always read, whatever's behind them.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: [0.35, 1],
                    colors: [Color(0x00000000), Color(0xE6000000)],
                  ),
                ),
              ),
              Positioned(
                left: inset,
                right: inset,
                bottom: tall ? 24 : 14,
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(widget.name,
                          style: TextStyle(fontSize: nameSize, fontWeight: FontWeight.w800, letterSpacing: -nameSize * 0.035, height: 1.05)),
                      if (showAbout) ...[
                        const SizedBox(height: 4),
                        Text(
                          widget.about,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: const Color(0xCCFFFFFF), fontSize: tall ? 15 : 13, height: 1.3),
                        ),
                      ],
                    ]),
                  ),
                  const SizedBox(width: 14),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: tall ? 46 : 38,
                    height: tall ? 46 : 38,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _on ? AppColors.primaryText : const Color(0x1FFFFFFF),
                      border: Border.all(color: _on ? AppColors.primaryText : const Color(0x40FFFFFF)),
                    ),
                    child: Icon(Icons.arrow_forward, size: tall ? 21 : 18, color: _on ? AppColors.background : AppColors.primaryText),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      );
    });
  }
}

/// A night flight, a road into the sunset, or deep space, drawn to fit any
/// shape of panel. In a wide, short panel the subject moves to the right so
/// the words have the left.
class _Scene extends CustomPainter {
  _Scene({required this.how, required this.accent, required this.drift, required this.lit}) : super(repaint: Listenable.merge([drift, lit]));

  final TripHow how;
  final Color accent;
  final Animation<double> drift;
  final Animation<double> lit;

  double get _wave => math.sin(drift.value * 2 * math.pi);

  @override
  void paint(Canvas canvas, Size size) {
    switch (how) {
      case TripHow.fly:
        _fly(canvas, size);
      case TripHow.drive:
        _drive(canvas, size);
      case TripHow.other:
        _space(canvas, size);
    }
  }

  static void _sky(Canvas canvas, Size size, List<Color> colors, List<double> stops) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect,
        Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors, stops: stops).createShader(rect));
  }

  static void _glow(Canvas canvas, Offset at, double radius, Color color) {
    canvas.drawCircle(
      at,
      radius,
      Paint()..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: at, radius: radius)),
    );
  }

  void _stars(Canvas canvas, Size size, {required int seed, required int count, required double bottom}) {
    final rnd = math.Random(seed);
    final paint = Paint();
    for (var i = 0; i < count; i++) {
      final x = rnd.nextDouble() * size.width, y = rnd.nextDouble() * size.height * bottom;
      final r = 0.45 + rnd.nextDouble() * rnd.nextDouble() * 1.25;
      final phase = rnd.nextDouble() * 2 * math.pi;
      final twinkle = 0.65 + 0.35 * math.sin(drift.value * 2 * math.pi * 2 + phase);
      paint.color = Colors.white.withValues(alpha: (0.2 + rnd.nextDouble() * 0.6) * twinkle);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  /// A Material icon as a shape, glowing, turned about its center.
  void _glyph(Canvas canvas, IconData icon, Offset at, double size, {double turn = 0, Color color = Colors.white, double glow = 0}) {
    TextPainter text(Paint foreground) => TextPainter(
          textDirection: TextDirection.ltr,
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: size, height: 1, foreground: foreground),
          ),
        )..layout();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(turn);
    if (glow > 0) {
      final halo = text(Paint()
        ..color = accent.withValues(alpha: 0.55 + 0.3 * lit.value)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, glow));
      halo.paint(canvas, Offset(-halo.width / 2, -halo.height / 2));
      halo.dispose();
    }
    final shape = text(Paint()..color = color);
    shape.paint(canvas, Offset(-shape.width / 2, -shape.height / 2));
    shape.dispose();
    canvas.restore();
  }

  void _fly(Canvas canvas, Size s) {
    final w = s.width, h = s.height, wide = w > h * 1.25;
    _sky(canvas, s, const [Color(0xFF040817), Color(0xFF0A1A44), Color(0xFF1C3B7C), Color(0xFF0B1228)], const [0, 0.45, 0.72, 1]);
    _stars(canvas, s, seed: 11, count: 70, bottom: 0.55);
    _glow(canvas, Offset(wide ? w * 0.7 : w * 0.5, h * 0.72), math.max(w, h) * 0.6, Energy.ice.withValues(alpha: 0.2 + 0.08 * lit.value));

    // Soft clouds, low in the sky.
    final rnd = math.Random(4);
    final cloud = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    for (var i = 0; i < 7; i++) {
      final x = rnd.nextDouble() * w + 8 * _wave;
      final y = h * (0.52 + rnd.nextDouble() * 0.2);
      cloud.color = Colors.white.withValues(alpha: 0.05 + rnd.nextDouble() * 0.07);
      canvas.drawOval(Rect.fromCenter(center: Offset(x, y), width: w * (0.3 + rnd.nextDouble() * 0.4), height: h * 0.05), cloud);
    }

    // The flight path: a long climbing arc, bright at the plane.
    final a = Offset(wide ? w * 0.36 : -w * 0.06, h * (wide ? 0.82 : 0.66));
    final c = Offset(wide ? w * 0.66 : w * 0.46, h * (wide ? 0.72 : 0.56));
    final b = Offset(wide ? w * 0.93 : w * 0.86, h * (wide ? 0.12 : 0.16));
    Offset at(double u) => Offset(
          (1 - u) * (1 - u) * a.dx + 2 * (1 - u) * u * c.dx + u * u * b.dx,
          (1 - u) * (1 - u) * a.dy + 2 * (1 - u) * u * c.dy + u * u * b.dy,
        );
    final u = 0.8 + 0.035 * _wave;
    final tip = at(u);
    final trail = Path()..moveTo(a.dx, a.dy);
    for (var i = 1; i <= 40; i++) {
      final p = at(u * i / 40);
      trail.lineTo(p.dx, p.dy);
    }
    final fade =
        LinearGradient(colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.9)]).createShader(Rect.fromPoints(a, tip));
    canvas.drawPath(
      trail,
      Paint()
        ..shader = fade
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );
    canvas.drawPath(
      trail,
      Paint()
        ..shader = fade
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );
    final d = at(u + 0.01) - at(u - 0.01);
    _glyph(canvas, Icons.flight, tip, (math.min(w, h) * 0.22).clamp(34.0, 92.0), turn: math.atan2(d.dy, d.dx) + math.pi / 2, glow: 12);
  }

  void _drive(Canvas canvas, Size s) {
    final w = s.width, h = s.height, wide = w > h * 1.25;
    final fx = wide ? w * 0.68 : w * 0.5;
    final horizon = h * 0.47;
    _sky(canvas, s, const [Color(0xFF0B0816), Color(0xFF2B1230), Color(0xFF8A3B1E), Color(0xFFF08A3C)],
        [0, horizon / h * 0.5, horizon / h * 0.86, horizon / h]);
    _stars(canvas, s, seed: 23, count: 26, bottom: 0.22);

    // The sun, setting at the end of the road.
    final sunR = math.min(w, h) * 0.11;
    _glow(canvas, Offset(fx, horizon), math.max(w, h) * 0.5, const Color(0xFFFFB44C).withValues(alpha: 0.4 + 0.1 * lit.value));
    canvas.drawCircle(Offset(fx, horizon), sunR, Paint()..color = const Color(0xFFFFD79A));

    void hills(double base, double rise, double wavelength, double phase, Color color) {
      final p = Path()..moveTo(0, horizon);
      for (var x = 0.0; x <= w + 8; x += 8) {
        final y = base - rise * (0.5 + 0.5 * math.sin(x / wavelength + phase)) * (0.6 + 0.4 * math.sin(x / (wavelength * 2.7) + phase));
        p.lineTo(x, y);
      }
      p
        ..lineTo(w, horizon + 1)
        ..lineTo(0, horizon + 1)
        ..close();
      canvas.drawPath(p, Paint()..color = color);
    }

    hills(horizon, h * 0.09, w * 0.13, 1.2, const Color(0xFF3A1A22));
    hills(horizon, h * 0.05, w * 0.09, 3.4, const Color(0xFF1A0D14));

    // Ground and road, in perspective from the sun.
    canvas.drawRect(
        Rect.fromLTRB(0, horizon, w, h),
        Paint()
          ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF17100F), Color(0xFF050505)])
              .createShader(Rect.fromLTRB(0, horizon, w, h)));
    final vanish = Offset(fx, horizon);
    final halfBase = math.max(w, h) * 0.55;
    final road = Path()
      ..moveTo(vanish.dx, vanish.dy)
      ..lineTo(fx + halfBase, h)
      ..lineTo(fx - halfBase, h)
      ..close();
    canvas.drawPath(
        road,
        Paint()
          ..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF3A241A), Color(0xFF0C0C0E)])
              .createShader(Rect.fromLTRB(0, horizon, w, h)));
    final edge = Paint()
      ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [const Color(0xFFFFD79A).withValues(alpha: 0.75), Colors.white.withValues(alpha: 0.28)])
          .createShader(Rect.fromLTRB(0, horizon, w, h))
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(vanish, Offset(fx + halfBase, h), edge);
    canvas.drawLine(vanish, Offset(fx - halfBase, h), edge);

    // The center line rushes toward you.
    const dashes = 9;
    final dash = Paint()..color = const Color(0xFFFFE3B0);
    for (var i = 0; i < dashes; i++) {
      final z0 = ((i + drift.value * dashes * 2) % dashes) / dashes;
      final z1 = z0 + 0.5 / dashes;
      double y(double z) => horizon + (h - horizon) * z * z;
      double half(double z) => 0.3 + 5 * z * z;
      // Gone before they reach the words.
      dash.color = const Color(0xFFFFE3B0).withValues(alpha: (1 - (z0 - 0.62) / 0.2).clamp(0.0, 1.0));
      final p = Path()
        ..moveTo(fx - half(z0), y(z0))
        ..lineTo(fx + half(z0), y(z0))
        ..lineTo(fx + half(z1), y(z1))
        ..lineTo(fx - half(z1), y(z1))
        ..close();
      canvas.drawPath(p, dash);
    }

    // A car in the lane ahead, taillights on.
    final carY = horizon + (h - horizon) * 0.3;
    final carSize = (math.min(w, h) * 0.2).clamp(30.0, 84.0);
    final carX = fx + (carY - horizon) / (h - horizon) * halfBase * 0.42 + 1.5 * _wave;
    canvas.drawOval(
        Rect.fromCenter(center: Offset(carX, carY + carSize * 0.42), width: carSize * 0.95, height: carSize * 0.18),
        Paint()
          ..color = const Color(0xB3000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    _glyph(canvas, Icons.directions_car, Offset(carX, carY - 1.5), carSize, color: const Color(0xFFD98A4A));
    _glyph(canvas, Icons.directions_car, Offset(carX, carY), carSize, color: const Color(0xFF2B2E39));
    for (final side in const [-1.0, 1.0]) {
      final light = Offset(carX + side * carSize * 0.285, carY + carSize * 0.075);
      _glow(canvas, light, carSize * 0.17, const Color(0xFFFF3B30).withValues(alpha: 0.6 + 0.3 * lit.value));
      canvas.drawCircle(light, carSize * 0.042, Paint()..color = const Color(0xFFFFB3A8));
    }
  }

  void _space(Canvas canvas, Size s) {
    final w = s.width, h = s.height, wide = w > h * 1.25;
    final m = math.min(w, h);
    _sky(canvas, s, const [Color(0xFF04030C), Color(0xFF120A2E), Color(0xFF220B3B), Color(0xFF0A0512)], const [0, 0.4, 0.7, 1]);
    _glow(canvas, Offset(w * (wide ? 0.55 : 0.2), h * 0.25), math.max(w, h) * 0.5, Energy.pink.withValues(alpha: 0.17 + 0.05 * lit.value));
    _glow(canvas, Offset(w * 0.85, h * 0.6), math.max(w, h) * 0.55, Energy.violet.withValues(alpha: 0.26));
    _stars(canvas, s, seed: 7, count: 150, bottom: 1);

    // A ringed planet.
    final planet = Offset(w * (wide ? 0.9 : 0.8), h * (wide ? 0.32 : 0.17));
    final r = m * 0.13;
    final tilt = Rect.fromCenter(center: Offset.zero, width: r * 3.5, height: r * 0.85);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.13
      ..color = const Color(0xFFF7C8E8).withValues(alpha: 0.65);
    canvas.save();
    canvas.translate(planet.dx, planet.dy);
    canvas.rotate(-0.42);
    canvas.drawArc(tilt, math.pi, math.pi, false, ring);
    canvas.restore();
    canvas.drawCircle(
      planet,
      r,
      Paint()
        ..shader = const RadialGradient(
            center: Alignment(-0.5, -0.55),
            colors: [Color(0xFFFFC2E6), Color(0xFF9B4BD6), Color(0xFF24103F)],
            stops: [0, 0.55, 1]).createShader(Rect.fromCircle(center: planet, radius: r)),
    );
    canvas.save();
    canvas.translate(planet.dx, planet.dy);
    canvas.rotate(-0.42);
    canvas.drawArc(tilt, 0, math.pi, false, ring);
    canvas.restore();

    // The rocket, climbing on a bright trail.
    final size = (m * 0.3).clamp(40.0, 120.0);
    final rocket = Offset(w * (wide ? 0.66 : 0.46) + 5 * _wave, h * (wide ? 0.44 : 0.42) - 7 * _wave);
    final tail = rocket + Offset(-size * 0.34, size * 0.34);
    final end = tail + Offset(-math.max(w, h) * 0.5, math.max(w, h) * 0.5);
    final flame = LinearGradient(
      begin: Alignment.topRight,
      end: Alignment.bottomLeft,
      colors: [Colors.white, Energy.pink.withValues(alpha: 0.85), Energy.violet.withValues(alpha: 0)],
      stops: const [0, 0.22, 0.95],
    ).createShader(Rect.fromPoints(tail, end));
    canvas.drawLine(
      tail,
      end,
      Paint()
        ..shader = flame
        ..strokeWidth = size * 0.13
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.drawLine(
      tail,
      end,
      Paint()
        ..shader = flame
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
    _glow(canvas, tail, size * 0.2, Energy.pink.withValues(alpha: 0.7));
    _glyph(canvas, Icons.rocket_launch, rocket, size, glow: 14);
  }

  @override
  bool shouldRepaint(_Scene old) => old.how != how || old.accent != accent;
}
