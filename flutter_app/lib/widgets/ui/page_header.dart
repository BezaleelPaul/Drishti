import 'package:flutter/material.dart';

import '../../theme/design_system.dart';

/// Screen title block with optional eyebrow, subtitle and trailing action.
class PageHeader extends StatelessWidget {
  const PageHeader({
    required this.title,
    required this.subtitle,
    this.eyebrow,
    this.trailing,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget? eyebrow;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (eyebrow != null) ...[eyebrow!, const SizedBox(height: 8)],
        Semantics(
          header: true,
          child: Text(
            title,
            style: const TextStyle(
              color: DrsTokens.textPrimary,
              fontSize: 25,
              height: 1.15,
              letterSpacing: -0.4,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(
            color: DrsTokens.textMuted,
            fontSize: 13,
            height: 1.4,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );

    if (trailing == null) return content;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: content),
        const SizedBox(width: 16),
        trailing!,
      ],
    );
  }
}
