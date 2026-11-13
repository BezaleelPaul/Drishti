import 'dart:math' as math;

import 'pipeline_schema.dart';
import 'quality_thresholds.dart';

/// Port of src/pipeline/confidence.py `ConfidenceEvaluator` (Section 7).
/// Flag strings are byte-identical to the Python output — QA corpus and
/// doctor console branch on them.
class ConfidenceEvaluatorDart {
  const ConfidenceEvaluatorDart();

  ConfidenceAssessment evaluate(DrClassificationResult drResult) {
    final flags = <String>[];
    var isConfident = true;
    var isAmbiguous = false;
    var isHighRisk = false;
    var requiresReview = false;

    // Rule 0: input validation — NaN/inf or confidence != max(probs).
    final validationError = drResult.validate();
    if (validationError != null) {
      isConfident = false;
      requiresReview = true;
      flags.add(validationError);
    } else {
      final maxProb = drResult.probabilities.reduce((a, b) => math.max(a, b));
      if ((drResult.confidence - maxProb).abs() > 1e-6) {
        isConfident = false;
        requiresReview = true;
        flags.add(
          'Confidence mismatch (confidence ${drResult.confidence.toStringAsFixed(4)} '
          '!= max(probs) ${maxProb.toStringAsFixed(4)}): mandatory human review',
        );
      }
    }

    // Rule 1: low softmax confidence.
    if (!drResult.confidence.isNaN &&
        drResult.confidence < kMinConfidenceThreshold) {
      isConfident = false;
      requiresReview = true;
      flags.add(
        'Low confidence '
        '(${(drResult.confidence * 100).toStringAsFixed(1)}% < '
        '${(kMinConfidenceThreshold * 100).toStringAsFixed(0)}%)',
      );
    }

    // Rule 2: class ambiguity (top1-top2 margin).
    if (!drResult.top2Margin.isNaN &&
        drResult.top2Margin < kMinAmbiguityMargin) {
      isAmbiguous = true;
      requiresReview = true;
      flags.add(
        'Class ambiguity (Top-1/Top-2 margin '
        '${drResult.top2Margin.toStringAsFixed(2)} < '
        '${kMinAmbiguityMargin.toStringAsFixed(2)})',
      );
    }

    // Rule 3: high-risk grades (3/4) always flagged, even when confident.
    if (kAlwaysFlagHighRisk && drResult.predictedGrade.isHighRisk) {
      isHighRisk = true;
      requiresReview = true;
      flags.add(
        'High-risk clinical grade (${drResult.predictedGrade.label}): mandatory ophthalmologist over-read',
      );
    }

    return ConfidenceAssessment(
      isConfident: isConfident,
      isAmbiguous: isAmbiguous,
      isHighRisk: isHighRisk,
      requiresHumanReview: requiresReview,
      flags: flags,
    );
  }
}
