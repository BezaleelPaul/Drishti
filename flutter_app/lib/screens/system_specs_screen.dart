import 'package:flutter/material.dart';

import '../widgets/scanner/scanner_theme.dart';

/// System Specs & Hardware Profiles — the technical appendix nested inside
/// About / System Info. Dark HUD chrome consistent with the clinical shell;
/// semantic model accents (green/cyan/amber/red) stay meaningful on dark.
class SystemSpecsScreen extends StatelessWidget {
  const SystemSpecsScreen({super.key, this.embedded = false});

  final bool embedded;

  static const _green = Color(0xFF34D399);
  static const _blue = Color(0xFF38BDF8);
  static const _amber = Color(0xFFF59E0B);
  static const _danger = Color(0xFFFB7185);

  @override
  Widget build(BuildContext context) {
    final specsBody = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // Header Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Row(
                    children: [
                      Icon(Icons.memory_rounded, color: _cyanAccent, size: 28),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'On-Device Edge Screening Architecture',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Manufacturer-agnostic pipeline running low-latency clinical deep learning locally on mobile/tablet edge hardware without mandatory internet connectivity.',
                    style: TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // AI Models Stack
            _darkCard('🧠 Dual-Model Edge Deep Learning Stack', [
              _buildSpecRow(
                'Model 1: Quality Gate',
                'Deep Ensemble (berenslab/fundus_image_toolbox) + Laplacian Fusion',
                '~42 ms edge latency | Certifies sharpness, FOV & illumination before grading',
                Icons.verified_rounded,
                _green,
              ),
              const Divider(height: 24, color: Color(0xFF1E293B)),
              _buildSpecRow(
                'Model 2: DR Classifier',
                'EfficientNetB0 (Fine-tuned on APTOS 2019 / EyePACS, 5-class severity)',
                '~118 ms edge latency | Softmax probabilities + CSME macular edema biomarker',
                Icons.science_rounded,
                _blue,
              ),
              const Divider(height: 24, color: Color(0xFF1E293B)),
              _buildSpecRow(
                'Explainability Engine',
                'Grad-CAM++ (Higher-Order Gradient Feature Attribution Map)',
                '~86 ms edge latency | Localizes microaneurysms, hard exudates & hemorrhages',
                Icons.visibility_rounded,
                _amber,
              ),
              const Divider(height: 24, color: Color(0xFF1E293B)),
              _buildSpecRow(
                'Upstream Risk Engine',
                'ICMR / Google-Aravind Calibrated Non-Invasive Diabetes Risk Tree',
                '<10 ms latency | Flags high-risk patients upstream using age, BMI, family history',
                Icons.health_and_safety_rounded,
                _danger,
              ),
            ]),
            const SizedBox(height: 16),

            // Multi-Camera Profiles
            _darkCard('📷 Manufacturer-Agnostic Camera Compatibility', [
              _buildCameraItem(
                'Forus 3nethra Classic',
                'Forus Health (India)',
                'Non-mydriatic tabletop camera deployed across Indian PHCs (2048x1536, 45° FOV)',
              ),
              const Divider(height: 18, color: Color(0xFF1E293B)),
              _buildCameraItem(
                'Remidio FOP (Fundus on Phone)',
                'Remidio Innovative Solutions',
                'Handheld smartphone fundus camera ideal for ASHA workers and rural vans (45° FOV)',
              ),
              const Divider(height: 18, color: Color(0xFF1E293B)),
              _buildCameraItem(
                'Volk iNview',
                'Volk Optical',
                'Smartphone 20D indirect ophthalmoscopy condensing lens attachment (50° FOV)',
              ),
              const Divider(height: 18, color: Color(0xFF1E293B)),
              _buildCameraItem(
                'Clinical Desktop Fundus Cameras',
                'Zeiss, Topcon, Canon, Kowa',
                'Standard hospital DICOM / high-resolution RGB fundus photography',
              ),
            ]),
            const SizedBox(height: 16),

            // Interoperability & ABDM Gateway
            _darkCard('🌐 Standards & ABDM Interoperability', [
              _checkRow(
                'ABDM FHIR R4 DiagnosticReport JSON bundles with ABHA token exchange',
              ),
              _checkRow(
                'ICD-10 Standardized Codification (E11.319 to E11.359) for automated EHR integration',
              ),
              _checkRow(
                'Store-and-Forward SQLite sync cache for zero data loss in offline rural zones',
              ),
            ]),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );

    if (embedded) {
      return Container(color: ScannerHUDTheme.background, child: specsBody);
    }

    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        title: const Text(
          'System Specs & Hardware Profiles',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
      ),
      body: specsBody,
    );
  }

  Widget _darkCard(String title, List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _checkRow(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded, color: _green, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                height: 1.4,
                color: Color(0xFFCBD5E1),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSpecRow(
    String title,
    String subtitle,
    String details,
    IconData icon,
    Color color,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFCBD5E1),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                details,
                style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCameraItem(String name, String manufacturer, String desc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.white,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: Text(
                manufacturer,
                style: const TextStyle(
                  fontSize: 11,
                  color: ScannerHUDTheme.neonCyan,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          desc,
          style: const TextStyle(
            fontSize: 12,
            height: 1.35,
            color: Color(0xFF94A3B8),
          ),
        ),
      ],
    );
  }
}

/// Cyan accent used inside const rows (ScannerHUDTheme is not const-able).
const _cyanAccent = Color(0xFF22D3EE);
