import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../../l10n/lang_scope.dart';
import '../../services/db/screening_persistence_service.dart';
import '../../services/pdf/clinical_pdf_generator.dart';
import '../../services/smtp/smtp_service.dart';
import '../../theme/figma_theme.dart';
import '../../widgets/scanner/scanner.dart';
import '../../widgets/workflow_bar.dart';
import '../admin/admin_portal_screen.dart';
import 'flow_state.dart';

/// Figma "Screening Report" (Workflow step 5): printable summary,
/// copy-to-clipboard export, restart. Clearly marked demo report.
class FlowReportScreen extends StatefulWidget {
  final FlowState state;

  const FlowReportScreen({super.key, required this.state});

  @override
  State<FlowReportScreen> createState() => _FlowReportScreenState();
}

class _FlowReportScreenState extends State<FlowReportScreen> {
  bool _more = false;
  bool _isGeneratingPdf = false;
  bool _isSendingEmail = false;

  @override
  void initState() {
    super.initState();
    unawaited(ScreeningPersistenceService().saveScreening(widget.state));
  }

  Future<void> _handleDownloadPdf() async {
    setState(() => _isGeneratingPdf = true);
    try {
      final savedPath = await ClinicalPdfGenerator.saveReportToFile(widget.state);
      if (!mounted) return;

      // On macOS/desktop, automatically open in Preview/default PDF viewer
      try {
        if (Platform.isMacOS) {
          await Process.run('open', [savedPath]);
        }
      } catch (_) {}

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF065F46),
          content: Row(
            children: [
              const Icon(Icons.picture_as_pdf, color: Color(0xFF34D399)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Clinical PDF saved to: $savedPath',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Open',
            textColor: ScannerHUDTheme.neonCyan,
            onPressed: () {
              if (Platform.isMacOS) {
                Process.run('open', [savedPath]);
              }
            },
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF7F1D1D),
          content: Text('Failed to generate PDF: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isGeneratingPdf = false);
    }
  }

  Future<void> _handleEmailReport() async {
    final smtp = SmtpService();
    final config = await smtp.loadConfig();
    if (!mounted) return;

    final emailController = TextEditingController(text: config.specialistEmail);
    final formKey = GlobalKey<FormState>();

    final shouldSend = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ScannerHUDTheme.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF334155)),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.email_outlined, color: ScannerHUDTheme.neonCyan, size: 22),
            ),
            const SizedBox(width: 12),
            const Text(
              'Email Clinical Report',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Dispatches an authenticated clinical dossier PDF and high-res fundus photograph to the specialist doctor.',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: emailController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Specialist / Recipient Email',
                  labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                  hintText: 'doctor@hospital.org',
                  hintStyle: const TextStyle(color: Colors.white30),
                  prefixIcon: const Icon(Icons.alternate_email, color: ScannerHUDTheme.neonCyan, size: 20),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF334155))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF334155))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: ScannerHUDTheme.neonCyan)),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'Recipient email is required';
                  if (!val.contains('@')) return 'Enter a valid email address';
                  return null;
                },
              ),
              if (config.senderEmail.isEmpty || config.senderPassword.isEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7F1D1D).withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFEF4444)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Color(0xFFEF4444), size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Sender credentials not configured in Admin Portal.',
                          style: TextStyle(color: Color(0xFFFCA5A5), fontSize: 11),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx, false);
                          Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPortalScreen()));
                        },
                        child: const Text('Configure', style: TextStyle(color: ScannerHUDTheme.neonCyan, fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton.icon(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(ctx, true);
              }
            },
            icon: const Icon(Icons.send_rounded, size: 16),
            label: const Text('Send Email'),
            style: ElevatedButton.styleFrom(
              backgroundColor: ScannerHUDTheme.neonCyan,
              foregroundColor: ScannerHUDTheme.background,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
          ),
        ],
      ),
    );

    if (shouldSend != true) return;

    final targetRecipient = emailController.text.trim();

    setState(() => _isSendingEmail = true);
    try {
      final result = await smtp.sendSpecialistAlert(
        state: widget.state,
        overrideRecipient: targetRecipient,
      );

      if (!mounted) return;
      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF065F46),
            content: Row(
              children: [
                const Icon(Icons.check_circle_outline, color: Color(0xFF34D399)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Clinical PDF report & fundus image successfully sent to $targetRecipient!',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF7F1D1D),
            content: Text(
              'Failed to dispatch email: ${result.message}',
              style: const TextStyle(color: Colors.white),
            ),
            action: result.message.contains('Admin Portal') || result.message.contains('credentials')
                ? SnackBarAction(
                    label: 'Open Admin',
                    textColor: ScannerHUDTheme.neonCyan,
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AdminPortalScreen()),
                    ),
                  )
                : null,
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF7F1D1D),
          content: Text('Error: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSendingEmail = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.state;
    final a = st.analysis;
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          context.tr('report_title'),
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
                const WorkflowBar(step: 5, dark: true),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(18),
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
                        color: Colors.black.withValues(alpha: 0.2),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('report_header'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 17,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        context.tr('demo_report'),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: FigmaColors.warning,
                        ),
                      ),
                      const Divider(height: 20, color: Color(0xFF334155)),
                      _row(
                        context.tr('patient_details'),
                        '${st.patient.name}, ${st.patient.age}y ${st.patient.gender}',
                      ),
                      _row(context.tr('patient_id'), st.patient.patientId),
                      _row(
                        context.tr('col_ai_result'),
                        a?.drLabel ?? context.tr('awaiting_verif'),
                      ),
                      _row(
                        context.tr('key_findings'),
                        a?.plainLanguageAdvice ?? '',
                      ),
                      _row(
                        context.tr('grad_cam'),
                        a?.gradcamOverlayUrl != null ? '✓' : '—',
                      ),
                      _row(
                        context.tr('sp_verified'),
                        context.tr('verified_msg'),
                      ),
                      _row(
                        context.tr('recommended_action'),
                        a?.actionRecommendation ?? '',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 1. Primary Action: Download Clinical PDF Report
                ElevatedButton.icon(
                  onPressed: _isGeneratingPdf ? null : _handleDownloadPdf,
                  icon: _isGeneratingPdf
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: Text(
                    _isGeneratingPdf ? 'Generating PDF Dossier...' : 'Download Clinical Report (PDF)',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 8),

                // 2. Email Report to Specialist Action
                ElevatedButton.icon(
                  onPressed: _isSendingEmail ? null : _handleEmailReport,
                  icon: _isSendingEmail
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                        )
                      : const Icon(Icons.mark_email_read_outlined),
                  label: Text(
                    _isSendingEmail ? 'Dispatching Email Report...' : 'Email Report to Specialist',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ScannerHUDTheme.neonCyan,
                    foregroundColor: ScannerHUDTheme.background,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
                const SizedBox(height: 8),

                // 3. Send SMS (Demo)
                OutlinedButton.icon(
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${context.tr('btn_sms')} (Demo)')),
                  ),
                  icon: const Icon(Icons.sms_outlined, size: 18),
                  label: Text('${context.tr('btn_sms')} (Demo)'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => setState(() => _more = !_more),
                  child: Text(context.tr(_more ? 'btn_hide' : 'btn_more')),
                ),
                if (_more)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${context.tr('technical_export')}: ${a?.screeningId ?? '-'}',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: () =>
                      Navigator.popUntil(context, (route) => route.isFirst),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: FigmaColors.success,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    context.tr('btn_new_screening'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFF94A3B8),
            ),
          ),
          Text(
            value.isEmpty ? '—' : value,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE2E8F0)),
          ),
        ],
      ),
    );
  }
}
