import 'package:flutter/material.dart';
import '../l10n/lang_scope.dart';
import '../theme/figma_theme.dart';

/// Figma `WorkflowBar`: 5 connected step dots
/// (Patient → Image → AI → Specialist → Report).
class WorkflowBar extends StatelessWidget {
  /// 1-based active step.
  final int step;

  /// Renders light-on-dark colors for midnight-navy orbit screens.
  /// Defaults to false so existing light screens are unchanged.
  final bool dark;

  const WorkflowBar({super.key, required this.step, this.dark = false});

  static const _keys = [
    'wf_patient',
    'wf_image',
    'wf_ai',
    'wf_specialist',
    'wf_report',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF101932) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: dark ? const Color(0xFF1E2D4A) : FigmaColors.border,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _keys.length; i++) ...[
            Expanded(
              flex: 2,
              child: _dot(context, i + 1, context.tr(_keys[i])),
            ),
            if (i < _keys.length - 1)
              Expanded(
                flex: 1,
                child: Container(
                  height: 3,
                  margin: const EdgeInsets.only(bottom: 22, left: 2, right: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: (i + 1) < step
                        ? const Color(0xFF10B981)
                        : dark
                        ? const Color(0xFF1E2D4A)
                        : FigmaColors.border,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _dot(BuildContext context, int index, String label) {
    final done = index < step;
    final active = index == step;

    final Color dotBg;
    final List<BoxShadow>? shadows;
    final Border? border;

    if (done) {
      dotBg = const Color(0xFF10B981);
      shadows = [
        const BoxShadow(
          color: Color(0x4010B981),
          blurRadius: 8,
          spreadRadius: 1,
        ),
      ];
      border = null;
    } else if (active) {
      dotBg = const Color(0xFF00B4D8);
      shadows = [
        const BoxShadow(
          color: Color(0x5500B4D8),
          blurRadius: 10,
          spreadRadius: 2,
        ),
      ];
      border = Border.all(color: const Color(0xFF7DF9FF), width: 1.5);
    } else {
      dotBg = dark ? const Color(0xFF141E36) : const Color(0xFFF1F5F9);
      shadows = null;
      border = Border.all(
        color: dark ? const Color(0xFF223254) : const Color(0xFFCBD5E1),
        width: 1,
      );
    }

    final fg = (done || active)
        ? Colors.white
        : dark
        ? const Color(0xFF94A3B8)
        : FigmaColors.faint;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: dotBg,
            shape: BoxShape.circle,
            border: border,
            boxShadow: shadows,
          ),
          child: Center(
            child: done
                ? const Icon(Icons.check, size: 15, color: Colors.white)
                : Text(
                    '$index',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: fg,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 0.2,
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: active
                ? (dark ? const Color(0xFF7DF9FF) : FigmaColors.primaryDark)
                : done
                ? const Color(0xFF10B981)
                : dark
                ? const Color(0xFF94A3B8)
                : FigmaColors.faint,
          ),
        ),
      ],
    );
  }
}
