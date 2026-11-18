import 'package:flutter/material.dart';

import '../../theme/design_system.dart';

/// Layered clinical surface with desktop hover, keyboard focus and screen
/// reader semantics. Replaces one-off card decorations with a consistent
/// radius, border, elevation and interaction treatment.
class ClinicalSurface extends StatefulWidget {
  const ClinicalSurface({
    required this.child,
    this.onTap,
    this.semanticLabel,
    this.padding = const EdgeInsets.all(16),
    this.accent,
    this.borderColor,
    this.gradient,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final EdgeInsetsGeometry padding;
  final Color? accent;
  final Color? borderColor;
  final Gradient? gradient;

  @override
  State<ClinicalSurface> createState() => _ClinicalSurfaceState();
}

class _ClinicalSurfaceState extends State<ClinicalSurface> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final interactive = widget.onTap != null;
    final highlighted = interactive && (_hovered || _focused);
    final borderColor =
        widget.borderColor ??
        (highlighted
            ? (accent ?? DrsTokens.accent).withValues(alpha: 0.65)
            : DrsTokens.border);

    Widget surface = AnimatedContainer(
      duration: DrsTokens.motion.normal,
      curve: DrsTokens.motion.ease,
      padding: widget.padding,
      decoration: BoxDecoration(
        gradient: widget.gradient ?? DrsTokens.surfaceGradient(accent: accent),
        borderRadius: DrsTokens.radii.lgRadius,
        border: Border.all(color: borderColor, width: highlighted ? 1.2 : 1),
        boxShadow: [
          DrsTokens.shadow(
            accent ?? Colors.black,
            opacity: highlighted ? 0.16 : (accent == null ? 0.12 : 0.09),
            blur: highlighted ? 22 : 14,
          ),
        ],
      ),
      child: widget.child,
    );

    if (interactive) {
      surface = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: DrsTokens.radii.lgRadius,
          hoverColor: (accent ?? DrsTokens.accent).withValues(alpha: 0.04),
          focusColor: (accent ?? DrsTokens.accent).withValues(alpha: 0.08),
          splashColor: (accent ?? DrsTokens.accent).withValues(alpha: 0.12),
          onHover: (v) => setState(() => _hovered = v),
          onFocusChange: (v) => setState(() => _focused = v),
          child: surface,
        ),
      );
    }

    return Semantics(
      button: interactive,
      label: widget.semanticLabel,
      child: surface,
    );
  }
}
