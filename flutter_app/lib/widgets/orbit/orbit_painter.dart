import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Paints the orbital rings, orbiting markers and the scanner arc.
///
/// Pure visual: receives a normalized animation value and state color only.
/// Under reduced motion the painter renders one static frame (no rotation).
class OrbitPainter extends CustomPainter {
  const OrbitPainter({
    required this.animationValue,
    required this.stateColor,
    required this.reducedMotion,
  });

  /// 0..1 loop position driving all rotation phases.
  final double animationValue;

  /// Accent color for the active state.
  final Color stateColor;

  /// When true, renders a single static frame with no rotation or sweep.
  final bool reducedMotion;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;
    final phase = reducedMotion ? 0.0 : animationValue * 2 * math.pi;

    _drawGrid(canvas, center, radius);
    _drawOuterRing(canvas, center, radius, phase);
    _drawMiddleRing(canvas, center, radius, phase);
    _drawInnerRing(canvas, center, radius, phase);
    _drawScannerArc(canvas, center, radius, phase);
    _drawOrbitingMarkers(canvas, center, radius, phase);
  }

  void _drawGrid(Canvas canvas, Offset center, double radius) {
    final paint = Paint()
      ..color = const Color(0x2200B4D8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (final f in const [0.35, 0.55, 0.75, 0.95]) {
      canvas.drawCircle(center, radius * f, paint);
    }
  }

  void _drawOuterRing(
    Canvas canvas,
    Offset center,
    double radius,
    double phase,
  ) {
    final r = radius * 0.92;
    final paint = Paint()
      ..color = stateColor.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    // Counter-clockwise rotation.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      -phase,
      math.pi * 1.55,
      false,
      paint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      -phase + math.pi * 1.7,
      math.pi * 0.2,
      false,
      paint,
    );
  }

  void _drawMiddleRing(
    Canvas canvas,
    Offset center,
    double radius,
    double phase,
  ) {
    final r = radius * 0.74;
    final paint = Paint()
      ..color = stateColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    // Clockwise rotation at a different speed.
    final p2 = phase * 1.6;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      p2,
      math.pi * 1.3,
      false,
      paint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      p2 + math.pi * 1.45,
      math.pi * 0.35,
      false,
      paint,
    );
  }

  void _drawInnerRing(
    Canvas canvas,
    Offset center,
    double radius,
    double phase,
  ) {
    final r = radius * 0.56;
    final paint = Paint()
      ..color = stateColor.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // Counter-clockwise again, slower than the outer ring.
    canvas.drawCircle(center, r, paint);
    final tick = Paint()
      ..color = stateColor.withValues(alpha: 0.5)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 12; i++) {
      final a = phase * 0.5 + i * math.pi / 6;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(center + dir * (r - 5), center + dir * (r + 5), tick);
    }
  }

  void _drawScannerArc(
    Canvas canvas,
    Offset center,
    double radius,
    double phase,
  ) {
    if (reducedMotion) {
      // Static arc at top position when motion is reduced.
      final r = radius * 0.83;
      final paint = Paint()
        ..color = stateColor.withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        -math.pi / 2,
        math.pi / 5,
        false,
        paint,
      );
      return;
    }
    final r = radius * 0.83;
    final paint = Paint()
      ..color = stateColor.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      phase * 2.2 - math.pi / 2,
      math.pi / 5,
      false,
      paint,
    );
  }

  void _drawOrbitingMarkers(
    Canvas canvas,
    Offset center,
    double radius,
    double phase,
  ) {
    final markerPaint = Paint()..color = stateColor;
    final haloPaint = Paint()..color = stateColor.withValues(alpha: 0.2);

    // Three markers on the outer orbit, evenly spaced, moving with the ring.
    for (var i = 0; i < 3; i++) {
      final a = -phase + i * 2 * math.pi / 3;
      final pos = center + Offset(math.cos(a), math.sin(a)) * radius * 0.92;
      canvas.drawCircle(pos, 7, haloPaint);
      canvas.drawCircle(pos, 3, markerPaint);
    }

    // One slower marker on the middle ring, opposite direction.
    final a2 = phase * 1.6 + math.pi;
    final pos2 = center + Offset(math.cos(a2), math.sin(a2)) * radius * 0.74;
    canvas.drawCircle(pos2, 6, haloPaint);
    canvas.drawCircle(pos2, 2.5, markerPaint);
  }

  @override
  bool shouldRepaint(covariant OrbitPainter oldDelegate) =>
      oldDelegate.animationValue != animationValue ||
      oldDelegate.stateColor != stateColor ||
      oldDelegate.reducedMotion != reducedMotion;
}
