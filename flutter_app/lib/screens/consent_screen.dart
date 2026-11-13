import 'package:flutter/material.dart';

import '../../l10n/lang_scope.dart';
import '../../services/consent_service.dart';
import '../../theme/figma_theme.dart';
import '../../widgets/scanner/scanner_theme.dart';

/// Consent gate for the referral uplink (Ticket C-3, DPDP S.5/S.6).
///
/// Shown BEFORE anything leaves the device. The patient/record identity
/// shown to the operator is the local record; nothing on this screen is
/// transmitted. Default is refusal — the referral is only allowed after an
/// explicit grant for the current consent version.
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({
    super.key,
    required this.localPatientId,
    required this.patientDisplayName,
  });

  final String localPatientId;
  final String patientDisplayName;

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  final _consent = ConsentService();
  bool _busy = false;
  bool? _existingGranted;

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final record = await _consent.get(widget.localPatientId);
    if (!mounted) return;
    setState(() => _existingGranted = record?.isSyncAllowed);
  }

  Future<void> _decide(bool granted) async {
    setState(() => _busy = true);
    final language = LangScope.langOf(context).name;
    if (granted) {
      await _consent.grant(widget.localPatientId, language: language);
    } else {
      await _consent.refuse(widget.localPatientId, language: language);
    }
    if (!mounted) return;
    Navigator.pop(context, granted);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: const Text(
          'Consent / सहमति',
          style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 672),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: ScannerHUDTheme.darkSurface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Referral upload consent',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'प्रेषण के लिए सहमति',
                        style: TextStyle(
                          fontSize: 13,
                          color: const Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Record: ${widget.patientDisplayName} '
                        '(${widget.localPatientId})',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'With your permission, ONLY the following will be '
                        'sent to the eye doctor over the local network:\n'
                        '• the retinal image (downscaled, location and '
                        'device metadata removed)\n'
                        '• the AI grade and confidence\n'
                        '• an anonymous code instead of the patient name\n\n'
                        'NEVER sent: name, phone number, ABHA ID, village, '
                        'or the original photo. Nothing is stored on any '
                        'cloud server.\n\n'
                        'आपकी अनुमति से केवल रेटिना छवि (संकुचित, मेटाडेटा '
                        'हटाई गई), AI ग्रेड और एक गुप्त कोड भेजा जाएगा। नाम, '
                        'फ़ोन, ABHA आईडी, गाँव या मूल तस्वीर कभी नहीं भेजी '
                        'जाती। कोई डेटा क्लाउड सर्वर पर संग्रहीत नहीं होता।',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Consent version: ${ConsentService.consentVersion} '
                        '• You may withdraw at any time.\n'
                        'सहमति संस्करण: ${ConsentService.consentVersion} • '
                        'आप कभी भी वापस ले सकते हैं।',
                        style: const TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      if (_existingGranted == true) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Consent already granted for this record.',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: FigmaColors.success,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _busy ? null : () => _decide(true),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text(
                    'Yes, send de-identified data / हाँ, भेजें',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: FigmaColors.success,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _decide(false),
                  icon: const Icon(Icons.block),
                  label: const Text(
                    'No, keep on device only / नहीं, केवल डिवाइस पर',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'AI is a screening aid. The final referral decision is '
                  'made by a registered medical practitioner.\n'
                  'AI केवल स्क्रीनिंग सहायक है। अंतिम निर्णय पंजीकृत चिकित्सक '
                  'करते हैं।',
                  style: const TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: Color(0xFF64748B),
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
