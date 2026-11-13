import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens lifted from "Enhance Drishti-AI Prototype (1)"
/// (React + Tailwind): cyan primary, slate surfaces, Nunito type.
abstract final class FigmaColors {
  static const primary = Color(0xFF0891B2); // cyan-600
  static const primaryDark = Color(0xFF0E7490); // cyan-700
  static const primarySoft = Color(0xFFECFEFF); // cyan-50
  static const primaryBorder = Color(0xFFA5F3FC); // cyan-200
  static const surface = Color(0xFFF8FAFC); // slate-50
  static const card = Colors.white;
  static const border = Color(0xFFE2E8F0); // slate-200
  static const text = Color(0xFF0F172A); // slate-900
  static const muted = Color(0xFF64748B); // slate-500
  static const faint = Color(0xFF94A3B8); // slate-400
  static const success = Color(0xFF16A34A); // green-600
  static const warning = Color(0xFFD97706); // amber-600
  static const danger = Color(0xFFDC2626); // red-600
  static const purple = Color(0xFF7E22CE); // purple-700
  static const info = Color(0xFF1D4ED8); // blue-700
}

/// Figma `StatusBadgeType` mapped to pill colors + label keys.
enum FigmaStatus {
  awaitingAi(
    'badge_awaiting_ai',
    Color(0xFFFFFBEB),
    Color(0xFFB45309),
    Color(0xFFFDE68C),
  ),
  aiComplete(
    'badge_ai_complete',
    Color(0xFFEFF6FF),
    Color(0xFF1D4ED8),
    Color(0xFFBFDBFE),
  ),
  awaitingSpecialist(
    'badge_awaiting_specialist',
    Color(0xFFFAF5FF),
    Color(0xFF7E22CE),
    Color(0xFFE9D5FF),
  ),
  verified(
    'badge_verified',
    Color(0xFFF0FDF4),
    Color(0xFF15803D),
    Color(0xFFBBF7D0),
  ),
  referral(
    'badge_referral',
    Color(0xFFFEF2F2),
    Color(0xFFB91C1C),
    Color(0xFFFECACA),
  ),
  offline(
    'badge_offline',
    Color(0xFFF8FAFC),
    Color(0xFF475569),
    Color(0xFFE2E8F0),
  ),
  rejected(
    'badge_rejected',
    Color(0xFFFFF7ED),
    Color(0xFFC2410C),
    Color(0xFFFED7AA),
  );

  final String labelKey;
  final Color bg;
  final Color fg;
  final Color border;

  const FigmaStatus(this.labelKey, this.bg, this.fg, this.border);
}

/// Global app theme: Figma primary/buttons/cards/inputs, Nunito type.
/// The chrome is DARK (HUD shell): every screen paints its own dark
/// background, so route-transition gaps must be dark too — a light canvas
/// flashed between screens during navigation.
ThemeData buildFigmaTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: FigmaColors.primary,
      brightness: Brightness.dark,
      primary: const Color(0xFF00B4D8),
      secondary: const Color(0xFF18D6C7),
      surface: const Color(0xFF0B132B),
    ),
    scaffoldBackgroundColor: const Color(0xFF0B132B),
  );

  return base.copyWith(
    textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme),
    canvasColor: const Color(0xFF0B132B),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(0xFF0F172A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: Color(0xFF1E293B)),
      ),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Color(0xFF0F172A)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1E293B),
      contentTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: Color(0xFF334155)),
      ),
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFF243350), thickness: 1),
    popupMenuTheme: PopupMenuThemeData(
      color: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF223254)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0F172A),
      foregroundColor: Color(0xFF7DF9FF),
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontWeight: FontWeight.w800,
        fontSize: 18,
        letterSpacing: 0.2,
        color: Colors.white,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF00B4D8),
        foregroundColor: Colors.white,
        elevation: 2,
        shadowColor: const Color(0x5500B4D8),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    cardTheme: CardThemeData(
      color: const Color(0xFF101932),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF1E2D4A), width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF101A33),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF223254)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF223254)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF00B4D8), width: 1.8),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
      ),
      labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
      hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 14),
    ),
  );
}
