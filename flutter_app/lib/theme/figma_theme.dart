import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'design_system.dart';

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
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    colorScheme: ColorScheme.fromSeed(
      seedColor: FigmaColors.primary,
      brightness: Brightness.dark,
      primary: DrsTokens.accent,
      onPrimary: const Color(0xFF06232D),
      secondary: const Color(0xFF18D6C7),
      surface: DrsTokens.background,
      onSurface: DrsTokens.textPrimary,
      error: DrsTokens.danger,
      outline: DrsTokens.border,
      outlineVariant: DrsTokens.borderStrong,
      surfaceContainerHighest: DrsTokens.surfaceElevated,
    ),
    scaffoldBackgroundColor: DrsTokens.background,
  );

  return base.copyWith(
    textTheme: GoogleFonts.plusJakartaSansTextTheme(base.textTheme).apply(
      bodyColor: DrsTokens.textSecondary,
      displayColor: DrsTokens.textPrimary,
    ),
    canvasColor: DrsTokens.background,
    dialogTheme: DialogThemeData(
      backgroundColor: DrsTokens.surface,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: DrsTokens.border),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: DrsTokens.surfaceElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DrsTokens.border),
      ),
      textStyle: const TextStyle(color: DrsTokens.textSecondary, fontSize: 12),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Color(0xFF0F172A)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: DrsTokens.surfaceElevated,
      elevation: 8,
      contentTextStyle: const TextStyle(
        color: DrsTokens.textPrimary,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: DrsTokens.borderStrong),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: DrsTokens.accent,
      circularTrackColor: DrsTokens.border,
      linearTrackColor: DrsTokens.border,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: DrsTokens.accent,
      selectionColor: Color(0x5522C7E6),
      selectionHandleColor: DrsTokens.accent,
    ),
    iconTheme: const IconThemeData(color: DrsTokens.textMuted, size: 20),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF243350),
      thickness: 1,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: const Color(0xFF0F172A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF223254)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: DrsTokens.surface,
      foregroundColor: DrsTokens.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 18,
        letterSpacing: -0.2,
        color: DrsTokens.textPrimary,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 70,
      elevation: 0,
      backgroundColor: DrsTokens.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: DrsTokens.accent.withValues(alpha: 0.14),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return IconThemeData(
          size: 21,
          color: states.contains(WidgetState.selected)
              ? DrsTokens.accent
              : DrsTokens.textMuted,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        return TextStyle(
          fontSize: 10,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? DrsTokens.accent
              : DrsTokens.textMuted,
        );
      }),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(
        DrsTokens.textSubtle.withValues(alpha: 0.45),
      ),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(6),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: DrsTokens.accent,
        foregroundColor: const Color(0xFF06232D),
        disabledBackgroundColor: DrsTokens.surfaceElevated,
        disabledForegroundColor: DrsTokens.textSubtle,
        elevation: 0,
        shadowColor: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14,
          height: 1.2,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: DrsTokens.accent,
        side: const BorderSide(color: DrsTokens.borderStrong),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: DrsTokens.accent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
    ),
    listTileTheme: ListTileThemeData(
      textColor: DrsTokens.textSecondary,
      iconColor: DrsTokens.textMuted,
      tileColor: DrsTokens.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: DrsTokens.surface,
      selectedColor: DrsTokens.accent.withValues(alpha: 0.18),
      labelStyle: const TextStyle(
        color: DrsTokens.textSecondary,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: const BorderSide(color: DrsTokens.border),
    ),
    cardTheme: CardThemeData(
      color: DrsTokens.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: DrsTokens.border, width: 1),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DrsTokens.surfaceMuted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DrsTokens.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DrsTokens.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DrsTokens.accent, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DrsTokens.danger, width: 1.4),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DrsTokens.danger, width: 1.6),
      ),
      labelStyle: const TextStyle(
        color: DrsTokens.textMuted,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
      hintStyle: const TextStyle(color: DrsTokens.textSubtle, fontSize: 13),
      errorStyle: const TextStyle(color: DrsTokens.danger, fontSize: 11),
    ),
  );
}
