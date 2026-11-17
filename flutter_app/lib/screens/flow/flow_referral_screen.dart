import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/lang_scope.dart';
import '../../models/specialist_models.dart';
import '../../services/db/local_store.dart';
import '../../services/db/screening_persistence_service.dart';
import '../../services/offline_queue_service.dart';
import '../../services/referral_uplink_service.dart';
import '../../services/smtp/smtp_service.dart';
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
  bool _emailing = false;
  ReferralUplinkService? _uplink;

  ReferralPlan? get _plan => widget.state.referralPlan;

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

  Future<bool> _requestConsent() async {
    final granted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ConsentScreen(
          localPatientId: widget.state.patient.patientId,
          patientDisplayName: widget.state.patient.name,
        ),
      ),
    );
    if (granted != true && mounted) {
      if (granted == false) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Consent refused — data stays on this device only.'),
            backgroundColor: FigmaColors.danger,
          ),
        );
      }
      return false;
    }
    return granted == true;
  }

  Future<void> _sendReferral() async {
    if (!await _requestConsent() || !mounted) return;

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

  Future<void> _sendSpecialistEmail() async {
    final plan = _plan;
    final specialist = plan?.primary.specialist;
    final smtp = SmtpService();
    final config = await smtp.loadConfig();
    if (!mounted) return;

    if (config.senderEmail.isEmpty ||
        config.senderPassword.isEmpty ||
        config.smtpHost.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'SMTP sender credentials are not configured. Add them in '
            'Admin Portal → SMTP Gateway.',
          ),
          backgroundColor: FigmaColors.danger,
        ),
      );
      return;
    }

    final recipient = (specialist?.email.trim().isNotEmpty ?? false)
        ? specialist!.email.trim()
        : config.specialistEmail.trim();
    if (recipient.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No specialist email is configured for this route.'),
          backgroundColor: FigmaColors.danger,
        ),
      );
      return;
    }

    // PHI leaves the device only after the patient's explicit consent.
    if (!await _requestConsent() || !mounted) return;

    setState(() => _emailing = true);
    try {
      final result = await smtp.sendSpecialistAlert(
        state: widget.state,
        overrideRecipient: recipient,
        addressedTo: specialist,
      );
      if (!mounted) return;
      if (result.success) {
        widget.state.specialistEmailSent = true;
        _auditReferralEmail(recipient);
        final sid = widget.state.analysis?.screeningId ??
            'LOC-${DateTime.now().millisecondsSinceEpoch}';
        unawaited(
          ScreeningPersistenceService().updateRecord({
            'local_screening_id': sid,
            'local_patient_id': widget.state.patient.patientId,
            'specialist_email_sent': 1,
            'referral_plan_json':
                plan == null ? null : jsonEncode(plan.toJson()),
          }),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Clinical dossier sent to ${specialist?.displayName ?? recipient}'
              '${plan != null ? ' · ${plan.primary.mode.label}' : ''}.',
            ),
            backgroundColor: FigmaColors.success,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message),
            backgroundColor: FigmaColors.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _emailing = false);
    }
  }

  void _auditReferralEmail(String recipient) {
    final sid = widget.state.analysis?.screeningId ??
        'LOC-${DateTime.now().millisecondsSinceEpoch}';
    () async {
      try {
        final store = await LocalStore.open(
          dbPassword: await OfflineQueueService.resolveDbPassword(),
        );
        await store.recordAudit(
          action: 'referral_email_sent',
          resource: sid,
          detail: 'recipient=$recipient; plan=${_plan?.algorithm ?? "manual"}',
        );
      } catch (_) {
        // Audit is best-effort; the email path must not fail because of it.
      }
    }();
  }

  Future<void> _startTeleconsult() async {
    final url = _plan?.primary.specialist.teleconsultUrl.trim() ?? '';
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No teleconsult link is configured for this specialist.'),
          backgroundColor: FigmaColors.danger,
        ),
      );
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open the teleconsult link.'),
          backgroundColor: FigmaColors.danger,
        ),
      );
    }
  }

  Future<void> _openDirections() async {
    final specialist = _plan?.primary.specialist;
    final location = specialist?.location;
    if (location == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No facility location is configured for this specialist.'),
          backgroundColor: FigmaColors.danger,
        ),
      );
      return;
    }
    final label = Uri.encodeComponent(specialist!.facilityName);
    final geo = Uri.parse(
      'geo:${location.latitude},${location.longitude}?q=${location.latitude},${location.longitude}($label)',
    );
    var ok = false;
    try {
      ok = await launchUrl(geo, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      ok = await launchUrl(
        Uri.parse(
          'https://www.google.com/maps/search/?api=1&query=${location.latitude},${location.longitude}',
        ),
        mode: LaunchMode.externalApplication,
      );
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open a maps application.'),
          backgroundColor: FigmaColors.danger,
        ),
      );
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
      'DRISHTI Referral Slip',
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

  Widget _routedSpecialistCard() {
    final plan = _plan;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B2239), Color(0xFF0C1428)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.55),
          width: 1.2,
        ),
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
          Row(
            children: [
              const Icon(Icons.alt_route, color: ScannerHUDTheme.neonCyan, size: 18),
              const SizedBox(width: 8),
              Text(
                'ROUTED SPECIALIST · ADDRESSED REFERRAL',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w800,
                  color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.95),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (plan == null) ...[
            const Text(
              'No specialist route is available. Configure the specialist '
              'directory and screening-centre location in Admin Portal → '
              'Specialist Routing.',
              style: TextStyle(fontSize: 12, color: Color(0xFFF59E0B), height: 1.4),
            ),
          ] else ...[
            Text(
              plan.specialist.displayName,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              plan.specialist.fullAddress,
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8), height: 1.4),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _referralChip(plan.urgency.shortLabel, const Color(0xFFEF4444)),
                _referralChip(plan.primary.mode.label, ScannerHUDTheme.neonCyan),
                _referralChip(plan.primary.distanceLabel, const Color(0xFFA78BFA)),
                _referralChip(plan.primary.travelLabel, const Color(0xFF34D399)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              plan.primary.rationale,
              style: const TextStyle(fontSize: 11, color: Color(0xFFCBD5E1), height: 1.4),
            ),
            if (plan.alternates.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Escalation alternates: ${plan.alternates.map((r) => '${r.specialist.displayName} (${r.specialist.facilityName})').join(' · ')}',
                style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B), height: 1.4),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                if (plan.specialist.canTeleconsult)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _startTeleconsult,
                      icon: const Icon(Icons.video_call_outlined, size: 16),
                      label: const Text('Teleconsult'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: ScannerHUDTheme.neonCyan,
                        side: BorderSide(
                          color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.5),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                    ),
                  ),
                if (plan.specialist.canTeleconsult && plan.specialist.location != null)
                  const SizedBox(width: 8),
                if (plan.specialist.location != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _openDirections,
                      icon: const Icon(Icons.map_outlined, size: 16),
                      label: const Text('Directions'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF34D399),
                        side: const BorderSide(color: Color(0x6634D399)),
                        padding: const EdgeInsets.symmetric(vertical: 11),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _referralChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
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
                _routedSpecialistCard(),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _emailing ? null : _sendSpecialistEmail,
                  icon: _emailing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          st.specialistEmailSent
                              ? Icons.mark_email_read_rounded
                              : Icons.outgoing_mail,
                        ),
                  label: Text(
                    st.specialistEmailSent
                        ? 'Clinical dossier sent to specialist'
                        : _plan == null
                            ? 'Email clinical dossier'
                            : 'Email dossier to ${_plan!.specialist.displayName}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0E7490),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
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
