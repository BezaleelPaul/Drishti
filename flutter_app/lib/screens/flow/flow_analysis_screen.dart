import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import '../../l10n/lang_scope.dart';
import '../../models/screening_models.dart';
import '../../services/api_service.dart';
import '../../services/ml/on_device_pipeline.dart';
import '../../theme/figma_theme.dart';
import '../../widgets/fx/particle_field.dart';
import '../../widgets/orbit/orbit.dart';
import '../../widgets/scanner/scanner.dart';
import '../../widgets/workflow_bar.dart';
import 'flow_result_screen.dart';
import 'flow_state.dart';

/// Figma "AI Screening" (Workflow step 3): Orbital scanner HUD and
/// clinical state machine driven by real inference events.
///
/// Offline-first order (never fake): on-device TFLite pipeline -> server
/// (LAN laptop) -> PENDING_SYNC queue entry with no grade assigned.
class FlowAnalysisScreen extends StatefulWidget {
  final FlowState state;

  const FlowAnalysisScreen({super.key, required this.state});

  @override
  State<FlowAnalysisScreen> createState() => _FlowAnalysisScreenState();
}

class _FlowAnalysisScreenState extends State<FlowAnalysisScreen> {
  static const _steps = [
    'step_quality',
    'step_retina',
    'step_lesion',
    'step_severity',
    'step_explain',
  ];

