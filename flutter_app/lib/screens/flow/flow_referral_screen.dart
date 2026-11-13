import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/lang_scope.dart';
import '../../services/referral_uplink_service.dart';
import '../../theme/figma_theme.dart';
import '../../widgets/scanner/scanner.dart';
import '../../widgets/workflow_bar.dart';
import '../consent_screen.dart';
import 'flow_report_screen.dart';
import 'flow_state.dart';

/// Figma "Referral" (Workflow step 4): urgency card, specialist,
/// send actions.
///
/// The send button is the END of the privacy chain (C-2 → C-3 → C-4 → D-2):
/// consent screen first, then the payload is built de-identified
/// (pseudonym, banded age, EXIF-stripped downscaled image), linted
/// client-side, POSTed to /sync/v2 — or queued durably for the next
/// connectivity window when the doctor console is unreachable.
class FlowReferralScreen extends StatefulWidget {
  final FlowState state;

  const FlowReferralScreen({super.key, required this.state});

  @override
  State<FlowReferralScreen> createState() => _FlowReferralScreenState();
}

class _FlowReferralScreenState extends State<FlowReferralScreen> {
  bool _smsSent = false;
  bool _uploading = false;
  ReferralUplinkService? _uplink;

  @override
  void initState() {
    super.initState();
    ReferralUplinkService.create().then((s) {
      if (mounted) setState(() => _uplink = s);
    });
  }

  String get _pseudonym {
    final uplink = _uplink;
    if (uplink == null) return 'RSV-........';
    // The pseudonym is deterministic for the patient on this device; the
    // uplink surfaces it so the operator sees the privacy guarantee.
    return uplink.pseudonymFor(widget.state.patient.patientId) ??
        'RSV-........';
  }

  /// ICMR/NHS-style referral urgency derived from the grade (Ticket D-1):
  /// grade 2 (referable NPDR) -> routine 4-week pathway; grade 3 (severe)
  /// -> 1 week; grade 4 (proliferative) -> urgent, within 48 hours. The
  /// urgency is clinical policy, not a hardcoded constant.
  ({String label, String hindi}) _urgencyFor(int grade) {
    switch (grade) {
      case 4:
        return (
          label: 'Urgent — within 48 hours',
          hindi: 'तत्काल — 48 घंटे के भीतर',
        );
      case 3:
        return (
          label: 'Priority — within 1 week',
          hindi: 'प्राथमिकता — 1 सप्ताह के भीतर',
        );
      default:
        return (
          label: 'Routine — within 4 weeks',
          hindi: 'सामान्य — 4 सप्ताह के भीतर',
        );
    }
  }

