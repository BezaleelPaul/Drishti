import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../scanner/scanner_theme.dart';

/// Holographic futuristic loading overlay with sweeping radar, glowing reticle, and telemetry metrics.
class FuturisticLoadingOverlay extends StatefulWidget {
  final String message;
  final String? subMessage;
  final double? progress;
  final VoidCallback? onCancel;

  const FuturisticLoadingOverlay({
    super.key,
    required this.message,
    this.subMessage,
    this.progress,
    this.onCancel,
  });

  static Future<T?> show<T>({
    required BuildContext context,
    required String message,
    String? subMessage,
    double? progress,
  }) {
    return showDialog<T>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      builder: (ctx) => Center(
        child: Material(
          color: Colors.transparent,
          child: FuturisticLoadingOverlay(
            message: message,
            subMessage: subMessage,
            progress: progress,
          ),
        ),
      ),
    );
  }

  @override
  State<FuturisticLoadingOverlay> createState() =>
      _FuturisticLoadingOverlayState();
}

class _FuturisticLoadingOverlayState extends State<FuturisticLoadingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _radarController;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _radarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 290,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF0B132B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.2),
            blurRadius: 24,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Animated Holographic Radar Pip
          SizedBox(
            width: 80,
            height: 80,
            child: AnimatedBuilder(
              animation: _radarController,
              builder: (context, _) {
                return CustomPaint(
                  painter: _RadarSweepPainter(
                    angle: _radarController.value * 2 * math.pi,
                    color: ScannerHUDTheme.neonCyan,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 18),

          // Message
          Text(
            widget.message.toUpperCase(),
            textAlign: TextAlign.center,
            style: ScannerHUDTheme.hudMonoStyle.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 1.1,
            ),
          ),
          if (widget.subMessage != null) ...[
            const SizedBox(height: 6),
            Text(
              widget.subMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.white60),
            ),
          ],
          const SizedBox(height: 14),

          // Progress Indicator
          if (widget.progress != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: widget.progress,
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  ScannerHUDTheme.neonCyan,
                ),
                minHeight: 5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${(widget.progress! * 100).toInt()}%',
              style: ScannerHUDTheme.hudMonoStyle.copyWith(
                fontSize: 10,
                color: ScannerHUDTheme.neonCyan,
              ),
            ),
          ] else
            const SizedBox(
              width: 120,
              child: LinearProgressIndicator(
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(
                  ScannerHUDTheme.neonCyan,
                ),
                minHeight: 3,
              ),
            ),

          if (widget.onCancel != null) ...[
            const SizedBox(height: 14),
            TextButton(
              onPressed: widget.onCancel,
              child: const Text(
                'ABORT',
                style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RadarSweepPainter extends CustomPainter {
  final double angle;
  final Color color;

  _RadarSweepPainter({required this.angle, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Rings
    final ringPaint = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawCircle(center, radius * 0.4, ringPaint);
    canvas.drawCircle(center, radius * 0.7, ringPaint);
    canvas.drawCircle(center, radius * 0.95, ringPaint);

    // Crosshairs
    canvas.drawLine(
      Offset(center.dx - radius * 0.95, center.dy),
      Offset(center.dx + radius * 0.95, center.dy),
      ringPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius * 0.95),
      Offset(center.dx, center.dy + radius * 0.95),
      ringPaint,
    );

    // Sweeping beam
    final beamRect = Rect.fromCircle(center: center, radius: radius * 0.95);
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        colors: [color.withValues(alpha: 0.0), color.withValues(alpha: 0.35)],
        stops: const [0.75, 1.0],
        transform: GradientRotation(angle - math.pi * 0.35),
      ).createShader(beamRect);

    canvas.drawArc(
      beamRect,
      angle - math.pi * 0.35,
      math.pi * 0.35,
      true,
      sweepPaint,
    );

    // Leading ray
    final rayPaint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 1.8;
    canvas.drawLine(
      center,
      Offset(
        center.dx + math.cos(angle) * radius * 0.95,
        center.dy + math.sin(angle) * radius * 0.95,
      ),
      rayPaint,
    );

    // Center pulse dot
    canvas.drawCircle(center, 3.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _RadarSweepPainter oldDelegate) =>
      oldDelegate.angle != angle;
}
