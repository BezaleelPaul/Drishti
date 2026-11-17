import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/lang_scope.dart';
import '../../models/specialist_models.dart';
import '../../services/api_service.dart';
import '../../services/db/screening_persistence_service.dart';
import '../../services/routing/specialist_directory_service.dart';
import '../../services/smtp/smtp_service.dart';
import '../../widgets/scanner/scanner.dart';
import '../../widgets/workflow_bar.dart';
import '../admin/admin_portal_screen.dart';
import '../admin/specialist_routing_screen.dart';
import 'flow_referral_screen.dart';
import 'flow_state.dart';

/// Figma "Specialist Review" (Workflow step 4):
/// why-this-result, confirm / change / re-examine, notes, submit.
class FlowSpecialistScreen extends StatefulWidget {
  final FlowState state;

  const FlowSpecialistScreen({super.key, required this.state});

  @override
  State<FlowSpecialistScreen> createState() => _FlowSpecialistScreenState();
}

class _FlowSpecialistScreenState extends State<FlowSpecialistScreen> {
  final _api = ApiService();
  final _notes = TextEditingController();
  String _decision = 'CONFIRM';
  int _correctedGrade = 2;
  bool _busy = false;
  String _specialistEmail = '';
  bool _autoSendEnabled = false;

  ReferralPlan? _plan;
  bool _routingLoading = true;
  String? _routingHint;

  int get _effectiveGrade {
    if (_decision == 'CHANGE') return _correctedGrade;
    return widget.state.analysis?.drGrade ?? 0;
  }

  @override
  void initState() {
    super.initState();
    _loadSpecialistRecipient();
    unawaited(_loadRouting());
  }

  Future<void> _loadRouting() async {
    final directory = SpecialistDirectoryService.instance;
    await directory.load(reload: true);
    final plan = directory.planForGrade(_effectiveGrade);
    if (!mounted) return;
    setState(() {
      _plan = plan;
      widget.state.referralPlan = plan;
      _routingLoading = false;
      if (directory.specialists.isEmpty) {
        _routingHint = 'No specialist directory configured yet.';
      } else if (directory.origin == null || directory.origin!.isRoutable == false) {
        _routingHint = 'Set the screening-centre location to enable offline routing.';
      } else if (plan == null) {
        _routingHint =
            'No configured specialist accepts Grade $_effectiveGrade patients.';
      } else {
        _routingHint = null;
      }
    });
  }

  void _refreshPlanForGrade() {
    final directory = SpecialistDirectoryService.instance;
    final plan = directory.planForGrade(_effectiveGrade);
    setState(() {
      _plan = plan;
      widget.state.referralPlan = plan;
      _routingHint = plan == null
          ? 'No configured specialist accepts Grade $_effectiveGrade patients.'
          : null;
    });
  }

  Future<void> _changeSpecialist() async {
    final directory = SpecialistDirectoryService.instance;
    final routes = directory.rankForGrade(_effectiveGrade);
    if (routes.isEmpty) {
      await _openRoutingDirectory();
      return;
    }
    final selected = await showModalBottomSheet<SpecialistRoute>(
      context: context,
      backgroundColor: ScannerHUDTheme.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Assign Specialist',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Ranked offline by travel time, retinal capability and teleconsult availability.',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: routes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final route = routes[i];
                    final isCurrent = _plan?.primary.specialist.id == route.specialist.id;
                    return ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: isCurrent
                              ? ScannerHUDTheme.neonCyan
                              : const Color(0xFF1E2D4A),
                        ),
                      ),
                      tileColor: const Color(0xFF111C38),
                      title: Text(
                        route.specialist.displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        '${route.specialist.facilityName}\n'
                        '${route.distanceLabel} · ${route.travelLabel} · ${route.mode.label}',
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                      trailing: isCurrent
                          ? const Icon(Icons.check_circle,
                              color: ScannerHUDTheme.neonCyan)
                          : null,
                      onTap: () => Navigator.pop(ctx, route),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final next = _plan?.withPrimary(selected) ??
        ReferralPlan(
          origin: directory.origin!,
          grade: _effectiveGrade,
          urgency: ReferralUrgency.forGrade(_effectiveGrade),
          primary: selected,
          alternates: const [],
          generatedAt: DateTime.now().toUtc(),
        );
    setState(() {
      _plan = next;
      widget.state.referralPlan = next;
    });
  }

