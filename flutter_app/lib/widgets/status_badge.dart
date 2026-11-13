import 'package:flutter/material.dart';
import '../l10n/lang_scope.dart';
import '../theme/figma_theme.dart';

/// Figma `StatusBadge`: rounded pill, localized label, Figma colors.
class StatusBadge extends StatelessWidget {
  final FigmaStatus status;

  const StatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = _colors(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border, width: 1),
        boxShadow: [
          BoxShadow(
            color: fg.withValues(alpha: 0.1),
            blurRadius: 6,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fg,
              boxShadow: [
                BoxShadow(
                  color: fg.withValues(alpha: 0.6),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            context.tr(status.labelKey),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  static (Color, Color, Color) _colors(FigmaStatus s) {
    switch (s) {
      case FigmaStatus.awaitingAi:
        return (const Color(0xFF2E2005), const Color(0xFFD97706), const Color(0xFFFBBF24));
      case FigmaStatus.aiComplete:
        return (const Color(0xFF0F224A), const Color(0xFF2563EB), const Color(0xFF60A5FA));
      case FigmaStatus.awaitingSpecialist:
        return (const Color(0xFF2B1242), const Color(0xFF9333EA), const Color(0xFFC084FC));
      case FigmaStatus.verified:
        return (const Color(0xFF072B1A), const Color(0xFF16A34A), const Color(0xFF4ADE80));
      case FigmaStatus.referral:
        return (const Color(0xFF381014), const Color(0xFFDC2626), const Color(0xFFF87171));
      case FigmaStatus.offline:
        return (const Color(0xFF1E293B), const Color(0xFF475569), const Color(0xFF94A3B8));
      case FigmaStatus.rejected:
        return (const Color(0xFF3B1A08), const Color(0xFFEA580C), const Color(0xFFFB923C));
    }
  }
}
