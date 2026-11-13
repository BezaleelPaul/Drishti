import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// "Glassmorphic Console" surface primitives for the clinical HUD.
///
/// DESIGN LANGUAGE
/// - Base tint: brand slate `#020617` at an opacity-mapped alpha, so the
///   panel reads as smoked glass over the live canvas instead of an opaque
///   box (the Flame layer stays visible through the console).
/// - Depth: a real `BackdropFilter` blur (sigma 16.0 by default) so the
///   canvas behind the panel is genuinely refracted, not simulated.
/// - Edge: a thin, high-contrast micro-border in the scanning-laser accent
///   `#00FFCC` (plus a hairline white at very low alpha) so the panel edge
///   stays legible on both dark and light clinician themes.
/// - Text: every label carries an explicit `maxLines` + `TextOverflow.fade`
///   so a long clinical string can never push the console out of its
///   fixed-height track.
///
/// PERFORMANCE: each `BackdropFilter` is a saveLayer. Keep instances per
/// screen small (the HUD uses exactly two: header + telemetry footer) and
/// disable the blur where motion/accessibility is reduced (see
/// `blurEnabled`) — a clipped, unblurred glass surface is far cheaper.
class GlassConsolePanel extends StatelessWidget {
  const GlassConsolePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.borderRadius = 12,
    this.baseColor = const Color(0xFF020617),
    this.baseOpacity = 0.55,
    this.accentColor = const Color(0xFF00FFCC),
    this.accentOpacity = 0.34,
    this.borderWidth = 1.0,
    this.blurSigma = 16.0,
    this.blurEnabled = true,
    this.alignment = Alignment.centerLeft,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  /// Brand slate used as the smoked-glass base tint.
  final Color baseColor;
  final double baseOpacity;

  /// Scanning-laser accent used for the micro-border and focus ring.
  final Color accentColor;
  final double accentOpacity;
  final double borderWidth;

  /// Depth blur sigma applied to the backdrop.
  final double blurSigma;
  final bool blurEnabled;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: blurEnabled ? blurSigma : 0,
          sigmaY: blurEnabled ? blurSigma : 0,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: baseColor.withValues(alpha: baseOpacity),
            borderRadius: radius,
            border: Border.all(
              color: accentColor.withValues(alpha: accentOpacity),
              width: borderWidth,
            ),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Console label: fixed single line, fades instead of wrapping or
/// overflowing its track. Use for status, telemetry and provenance text
/// inside [GlassConsolePanel]s.
class GlassConsoleLabel extends StatelessWidget {
  const GlassConsoleLabel(
    this.text, {
    super.key,
    this.color = const Color(0xFFE2E8F0),
    this.fontSize = 10,
    this.fontWeight = FontWeight.w700,
    this.letterSpacing = 0.6,
    this.maxLines = 1,
    this.textAlign = TextAlign.left,
    this.family,
  });

  final String text;
  final Color color;
  final double fontSize;
  final FontWeight fontWeight;
  final double letterSpacing;
  final int maxLines;
  final TextAlign textAlign;
  final String? family;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.fade,
      softWrap: false,
      textAlign: textAlign,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        letterSpacing: letterSpacing,
        fontFamily: family,
        height: 1.1,
      ),
    );
  }
}

/// Small accent dot used as the "engine live" indicator in console headers.
class GlassConsolePulse extends StatefulWidget {
  const GlassConsolePulse({
    super.key,
    this.color = const Color(0xFF00FFCC),
    this.size = 6,
  });

  final Color color;
  final double size;

  @override
  State<GlassConsolePulse> createState() => _GlassConsolePulseState();
}

class _GlassConsolePulseState extends State<GlassConsolePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color.withValues(alpha: 0.45 + (0.55 * t)),
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.28 * t),
                blurRadius: 6 + (6 * t),
                spreadRadius: 0.5 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}