  Future<void> _openRoutingDirectory() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SpecialistRoutingScreen()),
    );
    await _loadRouting();
  }

  Future<void> _loadSpecialistRecipient() async {
    final cfg = await SmtpService().loadConfig();
    if (!mounted) return;
    setState(() {
      _specialistEmail = cfg.specialistEmail.trim();
      _autoSendEnabled = cfg.autoSendOnDr;
    });
  }

  Future<void> _editSpecialistEmailDialog() async {
    final controller = TextEditingController(text: _specialistEmail);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF1E293B)),
        ),
        title: const Row(
          children: [
            Icon(Icons.mark_email_read_outlined, color: ScannerHUDTheme.neonCyan, size: 22),
            SizedBox(width: 10),
            Text(
              'Assign Specialist Recipient',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the email address of the ophthalmologist or hospital receiving clinical referral dossiers:',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Specialist Email(s)',
                hintText: 'dr.sharma@eyeclinic.org',
                hintStyle: const TextStyle(color: Color(0xFF475569)),
                labelStyle: const TextStyle(color: ScannerHUDTheme.neonCyan),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: ScannerHUDTheme.neonCyan),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: ScannerHUDTheme.neonCyan,
              foregroundColor: Colors.black,
            ),
            child: const Text('Save Recipient', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (updated != null && mounted) {
      final cfg = await SmtpService().loadConfig();
      cfg.specialistEmail = updated;
      await SmtpService().saveConfig(cfg);
      setState(() => _specialistEmail = updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF065F46),
          content: Text(
            updated.isNotEmpty
                ? 'Specialist recipient updated: $updated'
                : 'Specialist recipient cleared',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  static const _sevKeys = [
    'sev_no_dr',
    'sev_mild_npdr',
    'sev_moderate_npdr',
    'sev_severe_npdr',
    'sev_pdr',
  ];

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      widget.state.verdict = _decision;
      widget.state.correctedGrade = _decision == 'CHANGE'
          ? _correctedGrade
          : null;
      widget.state.specialistNotes = _notes.text.trim();
      widget.state.referralPlan = _plan;
      // Best-effort server verdict: find the pending review for this
      // screening and record the decision. Offline/unknown → local only.
      try {
        final pending = await _api.getPendingReviews(limit: 100);
        final sid = widget.state.analysis?.screeningId;
        final match = pending.where((r) => '${r['screening_id']}' == '$sid');
        if (match.isNotEmpty) {
          final decision = _decision == 'CHANGE'
              ? 'OVERRIDE_GRADE'
              : _decision == 'REEXAMINE'
              ? 'REQUEST_RECAPTURE'
              : 'CONFIRM';
          await _api.submitDoctorDecision(
            reviewId: '${match.first['review_id']}',
            doctorName: 'Dr. Sharma (MS Ophth)',
            decision: decision,
            clinicalNotes: widget.state.specialistNotes.isEmpty
                ? 'Figma flow specialist verdict: $_decision.'
                : widget.state.specialistNotes,
            gradeOverride: _decision == 'CHANGE' ? _correctedGrade : null,
          );
        }
      } catch (_) {
        // Local verdict stands; sync covers the rest.
      }
      unawaited(ScreeningPersistenceService().saveScreening(widget.state));
      // PHI is not emailed automatically here. The referral screen shows the
      // routed recipient and sends the dossier only after explicit consent.
      if (!mounted) return;
      unawaited(
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FlowReferralScreen(state: widget.state),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.state.analysis;
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: Text(
          context.tr('specialist_title'),
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
                // AI result card
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
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('ai_result_card'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      if (a != null)
                        Text(
                          '${a.drLabel ?? context.tr('awaiting_verif')}'
                          '${a.predictionScore != null ? ' • ${(a.predictionScore! * 100).toStringAsFixed(1)}%' : ''}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      const SizedBox(height: 6),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        iconColor: ScannerHUDTheme.neonCyan,
                        collapsedIconColor: ScannerHUDTheme.neonCyan,
                        textColor: Colors.white,
                        collapsedTextColor: ScannerHUDTheme.neonCyan,
                        title: Text(
                          context.tr('why_result'),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        children: [
                          Text(
                            context.tr('why_result_text'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _routingCard(),
                const SizedBox(height: 12),
                _specialistRecipientCard(),
                const SizedBox(height: 14),
                Text(
                  context.tr('decision_label'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                _decisionCard(
                  'CONFIRM',
                  Icons.check_circle,
                  'confirm_lbl',
                  'confirm_sub',
                ),
                _decisionCard('CHANGE', Icons.tune, 'change_lbl', 'change_sub'),
                _decisionCard(
                  'REEXAMINE',
                  Icons.refresh,
                  'reexamine_lbl',
                  'reexamine_sub',
                ),
                if (_decision == 'CHANGE') ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: _correctedGrade,
                    dropdownColor: ScannerHUDTheme.darkSurface,
                    style: const TextStyle(color: Color(0xFFE2E8F0)),
                    decoration: InputDecoration(
                      labelText: context.tr('select_severity'),
                      filled: true,
                      fillColor: ScannerHUDTheme.darkSurface,
                      labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF334155)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF334155)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                          color: ScannerHUDTheme.neonCyan,
                        ),
                      ),
                    ),
                    items: [
                      for (var i = 0; i < 5; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            context.tr(_sevKeys[i]),
                            style: const TextStyle(color: Color(0xFFE2E8F0)),
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      setState(() => _correctedGrade = v ?? 2);
                      _refreshPlanForGrade();
                    },
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: _notes,
                  maxLines: 3,
                  style: const TextStyle(color: Color(0xFFE2E8F0)),
                  decoration: InputDecoration(
                    labelText: context.tr('notes_lbl'),
                    hintText: context.tr('notes_ph'),
                    filled: true,
                    fillColor: ScannerHUDTheme.darkSurface,
                    labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                    hintStyle: const TextStyle(color: Color(0xFF64748B)),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF334155)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF334155)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(
                        color: ScannerHUDTheme.neonCyan,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _busy ? null : _submit,
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
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          context.tr('btn_verify'),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2,
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

  Widget _decisionCard(
    String value,
    IconData icon,
    String titleKey,
    String subKey,
  ) {
    final selected = _decision == value;
    return InkWell(
      onTap: () {
        setState(() => _decision = value);
        _refreshPlanForGrade();
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: selected
                ? [
                    const Color(0xFF10284A),
                    const Color(0xFF0C1B34),
                  ]
                : [
                    const Color(0xFF111C38),
                    const Color(0xFF0C1428),
                  ],
          ),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? ScannerHUDTheme.neonCyan
                : const Color(0xFF1E2D4A),
            width: selected ? 1.8 : 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: selected
                  ? ScannerHUDTheme.neonCyan.withValues(alpha: 0.12)
                  : Colors.black.withValues(alpha: 0.1),
              blurRadius: selected ? 10 : 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: selected
                  ? ScannerHUDTheme.neonCyan
                  : const Color(0xFF64748B),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr(titleKey),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: selected ? Colors.white : const Color(0xFFE2E8F0),
                    ),
                  ),
                  Text(
                    context.tr(subKey),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(
                Icons.check_circle,
                color: ScannerHUDTheme.neonCyan,
                size: 20,
              ),
          ],
        ),
      ),
    );
  }

  Widget _routingCard() {
    final plan = _plan;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B2239), Color(0xFF0A1729)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.55),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.alt_route, color: ScannerHUDTheme.neonCyan, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'NEAREST SPECIALIST · OFFLINE ROUTING',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              TextButton(
                onPressed: _openRoutingDirectory,
                child: const Text(
                  'Manage',
                  style: TextStyle(
                    color: ScannerHUDTheme.neonCyan,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (_routingLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: ScannerHUDTheme.neonCyan,
                  ),
                ),
              ),
            )
          else if (plan != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              plan.primary.specialist.displayName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (plan.primary.specialist.isDemo) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF59E0B).withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: const Color(0xFFF59E0B)),
                              ),
                              child: const Text(
                                'DEMO',
                                style: TextStyle(
                                  color: Color(0xFFF59E0B),
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        plan.primary.specialist.facilityName,
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _routeChip(
                            plan.urgency.shortLabel,
                            plan.urgency == ReferralUrgency.urgent
                                ? const Color(0xFFEF4444)
                                : plan.urgency == ReferralUrgency.priority
                                    ? const Color(0xFFF59E0B)
                                    : const Color(0xFF38BDF8),
                          ),
                          _routeChip(plan.primary.mode.label, ScannerHUDTheme.neonCyan),
                          _routeChip(plan.primary.distanceLabel, const Color(0xFFA78BFA)),
                          _routeChip(plan.primary.travelLabel, const Color(0xFF34D399)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        plan.summary,
                        style: const TextStyle(
                          color: Color(0xFFCBD5E1),
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                      if (plan.alternates.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Alternates: ${plan.alternates.map((r) => r.specialist.displayName).join(', ')}',
                          style: const TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: _changeSpecialist,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: ScannerHUDTheme.neonCyan,
                    side: BorderSide(
                      color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.6),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                  child: const Text('Change', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Route estimate uses the offline facility graph (Haversine road '
              'factor). No internet or patient data leaves the device.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 10, height: 1.4),
            ),
          ] else ...[
            Text(
              _routingHint ?? 'No routing destination is configured.',
              style: const TextStyle(
                color: Color(0xFFF59E0B),
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openRoutingDirectory,
              icon: const Icon(Icons.settings_ethernet, size: 16),
              label: const Text('Configure Specialist Directory'),
              style: OutlinedButton.styleFrom(
                foregroundColor: ScannerHUDTheme.neonCyan,
                side: BorderSide(
                  color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _routeChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _specialistRecipientCard() {
    final hasRecipient = _specialistEmail.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: hasRecipient
              ? const Color(0xFF00E5FF).withValues(alpha: 0.35)
              : const Color(0xFFF59E0B).withValues(alpha: 0.4),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
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
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: hasRecipient
                      ? const Color(0xFF064E3B).withValues(alpha: 0.5)
                      : const Color(0xFF78350F).withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  hasRecipient ? Icons.local_hospital : Icons.mark_email_unread_outlined,
                  size: 18,
                  color: hasRecipient ? const Color(0xFF34D399) : const Color(0xFFFBBF24),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ASSIGNED SPECIALIST RECIPIENT',
                      style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasRecipient ? _specialistEmail : 'No specialist email assigned yet',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: hasRecipient ? Colors.white : const Color(0xFFFBBF24),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _editSpecialistEmailDialog,
                icon: Icon(
                  hasRecipient ? Icons.edit_outlined : Icons.add_circle_outline,
                  size: 16,
                  color: ScannerHUDTheme.neonCyan,
                ),
                label: Text(
                  hasRecipient ? 'Edit' : 'Add',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: ScannerHUDTheme.neonCyan,
                  ),
                ),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: hasRecipient ? const Color(0xFF10B981) : const Color(0xFFF59E0B),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasRecipient
                      ? (_autoSendEnabled
                          ? 'Automated Email Dossier & PDF will be dispatched on submission'
                          : 'Manual referral mode active (auto-send disabled in Admin)')
                      : 'Referral email alerts paused until an email is added',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                ),
              ),
              GestureDetector(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AdminPortalScreen()),
                  );
                  await _loadSpecialistRecipient();
                },
                child: const Text(
                  'Admin Portal →',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF00E5FF),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
