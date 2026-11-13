import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../scanner/scanner_theme.dart';

/// Drishti-AI brand mark — a stylized retinal eye.
///
/// Pure `CustomPainter` vector: scales crisply to any size, needs no image
/// asset, and exposes a single [progress] driver so the same widget powers the
/// static launcher logo, the animated splash centerpiece, and the in-app
/// header mark. The design is a "neural iris": concentric retinal nerve-fibre
/// arcs, a pupil with a soft scanning sweep, and a pupil that pulses.
class AppLogo extends StatefulWidget {
  const AppLogo({
    super.key,
    this.size = 120,
    this.color = ScannerHUDTheme.neonCyan,
    this.accent = ScannerHUDTheme.deepTeal,

    /// 0..1 scanning arc position. When [animate] is true this is driven
    /// internally; otherwise it freezes the arc at a fixed angle.
    this.progress = 0.0,
    this.animate = true,
    this.showScanArc = true,
    this.pupilPulse = true,
  });

  final double size;
  final Color color;
  final Color accent;
  final double progress;
  final bool animate;
  final bool showScanArc;
  final bool pupilPulse;

  @override
  State<AppLogo> createState() => _AppLogoState();
}

class _AppLogoState extends State<AppLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.animate &&
        !MediaQuery.disableAnimationsOf(context) &&
        !_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(AppLogo old) {
    super.didUpdateWidget(old);
    final shouldRun =
        widget.animate && !MediaQuery.disableAnimationsOf(context);
    if (shouldRun && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldRun && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          painter: _LogoPainter(
            controller: _controller,
            frozen: reduced || !widget.animate,
            baseProgress: widget.progress,
            color: widget.color,
            accent: widget.accent,
            showScanArc: widget.showScanArc,
            pupilPulse: widget.pupilPulse,
          ),
        ),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter({
    required this.controller,
    required this.frozen,
    required this.baseProgress,
    required this.color,
    required this.accent,
    required this.showScanArc,
    required this.pupilPulse,
  }) : super(repaint: controller);

  final AnimationController controller;
  final bool frozen;
  final double baseProgress;
  final Color color;
  final Color accent;
  final bool showScanArc;
  final bool pupilPulse;

  @override
  void paint(Canvas canvas, Size size) {
    final t = frozen ? 0.0 : controller.value;
    final center = Offset(size.width / 2, size.height / 2);
    final shortest = math.min(size.width, size.height);
    final scanAngle = (baseProgress > 0 ? baseProgress : t) * math.pi * 2;

    // ---- Soft outer glow so the mark reads as "lit" on any background ----
    _drawGlow(canvas, center, shortest);

    // ---- Retinal nerve-fibre arcs (concentric dashed rings) ----
    _drawNerveRings(canvas, center, shortest, t);

    // ---- Iris body: a subtle filled disc behind everything ----
    _drawIris(canvas, center, shortest);

    // ---- Scanning arc sweeping the iris ----
    if (showScanArc) {
      _drawScanArc(canvas, center, shortest, scanAngle, t);
    }

    // ---- Pupil with neural-core pulse ----
    _drawPupil(canvas, center, shortest, t);
  }

  void _drawGlow(Canvas canvas, Offset center, double shortest) {
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)],
      ).createShader(Rect.fromCircle(center: center, radius: shortest / 2))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, shortest / 2, glow);
  }

  void _drawIris(Canvas canvas, Offset center, double shortest) {
    final irisRadius = shortest * 0.42;
    final iris = Paint()
      ..shader = RadialGradient(
        colors: [
          accent.withValues(alpha: 0.28),
          accent.withValues(alpha: 0.06),
          Colors.transparent,
        ],
        stops: const [0.0, 0.7, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: irisRadius));
    canvas.drawCircle(center, irisRadius, iris);
  }

  void _drawNerveRings(
    Canvas canvas,
    Offset center,
    double shortest,
    double t,
  ) {
    // Three concentric dashed rings, each rotating at a slightly different
    // speed to suggest independent optical subsystems calibrating.
    const rings = <_Ring>[
      _Ring(radius: 0.44, segments: 24, sweep: 0.55, speed: 0.10, width: 1.1),
      _Ring(radius: 0.36, segments: 18, sweep: 0.40, speed: -0.16, width: 1.4),
      _Ring(radius: 0.28, segments: 12, sweep: 0.30, speed: 0.22, width: 1.6),
    ];

    for (var i = 0; i < rings.length; i++) {
      final r = rings[i];
      final rotation = t * math.pi * 2 * r.speed;
      final radius = shortest * r.radius;
      final ringPaint = Paint()
        ..color = color.withValues(alpha: 0.20 + i * 0.05)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r.width
        ..strokeCap = StrokeCap.round;

      final segAngle = (math.pi * 2) / r.segments;
      for (var s = 0; s < r.segments; s++) {
        final start = rotation + s * segAngle;
        final rect = Rect.fromCircle(center: center, radius: radius);
        canvas.drawArc(rect, start, segAngle * r.sweep, false, ringPaint);
      }
    }
  }

  void _drawScanArc(
    Canvas canvas,
    Offset center,
    double shortest,
    double angle,
    double t,
  ) {
    final radius = shortest * 0.40;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // The travelling highlight: a short bright arc with a fading tail.
    final headPaint = Paint()
      ..shader = SweepGradient(
        startAngle: angle,
        endAngle: angle + math.pi / 3,
        colors: [
          color.withValues(alpha: 0.0),
          color.withValues(alpha: 0.9),
          color.withValues(alpha: 0.0),
        ],
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, angle, math.pi / 3, false, headPaint);

    // A faint leading dot at the arc head for a "laser tip" read.
    final tipPos =
        center + Offset(math.cos(angle) * radius, math.sin(angle) * radius);
    final tipGlow = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(tipPos, 3.2, tipGlow);
    canvas.drawCircle(tipPos, 1.6, Paint()..color = Colors.white);
  }

  void _drawPupil(Canvas canvas, Offset center, double shortest, double t) {
    // Pupil breathes subtly (scaled up to keep it calm, not distracting).
    final breathe = pupilPulse ? 1.0 + math.sin(t * math.pi * 2) * 0.05 : 1.0;
    final pupilRadius = shortest * 0.13 * breathe;

    // Neural core: a layered glow so the pupil looks energized, not flat.
    final coreGlow = Paint()
      ..shader =
          RadialGradient(
            colors: [
              color.withValues(alpha: 0.9),
              color.withValues(alpha: 0.3),
              color.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 0.55, 1.0],
          ).createShader(
            Rect.fromCircle(center: center, radius: pupilRadius * 2.4),
          );
    canvas.drawCircle(center, pupilRadius * 2.4, coreGlow);

    // Solid pupil disc.
    final pupil = Paint()
      ..shader = RadialGradient(
        colors: [const Color(0xFF0B132B), accent.withValues(alpha: 0.9)],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: pupilRadius));
    canvas.drawCircle(center, pupilRadius, pupil);

    // Bright pupil rim.
    final rim = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawCircle(center, pupilRadius, rim);

    // Specular highlight (off-center) so it reads as a wet eye surface.
    final highlightPos =
        center + Offset(-pupilRadius * 0.35, -pupilRadius * 0.35);
    final highlight = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2);
    canvas.drawCircle(highlightPos, pupilRadius * 0.22, highlight);
  }

  @override
  bool shouldRepaint(_LogoPainter old) {
    return old.color != color ||
        old.accent != accent ||
        old.baseProgress != baseProgress ||
        old.showScanArc != showScanArc ||
        old.pupilPulse != pupilPulse;
  }
}

/// Immutable ring spec for the nerve-fibre arcs.
class _Ring {
  const _Ring({
    required this.radius,
    required this.segments,
    required this.sweep,
    required this.speed,
    required this.width,
  });

  final double radius;
  final int segments;
  final double sweep;
  final double speed;
  final double width;
}
