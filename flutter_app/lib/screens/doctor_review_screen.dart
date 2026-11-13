import 'package:flutter/material.dart';
import '../models/retinal_markers.dart';
import '../services/api_service.dart';
import '../widgets/review/marker_viewer.dart';
import '../widgets/scanner/scanner_theme.dart';

/// Tele-ophthalmologist Review Queue — dark HUD chrome consistent with the
/// clinical shell (dashboard/about). Review affordances and copy are pinned
/// by doctor_review_markers_test.dart; only the styling was restyled.
class DoctorReviewScreen extends StatefulWidget {
  final ApiService apiService;

  final bool embedded;

  const DoctorReviewScreen({
    super.key,
    required this.apiService,
    this.embedded = false,
  });

  @override
  State<DoctorReviewScreen> createState() => _DoctorReviewScreenState();
}

class _DoctorReviewScreenState extends State<DoctorReviewScreen> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _pendingCases = [];
  String? _authNotice;

  @override
  void initState() {
    super.initState();
    _loadQueue();
  }

  Future<void> _loadQueue() async {
    setState(() {
      _isLoading = true;
      _authNotice = null;
    });
    List<Map<String, dynamic>> remoteCases = [];
    try {
      remoteCases = await widget.apiService.getPendingReviews();
    } on ReviewAuthException catch (e) {
      // Operator key on a doctor-only endpoint: say so instead of
      // rendering a fake "empty queue".
      _authNotice = e.message;
    }
    if (mounted) {
      setState(() {
        _isLoading = false;
        if (remoteCases.isNotEmpty) {
          _pendingCases = remoteCases.map((item) {
            final rawGrade = item['dr_grade_num'];
            final int? parsedGrade = rawGrade == null
                ? null
                : rawGrade is int
                ? rawGrade
                : int.tryParse(rawGrade.toString());
            final rawConf = item['dr_confidence'];
            final String confidenceStr = rawConf != null
                ? '${(rawConf * 100).toStringAsFixed(1)}%'
                : 'N/A';
            return {
              'review_id': item['review_id'] ?? item['id'] ?? 'Unknown',
              'patient_name': item['patient_name'] ?? 'Unknown',
              'abha_id': item['abha_id'] ?? 'Unknown',
              'screening_id': item['screening_id'] ?? 'Unknown',
              'eye_side': item['eye_side'] ?? 'Unknown',
              'original_image_url': item['original_image_url'] ?? '',
              'dr_grade': parsedGrade,
              'dr_label': item['dr_grade_label'] ?? 'Unknown',
              'reason':
                  item['human_review_reason'] ??
                  'No reason provided by AI backend.',
              'confidence': confidenceStr,
              'priority': item['priority'] ?? 'Review Required',
              'is_signed_off': item['status'] != 'PENDING',
            };
          }).toList();
        } else {
          // No remote cases and no cached queue: truly nothing to review.
          // Do NOT inject mock patient data — that would present fabricated
          // clinical records as real.
          _pendingCases = [];
        }
      });
    }
  }

  Future<void> _signOffCase(int index) async {
    final caseItem = _pendingCases[index];
    final revId = caseItem['review_id'].toString();

    // Optimistically update
    setState(() {
      _pendingCases[index]['is_signed_off'] = true;
    });

    // A verdict is only real when the SERVER accepts it: an operator key
    // gets 401/403 here, and claiming success would forge a clinical
    // sign-off the backend never recorded. Revert + say so on failure.
    final result = await widget.apiService.submitDoctorDecision(
      reviewId: revId,
      doctorName: 'Dr. Sharma (MS Ophth)',
      decision: 'CONFIRMED',
      clinicalNotes:
          'Specialist tele-ophthalmology audit approved for referral.',
    );

    if (!mounted) return;
    if (result['ok'] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '✅ Case $revId successfully signed off by Ophthalmologist.',
          ),
          backgroundColor: const Color(0xFF047857),
        ),
      );
    } else {
      setState(() {
        _pendingCases[index]['is_signed_off'] = false;
      });
      final status = result['status'];
      final denied = status == 401 || status == 403;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            denied
                ? '⛔ Sign-off rejected (doctor key required). Case stays in queue.'
                : '⚠️ Sign-off failed (${result['error'] ?? 'server $status'}). Case stays in queue.',
          ),
          backgroundColor: const Color(0xFFDC2626),
        ),
      );
    }
  }

  /// Opens the clinician marker viewer for the case in its own route.
  /// Marker/image loading is fully async inside the viewer and never
  /// blocks returning to the queue (instant back) or the sign-off flow.
  void _openMarkerViewer(Map<String, dynamic> caseItem) {
    final reviewId = caseItem['review_id']?.toString() ?? 'Unknown';
    final imageUrl = caseItem['original_image_url']?.toString() ?? '';
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          backgroundColor: ScannerHUDTheme.background,
          appBar: AppBar(
            title: Text(
              'Case Markers — $reviewId',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            backgroundColor: ScannerHUDTheme.darkSurface,
            foregroundColor: ScannerHUDTheme.neonCyan,
          ),
          body: ClinicianMarkerViewer(
            reviewId: reviewId,
            fetchMarkers: (rid) async {
              final markers = await widget.apiService.getReviewMarkers(rid);
              return markers ??
                  RetinalMarkers(
                    reviewId: rid,
                    available: false,
                    reason:
                        'Marker data could not be loaded (check connectivity '
                        'and try again).',
                  );
            },
            fetchImage: (rid) async {
              if (imageUrl.isEmpty) {
                throw StateError(
                  'No fundus image URL was recorded for this case.',
                );
              }
              final bytes = await widget.apiService.fetchReviewImage(imageUrl);
              if (bytes == null) {
                throw StateError(
                  'The fundus image is not available from the server right '
                  'now.',
                );
              }
              return bytes;
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final queueBody = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  color: ScannerHUDTheme.neonCyan,
                ),
              )
            : RefreshIndicator(
                color: ScannerHUDTheme.neonCyan,
                backgroundColor: ScannerHUDTheme.darkSurface,
                onRefresh: _loadQueue,
                child: _pendingCases.isEmpty
                    ? ListView(
                        children: [
                          if (_authNotice != null)
                            Container(
                              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: ScannerHUDTheme.darkSurface,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: ScannerHUDTheme.warning.withValues(
                                    alpha: 0.55,
                                  ),
                                ),
                              ),
                              child: Text(
                                _authNotice!,
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: Color(0xFFFBBF24),
                                ),
                              ),
                            ),
                          const SizedBox(height: 80),
                          const Center(
                            child: Text(
                              'No cases currently pending review 🎉',
                              style: TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _pendingCases.length,
                        itemBuilder: (context, index) {
                          final c = _pendingCases[index];
                          final isSigned = (c['is_signed_off'] == true);
                          final grade = (c['dr_grade'] is int)
                              ? c['dr_grade'] as int
                              : int.tryParse(c['dr_grade'].toString()) ?? 0;
                          final isHigh = grade >= 3;

                          final reviewId = c['review_id']?.toString() ?? '';
                          final hasRealReviewId =
                              reviewId.isNotEmpty && reviewId != 'Unknown';
                          return Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(16.0),
                            decoration: BoxDecoration(
                              color: ScannerHUDTheme.darkSurface,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isHigh
                                    ? ScannerHUDTheme.danger.withValues(
                                        alpha: 0.35,
                                      )
                                    : const Color(0xFF1E293B),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${c['patient_name']}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isSigned
                                            ? ScannerHUDTheme.success
                                                  .withValues(alpha: 0.14)
                                            : (isHigh
                                                  ? ScannerHUDTheme.danger
                                                        .withValues(alpha: 0.14)
                                                  : ScannerHUDTheme.warning
                                                        .withValues(
                                                          alpha: 0.14,
                                                        )),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        isSigned
                                            ? 'SIGNED OFF'
                                            : 'AWAITING AUDIT',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: isSigned
                                              ? const Color(0xFF34D399)
                                              : (isHigh
                                                    ? const Color(0xFFFB7185)
                                                    : const Color(0xFFFBBF24)),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'ABHA: ${c['abha_id']} • Screening: ${c['screening_id']} (${c['eye_side']})',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF94A3B8),
                                  ),
                                ),
                                const Divider(
                                  height: 20,
                                  color: Color(0xFF334155),
                                ),

                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: isHigh
                                            ? ScannerHUDTheme.danger.withValues(
                                                alpha: 0.14,
                                              )
                                            : ScannerHUDTheme.primaryCyan
                                                  .withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'Grade $grade: ${c['dr_label']}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          color: isHigh
                                              ? const Color(0xFFFB7185)
                                              : const Color(0xFF67E8F9),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Confidence: ${c['confidence']}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFFCBD5E1),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                Text(
                                  'Clinical Flag: ${c['reason']}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontStyle: FontStyle.italic,
                                    height: 1.35,
                                    color: Color(0xFF94A3B8),
                                  ),
                                ),
                                const SizedBox(height: 14),

                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    // Anatomical/lesion markers from a
                                    // server endpoint — never a
                                    // "Grad-CAM heatmap" claim.
                                    TextButton.icon(
                                      onPressed: hasRealReviewId
                                          ? () => _openMarkerViewer(c)
                                          : null,
                                      icon: const Icon(
                                        Icons.my_location,
                                        size: 18,
                                      ),
                                      label: const Text('View Markers'),
                                      style: TextButton.styleFrom(
                                        foregroundColor:
                                            ScannerHUDTheme.neonCyan,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton.icon(
                                      onPressed: isSigned
                                          ? null
                                          : () => _signOffCase(index),
                                      icon: const Icon(Icons.check, size: 18),
                                      label: Text(
                                        isSigned
                                            ? 'Approved'
                                            : 'Sign Off Referral',
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF047857,
                                        ),
                                        foregroundColor: Colors.white,
                                        disabledBackgroundColor:
                                            ScannerHUDTheme.darkSurface,
                                        disabledForegroundColor: const Color(
                                          0xFF475569,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
      ),
    );

    if (widget.embedded) {
      return Container(
        color: ScannerHUDTheme.background,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: ScannerHUDTheme.darkSurface,
              child: Row(
                children: [
                  const Icon(
                    Icons.medical_services_rounded,
                    color: ScannerHUDTheme.neonCyan,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Tele-Ophthalmologist Review Queue',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Colors.white,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(
                      Icons.refresh,
                      color: ScannerHUDTheme.neonCyan,
                    ),
                    tooltip: 'Refresh Queue',
                    onPressed: _loadQueue,
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFF1E293B)),
            Expanded(child: queueBody),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        title: const Text(
          'Tele-Ophthalmologist Review Queue',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh Queue',
            onPressed: _loadQueue,
          ),
        ],
      ),
      body: queueBody,
    );
  }
}
