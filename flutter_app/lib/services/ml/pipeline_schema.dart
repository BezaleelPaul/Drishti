// Enum identifiers intentionally mirror src/pipeline/schema.py value strings
// byte-for-byte: the server wire contract, SQLite CHECK constraints and the
// QA corpus branch on these exact strings (GOOD/BORDERLINE/BAD,
// CLINICAL_LEVEL/OPERATOR_LEVEL, ...). The Dart naming lint is waived for
// this file only — renaming would break the parity contract.
// ignore_for_file: constant_identifier_names

import 'dart:math' as math;

/// Byte-parity port of src/pipeline/schema.py.
/// Enum VALUE STRINGS and error codes are a public contract shared with the
/// server/QA corpus — change them only in schema.py and re-run parity tests.

enum QualityGrade { GOOD, BORDERLINE, BAD }

enum ReassessmentOutcome { CLEARED, FAILED, NOT_APPLICABLE }

enum HumanReviewType { NONE, OPERATOR_LEVEL, CLINICAL_LEVEL }

enum DrGrade {
  noDr(0),
  mildNpdr(1),
  moderateNpdr(2),
  severeNpdr(3),
  proliferativeDr(4);

  const DrGrade(this.value);
  final int value;

  static DrGrade fromValue(int value) {
    final match = tryFromValue(value);
    if (match == null) {
      throw ArgumentError('Invalid DR grade: $value');
    }
    return match;
  }

  /// Non-throwing variant for defensive callers (stored rows may predate the
  /// grade range contract); null means "not a valid DR grade".
  static DrGrade? tryFromValue(int value) {
    final match = DrGrade.values.where((g) => g.value == value).toList();
    if (match.isEmpty) return null;
    return match.first;
  }

  String get label => switch (this) {
    noDr => 'No DR',
    mildNpdr => 'Mild NPDR',
    moderateNpdr => 'Moderate NPDR',
    severeNpdr => 'Severe NPDR',
    proliferativeDr => 'Proliferative DR',
  };

  /// Referable DR is defined at grade >= 2.
  bool get isReferable => value >= 2;

  /// High-risk grades (Severe, Proliferative) per Section 7.
  bool get isHighRisk => value == 3 || value == 4;
}

enum QualityReason {
  adequate('Adequate diagnostic quality'),
  severeBlur(
    'Severe blur / loss of retinal focus (Suspected camera defocus or media opacity/cataract)',
  ),
  inadequateIllumination(
    'Inadequate illumination (Suspected insufficient pupil dilation or non-mydriatic issue)',
  ),
  overexposure(
    'Severe glare / overexposure (Corneal reflection or tear film drying)',
  ),
  lowContrast('Low vessel-background contrast'),
  insufficientFieldOfView(
    'Insufficient retinal field of view (Patient fixation loss or uncooperative gaze)',
  ),
  nonFundusOrCorrupt('Non-fundus or corrupt image file'),
  borderlineMarginal('Marginal quality across focus or illumination'),
  lowMlQuality('Low ML ensemble quality score (model confidence below cutoff)');

  const QualityReason(this.display);
  final String display;
}

enum PipelineErrorCode {
  imgInvalid('IMG_INVALID'),
  imgNotFundus('IMG_NOT_FUNDUS'),
  imgUntgradable('IMG_UNGRADABLE'),
  aiLowConfidence('AI_LOW_CONFIDENCE'),
  aiUnavailable('AI_UNAVAILABLE'),
  aiTimeout('AI_TIMEOUT');

  const PipelineErrorCode(this.code);
  final String code;

  static PipelineErrorCode? tryParse(String? code) {
    if (code == null) return null;
    for (final e in PipelineErrorCode.values) {
      if (e.code == code) return e;
    }
    return null;
  }
}

class QualityMetrics {
  const QualityMetrics({
    this.sharpnessScore = 0,
    this.meanBrightness = 0,
    this.contrastScore = 0,
    this.fovRatio = 0,
    this.mlQualityScore = 0,
    this.blackoutRatio = 0,
    this.blowoutRatio = 0,
    this.qualityEngine = 'MultiScale_Adaptive_Fusion',
    Map<String, double>? extraScores,
  }) : extraScores = extraScores ?? const {};

  final double sharpnessScore; // Laplacian variance within retinal mask
  final double meanBrightness; // mean luma [0,255] within retinal mask
  final double contrastScore; // std of luma within retinal mask
  final double fovRatio; // retinal circle area / frame area
  final double mlQualityScore; // multi-scale fusion [0,1]
  final double blackoutRatio; // fraction of FOV pixels blacked out (G < 8)
  final double blowoutRatio; // fraction of FOV pixels blown out (R > 252 & G > 252)
  final String qualityEngine;
  final Map<String, double> extraScores;
}

class QualityAssessmentResult {
  const QualityAssessmentResult({
    required this.grade,
    required this.isReliable,
    this.reasons = const [],
    this.metrics = const QualityMetrics(),
    this.details = '',
    this.suspectedClinicalCause,
    this.errorCode,
  });

  final QualityGrade grade;
  final bool isReliable;
  final List<QualityReason> reasons;
  final QualityMetrics metrics;
  final String details;
  final String? suspectedClinicalCause;
  final PipelineErrorCode? errorCode;
}

class DrClassificationResult {
  const DrClassificationResult({
    required this.predictedGrade,
    required this.probabilities,
    required this.confidence,
    required this.top2Margin,
    required this.isReferable,
  });

