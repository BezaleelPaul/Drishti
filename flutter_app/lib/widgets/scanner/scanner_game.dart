import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'scanner_state.dart';

/// Floating dust/energy particle within the optical scanner.
class _ScannerParticle {
  double x;
  double y;
  double vx;
  double vy;
  double life;
  double maxLife;
  double size;
  double alpha;

  _ScannerParticle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
    required this.maxLife,
    required this.size,
    required this.alpha,
  });

  factory _ScannerParticle.random(math.Random rnd, double radius) {
    final angle = rnd.nextDouble() * 2 * math.pi;
    final dist = math.sqrt(rnd.nextDouble()) * radius;
    final speed = 8.0 + rnd.nextDouble() * 24.0;
    final maxLife = 1.5 + rnd.nextDouble() * 2.5;
    return _ScannerParticle(
      x: math.cos(angle) * dist,
      y: math.sin(angle) * dist,
      vx: -math.sin(angle) * speed * 0.4 + (rnd.nextDouble() - 0.5) * 5,
      vy: math.cos(angle) * speed * 0.4 + (rnd.nextDouble() - 0.5) * 5,
      life: rnd.nextDouble() * maxLife,
      maxLife: maxLife,
      size: 1.0 + rnd.nextDouble() * 2.2,
      alpha: 0.2 + rnd.nextDouble() * 0.7,
    );
  }

  void update(double dt, double radius, math.Random rnd, bool energized) {
    life += dt;
    if (life >= maxLife) {
      life = 0;
      final angle = rnd.nextDouble() * 2 * math.pi;
      final dist =
          (energized ? 0.2 + rnd.nextDouble() * 0.8 : rnd.nextDouble()) *
          radius;
      x = math.cos(angle) * dist;
      y = math.sin(angle) * dist;
      final speed = (energized ? 25.0 : 8.0) + rnd.nextDouble() * 15.0;
      vx = -math.sin(angle) * speed * 0.5 + (rnd.nextDouble() - 0.5) * 6;
      vy = math.cos(angle) * speed * 0.5 + (rnd.nextDouble() - 0.5) * 6;
    } else {
      x += vx * dt;
      y += vy * dt;
      // CONTAINMENT: keep every particle inside the scanner aperture. Without
      // this, particles drift past the ring and paint over the console
      // bands (the canvas clip in scanner_view.dart is the second line of
      // defence; this is the first).
      final dist = math.sqrt(x * x + y * y);
      final maxDist = radius * 1.12;
      if (dist > maxDist) {
        final k = maxDist / dist;
        x *= k;
        y *= k;
        // Reflect the velocity at the boundary so particles keep moving
        // instead of sticking to the edge.
        vx = -vx * 0.6;
        vy = -vy * 0.6;
      }
    }
  }
}

/// Flame-based Retinal Scanner Canvas Engine.
///
/// Draws concentric calibration rings, rotating segmented arcs, a scanning beam,
/// radial tick marks, floating energy particles, and real fundus imagery under HUD.
class ScannerGame extends FlameGame {
  ScannerAnimationState animationState = ScannerAnimationState.idle;
  double progress = 0.0;
  bool reduceMotion = false;
  ui.Image? fundusImage;

  double _anglePrimary = 0.0;
  double _angleSecondary = 0.0;
  double _beamAngle = 0.0;
  double _elapsed = 0.0;
  Vector2 _viewport = Vector2.zero();

  final math.Random _rnd = math.Random(42);
  final List<_ScannerParticle> _particles = [];
  static const int _particleCount = 36;

