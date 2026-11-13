import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../scanner/scanner_theme.dart';

/// Futuristic animated cyber button with interactive scale, neon glow, and light sweep.
class FuturisticGlowButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget? icon;
  final String label;
  final Color glowColor;
  final Color backgroundColor;
  final Color textColor;
  final bool isLoading;
  final bool enableContinuousShimmer;
  final double height;
  final double? width;
  final EdgeInsetsGeometry padding;

  const FuturisticGlowButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.glowColor = ScannerHUDTheme.neonCyan,
    this.backgroundColor = const Color(0xFF0F172A),
    this.textColor = Colors.white,
    this.isLoading = false,
    this.enableContinuousShimmer = false,
    this.height = 48,
    this.width,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  @override
  State<FuturisticGlowButton> createState() => _FuturisticGlowButtonState();
}

class _FuturisticGlowButtonState extends State<FuturisticGlowButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    if (widget.enableContinuousShimmer) {
      _animController.repeat();
    }
  }

  @override
  void didUpdateWidget(FuturisticGlowButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enableContinuousShimmer != oldWidget.enableContinuousShimmer) {
      if (widget.enableContinuousShimmer) {
        _animController.repeat();
      } else {
        _animController.stop();
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _triggerSweep() {
    if (!widget.enableContinuousShimmer) {
      _animController.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.isLoading;
    final scale = _isPressed ? 0.95 : 1.0;

    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      child: GestureDetector(
        onTapDown: enabled
            ? (_) {
                setState(() => _isPressed = true);
                _triggerSweep();
              }
            : null,
        onTapUp: enabled ? (_) => setState(() => _isPressed = false) : null,
        onTapCancel: enabled ? () => setState(() => _isPressed = false) : null,
        onTap: widget.onPressed,
        child: AnimatedBuilder(
          animation: _animController,
          builder: (context, child) {
            final sweepProgress = _animController.value;

            return Container(
              height: widget.height,
              width: widget.width,
              padding: widget.padding,
              decoration: BoxDecoration(
                color: widget.backgroundColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: widget.glowColor.withValues(
                    alpha: enabled ? 0.75 : 0.25,
                  ),
                  width: 1.5,
                ),
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: widget.glowColor.withValues(alpha: 0.25),
                          blurRadius: 14,
                          spreadRadius: 1,
                        ),
                        BoxShadow(
                          color: widget.glowColor.withValues(alpha: 0.12),
                          blurRadius: 28,
                          spreadRadius: 2,
                        ),
                      ]
                    : [],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Shimmer Light-Sweep
                  if (enabled && !widget.isLoading)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _ShimmerSweepPainter(
                          progress: sweepProgress,
                          color: widget.glowColor.withValues(alpha: 0.18),
                        ),
                      ),
                    ),

                  // Content
                  if (widget.isLoading)
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          widget.glowColor,
                        ),
                      ),
                    )
                  else
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (widget.icon != null) ...[
                          widget.icon!,
                          const SizedBox(width: 8),
                        ],
                        Text(
                          widget.label,
                          style: TextStyle(
                            color: widget.textColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ShimmerSweepPainter extends CustomPainter {
  final double progress;
  final Color color;

  _ShimmerSweepPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final startX = (size.width * 2.0 * progress) - size.width;
    final width = size.width * 0.45;

    final rect = Rect.fromLTWH(startX, 0, width, size.height);
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [Colors.transparent, color, Colors.transparent],
        transform: const GradientRotation(math.pi / 4),
      ).createShader(rect);

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _ShimmerSweepPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
