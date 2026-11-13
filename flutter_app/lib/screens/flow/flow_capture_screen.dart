import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/lang_scope.dart';
import '../../l10n/evidence_strings.dart';
import '../../models/screening_models.dart';
import '../../services/api_service.dart';
import '../../services/ml/on_device_pipeline.dart';
import '../../theme/figma_theme.dart';
import '../../widgets/orbit/orbit.dart';
import '../../widgets/review/zoomable_fundus_screen.dart';
import '../../widgets/scanner/scanner.dart';
import '../../widgets/workflow_bar.dart';
import '../live_camera_screen.dart';
import 'flow_analysis_screen.dart';
import 'flow_state.dart';

/// Figma "Fundus Image Capture" + quality card (Workflow step 2).
/// Eye toggle, bundled samples or device upload, server quality gate.
class FlowCaptureScreen extends StatefulWidget {
  final FlowState state;

  const FlowCaptureScreen({super.key, required this.state});

  @override
  State<FlowCaptureScreen> createState() => _FlowCaptureScreenState();
}

class _FlowCaptureScreenState extends State<FlowCaptureScreen> {
  final _api = ApiService();
  final _onDevice = OnDevicePipeline();
  String _sample = 'assets/images/2_clear_eye_normal.jpg';
  bool _checking = false;

  static const _samples = [
    ('assets/images/2_clear_eye_normal.jpg', '2_clear_eye_normal.jpg'),
    ('assets/images/1_blurry_eye_retake.jpg', '1_blurry_eye_retake.jpg'),
    ('assets/images/3_severe_eye_referral.jpg', '3_severe_eye_referral.jpg'),
  ];

  @override
  void initState() {
    super.initState();
    // Fresh operator session starts EMPTY at the viewfinder ('RETINAL
    // VIEWFINDER READY'): a bundled sample is loaded only by explicit
    // dropdown selection (demo/kiosk mode). A restored in-flight capture
    // (bytes already in state) re-runs the quality gate directly — never
    // replaced by a sample image.
    if (widget.state.imageBytes != null) {
      unawaited(_runQuality());
    }
  }

  /// Demo/kiosk sample loader — explicit selection only. A load failure is
  /// surfaced (logged + operator-visible), never a silent blank viewfinder.
  Future<void> _loadSample(String asset) async {
    try {
      final data = await rootBundle.load(asset);
      if (!mounted) return;
      setState(() {
        _sample = asset;
        widget.state.imageBytes = data.buffer.asUint8List();
        widget.state.filename = asset.split('/').last;
        widget.state.quality = null;
      });
      unawaited(_runQuality());
    } catch (e) {
      debugPrint('Sample asset load failed ($asset): $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.ev('capture_open_failed'))),
      );
    }
  }

