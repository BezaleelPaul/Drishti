import 'package:flutter/material.dart';

import 'district_simulation_screen.dart';
import 'system_specs_screen.dart';
import '../widgets/fx/particle_field.dart';
import '../widgets/scanner/scanner_theme.dart';

/// About / System Info — the single Support destination for everything that
/// is documentation rather than a daily task. Benchmarks, device specs and
/// the Production Clinical Standard district macro model live HERE (judge/demo material), not
/// in the primary screening navigation.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: const Text(
          'About / System Info',
          style: TextStyle(
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
              particleCount: 16,
              opacity: 0.2,
              speed: 0.55,
              seed: 41,
            ),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 672),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // Brand block.
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: ScannerHUDTheme.darkSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                colors: [
                                  ScannerHUDTheme.primaryCyan,
                                  ScannerHUDTheme.neonCyan,
                                ],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: ScannerHUDTheme.neonCyan.withValues(
                                    alpha: 0.4,
                                  ),
                                  blurRadius: 12,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.remove_red_eye_outlined,
                              color: ScannerHUDTheme.background,
                              size: 26,
                            ),
                          ),
                          const SizedBox(width: 14),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'DRISHTI',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 18,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'v2.0.0',
                                      style: TextStyle(
                                        color: ScannerHUDTheme.neonCyan,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Autonomous Clinical AI Retinal Screening System',
                                  style: TextStyle(
                                    color: Color(0xFF94A3B8),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Platform Overview Card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: ScannerHUDTheme.darkSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text(
                            'ABOUT THE PLATFORM',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                              color: ScannerHUDTheme.neonCyan,
                            ),
                          ),
                          SizedBox(height: 10),
                          Text(
                            'Drishti is an offline-first autonomous clinical AI screening system engineered to eliminate preventable blindness from Diabetic Retinopathy in primary health centres and rural camps.\n\n'
                            'By combining upstream clinical risk scoring, Model 1 image quality certification (zero-leakage gate), and Model 2 ordinal classification with Grad-CAM++ lesion saliency, Drishti ensures that non-diagnostic fundus captures are rejected and triaged safely rather than misdiagnosed.',
                            style: TextStyle(
                              color: Color(0xFFCBD5E1),
                              fontSize: 12.5,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'TECHNICAL APPENDIX',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.6,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Demo / judge-facing destinations, removed from daily
                    // navigation as the product drawer was streamlined.
                    _aboutTile(
                      context,
                      icon: Icons.memory_rounded,
                      title: 'System Information',
                      subtitle:
                          'Edge architecture, hardware benchmarks, latency '
                          'metrics and the deployed AI model stack.',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SystemSpecsScreen(),
                        ),
                      ),
                    ),
                    _aboutTile(
                      context,
                      icon: Icons.map_outlined,
                      title: 'District Simulation (Macro Model)',
                      subtitle:
                          'Production Clinical Standard district-level demand simulation for '
                          'evaluation and planning — not a clinical tool.',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DistrictSimulationScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Every screening grade this app displays must trace to a '
                      'real model execution or be escalated to a human reviewer. '
                      'Clinical claims are limited to the committed evaluation '
                      'artifacts in the repository.',
                      style: TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aboutTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: ScannerHUDTheme.neonCyan),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 14.5,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
      ),
    );
  }
}
