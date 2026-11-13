import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import '../../models/screening_models.dart';
import 'dr_classifier.dart';
import 'drdetect_ordinal_runner.dart';
import 'model_runner.dart';
import 'pipeline/async_isolate_ordinal_runner.dart';
import 'pipeline_schema.dart';
import 'quality_gate.dart';
import 'quality_thresholds.dart';
import 'screening_orchestrator.dart';

/// Top-level compute worker: canonical RGB decode + quality-gate metric
/// passes run OFF the UI isolate.
///
/// WHY: `decodeCanonicalRgb` (package:image, pure Dart) is O(source pixels)
/// and the gate is O(analysis pixels) — a 12 MP capture costs seconds when
/// run synchronously, stalling the Flame game loop and every animated HUD
/// during capture. Both stages are pure-Dart functions on sendable inputs
/// (encoded bytes) / outputs (enum+double data classes), so they are
/// `compute`-safe. The DECODE + ASSESS pair runs in one worker spawn so the
/// 12 MP frame is decoded, downscaled (<=2048 analysis dim), and graded in
/// a single background hop with no large buffer round-trips.
///
/// NOTE: this does NOT touch the ordinal-regression inference path — the
/// LiteRT isolate bridge (`AsyncIsolateOrdinalRunner`) remains the
/// orchestrator's concern and is unchanged.
QualityAssessmentResult qualityGateComputeWorker(Uint8List encoded) {
  final canonical = decodeCanonicalRgb(encoded);
  return const QualityGateDart().assess(
    canonical.bytes,
    canonical.width,
    canonical.height,
  );
}

/// Bridges the on-device ML layer into the app's existing [ScreeningAnalysisModel] contract.
///
/// Default grader chain (mirrors server backend priority in
/// src/classification/classifier.py): DRDetect ordinal TFLite
/// (`drdetect_ordinal_512_fp32.tflite`, parity-gated vs ONNX) first,
/// falling back to the Keras TFLite classifier
/// (`dr_efficientnet_b0_fp32.tflite`) when the primary artifact cannot load
/// or predict. When NO runner is usable, [analyze] returns null so callers
/// fall through to the server path — it never fabricates a grade on-device.
class OnDevicePipeline {
  OnDevicePipeline({DrModelRunner? modelRunner, DrClassifierDart? classifier})
    : this.withRunner(_resolveRunner(modelRunner, classifier));

  /// Explicit runner injection (also used by tests).
  OnDevicePipeline.withRunner(DrModelRunner runner)
    : _modelRunner = runner,
      _orchestrator = ScreeningOrchestrator(modelRunner: runner);

  static DrModelRunner _resolveRunner(
    DrModelRunner? modelRunner,
    DrClassifierDart? classifier,
  ) {
    if (modelRunner != null) return modelRunner;
    return FallbackModelRunner([
      // Preferred: preprocessing + inference on a background isolate, so the
      // 512px Gaussian blur never janks the capture UI.
      AsyncIsolateOrdinalRunner(),
      // Failover: same model, synchronous, for platforms where the isolate
      // cannot load the LiteRT native library.
      DrDetectOrdinalTfliteRunner(
        thresholds: DrDetectOrdinalTfliteRunner.calibratedThresholds,
      ),
      LegacyClassifierAdapter(classifier ?? DrClassifierDart()),
    ]);
  }

  final DrModelRunner _modelRunner;
  DrModelRunner get modelRunner => _modelRunner;
  final ScreeningOrchestrator _orchestrator;
  bool _initTried = false;
  bool _orchestratorReady = false;

  /// True when the on-device model runner is initialized and usable.
  Future<bool> ensureReady() async {
    if (_initTried) return _orchestratorReady;
    _initTried = true;
    try {
      await _orchestrator.initialize();
      _orchestratorReady = true;
      return true;
    } catch (_) {
      // Missing/corrupt TFLite asset or unsupported platform: fail closed so
      // the caller falls through to the server. Never substitute a grade.
      _orchestratorReady = false;
      return false;
    }
  }

  /// Runs ONLY the on-device quality gate (Node 2) — used by the capture
  /// screen so image usability is checked with airplane mode on.
  ///
  /// Decode + metric passes execute on a background isolate via [compute];
  /// the UI isolate only awaits. Failure semantics are unchanged: a
  /// FormatException from decode maps to IMG_INVALID (fail closed), never
  /// stale pixels — and a worker crash rethrows to the caller's guard.
  Future<RetinalQualityModel?> checkQualityOnDevice(
    Uint8List imageBytes,
  ) async {
    try {
      final res = await compute(qualityGateComputeWorker, imageBytes);
      return _toQualityModel(res);
    } on FormatException {
      return _toQualityModel(
        const QualityAssessmentResult(
          grade: QualityGrade.BAD,
          isReliable: false,
          reasons: [QualityReason.nonFundusOrCorrupt],
          details: 'Image could not be decoded',
          errorCode: PipelineErrorCode.imgInvalid,
        ),
      );
    }
  }