  Future<void> _upload() async {
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Select a fundus photo',
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png'],
      );
      if (files.isEmpty) return; // user cancelled the picker
      if (!mounted) return;
      final picked = files.first;
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.ev('capture_empty_file'))),
        );
        return;
      }
      await _useCapturedBytes(bytes, 'camera_capture.jpg');
    } catch (e) {
      debugPrint('Photo picker failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.ev('capture_open_failed'))),
      );
    }
  }

  /// Live camera path (Ticket: camera integration): open the full-screen
  /// back-camera preview, get JPEG bytes back, run the same on-device
  /// quality gate as every other capture source.
  Future<void> _openCamera() async {
    try {
      final bytes = await Navigator.push<Uint8List>(
        context,
        MaterialPageRoute(builder: (_) => const LiveFundusCameraScreen()),
      );
      if (bytes == null || bytes.isEmpty) return; // user backed out
      if (!mounted) return;
      await _useCapturedBytes(
        bytes,
        'camera_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
    } catch (e) {
      debugPrint('Camera open failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.ev('camera_unavailable'))));
    }
  }

  Future<void> _useCapturedBytes(Uint8List bytes, String filename) async {
    if (!mounted) return;
    setState(() {
      widget.state.imageBytes = bytes;
      widget.state.filename = filename;
      widget.state.quality = null;
    });
    unawaited(_runQuality());
  }

  Future<void> _runQuality() async {
    final bytes = widget.state.imageBytes;
    if (bytes == null) return;
    setState(() => _checking = true);
    try {
      // Offline-first: on-device quality gate, server as fallback. Both
      // paths use the same thresholds, so verdicts agree in either mode.
      // The on-device gate decodes + assesses on a background isolate
      // (compute), so the Flame canvas keeps animating during capture.
      RetinalQualityModel? q;
      try {
        q = await _onDevice.checkQualityOnDevice(bytes);
      } catch (_) {
        q = null;
      }
      q ??= await _api.checkQuality(
        imageBytes: bytes,
        filename: widget.state.filename,
        cameraProfile: widget.state.cameraProfile,
      );
      if (q.qualityGrade == 'BAD') {
        widget.state.recaptureAttemptCount += 1;
      }
      if (mounted) setState(() => widget.state.quality = q);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _openInspector() {
    final bytes = widget.state.imageBytes;
    if (bytes == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ZoomableFundusScreen(
          imageBytes: bytes,
          title: 'Fundus inspection',
          caption: 'Inspect the capture · pinch, drag, double-tap',
        ),
      ),
    );
  }

  void _proceed() {
    if (widget.state.imageBytes == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FlowAnalysisScreen(state: widget.state),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.state;
    final q = st.quality;
    final good = q != null && q.qualityGrade == 'GOOD';
    final bad = q != null && q.qualityGrade == 'BAD';
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: Text(
          context.tr('capture_title'),
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
                const WorkflowBar(step: 2, dark: true),
                const SizedBox(height: 12),
                Text(
                  context.tr('select_eye'),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'Right',
                      label: Text(context.tr('right_eye')),
                    ),
                    ButtonSegment(
                      value: 'Left',
                      label: Text(context.tr('left_eye')),
                    ),
                  ],
                  selected: {st.eyeSide},
                  onSelectionChanged: (s) =>
                      setState(() => st.eyeSide = s.first),
                  style: SegmentedButton.styleFrom(
                    backgroundColor: ScannerHUDTheme.darkSurface,
                    foregroundColor: const Color(0xFF94A3B8),
                    selectedBackgroundColor: ScannerHUDTheme.neonCyan
                        .withValues(alpha: 0.14),
                    selectedForegroundColor: ScannerHUDTheme.neonCyan,
                    side: const BorderSide(color: Color(0xFF334155)),
                  ),
                ),
                const SizedBox(height: 12),
                // Orbit viewfinder / retinal scanner reticle
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: st.imageBytes == null ? null : _openInspector,
                      child: OrbitScanner(
                        state: _checking
                            ? OrbitScannerState.qualityCheck
                            : (st.quality != null && !st.quality!.isReliable)
                            ? OrbitScannerState.failure
                            : OrbitScannerState.idle,
                        imageBytes: st.imageBytes,
                        statusText: st.imageBytes == null
                            ? 'RETINAL VIEWFINDER READY'
                            : _checking
                            ? 'CALIBRATING OPTICS'
                            : (st.quality != null && !st.quality!.isReliable)
                            ? 'QUALITY REJECTED'
                            : 'IMAGE ALIGNED',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${context.tr('viewfinder_msg')}. ${context.tr('viewfinder_sub')}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF94A3B8),
                  ),
                  textAlign: TextAlign.center,
                ),
                if (st.imageBytes != null)
                  TextButton.icon(
                    onPressed: _openInspector,
                    icon: const Icon(Icons.zoom_in, size: 16),
                    label: const Text(
                      'Tap image to inspect & zoom',
                      style: TextStyle(fontSize: 11),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: ScannerHUDTheme.neonCyan,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                const SizedBox(height: 10),
                // Live camera is the primary capture path (Ticket: camera
                // integration); upload + samples remain for demos/kiosks.
                FilledButton.icon(
                  onPressed: _openCamera,
                  icon: const Icon(Icons.photo_camera_rounded, size: 20),
                  label: Text(
                    'Use camera',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00B4D8),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: 3,
                    shadowColor: const Color(0x6600B4D8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _upload,
                        icon: const Icon(Icons.upload_file_rounded, size: 18),
                        label: Text(
                          context.tr('btn_upload'),
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: const Color(0xFF101932),
                          side: const BorderSide(color: Color(0xFF223254)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _sample,
                        isDense: true,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF101A33),
                        style: const TextStyle(color: Color(0xFFE2E8F0)),
                        decoration: InputDecoration(
                          filled: true,
                          fillColor: const Color(0xFF101932),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFF223254),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: Color(0xFF223254),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(
                              color: ScannerHUDTheme.neonCyan,
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        items: _samples
                            .map(
                              (s) => DropdownMenuItem(
                                value: s.$1,
                                child: Text(
                                  _sampleLabel(s.$2),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFFE2E8F0),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) {
                          if (v != null) _loadSample(v);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Quality card
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
                      color: good
                          ? const Color(0xFF10B981).withValues(alpha: 0.35)
                          : bad
                          ? const Color(0xFFEF4444).withValues(alpha: 0.35)
                          : const Color(0xFF1E2D4A),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: (good ? const Color(0xFF10B981) : Colors.black)
                            .withValues(alpha: 0.1),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: _checking
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: ScannerHUDTheme.neonCyan,
                            ),
                          ),
                        )
                      : q == null
                      ? Text(
                          context.tr('analyzing'),
                          style: const TextStyle(color: Color(0xFF94A3B8)),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.health_and_safety_outlined,
                                      size: 18,
                                      color: good
                                          ? const Color(0xFF10B981)
                                          : const Color(0xFFF59E0B),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      context.tr('quality_title'),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: (good
                                            ? const Color(0xFF10B981)
                                            : const Color(0xFFF59E0B))
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: good
                                          ? const Color(0xFF10B981)
                                          : const Color(0xFFF59E0B),
                                    ),
                                  ),
                                  child: Text(
                                    good ? context.tr('quality_good') : q.qualityGrade,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: good
                                          ? const Color(0xFF34D399)
                                          : const Color(0xFFFBBF24),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            _checkRow(context.tr('retina_visible'), good),
                            _checkRow(context.tr('focus_ok'), good),
                            _checkRow(context.tr('brightness_ok'), good),
                            const SizedBox(height: 8),
                            Text(
                              '${context.tr('quality_label')} ${good ? context.tr('quality_good') : q.qualityGrade}',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: good
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFFF59E0B),
                              ),
                            ),
                            if (bad) ...[
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF350E12),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFFDC2626)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.info_outline, color: Color(0xFFF87171), size: 16),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        context.tr('quality_fail'),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFFF87171),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
                const SizedBox(height: 14),
                ElevatedButton(
                  onPressed: st.imageBytes == null ? null : _proceed,
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
                  child: Text(
                    context.tr('btn_proceed_ai'),
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

  /// Operator-friendly sample labels (demo fixtures keep their asset paths).
  String _sampleLabel(String filename) {
    if (filename.startsWith('2_clear')) return context.ev('sample_healthy');
    if (filename.startsWith('1_blurry')) return context.ev('sample_blurry');
    if (filename.startsWith('3_severe')) return context.ev('sample_severe');
    return filename;
  }

  Widget _checkRow(String label, bool ok) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: ok ? FigmaColors.success : const Color(0xFF64748B),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFFE2E8F0)),
          ),
        ],
      ),
    );
  }
}
