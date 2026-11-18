import 'package:flutter/material.dart';

/// Drishti visual language.
///
/// One place for the brand palette, elevation, radii and text colours used by
/// the clinical shell. The intent is a calm, high-contrast medical workstation:
/// near-navy canvas, layered surfaces, one cyan action colour, and colour used
/// only for clinical meaning (severity / sync / referral).
abstract final class DrsTokens {
  // Canvas & surfaces (kept in the same navy family as the original HUD).
  static const background = Color(0xFF0B132B);
  static const surface = Color(0xFF101A2E);
  static const surfaceElevated = Color(0xFF15213A);
  static const surfaceMuted = Color(0xFF0D1730);
  static const border = Color(0xFF223354);
  static const borderStrong = Color(0xFF35507A);

  // Brand and state accents.
  static const accent = Color(0xFF22C7E6);
  static const accentStrong = Color(0xFF00B4D8);
  static const accentSoft = Color(0xFF0E7490);
  static const neon = Color(0xFF7DF9FF);
  static const success = Color(0xFF34D399);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFFB7185);
  static const purple = Color(0xFFA78BFA);
  static const info = Color(0xFF7DD3FC);

  // Text ramp (WCAG-friendly on the navy canvas).
  static const textPrimary = Color(0xFFF8FAFC);
  static const textSecondary = Color(0xFFCBD5E1);
  static const textMuted = Color(0xFF94A3B8);
  static const textSubtle = Color(0xFF70839D);

  static const spacing = DrsSpacing._();
  static const radii = DrsRadii._();
  static const motion = DrsMotion._();

  static BoxShadow shadow(
    Color color, {
    double opacity = 0.18,
    double blur = 16,
  }) {
    return BoxShadow(
      color: color.withValues(alpha: opacity),
      blurRadius: blur,
      offset: const Offset(0, 4),
    );
  }

  static LinearGradient surfaceGradient({Color? accent}) {
    if (accent == null) {
      return const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [surfaceElevated, surfaceMuted],
      );
    }
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(accent.withValues(alpha: 0.09), surfaceElevated),
        surfaceMuted,
      ],
    );
  }
}

class DrsSpacing {
  const DrsSpacing._();
  double get xs => 4;
  double get sm => 8;
  double get md => 12;
  double get lg => 16;
  double get xl => 20;
  double get xxl => 24;
  double get section => 32;
}

class DrsRadii {
  const DrsRadii._();
  double get sm => 8;
  double get md => 12;
  double get lg => 16;
  double get xl => 20;
  double get pill => 999;

  BorderRadius get smRadius => BorderRadius.circular(sm);
  BorderRadius get mdRadius => BorderRadius.circular(md);
  BorderRadius get lgRadius => BorderRadius.circular(lg);
  BorderRadius get xlRadius => BorderRadius.circular(xl);
}

class DrsMotion {
  const DrsMotion._();
  Duration get fast => const Duration(milliseconds: 120);
  Duration get normal => const Duration(milliseconds: 200);
  Curve get ease => Curves.easeOutCubic;
}
