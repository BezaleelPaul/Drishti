import 'package:flutter/material.dart';
import '../scanner/scanner_theme.dart';

/// Futuristic glassmorphism card with cyber corner reticles and neon border accents.
class FuturisticGlassCard extends StatelessWidget {
  final Widget child;
  final String? title;
  final Widget? trailing;
  final Color borderColor;
  final Color backgroundColor;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final bool showCornerReticles;

  const FuturisticGlassCard({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.borderColor = ScannerHUDTheme.primaryCyan,
    this.backgroundColor = const Color(0xFF0F172A),
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = 14,
    this.showCornerReticles = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: borderColor.withValues(alpha: 0.35),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: borderColor.withValues(alpha: 0.08),
            blurRadius: 18,
            spreadRadius: 1,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // Corner Reticles
          if (showCornerReticles) ...[
            Positioned(
              top: 4,
              left: 4,
              child: _CornerTick(turns: 0, color: borderColor),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: _CornerTick(turns: 1, color: borderColor),
            ),
            Positioned(
              bottom: 4,
              right: 4,
              child: _CornerTick(turns: 2, color: borderColor),
            ),
            Positioned(
              bottom: 4,
              left: 4,
              child: _CornerTick(turns: 3, color: borderColor),
            ),
          ],

          // Card Body
          Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null || trailing != null) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (title != null)
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: borderColor,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              title!.toUpperCase(),
                              style: ScannerHUDTheme.hudMonoStyle.copyWith(
                                color: borderColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ?trailing,
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CornerTick extends StatelessWidget {
  final int turns;
  final Color color;

  const _CornerTick({required this.turns, required this.color});

  @override
  Widget build(BuildContext context) {
    return RotatedBox(
      quarterTurns: turns,
      child: CustomPaint(
        size: const Size(8, 8),
        painter: _CornerTickPainter(color: color),
      ),
    );
  }
}

class _CornerTickPainter extends CustomPainter {
  final Color color;

  _CornerTickPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
