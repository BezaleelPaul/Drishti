import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../l10n/lang_scope.dart';
import '../../l10n/evidence_strings.dart';
import '../../models/retinal_markers.dart';
import '../../models/screening_models.dart' as ui;
import '../../services/ml/pipeline/structure_segmenter.dart';
import '../../theme/figma_theme.dart';
import '../../widgets/orbit/orbit.dart';
import '../../widgets/review/gradcam_explanation_card.dart';
import '../../widgets/review/zoomable_fundus_screen.dart';
import '../../widgets/scanner/scanner.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/workflow_bar.dart';
import 'flow_capture_screen.dart';
import 'flow_specialist_screen.dart';
import 'flow_state.dart';

/// Figma "AI Screening Result" (Workflow step 3):
/// severity scale, findings, explainability.
///
/// Honest-visibility rules enforced here:
/// - preliminary on-device results are never labeled service-confirmed;
/// - no synthetic "attention" overlay is ever drawn over the fundus;
/// - an explanation section either shows a real model-derived artifact or
///   an explicit unavailable state.
class FlowResultScreen extends StatefulWidget {
  final FlowState state;

  const FlowResultScreen({super.key, required this.state});

  @override
  State<FlowResultScreen> createState() => _FlowResultScreenState();
}

class _FlowResultScreenState extends State<FlowResultScreen> {
  static const _sevKeys = [
    'sev_no_dr',
    'sev_mild',
    'sev_moderate',
    'sev_severe',
    'sev_pdr',
  ];
  static const _sevColors = [
    FigmaColors.success,
    Color(0xFF2563EB),
    FigmaColors.warning,
    Color(0xFFEA580C),
    FigmaColors.danger,
  ];

  RetinalMarkers? _markers;
  bool _markersLoading = false;

  @override
  void initState() {
    super.initState();
    _markers = widget.state.markers;
    if (_markers == null) _loadMarkers();
  }

  /// Computes classical-CV landmark markers off the UI thread. Advisory
  /// only — never gates the grade and never fabricates a landmark.
  Future<void> _loadMarkers() async {
    final bytes = widget.state.imageBytes;
    if (bytes == null) return;
    setState(() => _markersLoading = true);
    try {
      final markers = await compute(computeRetinalMarkers, bytes);
      if (!mounted) return;
      widget.state.markers = markers;
      setState(() => _markers = markers);
    } catch (_) {
      if (!mounted) return;
      setState(() => _markers = null);
    } finally {
      if (mounted) setState(() => _markersLoading = false);
    }
  }

  /// Honest provenance line (E-2): where the numbers came from and what
  /// they cost. Measured on-device time when available, e.g.
  /// "on-device TFLite, 612 ms" — never a fabricated number.
  String _backendSuffix(ui.ScreeningAnalysisModel a) {
    final backend = a.modelBackend;
    final ms = (a.biomarkers?['inference_time_ms'] as num?)?.toDouble();
    if (backend == null && ms == null) return '';
    final parts = <String>[
      if (backend != null) backend == 'tflite-fp32' ? 'on-device' : backend,
      if (ms != null) '${ms.toStringAsFixed(0)} ms',
    ];
    return parts.isEmpty ? '' : '  •  ${parts.join(" • ")}';
  }

