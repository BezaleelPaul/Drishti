import 'package:flutter/material.dart';

/// Clinical HUD visual design tokens for the Retinal Scanner.
abstract final class ScannerHUDTheme {
  static const background = Color(0xFF0B132B);
  static const darkSurface = Color(0xFF0F172A);
  static const primaryCyan = Color(0xFF00B4D8);
  static const neonCyan = Color(0xFF7DF9FF);
  static const deepTeal = Color(0xFF0077B6);
  static const gridLine = Color(0x2200B4D8);
  static const reticle = Color(0x667DF9FF);

  static const success = Color(0xFF10B981);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);
  static const purple = Color(0xFFA855F7);

  static const hudMonoStyle = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11,
    letterSpacing: 1.2,
    fontWeight: FontWeight.w600,
    color: Color(0xFF7DF9FF),
  );

  static const hudTitleStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.8,
    color: Colors.white,
  );
}
