import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'dr_classifier.dart';
import 'confidence_evaluator.dart';
import 'model_runner.dart';
import 'pipeline_schema.dart';
import 'quality_gate.dart';
import 'quality_thresholds.dart';

/// Adapter wrapping DrClassifierDart inside the interchangeable DrModelRunner
/// interface. Reports the exact deployed artifact identity for audit trails.
class LegacyClassifierAdapter implements DrModelRunner {
  LegacyClassifierAdapter(this.classifier);
  final DrClassifierDart classifier;

  @override
  String get modelId => DrClassifierDart.backendId;

  @override
  String get modelVersion => DrClassifierDart.artifactVersion;

  @override
  Future<void> initialize() => classifier.initialize();

  @override
  Future<DrModelOutput> predict(img.Image image) async {
    // PIL-parity bicubic resize on the ORIGINAL image, then raw RGB bytes.
    final targetSize = classifier.inputSize;
    final resized = img.copyResize(
      image,
      width: targetSize,
      height: targetSize,
      interpolation: img.Interpolation.cubic,
    );
    final rgbBytes = Uint8List(targetSize * targetSize * 3);
    var j = 0;
    for (final p in resized) {
      rgbBytes[j++] = p.r.toInt().clamp(0, 255);
      rgbBytes[j++] = p.g.toInt().clamp(0, 255);
      rgbBytes[j++] = p.b.toInt().clamp(0, 255);
    }
    final sw = Stopwatch()..start();
    final res = classifier.classify(rgbBytes);
    sw.stop();
    final top1 = res.confidence;
    var top2 = 0.0;
    for (final p in res.probabilities) {
      if (p < top1 && p > top2) top2 = p;
    }
    return DrModelOutput(
      grade: res.predictedGrade,
      probabilities: res.probabilities,
      referableScore: res.probabilities
          .sublist(2)
          .fold<double>(0.0, (double a, double b) => a + b),
      referable: res.isReferable,
      uncertainty: 1.0 - top1,
      modelId: modelId,
      modelVersion: modelVersion,
      top2Margin: top1 - top2,
      inferenceMs: sw.elapsedMicroseconds / 1000.0,
    );
  }

  @override
  void dispose() => classifier.dispose();
}

/// On-device port of src/pipeline/router.py (Nodes 1-11) utilizing
/// interchangeable DrModelRunner.
///
/// Default grader: the parity-gated TFLite fp32 classifier (DrClassifierDart
/// via LegacyClassifierAdapter). Fallback order is enforced by callers:
/// on-device -> server /retinal/analyze -> PENDING_SYNC (no grade).
class ScreeningOrchestrator {
  ScreeningOrchestrator({
    DrModelRunner? modelRunner,
    DrClassifierDart? classifier,
    QualityGateDart? qualityGate,
  }) : _modelRunner =
           modelRunner ??
           (classifier != null
               ? LegacyClassifierAdapter(classifier)
               : LegacyClassifierAdapter(DrClassifierDart())),
       _gate = qualityGate ?? const QualityGateDart();

  final DrModelRunner _modelRunner;
  final QualityGateDart _gate;

  Future<void> initialize() => _modelRunner.initialize();

