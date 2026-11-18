import 'package:flutter/material.dart';
import '../l10n/lang_scope.dart';
import '../theme/design_system.dart';
import '../theme/figma_theme.dart';

/// Figma `StatusBadge`: rounded pill, localized label, Figma colors.
class StatusBadge extends StatelessWidget {
  final FigmaStatus status;

  const StatusBadge({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = _colors(status);
    final label = context.tr(status.labelKey);
    return Semantics(
      label: 'Status: $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border.withValues(alpha: 0.65)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(shape: BoxShape.circle, color: fg),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                  height: 1.2,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static (Color, Color, Color) _colors(FigmaStatus s) {
    switch (s) {
      case FigmaStatus.awaitingAi:
        return (
          const Color(0xFF292313),
          DrsTokens.warning,
          const Color(0xFFFBBF24),
        );
      case FigmaStatus.aiComplete:
        return (
          const Color(0xFF12243B),
          DrsTokens.info,
          const Color(0xFF93C5FD),
        );
      case FigmaStatus.awaitingSpecialist:
        return (
          const Color(0xFF251A36),
          DrsTokens.purple,
          const Color(0xFFC4B5FD),
        );
      case FigmaStatus.verified:
        return (
          const Color(0xFF102A24),
          DrsTokens.success,
          const Color(0xFF6EE7B7),
        );
      case FigmaStatus.referral:
        return (
          const Color(0xFF321B27),
          DrsTokens.danger,
          const Color(0xFFFDA4AF),
        );
      case FigmaStatus.offline:
        return (
          DrsTokens.surfaceElevated,
          DrsTokens.borderStrong,
          DrsTokens.textMuted,
        );
      case FigmaStatus.rejected:
        return (
          const Color(0xFF332016),
          const Color(0xFFFB923C),
          const Color(0xFFFDBA74),
        );
    }
  }
}
