import 'package:flutter/material.dart';
import '../l10n/lang_scope.dart';
import '../widgets/fx/particle_field.dart';
import '../widgets/nav/neon_nav_rail.dart';
import '../widgets/scanner/scanner_theme.dart';

/// Help & Guidelines — dark HUD chrome matching the dashboard/about pages.
/// 4 FAQ accordions + support card. FAQ bodies are English in the Figma
/// source itself — mirrored as-is.
class FigmaHelpScreen extends StatelessWidget {
  const FigmaHelpScreen({super.key});

  static const _faqs = [
    (
      'help_q1',
      [
        'Position the patient in front of the fundus camera.',
        'Ask the patient to keep their eye wide open and look at the fixation light.',
        'Adjust the camera focus until the retina appears clear.',
        'Capture when the optic disc and macula are both visible.',
        'If quality check fails, retake the image.',
      ],
    ),
    (
      'help_q2',
      [
        'The AI analyses the retinal image and estimates DR severity.',
        'No DR: no signs detected.',
        'Mild NPDR: early signs — microaneurysms.',
        'Moderate NPDR: more changes — specialist review.',
        'Severe NPDR: many changes — referral needed.',
        'PDR: advanced — urgent referral.',
      ],
    ),
    (
      'help_q3',
      [
        'Moderate NPDR or higher severity.',
        'Any vision-threatening changes detected.',
        'No specialist review in 12 months.',
        'Specialist requests re-examination.',
      ],
    ),
    (
      'help_q4',
      [
        'Images are securely saved on the device.',
        'Cases appear in the Offline Queue.',
        'When connectivity returns, press Sync Now.',
        'AI analysis and specialist review proceed automatically.',
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      drawer: NeonNavRail(
        entries: buildNavEntries(context),
        activeLabel: 'Help & Guidelines',
      ),
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: Text(
          context.tr('help_title'),
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
      ),
      body: Stack(
        children: [
          const Positioned.fill(
            child: ParticleField(
              particleCount: 15,
              opacity: 0.18,
              speed: 0.5,
              seed: 17,
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 672),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    context.tr('help_subtitle'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ..._faqs.map(
                    (faq) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: ScannerHUDTheme.darkSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          dividerColor: Colors.transparent,
                          expansionTileTheme: const ExpansionTileThemeData(
                            backgroundColor: Colors.transparent,
                            collapsedBackgroundColor: Colors.transparent,
                            iconColor: ScannerHUDTheme.neonCyan,
                            collapsedIconColor: Color(0xFF94A3B8),
                            textColor: Colors.white,
                            collapsedTextColor: Color(0xFFCBD5E1),
                          ),
                        ),
                        child: ExpansionTile(
                          tilePadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                          ),
                          title: Text(
                            context.tr(faq.$1),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: Colors.white,
                            ),
                          ),
                          children: [
                            Container(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: faq.$2
                                    .map(
                                      (line) => Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          '• $line',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            height: 1.4,
                                            color: Color(0xFFCBD5E1),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: ScannerHUDTheme.darkSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.tr('need_help'),
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: ScannerHUDTheme.neonCyan,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.tr('need_help_msg'),
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: Color(0xFFCBD5E1),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