  /// The ONE shared score derivation for every 5-class model-provided score
  /// vector: sum-normalise, argmax grade, top-1 confidence, top-1 minus
  /// top-2 margin. DrClassifierDart's own result building delegates here,
  /// and the orchestrator conversion (task 2.2) consumes the same factory,
  /// so the two can never disagree.
  ///
  /// Measurement-only contract: every output value is derived from [probs]
  /// itself — never substituted, padded or synthesized. Malformed vectors
  /// (wrong length, non-positive/NaN/infinite sum) throw instead of
  /// fabricating a result.
  ///
  /// Arithmetic is intentionally identical to the classifier's former
  /// inline derivation (normalisation order, argmax scan, margin) so
  /// existing results keep bit-identical numbers.
  static DrClassificationResult fromProbabilities(List<double> probs) {
    if (probs.length != 5) {
      throw ArgumentError(
        'Expected 5-class probability vector, got ${probs.length}',
      );
    }
    final total = probs.fold<double>(0.0, (a, b) => a + b);
    if (total <= 0 || total.isNaN || total.isInfinite) {
      throw ArgumentError(
        'Invalid probability vector: sum must be positive and finite',
      );
    }
    final normalized = probs.map((p) => p / total).toList();

    var top1Idx = 0;
    var top2Idx = 1;
    for (var i = 0; i < 5; i++) {
      if (normalized[i] > normalized[top1Idx]) {
        top2Idx = top1Idx;
        top1Idx = i;
      } else if (normalized[i] > normalized[top2Idx]) {
        top2Idx = i;
      }
    }

    final top1Conf = normalized[top1Idx];
    final margin = top1Conf - normalized[top2Idx];
    final grade = DrGrade.fromValue(top1Idx);
    return DrClassificationResult(
      predictedGrade: grade,
      probabilities: normalized,
      confidence: top1Conf,
      top2Margin: margin,
      isReferable: grade.isReferable,
    );
  }

  final DrGrade predictedGrade;
  final List<double> probabilities; // [P0..P4]
  final double confidence; // top-1 probability
  final double top2Margin; // top1 - top2
  final bool isReferable;

  /// Port of ConfidenceEvaluator Rule 0: NaN/inf or confidence != max(probs)
  /// must fail closed. Returns an error string, or null when valid.
  String? validate() {
    const tolerance = 1e-6;
    if (probabilities.length != 5 ||
        probabilities.any(
          (p) => p.isNaN || p.isInfinite || p < 0 || p > 1.0000001,
        )) {
      return 'Invalid confidence inputs (NaN/inf or missing values detected): mandatory human review';
    }
    if (confidence.isNaN ||
        confidence.isInfinite ||
        top2Margin.isNaN ||
        top2Margin.isInfinite) {
      return 'Invalid confidence inputs (NaN/inf or missing values detected): mandatory human review';
    }
    final maxProb = probabilities.reduce(math.max);
    if ((confidence - maxProb).abs() > tolerance) {
      return 'Confidence mismatch (confidence ${confidence.toStringAsFixed(4)} '
          '!= max(probs) ${maxProb.toStringAsFixed(4)}): mandatory human review';
    }
    return null;
  }
}

class ConfidenceAssessment {
  const ConfidenceAssessment({
    required this.isConfident,
    required this.isAmbiguous,
    required this.isHighRisk,
    required this.requiresHumanReview,
    this.flags = const [],
  });

  final bool isConfident;
  final bool isAmbiguous;
  final bool isHighRisk;
  final bool requiresHumanReview;
  final List<String> flags;
}

class ScreeningRecordDart {
  const ScreeningRecordDart({
    required this.imagePath,
    required this.qualityGrade,
    required this.qualityStatus,
    required this.rejectionReasons,
    required this.recaptureAttemptCount,
    required this.reassessmentOutcome,
    this.suspectedClinicalCause,
    this.drPrediction,
    this.confidence,
    this.humanReviewRequired = false,
    this.humanReviewType = HumanReviewType.NONE,
    this.humanReviewReason,
    this.action = '',
    this.qualityMetrics,
    this.errorCode,
    this.modelBackend,
    this.inferenceMs,
  });

  final String imagePath;
  final QualityGrade qualityGrade;
  final String qualityStatus;
  final List<String> rejectionReasons;
  final int recaptureAttemptCount;
  final ReassessmentOutcome reassessmentOutcome;
  final String? suspectedClinicalCause;
  final DrClassificationResult? drPrediction;
  final ConfidenceAssessment? confidence;
  final bool humanReviewRequired;
  final HumanReviewType humanReviewType;
  final String? humanReviewReason;
  final String action;
  final QualityMetrics? qualityMetrics;
  final PipelineErrorCode? errorCode;

  /// Backend identity of the model that actually executed and produced this
  /// record's grade. Null when no model ran (decode/quality rejection, model
  /// unavailable) — a record must never claim a backend it did not use.
  /// No default: writing a record without a model run cannot assert one did.
  final String? modelBackend;

  /// Measured resize + pixel-copy + TFLite run time in ms (E-2); null when
  /// classification never ran (BAD/BORDERLINE/unavailable paths).
  final double? inferenceMs;

  /// Clinical calibrated operating point: referable iff top-1 >= 2 OR
  /// referable probability mass (p2+p3+p4) >= 0.6450, per
  /// Kaggle GPU clinical calibration (held-out t* = 0.6450: sens 96.28% / spec 91.03% / QWK 0.8739).
  bool get referableFlag {
    final dr = drPrediction;
    if (dr == null) return false;
    final referableMass = dr.probabilities
        .sublist(2)
        .fold(0.0, (a, b) => a + b);
    return dr.predictedGrade.isReferable || referableMass >= 0.6450;
  }
}