  void _rescan() {
    widget.state.imageBytes = null;
    widget.state.quality = null;
    widget.state.analysis = null;
    widget.state.markers = null;
    widget.state.screeningId = null;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => FlowCaptureScreen(state: widget.state),
      ),
    );
  }

  void _openInspector() {
    final bytes = widget.state.imageBytes;
    if (bytes == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ZoomableFundusScreen(
          imageBytes: bytes,
          title: 'Fundus inspection',
          caption: 'Inspect the original capture · pinch, drag, double-tap',
          markers: _markers,
          onRescan: _rescan,
        ),
      ),
    );
  }

  /// Landmark marker status card. Honest provenance: coordinates come from
  /// classical CV segmentation computed on-device — they are structural
  /// landmarks and lesion CANDIDATES, never model attention or a diagnosis.
  Widget _markerCard() {
    Widget body;
    if (_markersLoading) {
      body = Row(
        children: const [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Locating landmarks (optic disc, fovea, lesion candidates)…',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ),
        ],
      );
    } else {
      final markers = _markers;
      if (markers == null || !markers.available) {
        body = Text(
          markers?.reason ?? 'Landmark markers are unavailable for this image.',
          style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
        );
      } else {
        final count = markers.maCandidates.length;
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              count == 0
                  ? 'Optic disc & fovea located. No lesion candidates found '
                        '(classical CV — a clear frame can be healthy).'
                  : 'Optic disc, fovea and $count lesion candidate${count == 1 ? '' : 's'} '
                        'located (classical CV segmentation).',
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('view_markers_arrows'),
                onPressed: _openInspector,
                icon: const Icon(Icons.arrow_outward, size: 14),
                label: const Text(
                  'View with arrows',
                  style: TextStyle(fontSize: 11),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: ScannerHUDTheme.neonCyan,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
            ),
          ],
        );
      }
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.my_location,
            size: 16,
            color: ScannerHUDTheme.neonCyan,
          ),
          const SizedBox(width: 8),
          Expanded(child: body),
        ],
      ),
    );
  }

  /// Evidence-linked criteria card (schema_version 1.0 payloads only).
  ///
  /// Rendered ONLY when the backend-graded analysis carries criteria
  /// evaluations: each criterion row shows its localized title, status
  /// chip, and how many lesion candidates support it. Unsupported criteria
  /// (no detector) are shown as "not evaluated" — absence is never
  /// presented as a negative clinical finding. The upper-bound note states
  /// the documented ICDRS subset limitation. No card renders when the
  /// payload carries no criteria (on-device/offline path): the existing
  /// unavailable states already communicate that honestly.
  Widget _criteriaCard() {
    final a = widget.state.analysis!;
    final criteria = a.criteriaEvaluation;
    if (criteria.isEmpty) return const SizedBox.shrink();

    final rows = <Widget>[];
    for (final c in criteria) {
      final (icon, color) = switch (c.status) {
        CriterionEvaluation.satisfied => (
          Icons.check_circle,
          const Color(0xFF34D399),
        ),
        CriterionEvaluation.notMet => (
          Icons.remove_circle,
          const Color(0xFF94A3B8),
        ),
        CriterionEvaluation.indeterminate => (
          Icons.help_outline,
          FigmaColors.warning,
        ),
        _ => (Icons.block, const Color(0xFF94A3B8)),
      };
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${context.ev(c.criterionId)}  ·  ${context.ev('criterion_status_${c.status}')}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFFE2E8F0),
                  ),
                ),
              ),
              if (c.supportingEvidenceIds.isNotEmpty)
                Text(
                  '${c.supportingEvidenceIds.length}',
                  key: ValueKey('criteria-count-${c.criterionId}'),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: ScannerHUDTheme.neonCyan,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final policy = a.gradingPolicy;
    return Container(
      key: const ValueKey('criteria-evidence-card'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.ev('criteria_title'),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          ...rows,
          const SizedBox(height: 6),
          Text(
            context.ev('upper_bound_note'),
            style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
          ),
          if (policy != null && policy.policyId.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${context.ev('policy_label')}: ${policy.policyId} v${policy.policyVersion}',
              style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
            ),
          ],
        ],
      ),
    );
  }

  /// CNN-vs-evidence disagreement banner. Conflict/model-unavailable states
  /// force the review styling; match/adjacent states stay advisory. Only
  /// renders from payload data — never synthesized in the UI.
  Widget _disagreementBanner() {
    final d = widget.state.analysis?.disagreement;
    if (d == null) return const SizedBox.shrink();
    final (border, text) = switch (d.status) {
      DisagreementInfo.conflict => (
        FigmaColors.danger,
        context.ev('disagreement_conflict'),
      ),
      DisagreementInfo.modelUnavailable => (
        FigmaColors.danger,
        context.ev('disagreement_model_unavailable'),
      ),
      DisagreementInfo.adjacent => (
        FigmaColors.warning,
        context.ev('disagreement_adjacent'),
      ),
      DisagreementInfo.incomplete => (
        const Color(0xFF1E293B),
        context.ev('disagreement_incomplete'),
      ),
      DisagreementInfo.notAsserted => (
        const Color(0xFF1E293B),
        context.ev('disagreement_not_asserted'),
      ),
      DisagreementInfo.match => (
        const Color(0xFF14532D),
        context.ev('disagreement_match'),
      ),
      _ => (const Color(0xFF1E293B), context.ev('disagreement_incomplete')),
    };
    return Container(
      key: const ValueKey('disagreement-banner'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(
            d.reviewRequired ? Icons.gpp_maybe : Icons.balance,
            size: 15,
            color: d.reviewRequired
                ? FigmaColors.danger
                : ScannerHUDTheme.neonCyan,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFE2E8F0)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.state.analysis == null;
    if (pending) {
      return Scaffold(
        backgroundColor: ScannerHUDTheme.background,
        appBar: AppBar(
          backgroundColor: ScannerHUDTheme.darkSurface,
          foregroundColor: ScannerHUDTheme.neonCyan,
          elevation: 0,
          title: Text(
            context.tr('ai_result_title'),
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ),
        body: Center(
          child: Text(
            context.tr('awaiting_verif'),
            style: const TextStyle(color: FigmaColors.warning),
          ),
        ),
      );
    }
    final a = widget.state.analysis!;
    final grade = a.drGrade ?? 0;
    // A terminal error code means the prediction is not a result: never show
    // it as "AI detected X". Exception: a referable grade stays visible
    // because under-referral is the larger clinical risk.
    final errorCode = a.errorCode;
    final isReferable = a.isReferable == true;
    final ungraded = a.drGrade == null || (errorCode != null && !isReferable);
    final provisional = errorCode != null && !ungraded;
    final idx = grade.clamp(0, 4);
    final conf = a.predictionScore != null
        ? '${(a.predictionScore! * 100).toStringAsFixed(1)}%'
        : '—';
    final ma = (a.biomarkers?['microaneurysm_count'] as num?)?.toInt() ?? 0;

    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          context.tr('ai_result_title'),
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
                const WorkflowBar(step: 3, dark: true),
                const SizedBox(height: 12),
                _urgentReferralBanner(a),
                // Result card
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
                    border: Border.all(
                      color: ungraded
                          ? const Color(0xFFF59E0B).withValues(alpha: 0.35)
                          : _sevColors[idx].withValues(alpha: 0.35),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (ungraded ? const Color(0xFFF59E0B) : _sevColors[idx])
                            .withValues(alpha: 0.1),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const StatusBadge(status: FigmaStatus.awaitingSpecialist),
                      const SizedBox(height: 8),
                      // Provenance/limitation markers: what this result is
                      // (preliminary) and how it reached us (offline queue).
                      // Backend identity stays in the confidence line below.
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (!ungraded)
                            const OrbitChip(
                              label: 'PRELIMINARY',
                              color: Color(0xFFA855F7),
                            ),
                          if (a.isOffline)
                            const OrbitChip(
                              label: 'OFFLINE — PENDING SYNC',
                              color: Color(0xFFF59E0B),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        ungraded
                            ? context.tr('awaiting_verif')
                            : '${context.tr('ai_detected')}: ${context.tr(_sevKeys[idx])}'
                                  '${provisional ? ' — provisional, clinician sign-off required' : ''}',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: ungraded
                              ? FigmaColors.warning
                              : _sevColors[idx],
                        ),
                      ),
                      Text(
                        '${context.tr('confidence')}: $conf'
                        '${_backendSuffix(a)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                      // Rejection transparency: when the gate refuses an
                      // image the operator must see WHY (reason codes are
                      // the contract — a bare "pending" reads like a bug).
                      if (ungraded && a.rejectionReasons.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: ScannerHUDTheme.darkSurface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: FigmaColors.danger),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Rejected — no DR grade assigned '
                                '(${a.errorCode ?? 'IMG_UNGRADABLE'}):',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFFF87171),
                                ),
                              ),
                              for (final reason in a.rejectionReasons)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    '• $reason',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFFE2E8F0),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        context.tr('severity_scale'),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          for (var i = 0; i < 5; i++)
                            Expanded(
                              child: Container(
                                height: 10,
                                margin: EdgeInsets.only(right: i < 4 ? 4 : 0),
                                decoration: BoxDecoration(
                                  color: !ungraded && i <= idx
                                      ? _sevColors[idx]
                                      : const Color(0xFF1E293B),
                                  borderRadius: BorderRadius.circular(5),
                                  boxShadow: !ungraded && i == idx
                                      ? [
                                          BoxShadow(
                                            color: _sevColors[idx].withValues(alpha: 0.6),
                                            blurRadius: 6,
                                          ),
                                        ]
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            context.tr('sev_no_dr'),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                          Text(
                            context.tr('sev_pdr'),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${context.tr('risk_level')} ${(a.isReferable ?? false) ? context.tr('badge_referral') : (idx == 0 ? '${context.tr('sev_no_dr')} (Low Risk)' : (idx == 1 ? '${context.tr('sev_mild_npdr')} (Low Risk)' : context.tr('sev_moderate')))}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // Findings
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
                        context.tr('ai_findings'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (ma > 0 || grade >= 1)
                        _finding(context.tr('finding_ma'), '$ma'),
                      if (grade >= 2) ...[
                        _finding(context.tr('finding_hm'), '✓'),
                        _finding(context.tr('finding_ex'), '✓'),
                      ],
                      _finding(context.tr('finding_iq'), a.qualityGrade),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // Explainability — honest state only: real fundus image plus
                // an explicit unavailable notice (no synthetic overlay).
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF1E293B)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('xai_label'),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (widget.state.imageBytes != null)
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 320),
                            child: ScannerView(
                              imageBytes: widget.state.imageBytes,
                              isInteractive: true,
                              state:
                                  a.qualityGrade.toUpperCase() == 'BORDERLINE'
                                  ? ScannerAnimationState.reviewRequired
                                  : ScannerAnimationState.resultReady,
                              customStatusText:
                                  a.qualityGrade.toUpperCase() == 'BORDERLINE'
                                  ? 'REVIEW REQUIRED'
                                  : 'ORIGINAL FUNDUS',
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              context.tr('original_fundus'),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: widget.state.imageBytes == null
                                ? null
                                : _openInspector,
                            icon: const Icon(Icons.zoom_in, size: 16),
                            label: const Text('Inspect & zoom'),
                            style: TextButton.styleFrom(
                              foregroundColor: ScannerHUDTheme.neonCyan,
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        'Pinch to zoom · open full-screen for detail',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white38,
                        ),
                      ),
                      const SizedBox(height: 8),
                      GradcamExplanationCard(analysis: a),
                      const SizedBox(height: 8),
                      _markerCard(),
                      _criteriaCard(),
                      _disagreementBanner(),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${context.tr('ai_note_label')} ${context.tr('ai_note_text')}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94A3B8),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: OutlinedButton.icon(
                        key: const ValueKey('btn_rescan_capture'),
                        onPressed: _rescan,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(
                          context.tr('btn_rescan'),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          foregroundColor: const Color(0xFF67E8F9),
                          side: const BorderSide(color: Color(0xFF00B4D8), width: 1.2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 1,
                      child: ElevatedButton(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => FlowSpecialistScreen(state: widget.state),
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: const Color(0xFF00B4D8),
                          foregroundColor: Colors.white,
                          elevation: 3,
                          shadowColor: const Color(0x6600B4D8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          context.tr('btn_proceed_specialist'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _urgentReferralBanner(ui.ScreeningAnalysisModel a) {
    if (a.isReferable != true && (a.drGrade ?? 0) < 2) {
      return const SizedBox.shrink();
    }
    final grade = a.drGrade ?? 0;
    final isUrgent = grade >= 3;
    final bannerColor =
        isUrgent ? const Color(0xFFEF4444) : const Color(0xFFF59E0B);
    final bannerBg =
        isUrgent ? const Color(0xFF2A0F0F) : const Color(0xFF261908);
    final title = isUrgent
        ? 'URGENT OPHTHALMOLOGY REFERRAL REQUIRED'
        : 'OPHTHALMOLOGY CONSULTATION RECOMMENDED';
    final timeframe = isUrgent
        ? 'Schedule evaluation within 48–72 hours at District Hospital'
        : 'Schedule routine referral within 2–4 weeks at Primary Eye Care';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bannerBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: bannerColor.withValues(alpha: 0.6),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: bannerColor.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isUrgent ? Icons.warning_rounded : Icons.info_outline_rounded,
                color: bannerColor,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: bannerColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            timeframe,
            style: const TextStyle(
              color: Color(0xFFF1F5F9),
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (a.actionRecommendation.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              a.actionRecommendation,
              style: const TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _finding(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 15, color: FigmaColors.success),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Color(0xFFE2E8F0)),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }
}
