import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../l10n/lang_scope.dart';
import '../models/screening_models.dart';
import '../services/db/screening_persistence_service.dart';
import '../services/pdf/clinical_pdf_generator.dart';
import '../services/smtp/smtp_service.dart';
import '../theme/figma_theme.dart';
import '../widgets/scanner/scanner_theme.dart';
import '../widgets/status_badge.dart';
import 'figma_dashboard_screen.dart';
import 'flow/flow_state.dart';

/// Patient History — real longitudinal records only, dark HUD chrome
/// consistent with the clinical shell.
/// Powered by ScreeningPersistenceService multi-tier storage:
/// encrypted SQLite vault, SharedPreferences instant cache, and local file backup.
class FigmaHistoryScreen extends StatefulWidget {
  const FigmaHistoryScreen({super.key});

  @override
  State<FigmaHistoryScreen> createState() => _FigmaHistoryScreenState();
}

class _FigmaHistoryScreenState extends State<FigmaHistoryScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _rawRecords = const [];
  List<(String, String, String, String, FigmaStatus)> _rows = const [];
  String _searchQuery = '';
  String _selectedFilter = 'all';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaitedLoad();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<(String, String, String, String, FigmaStatus, Map<String, dynamic>)> get _filteredRows {
    final List<(String, String, String, String, FigmaStatus, Map<String, dynamic>)> result = [];
    for (int i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      final record = i < _rawRecords.length ? _rawRecords[i] : <String, dynamic>{};
      final pid = r.$1.toLowerCase();
      final name = r.$2.toLowerCase();
      final res = r.$4.toLowerCase();
      final status = r.$5;

      if (_selectedFilter == 'urgent') {
        final isUrgent = status == FigmaStatus.referral ||
            res.contains('severe') ||
            res.contains('pdr') ||
            res.contains('grade 3') ||
            res.contains('grade 4');
        if (!isUrgent) continue;
      } else if (_selectedFilter == 'awaiting') {
        final isAwaiting = status == FigmaStatus.awaitingAi ||
            status == FigmaStatus.awaitingSpecialist;
        if (!isAwaiting) continue;
      } else if (_selectedFilter == 'normal') {
        final isNormal = status == FigmaStatus.verified ||
            res.contains('no dr') ||
            res.contains('mild');
        if (!isNormal) continue;
      }

      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        if (!pid.contains(q) && !name.contains(q) && !res.contains(q)) {
          continue;
        }
      }
      result.add((r.$1, r.$2, r.$3, r.$4, r.$5, record));
    }
    return result;
  }

  Future<void> unawaitedLoad() async {
    setState(() => _loading = true);
    List<Map<String, dynamic>> records = const [];
    List<(String, String, String, String, FigmaStatus)> mappedRows = const [];
    try {
      records = await ScreeningPersistenceService().getRecentScreenings(limit: 100);
      mappedRows = records.map((r) => localScreeningRow(r)).toList();
    } catch (e) {
      debugPrint('Screening history load error: $e');
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
      _rawRecords = records;
      _rows = mappedRows;
    });
  }

  FlowState _buildFlowStateFromRecord(Map<String, dynamic> r) {
    final pid = (r['local_patient_id'] ?? r['patient_id'] ?? 'PT-UNKNOWN').toString();
    final name = (r['name'] ?? pid).toString();
    final age = (r['age'] as num?)?.toInt() ?? 50;
    final gender = (r['gender'] ?? 'Unknown').toString();
    final phone = (r['phone'] ?? '').toString();
    final village = (r['village'] ?? '').toString();
    final grade = (r['dr_grade_num'] as num?)?.toInt() ?? 0;
    final label = (r['dr_label'] ??
            (grade == 0
                ? 'No Diabetic Retinopathy'
                : 'Diabetic Retinopathy Grade $grade'))
        .toString();
    final conf = (r['confidence'] as num?)?.toDouble() ?? 0.95;
    final eye = (r['eye_side'] ?? 'Right').toString();
    final sid = (r['local_screening_id'] ?? 'LOC-$pid').toString();

    // Check if image file exists
    final imgPath = (r['image_path'] ?? '').toString();
    List<int>? bytes;
    if (imgPath.isNotEmpty && File(imgPath).existsSync()) {
      try {
        bytes = File(imgPath).readAsBytesSync();
      } catch (_) {}
    }

    return FlowState(
      patient: PatientModel(
        patientId: pid,
        name: name,
        age: age,
        gender: gender,
        phone: phone,
        abhaId: '',
        village: village,
        knownDiabetes: (r['known_diabetes'] ?? 'Yes').toString(),
        diabetesDurationYears: (r['diabetes_duration_years'] as num?)?.toDouble(),
        hba1c: (r['hba1c'] as num?)?.toDouble(),
        fastingGlucose: (r['fasting_glucose'] as num?)?.toDouble(),
        bloodPressure: r['blood_pressure']?.toString(),
      ),
      eyeSide: eye,
      imageBytes: bytes != null ? Uint8List.fromList(bytes) : null,
      analysis: ScreeningAnalysisModel.fromJson({
        'screening_id': sid,
        'patient_id': pid,
        'eye_side': eye,
        'camera_profile': 'Remidio FOP (Smartphone Handheld)',
        'quality_grade': 'GOOD',
        'quality_score': 0.95,
        'quality_passed': true,
        'rejection_reasons': <String>[],
        'dr_grade': grade,
        'dr_label': label,
        'prediction_score': conf,
        'is_referable': grade > 0,
        'requires_human_review':
            ((r['requires_human_review'] as num?)?.toInt() ?? 0) == 1,
        'human_review_type': grade >= 3 ? 'URGENT' : (grade > 0 ? 'ROUTINE' : null),
        'human_review_reason': (r['human_review_reason'] ?? '').toString(),
        'original_image_url': '',
        'model_backend': (r['model_backend'] ?? 'tflite-fp32').toString(),
        'action_recommendation': grade > 0 ? 'Route to specialist' : 'Annual screening',
        'plain_language_advice': grade > 0 ? 'Specialist review recommended' : 'Retina healthy',
        'sms_referral_slip': '',
      }),
      specialistNotes: (r['human_review_reason'] ?? '').toString(),
    );
  }

  void _showPatientDetailModal(Map<String, dynamic> r) {
    final pid = (r['local_patient_id'] ?? '').toString();
    final name = (r['name'] ?? pid).toString();
    final age = r['age']?.toString() ?? '—';
    final gender = (r['gender'] ?? '—').toString();
    final village = (r['village'] ?? '—').toString();
    final phone = (r['phone'] ?? '—').toString();
    final eye = (r['eye_side'] ?? 'Right').toString();
    final grade = (r['dr_grade_num'] as num?)?.toInt() ?? 0;
    final label = (r['dr_label'] ?? 'Unknown').toString();
    final reason = (r['human_review_reason'] ?? '').toString();
    final date = formatScreeningDate(r['created_at']?.toString());
    final flowState = _buildFlowStateFromRecord(r);

    bool isExportingPdf = false;
    bool isDispatchingEmail = false;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF0C1428),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.3)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 20,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.person, color: Color(0xFF00E5FF), size: 24),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                'ID: $pid · $age yrs · $gender · $village',
                                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(color: Color(0xFF1E2D4A), height: 24),
                    // Diagnostic Overview Card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111C38),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: grade >= 3
                              ? const Color(0xFFEF4444).withValues(alpha: 0.5)
                              : (grade > 0
                                  ? const Color(0xFFF59E0B).withValues(alpha: 0.5)
                                  : const Color(0xFF10B981).withValues(alpha: 0.5)),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'AI Screening: $eye Eye',
                                style: const TextStyle(
                                  color: Color(0xFF7DF9FF),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                date,
                                style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            label,
                            style: TextStyle(
                              color: grade >= 3
                                  ? const Color(0xFFEF4444)
                                  : (grade > 0
                                      ? const Color(0xFFFBBF24)
                                      : const Color(0xFF34D399)),
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (reason.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Specialist / Triage: $reason',
                              style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 12),
                            ),
                          ],
                          if (phone.isNotEmpty && phone != '—') ...[
                            const SizedBox(height: 4),
                            Text(
                              'Contact: $phone',
                              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Action Buttons: PDF and Email
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF),
                              foregroundColor: const Color(0xFF0A1128),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: isExportingPdf
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFF0A1128),
                                    ),
                                  )
                                : const Icon(Icons.picture_as_pdf_rounded, size: 20),
                            label: Text(
                              isExportingPdf ? 'Generating...' : 'Open PDF Report',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            onPressed: isExportingPdf
                                ? null
                                : () async {
                                    final messenger = ScaffoldMessenger.of(context);
                                    setModalState(() => isExportingPdf = true);
                                    try {
                                      final path = await ClinicalPdfGenerator.saveReportToFile(flowState);
                                      if (Platform.isMacOS) {
                                        await Process.run('open', [path]);
                                      }
                                      messenger.showSnackBar(
                                        SnackBar(
                                          backgroundColor: const Color(0xFF065F46),
                                          content: Text('Report saved to: $path'),
                                        ),
                                      );
                                    } catch (e) {
                                      messenger.showSnackBar(
                                        SnackBar(
                                          backgroundColor: const Color(0xFF7F1D1D),
                                          content: Text('Failed to generate PDF: $e'),
                                        ),
                                      );
                                    } finally {
                                      setModalState(() => isExportingPdf = false);
                                    }
                                  },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF00E5FF),
                              side: const BorderSide(color: Color(0xFF00E5FF)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: isDispatchingEmail
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFF00E5FF),
                                    ),
                                  )
                                : const Icon(Icons.mail_outline_rounded, size: 20),
                            label: Text(
                              isDispatchingEmail ? 'Sending...' : 'Email Specialist',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                            onPressed: isDispatchingEmail
                                ? null
                                : () async {
                                    final messenger = ScaffoldMessenger.of(context);
                                    setModalState(() => isDispatchingEmail = true);
                                    try {
                                      final res = await SmtpService().sendSpecialistAlert(state: flowState);
                                      messenger.showSnackBar(
                                        SnackBar(
                                          backgroundColor: res.success
                                              ? const Color(0xFF065F46)
                                              : const Color(0xFF7F1D1D),
                                          content: Text(res.success
                                              ? 'Clinical alert & PDF emailed successfully!'
                                              : 'SMTP error: ${res.message}'),
                                        ),
                                      );
                                    } catch (e) {
                                      messenger.showSnackBar(
                                        SnackBar(
                                          backgroundColor: const Color(0xFF7F1D1D),
                                          content: Text('Email failed: $e'),
                                        ),
                                      );
                                    } finally {
                                      setModalState(() => isDispatchingEmail = false);
                                    }
                                  },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: Text(
          context.tr('history_title'),
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh Local Records',
            icon: const Icon(Icons.refresh_rounded, color: ScannerHUDTheme.neonCyan),
            onPressed: unawaitedLoad,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('screening_history'),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F2942),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF00E5FF).withValues(alpha: 0.4),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.shield_outlined, size: 13, color: Color(0xFF00E5FF)),
                        SizedBox(width: 5),
                        Text(
                          'Local Encrypted Vault',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF00E5FF),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: CircularProgressIndicator(
                      color: ScannerHUDTheme.neonCyan,
                    ),
                  ),
                )
              else if (_rows.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
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
                    border: Border.all(color: const Color(0xFF1E2D4A)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF162344),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.folder_off_outlined,
                          color: Color(0xFF94A3B8),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Text(
                          'No screening records yet — capture a screening '
                          'for a patient and it appears here.',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                _searchAndFilterBar(context),
                const SizedBox(height: 12),
                if (_filteredRows.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: ScannerHUDTheme.darkSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF1E2D4A)),
                    ),
                    child: Center(
                      child: Column(
                        children: [
                          const Icon(
                            Icons.search_off_rounded,
                            color: Color(0xFF64748B),
                            size: 26,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _searchQuery.isNotEmpty
                                ? 'No records matching "$_searchQuery"'
                                : 'No records in this category',
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ..._filteredRows.map(
                    (item) {
                      final pid = item.$1;
                      final name = item.$2;
                      final date = item.$3;
                      final res = item.$4;
                      final status = item.$5;
                      final record = item.$6;

                      final initial = name.isNotEmpty ? name.trim()[0].toUpperCase() : 'P';
                      return InkWell(
                        onTap: () => _showPatientDetailModal(record),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFF111B34),
                                Color(0xFF0C1428),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFF1E2D4A), width: 1),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.15),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF0E7490),
                                      Color(0xFF00B4D8),
                                    ],
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF00B4D8).withValues(alpha: 0.25),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Text(
                                    initial,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            name,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 14,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        if (pid.isNotEmpty) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 5,
                                              vertical: 1,
                                            ),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF1A2642),
                                              borderRadius: BorderRadius.circular(4),
                                              border: Border.all(color: const Color(0xFF283A64)),
                                            ),
                                            child: Text(
                                              pid,
                                              style: const TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w600,
                                                color: Color(0xFF7DF9FF),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      '$res · $date',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF94A3B8),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              StatusBadge(status: status),
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.chevron_right_rounded,
                                color: Color(0xFF64748B),
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
              ],
              if (!_loading && _rows.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 14, bottom: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_outline, size: 12, color: Color(0xFF64748B)),
                      SizedBox(width: 6),
                      Text(
                        'Stored locally on this device via encrypted SQLCipher database',
                        style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchAndFilterBar(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 4, bottom: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF101A33),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF223254)),
          ),
          child: TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search records by name or patient ID...',
              hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
              prefixIcon: const Icon(
                Icons.search,
                color: Color(0xFF94A3B8),
                size: 18,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Color(0xFF94A3B8),
                        size: 16,
                      ),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            onChanged: (val) => setState(() => _searchQuery = val.trim()),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _filterChip('all', 'All (${_rows.length})', null),
              const SizedBox(width: 6),
              _filterChip('urgent', 'Urgent / Referral', const Color(0xFFEF4444)),
              const SizedBox(width: 6),
              _filterChip('awaiting', 'Pending Review', const Color(0xFFF59E0B)),
              const SizedBox(width: 6),
              _filterChip('normal', 'Normal / Mild', const Color(0xFF10B981)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String id, String label, Color? dotColor) {
    final isSelected = _selectedFilter == id;
    return InkWell(
      onTap: () => setState(() => _selectedFilter = id),
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected
              ? ScannerHUDTheme.neonCyan.withValues(alpha: 0.18)
              : const Color(0xFF101932),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? ScannerHUDTheme.neonCyan
                : const Color(0xFF223254),
            width: isSelected ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? ScannerHUDTheme.neonCyan
                    : const Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