  @override
  Color backgroundColor() => const Color(0xFF0B132B);

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _viewport = size;
    _initParticlesIfNeeded();
  }

  void _initParticlesIfNeeded() {
    if (_particles.isEmpty && _viewport.x > 0 && _viewport.y > 0) {
      final radius = math.min(_viewport.x, _viewport.y) * 0.42;
      for (var i = 0; i < _particleCount; i++) {
        _particles.add(_ScannerParticle.random(_rnd, radius));
      }
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (reduceMotion) return;

    _elapsed += dt;

    final isActive = animationState.isActiveLoop;
    final isAnalyzing = animationState == ScannerAnimationState.analyzing;
    final isReview = animationState == ScannerAnimationState.reviewRequired;
    final isStopped =
        animationState == ScannerAnimationState.rejected ||
        animationState == ScannerAnimationState.error;

    if (!isStopped && !isReview) {
      final speedMult = isAnalyzing ? 1.4 : (isActive ? 1.0 : 0.4);
      _anglePrimary = (_anglePrimary + dt * 0.55 * speedMult) % (2 * math.pi);
      _angleSecondary =
          (_angleSecondary - dt * 0.35 * speedMult) % (2 * math.pi);
      _beamAngle = (_beamAngle + dt * 1.25 * speedMult) % (2 * math.pi);

      final radius = math.min(_viewport.x, _viewport.y) * 0.42;
      for (final p in _particles) {
        p.update(dt, radius, _rnd, isActive);
      }
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    final w = _viewport.x;
    final h = _viewport.y;
    if (w <= 0 || h <= 0) return;

    final center = Offset(w / 2, h / 2);
    final outerRadius = math.min(w, h) * 0.42;
    final stateColor = animationState.primaryColor;

    // 1. Fundus Image Backdrop (clipped circular aperture)
    if (fundusImage != null) {
      _renderFundusImage(canvas, center, outerRadius);
    } else {
      _renderApertureBackdrop(canvas, center, outerRadius);
    }

    // 2. Optical Grid & Crosshairs
    _renderReticles(canvas, center, outerRadius, stateColor);

    // 3. Radial Calibration Tick Marks
    _renderRadialTicks(canvas, center, outerRadius, stateColor);

    // 4. Concentric Scanner Rings
    _renderConcentricRings(canvas, center, outerRadius, stateColor);

    // 5. Active Scanning Beam (during active states)
    if (animationState == ScannerAnimationState.scanning ||
        animationState == ScannerAnimationState.qualityCheck ||
        animationState == ScannerAnimationState.analyzing) {
      _renderScanningBeam(canvas, center, outerRadius, stateColor);
    }

    // 6. Rotating Segmented Arcs
    _renderRotatingArcs(canvas, center, outerRadius, stateColor);

    // 7. Ambient / Energized Particle Dust
    _renderParticles(canvas, center, stateColor);

    // 8. Pulsing Retinal Target / Centre Glow
    _renderCenterTarget(canvas, center, outerRadius, stateColor);

    // 9. Status & Progress Ring
    if (progress > 0.0 && progress <= 1.0) {
      _renderProgressArc(canvas, center, outerRadius, stateColor);
    }
  }

  void _renderFundusImage(Canvas canvas, Offset center, double radius) {
    final img = fundusImage!;
    canvas.save();

    final clipPath = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius * 0.96));
    canvas.clipPath(clipPath);

    final srcRect = Rect.fromLTWH(
      0,
      0,
      img.width.toDouble(),
      img.height.toDouble(),
    );
    final dstRect = Rect.fromCircle(center: center, radius: radius * 0.96);

    canvas.drawImageRect(
      img,
      srcRect,
      dstRect,
      Paint()..filterQuality = FilterQuality.medium,
    );

    // Subtle dark vignette on the fundus perimeter to integrate with the HUD
    final vignettePaint = Paint()
      ..shader = ui.Gradient.radial(
        center,
        radius * 0.96,
        [Colors.transparent, const Color(0xAA0B132B)],
        [0.65, 1.0],
      );
    canvas.drawCircle(center, radius * 0.96, vignettePaint);

    canvas.restore();
  }

  void _renderApertureBackdrop(Canvas canvas, Offset center, double radius) {
    final bgPaint = Paint()
      ..shader = ui.Gradient.radial(center, radius, [
        const Color(0xFF132247),
        const Color(0xFF0B132B),
      ]);
    canvas.drawCircle(center, radius * 0.96, bgPaint);
  }

  void _renderReticles(
    Canvas canvas,
    Offset center,
    double radius,
    Color stateColor,
  ) {
    final gridPaint = Paint()
      ..color = stateColor.withValues(alpha: 0.15)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // Crosshairs with center gap
    const gap = 18.0;
    canvas.drawLine(
      Offset(center.dx - radius * 0.9, center.dy),
      Offset(center.dx - gap, center.dy),
      gridPaint,
    );
    canvas.drawLine(
      Offset(center.dx + gap, center.dy),
      Offset(center.dx + radius * 0.9, center.dy),
      gridPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius * 0.9),
      Offset(center.dx, center.dy - gap),
      gridPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy + gap),
      Offset(center.dx, center.dy + radius * 0.9),
      gridPaint,
    );
  }

  void _renderRadialTicks(
    Canvas canvas,
    Offset center,
    double radius,
    Color stateColor,
  ) {
    final tickPaint = Paint()
      ..color = stateColor.withValues(alpha: 0.4)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    const tickCount = 24;
    for (var i = 0; i < tickCount; i++) {
      final angle = (i * 2 * math.pi) / tickCount;
      final isMajor = i % 6 == 0;
      final inner = radius * (isMajor ? 0.90 : 0.93);
      final outer = radius * 0.96;

      final p1 = Offset(
        center.dx + math.cos(angle) * inner,
        center.dy + math.sin(angle) * inner,
      );
      final p2 = Offset(
        center.dx + math.cos(angle) * outer,
        center.dy + math.sin(angle) * outer,
      );

      tickPaint.strokeWidth = isMajor ? 2.0 : 1.0;
      tickPaint.color = stateColor.withValues(alpha: isMajor ? 0.75 : 0.35);
      canvas.drawLine(p1, p2, tickPaint);
    }
  }

  void _renderConcentricRings(
    Canvas canvas,
    Offset center,
    double radius,
    Color stateColor,
  ) {
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    for (var i = 1; i <= 4; i++) {
      final r = radius * (i / 4.0);
      final alpha = 0.15 + (i * 0.12);
      ringPaint.color = stateColor.withValues(alpha: alpha);
      canvas.drawCircle(center, r, ringPaint);
    }
  }

  void _renderScanningBeam(
    Canvas canvas,
    Offset center,
    double radius,
    Color stateColor,
  ) {
    final beamRect = Rect.fromCircle(center: center, radius: radius * 0.95);
    final sweepPaint = Paint()
      ..shader = ui.Gradient.sweep(
        center,
        [stateColor.withValues(alpha: 0.0), stateColor.withValues(alpha: 0.28)],
        [0.75, 1.0],
        TileMode.clamp,
        _beamAngle - math.pi * 0.35,
        _beamAngle,
      );

    canvas.drawArc(
      beamRect,
      _beamAngle - math.pi * 0.35,
      math.pi * 0.35,
      true,
      sweepPaint,
    );

    // Leading sharp laser ray
    final rayPaint = Paint()
      ..color = stateColor.withValues(alpha: 0.85)
      ..strokeWidth = 1.8;
    final edgePoint = Offset(
      center.dx + math.cos(_beamAngle) * radius * 0.95,
      center.dy + math.sin(_beamAngle) * radius * 0.95,
    );
    canvas.drawLine(center, edgePoint, rayPaint);
  }

  void _renderRotatingArcs(
    Canvas canvas,
    Offset center,
    double radius,
    Color stateColor,
  ) {
    final outerRect = Rect.fromCircle(center: center, radius: radius * 0.98);
    final innerRect = Rect.fromCircle(center: center, radius: radius * 0.68);

    // Outer primary arc
    final outerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..color = stateColor.withValues(alpha: 0.9);

    canvas.drawArc(outerRect, _anglePrimary, math.pi * 0.65, false, outerPaint);
    canvas.drawArc(
      outerRect,
      _anglePrimary + math.pi,
      math.pi * 0.35,
      false,
      outerPaint,
    );

    // Inner counter-rotating segmented arc
    final innerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..color = stateColor.withValues(alpha: 0.65);

    canvas.drawArc(
      innerRect,
      _angleSecondary,
      math.pi * 0.45,
      false,
      innerPaint,
    );
    canvas.drawArc(
      innerRect,
      _angleSecondary + math.pi * 0.75,
      math.pi * 0.25,
      false,
      innerPaint,
    );
  }

  void _renderParticles(Canvas canvas, Offset center, Color stateColor) {
    final particlePaint = Paint()..style = PaintingStyle.fill;

    for (final p in _particles) {
      final pos = Offset(center.dx + p.x, center.dy + p.y);
      particlePaint.color = stateColor.withValues(alpha: p.alpha * 0.6);
      canvas.drawCircle(pos, p.size, particlePaint);
    }
  }

  void _renderCenterTarget(
    Canvas canvas,
    Offset center,
    double radius,
    Color stateColor,
  ) {
    final pulse = 1.0 + 0.10 * math.sin(_elapsed * 2.8);

    // Outer glow halo
    canvas.drawCircle(
      center,
      radius * 0.12 * pulse,
      Paint()
        ..color = stateColor.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    // Core target pip
    canvas.drawCircle(
      center,
      radius * 0.05 * pulse,
      Paint()..color = stateColor.withValues(alpha: 0.95),
    );
  }

  void _renderProgressArc(
    Canvas canvas,
    Offset center,
    double radius,
    Color stateColor,
  ) {
    final progressRect = Rect.fromCircle(center: center, radius: radius * 1.03);
    final progressPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF10B981);

    canvas.drawArc(
      progressRect,
      -math.pi / 2,
      2 * math.pi * progress.clamp(0.0, 1.0),
      false,
      progressPaint,
    );
  }
}