  /// Full on-device screening for one capture.
  Future<ScreeningRecordDart> processImage(
    Uint8List encodedBytes, {
    int recaptureAttemptCount = 0,
  }) async {
    final attempt = recaptureAttemptCount < 0 ? 0 : recaptureAttemptCount;

    // Node 1: decode ONCE to canonical RGB (shared with every stage).
    // Catch-all (not just FormatException): image decoders may throw
    // RangeError/other errors on corrupt input while probing formats —
    // every failure mode must map to IMG_INVALID, never crash the pipeline.
    final img.Image decoded;
    try {
      final raw = img.decodeImage(encodedBytes);
      if (raw == null) {
        throw const FormatException('Could not decode image');
      }
      decoded = raw;
    } catch (_) {
      return ScreeningRecordDart(
        imagePath: 'capture',
        qualityGrade: QualityGrade.BAD,
        qualityStatus: 'Unreliable',
        rejectionReasons: [QualityReason.nonFundusOrCorrupt.display],
        recaptureAttemptCount: attempt,
        reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
        errorCode: PipelineErrorCode.imgInvalid,
        action: 'Image could not be decoded. Recapture the image.',
      );
    }

    CanonicalImage canonical;
    try {
      canonical = canonicalRgbFromDecoded(decoded);
    } catch (_) {
      return ScreeningRecordDart(
        imagePath: 'capture',
        qualityGrade: QualityGrade.BAD,
        qualityStatus: 'Unreliable',
        rejectionReasons: [QualityReason.nonFundusOrCorrupt.display],
        recaptureAttemptCount: attempt,
        reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
        errorCode: PipelineErrorCode.imgInvalid,
        action: 'Invalid image dimensions. Recapture the image.',
      );
    }

    // Node 2: quality gate (Model 1).
    final quality = _gate.assess(
      canonical.bytes,
      canonical.width,
      canonical.height,
    );

    // Node 3c: BAD path.
    if (quality.grade == QualityGrade.BAD) {
      if (attempt >= kMaxRecaptureCap) {
        return ScreeningRecordDart(
          imagePath: 'capture',
          qualityGrade: QualityGrade.BAD,
          qualityStatus: 'Unreliable (Retry limit reached)',
          rejectionReasons: quality.reasons.map((r) => r.display).toList(),
          recaptureAttemptCount: attempt,
          reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
          humanReviewRequired: true,
          humanReviewType: HumanReviewType.OPERATOR_LEVEL,
          humanReviewReason:
              'Recapture cap of $kMaxRecaptureCap attempts reached. '
              'Operator/clinician must inspect patient eye directly.',
          action:
              'Recapture cap reached ($attempt/$kMaxRecaptureCap). '
              'Escalate to supervising clinician for on-site physical evaluation.',
          qualityMetrics: quality.metrics,
          errorCode: PipelineErrorCode.imgUntgradable,
        );
      }
      return ScreeningRecordDart(
        imagePath: 'capture',
        qualityGrade: QualityGrade.BAD,
        qualityStatus: 'Unreliable (Recapture recommended)',
        rejectionReasons: quality.reasons.map((r) => r.display).toList(),
        recaptureAttemptCount: attempt + 1,
        reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
        humanReviewRequired: false,
        action:
            'Quality gate failed: ${quality.details}. '
            'Recapture attempt #${attempt + 1}/$kMaxRecaptureCap.',
        qualityMetrics: quality.metrics,
        errorCode: PipelineErrorCode.imgUntgradable,
      );
    }

    // Node 3b: BORDERLINE path.
    if (quality.grade == QualityGrade.BORDERLINE) {
      if (attempt >= kMaxRecaptureCap) {
        return ScreeningRecordDart(
          imagePath: 'capture',
          qualityGrade: QualityGrade.BORDERLINE,
          qualityStatus: 'Unreliable (Retry limit reached)',
          rejectionReasons: quality.reasons.map((r) => r.display).toList(),
          recaptureAttemptCount: attempt,
          reassessmentOutcome: ReassessmentOutcome.FAILED,
          humanReviewRequired: true,
          humanReviewType: HumanReviewType.OPERATOR_LEVEL,
          humanReviewReason:
              'Borderline image after $kMaxRecaptureCap recapture attempts: '
              'escalate to supervising clinician.',
          action:
              'Recapture cap reached ($attempt/$kMaxRecaptureCap). '
              'Image remains borderline; escalate to clinician.',
          qualityMetrics: quality.metrics,
          errorCode: PipelineErrorCode.imgUntgradable,
        );
      }
      return ScreeningRecordDart(
        imagePath: 'capture',
        qualityGrade: QualityGrade.BORDERLINE,
        qualityStatus: 'Unreliable (Failed Reassessment)',
        rejectionReasons: quality.reasons.map((r) => r.display).toList(),
        recaptureAttemptCount: attempt + 1,
        reassessmentOutcome: ReassessmentOutcome.FAILED,
        humanReviewRequired: true,
        humanReviewType: HumanReviewType.OPERATOR_LEVEL,
        humanReviewReason:
            'Borderline image requires recapture (on-device conservative mode).',
        action:
            'Reassessment pending. Recapture attempt '
            '#${attempt + 1}/$kMaxRecaptureCap. Image does NOT proceed to '
            'DR Classification.',
        qualityMetrics: quality.metrics,
        errorCode: PipelineErrorCode.imgUntgradable,
      );
    }

    // Node 6→7: reliable image — Primary DR Grader (Model 2, TFLite fp32
    // classifier by default). On any failure the orchestrator returns
    // AI_UNAVAILABLE and mandatory review — never a substitute grade.
    final DrModelOutput modelOutput;
    try {
      modelOutput = await _modelRunner.predict(decoded);
    } catch (e) {
      return ScreeningRecordDart(
        imagePath: 'capture',
        qualityGrade: quality.grade,
        qualityStatus: 'AI unavailable',
        rejectionReasons: const [],
        recaptureAttemptCount: attempt,
        reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
        humanReviewRequired: true,
        humanReviewType: HumanReviewType.OPERATOR_LEVEL,
        humanReviewReason: 'On-device DR model error ($e): mandatory review.',
        action: 'AI unavailable. Route capture for human review.',
        qualityMetrics: quality.metrics,
        errorCode: PipelineErrorCode.aiUnavailable,
      );
    }

    // Fail-closed: a grader that cannot produce a real, calibrated
    // probability vector + top-2 margin must not yield an automated grade.
    // (A previous version manufactured a near-one-hot probability vector for
    // ordinal outputs here — removed: fabricated clinical output is a safety
    // defect. Ordinal runners must either supply probabilities or route to
    // mandatory review.)
    final probs = modelOutput.probabilities;
    final margin = modelOutput.top2Margin;
    if (probs == null ||
        probs.length != 5 ||
        probs.any((p) => p.isNaN || p.isInfinite || p < 0 || p > 1.0000001) ||
        margin == null ||
        margin.isNaN ||
        margin.isInfinite) {
      return ScreeningRecordDart(
        imagePath: 'capture',
        qualityGrade: quality.grade,
        qualityStatus: 'AI unavailable (no calibrated probabilities)',
        rejectionReasons: const [],
        recaptureAttemptCount: attempt,
        reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
        humanReviewRequired: true,
        humanReviewType: HumanReviewType.OPERATOR_LEVEL,
        humanReviewReason:
            'On-device grader ${modelOutput.modelId} returned no valid '
            'probability vector. Automated grading withheld; mandatory review.',
        action:
            'Automated grading withheld: the on-device model did not produce '
            'a calibrated probability output. Route capture for human review.',
        qualityMetrics: quality.metrics,
        errorCode: PipelineErrorCode.aiUnavailable,
        modelBackend: modelOutput.modelId,
        inferenceMs: modelOutput.inferenceMs,
      );
    }

    // Confidence = top-1 probability (== max(probs) by classifier contract);
    // top-2 margin is the real measured margin, never synthesized.
    final confVal = probs.reduce((a, b) => a > b ? a : b);

    final drResult = DrClassificationResult(
      predictedGrade: modelOutput.grade,
      probabilities: probs,
      confidence: confVal.clamp(0.0, 1.0),
      top2Margin: margin,
      isReferable: modelOutput.referable ?? modelOutput.grade.isReferable,
    );

    // Node 8: confidence / uncertainty evaluation.
    final confidence = const ConfidenceEvaluatorDart().evaluate(drResult);

    final isReferable = modelOutput.referable ?? modelOutput.grade.isReferable;
    final humanReviewRequired = confidence.requiresHumanReview || isReferable;
    final reviewType = humanReviewRequired
        ? HumanReviewType.CLINICAL_LEVEL
        : HumanReviewType.NONE;
    final flags = List<String>.from(confidence.flags);
    if (isReferable && !confidence.requiresHumanReview) {
      flags.add(
        'Referable ${drResult.predictedGrade.label} requires clinician confirmation per triage protocol',
      );
    }

    final uncertain =
        (modelOutput.uncertainty ?? 0.0) > 0.4 || !confidence.isConfident;
    final errorCode = uncertain ? PipelineErrorCode.aiLowConfidence : null;

    String actionText;
    if (uncertain && !isReferable) {
      actionText =
          'AI confidence below the reliability threshold: no automated '
          'result released. Image routed for mandatory clinician review.';
    } else if (isReferable) {
      actionText =
          'Referable DR detected (${drResult.predictedGrade.label}). '
          'Route to ophthalmologist within referral SLA.';
    } else {
      actionText =
          'Non-referable (${drResult.predictedGrade.label}). Routine annual screening.';
    }

    return ScreeningRecordDart(
      imagePath: 'capture',
      qualityGrade: quality.grade,
      qualityStatus: quality.isReliable ? 'Certified Reliable' : 'Marginal',
      rejectionReasons: const [],
      recaptureAttemptCount: attempt,
      reassessmentOutcome: ReassessmentOutcome.NOT_APPLICABLE,
      drPrediction: drResult,
      confidence: confidence,
      humanReviewRequired: humanReviewRequired,
      humanReviewType: reviewType,
      humanReviewReason: flags.isNotEmpty ? flags.first : null,
      action: actionText,
      qualityMetrics: quality.metrics,
      errorCode: errorCode,
      modelBackend: modelOutput.modelId,
      inferenceMs: modelOutput.inferenceMs,
    );
  }
}