  Future<void> _sendReferral() async {
    final granted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ConsentScreen(
          localPatientId: widget.state.patient.patientId,
          patientDisplayName: widget.state.patient.name,
        ),
      ),
    );
    if (granted != true || !mounted) {
      if (granted == false && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Consent refused — data stays on this device only.'),
            backgroundColor: FigmaColors.danger,
          ),
        );
      }
      return;
    }

    final uplink = _uplink;
    if (uplink == null || !mounted) return;

    setState(() => _uploading = true);
    try {
      final analysis = widget.state.analysis;
      final build = await uplink.buildPayload(
        localPatientId: widget.state.patient.patientId,
        patientAge: widget.state.patient.age,
        patientGender: widget.state.patient.gender,
        eyeSide: widget.state.eyeSide,
        localScreeningId:
            analysis?.screeningId ??
            'LOC-${DateTime.now().millisecondsSinceEpoch}',
        drGrade: widget.state.correctedGrade ?? analysis?.drGrade,
        drLabel: analysis?.drLabel,
        confidence: analysis?.predictionScore,
        requiresHumanReview: analysis?.requiresHumanReview ?? true,
        consentLanguage: LangScope.langOf(context).name,
        imageBytes: widget.state.imageBytes,
      );

      if (!build.isOk) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              build.refusal == ReferralBuildRefusal.noConsent
                  ? 'Consent refused — data stays on this device only.'
                  : 'Referral blocked by privacy lint: ${build.violations.join(", ")}',
            ),
            backgroundColor: FigmaColors.danger,
          ),
        );
        return;
      }

      final result = await uplink.upload(build.payload!);
      if (!mounted) return;
      setState(() {
        widget.state.referralSent = true;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.outcome == ReferralOutcome.uploaded
                ? 'Referral uploaded de-identified as $_pseudonym '
                      '(no name/phone/ABHA/village left the device).'
                : 'Offline — referral queued securely and will upload on '
                      'the next connection (still de-identified as $_pseudonym).',
          ),
          backgroundColor: FigmaColors.success,
        ),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Real referral slip via the phone's own SMS app (no SEND_SMS permission,
  /// no silent messaging — the operator sees and sends it themselves, which
  /// is also the DPDP-friendly posture: the patient's own referral going to
  /// their own number, explicitly).
  Future<void> _sendSms() async {
    final st = widget.state;
    final grade = st.correctedGrade ?? st.analysis?.drGrade ?? 2;
    final urgency = _urgencyFor(grade);
    final backend = st.analysis?.modelBackend == 'tflite-fp32'
        ? 'on-device'
        : 'clinic';
    final slip = [
      'ELYTRIVA Referral Slip',
      'Patient: ${st.patient.name} (${st.patient.age}y)',
      'Eye: ${st.eyeSide}  |  AI: ${st.analysis?.drLabel ?? "grade $grade"}',
      'Urgency: ${urgency.label}',
      'Screened: $backend, ${DateTime.now().toIso8601String().substring(0, 16)}',
      'AI is a screening aid — final decision by an eye doctor.',
      'District Eye Care Centre — Retina Clinic',
    ].join('\n');
    final phone = st.patient.phone.trim();
    final uri = Uri(
      scheme: 'sms',
      path: phone.isEmpty ? null : phone,
      queryParameters: phone.isEmpty ? null : {'body': slip},
    );
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!mounted) return;
      if (launched) {
        setState(() => _smsSent = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'SMS app opened with the referral slip — review and press send.',
            ),
            backgroundColor: FigmaColors.success,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No SMS app available on this device.'),
            backgroundColor: FigmaColors.danger,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open SMS app: $e'),
          backgroundColor: FigmaColors.danger,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.state;
    final grade = st.correctedGrade ?? st.analysis?.drGrade ?? 2;
    final urgency = _urgencyFor(grade);
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          context.tr('referral_title'),
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
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
                const WorkflowBar(step: 4, dark: true),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF2E1015),
                        Color(0xFF16080B),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFEF4444).withValues(alpha: 0.15),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('referral_required'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: FigmaColors.danger,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${context.tr('sev_label')}: Grade $grade',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        '${context.tr('urgency_label')}: ${urgency.label}\n'
                        '${urgency.hindi}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFFE2E8F0),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        context.tr('referral_msg'),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF111C38),
                        Color(0xFF0C1428),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF1E2D4A), width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('recommended_specialist'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'District Eye Care Centre — Retina & Vitreous Clinic',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                      Text(
                        '${st.patient.name} • ${st.patient.phone}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: (st.referralSent || _uploading)
                      ? null
                      : _sendReferral,
                  icon: _uploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          st.referralSent ? Icons.check_circle_rounded : Icons.send_rounded,
                        ),
                  label: Text(
                    st.referralSent
                        ? context.tr('sync_complete')
                        : context.tr('btn_send_referral'),
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00B4D8),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    elevation: 3,
                    shadowColor: const Color(0x6600B4D8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _smsSent ? null : _sendSms,
                  icon: const Icon(Icons.sms_outlined, size: 18),
                  label: Text(
                    context.tr('btn_send_sms'),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: const Color(0xFF101932),
                    side: const BorderSide(color: Color(0xFF223254)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => FlowReportScreen(state: st),
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ScannerHUDTheme.neonCyan,
                    backgroundColor: const Color(0xFF101932),
                    side: BorderSide(
                      color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.4),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    context.tr('btn_continue_report'),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
