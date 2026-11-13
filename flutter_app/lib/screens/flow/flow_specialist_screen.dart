import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/lang_scope.dart';
import '../../services/api_service.dart';
import '../../services/db/screening_persistence_service.dart';
import '../../services/smtp/smtp_service.dart';
import '../../widgets/scanner/scanner.dart';
import '../../widgets/workflow_bar.dart';
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
      unawaited(SmtpService().handleScreeningCompleted(widget.state));
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
                const SizedBox(height: 10),
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
                    onChanged: (v) => setState(() => _correctedGrade = v ?? 2),
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
      onTap: () => setState(() => _decision = value),
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
}