  RetinalQualityModel _toQualityModel(QualityAssessmentResult res) {
    final tips = <String>[];
    if (res.reasons.contains(QualityReason.severeBlur)) {
      tips.add('Hold the camera steady and refocus');
    }
    if (res.reasons.contains(QualityReason.inadequateIllumination)) {
      tips.add('Increase illumination / check pupil dilation');
    }
    if (res.reasons.contains(QualityReason.overexposure)) {
      tips.add('Reduce glare and flash intensity');
    }
    if (res.reasons.contains(QualityReason.insufficientFieldOfView)) {
      tips.add('Center the retina inside the frame');
    }
    return RetinalQualityModel(
      qualityGrade: res.grade.name,
      qualityScore: res.metrics.mlQualityScore,
      isReliable: res.isReliable,
      rejectionReasons: res.reasons.map((r) => r.display).toList(),
      suspectedClinicalCause: res.suspectedClinicalCause,
      operatorAction: res.grade == QualityGrade.BAD
          ? 'Recapture the image. Do not display a DR grade for an image '
                'that fails the reliability gate.'
          : res.grade == QualityGrade.BORDERLINE
          ? 'Recapture recommended for a borderline image.'
          : 'Image certified as reliable. Proceed to analysis.',
      recaptureTips: tips,
      audioGuidanceHindi: 'कृपया पुनः प्रयास करें।',
    );
  }

  /// Returns the on-device result, or null when the artifact is unavailable.
  Future<ScreeningAnalysisModel?> analyze({
    required Uint8List imageBytes,
    required String patientId,
    required String eyeSide,
    required String cameraProfile,
    int recaptureAttemptCount = 0,
  }) async {
    if (!await ensureReady()) return null;
    final record = await _orchestrator.processImage(
      imageBytes,
      recaptureAttemptCount: recaptureAttemptCount,
    );
    return _toAnalysisModel(record, patientId, eyeSide, cameraProfile);
  }

  /// Maps ScreeningRecordDart -> ScreeningAnalysisModel.
  ScreeningAnalysisModel _toAnalysisModel(
    ScreeningRecordDart record,
    String patientId,
    String eyeSide,
    String cameraProfile,
  ) {
    final dr = record.drPrediction;
    final conf = record.confidence;
    final metrics = record.qualityMetrics;

    final referableMass = dr == null
        ? 0.0
        : dr.probabilities.sublist(2).fold<double>(0.0, (a, b) => a + b);
    final isReferable =
        dr != null &&
        (dr.predictedGrade.isReferable ||
            referableMass >= kReferableMassThreshold);

    return ScreeningAnalysisModel(
      screeningId: 'LOC-${DateTime.now().millisecondsSinceEpoch}',
      patientId: patientId,
      eyeSide: eyeSide,
      cameraProfile: cameraProfile,
      qualityGrade: record.qualityGrade.name,
      qualityScore: metrics?.mlQualityScore ?? 0.0,
      qualityPassed: record.qualityGrade == QualityGrade.GOOD,
      rejectionReasons: record.rejectionReasons,
      drGrade: dr?.predictedGrade.value,
      drLabel: dr?.predictedGrade.label,
      predictionScore: dr?.confidence,
      isReferable: isReferable,
      requiresHumanReview: record.humanReviewRequired,
      humanReviewType: record.humanReviewType == HumanReviewType.NONE
          ? null
          : record.humanReviewType.name,
      humanReviewReason: record.humanReviewReason,
      originalImageUrl: '',
      gradcamOverlayUrl: null,
      gradcamTargetLayer: null,
      modelBackend: record.modelBackend,
      actionRecommendation: record.action,
      plainLanguageAdvice: record.action,
      smsReferralSlip: '',
      probabilities: dr?.probabilities,
      biomarkers: conf == null
          ? null
          : {
              'confidence_flag_count': conf.flags.length,
              'is_ambiguous': conf.isAmbiguous,
              'is_high_risk': conf.isHighRisk,
              if (record.inferenceMs != null)
                'inference_time_ms': record.inferenceMs,
            },
      isOffline: false,
      isFromFallback: false,
      errorCode: record.errorCode?.code,
    );
  }

  /// Releases the native interpreter / background isolate owned by the runner
  /// chain. Safe to call even when [ensureReady] was never invoked.
  void dispose() {
    _orchestratorReady = false;
    _initTried = false;
    _modelRunner.dispose();
  }
}