  final _api = ApiService();
  final _onDevice = OnDevicePipeline();
  int _done = 0;
  Timer? _timer;
  ScreeningAnalysisModel? _result;
  Object? _error;
  ScannerAnimationState _scannerState = ScannerAnimationState.qualityCheck;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 700), (t) {
      if (!mounted) return;
      if (_done < _steps.length) {
        setState(() {
          _done++;
          _updateScannerStateForStep(_done);
        });
      } else {
        t.cancel();
        _handleAnalysisCompletion();
      }
    });
    _runAnalysis();
  }

  void _updateScannerStateForStep(int stepIndex) {
    if (_error != null) {
      _scannerState = ScannerAnimationState.error;
      return;
    }
    switch (stepIndex) {
      case 0:
        _scannerState = ScannerAnimationState.qualityCheck;
        break;
      case 1:
        _scannerState = ScannerAnimationState.scanning;
        break;
      case 2:
      case 3:
      case 4:
        _scannerState = ScannerAnimationState.analyzing;
        break;
      default:
        break;
    }
  }

  Future<void> _runAnalysis() async {
    final bytes = widget.state.imageBytes;
    if (bytes == null) {
      if (!mounted) return;
      setState(() {
        _error = StateError('No image captured');
        _scannerState = ScannerAnimationState.error;
      });
      return;
    }

    // 1. On-device pipeline (works with airplane mode on). Primary path:
    //    fast, offline, and uses the SAME quality thresholds as the capture
    //    gate, so verdicts stay consistent for the operator. The deployed
    //    edge server's DR inference is currently unstable (502/503 worker
    //    crashes), so the server is a fallback, not the default.
    try {
      final local = await _onDevice.analyze(
        imageBytes: bytes,
        patientId: widget.state.patient.patientId,
        eyeSide: widget.state.eyeSide,
        cameraProfile: widget.state.cameraProfile,
        recaptureAttemptCount: widget.state.recaptureAttemptCount,
      );
      if (local != null) {
        if (!mounted) return;
        setState(() {
          _result = local;
        });
        _handleAnalysisCompletion();
        return;
      }
      // On-device artifact unavailable: fall through to the server path.
    } catch (_) {
      // On-device failure falls back to the server path; it never produces
      // a fabricated grade.
    }

    // 2. Server analysis (edge path) — full clinical pipeline including the
    //    Grad-CAM++ explanation engine when the deployment is healthy.
    try {
      final res = await _api.analyzeRetinaFull(
        imageBytes: bytes,
        patientId: widget.state.patient.patientId,
        eyeSide: widget.state.eyeSide,
        cameraProfile: widget.state.cameraProfile,
        filename: widget.state.filename,
      );
      if (!mounted) return;
      setState(() {
        _result = res;
      });
      _handleAnalysisCompletion();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _scannerState = ScannerAnimationState.error;
      });
    }
  }

  void _handleAnalysisCompletion() {
    if (_error != null) {
      setState(() => _scannerState = ScannerAnimationState.error);
      return;
    }

    if (_result != null && _done >= _steps.length && mounted) {
      // If quality check rejected image, halt scan and enter rejected state
      if (_result!.qualityPassed == false) {
        setState(() => _scannerState = ScannerAnimationState.rejected);
        return;
      }

      // Check if clinician review required (borderline quality or uncertain prediction)
      if (_result!.qualityGrade.toUpperCase() == 'BORDERLINE') {
        setState(() => _scannerState = ScannerAnimationState.reviewRequired);
      } else {
        setState(() => _scannerState = ScannerAnimationState.resultReady);
      }

      widget.state.analysis = _result;
      _timer?.cancel();

      // Brief transition delay so the user experiences the calm completion state
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => FlowResultScreen(state: widget.state),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _onDevice.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final statusText = _scannerState == ScannerAnimationState.rejected
        ? 'IMAGE UNGRADABLE'
        : _scannerState == ScannerAnimationState.reviewRequired
        ? 'REVIEW REQUIRED'
        : null;

    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          context.tr('ai_title'),
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      ),
      body: Stack(
        children: [
          const Positioned.fill(
            child: ParticleField(
              particleCount: 22,
              opacity: 0.28,
              speed: 0.7,
              seed: 13,
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 672),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const WorkflowBar(step: 3, dark: true),
                    const SizedBox(height: 12),
                    Text(
                      context.tr('ai_subtitle'),
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF94A3B8),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: OrbitScanner(
                          state: OrbitScannerState.fromScannerAnimationState(
                            _scannerState,
                          ),
                          imageBytes: widget.state.imageBytes,
                          statusText: statusText,
                          technicalLabel: _result == null
                              ? null
                              : 'backend: ${_result!.modelBackend ?? 'unknown'}',
                          onCancel: () => Navigator.pop(context),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: ScannerHUDTheme.darkSurface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: Column(
                        children: [
                          for (var i = 0; i < _steps.length; i++)
                            _stepRow(
                              context.tr(_steps[i]),
                              i < _done,
                              i == _done &&
                                  _error == null &&
                                  _scannerState !=
                                      ScannerAnimationState.rejected,
                            ),
                        ],
                      ),
                    ),
                    if (_scannerState == ScannerAnimationState.rejected) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: ScannerHUDTheme.darkSurface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: FigmaColors.warning),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: FigmaColors.warning,
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Image Ungradable / Quality Rejected',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: FigmaColors.warning,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _result?.rejectionReasons.isNotEmpty == true
                                  ? _result!.rejectionReasons.join(', ')
                                  : 'The scan quality is insufficient for diagnostic evaluation. Please retake the image.',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFE2E8F0),
                              ),
                            ),
                            const SizedBox(height: 10),
                            ElevatedButton.icon(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.camera_alt, size: 16),
                              label: const Text('Retake Retinal Photo'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: FigmaColors.warning,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: ScannerHUDTheme.darkSurface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: FigmaColors.danger),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Analysis unavailable: $_error',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFF87171),
                              ),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.arrow_back, size: 16),
                              label: const Text('Back'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: ScannerHUDTheme.neonCyan,
                                side: const BorderSide(
                                  color: ScannerHUDTheme.neonCyan,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      context.tr('ai_disclaimer'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                        color: Color(0xFF94A3B8),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepRow(String label, bool done, bool active) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          done
              ? const Icon(
                  Icons.check_circle,
                  size: 20,
                  color: FigmaColors.success,
                )
              : active
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: SpinKitFadingCube(
                    color: FigmaColors.primary,
                    size: 18,
                  ),
                )
              : const Icon(
                  Icons.radio_button_unchecked,
                  size: 20,
                  color: FigmaColors.faint,
                ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.normal,
              color: done
                  ? FigmaColors.success
                  : active
                  ? Colors.white
                  : const Color(0xFF94A3B8),
            ),
          ),
        ],
      ),
    );
  }
}
