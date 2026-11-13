import 'package:flutter/material.dart';

import '../scanner/scanner_theme.dart';

/// Thin-outline monospace pill for provenance/limitation markers
/// (e.g. PRELIMINARY, OFFLINE) on orbit screens.
class OrbitChip extends StatelessWidget {
  const OrbitChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface.withValues(alpha: 0.85),
        border: Border.all(color: color.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: ScannerHUDTheme.hudMonoStyle.copyWith(
          color: color,
          fontSize: 10,
        ),
      ),
    );
  }
}
