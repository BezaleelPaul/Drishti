import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/services/ml/pipeline_schema.dart';

/// Task 1.2: the ONE shared score derivation used by DrClassifierDart's own
/// result building (and, from task 2.2, by the orchestrator conversion) so
/// the two can never disagree.
///
/// Numeric identity: the [referenceBuildResult] function below is the exact
/// derivation DrClassifierDart._buildResult performs today (dr_classifier.dart
/// _buildResult at HEAD). The shared factory must produce bit-identical
/// doubles for every input — the classifier's output values must not change.
void main() {
  // Frozen reference: verbatim port of DrClassifierDart._buildResult at HEAD.
  DrClassificationResult referenceBuildResult(List<double> probs) {
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

  void expectBitIdentical(
    DrClassificationResult a,
    DrClassificationResult b,
    String reason,
  ) {
    expect(a.predictedGrade, b.predictedGrade, reason: reason);
    // Exact double equality — no tolerance: the classifier's numbers must not
    // drift by even one ulp when the derivation moves behind the factory.
    expect(a.confidence, b.confidence, reason: reason);
    expect(a.top2Margin, b.top2Margin, reason: reason);
    expect(a.isReferable, b.isReferable, reason: reason);
    expect(a.probabilities.length, b.probabilities.length, reason: reason);
    for (var i = 0; i < a.probabilities.length; i++) {
      expect(a.probabilities[i], b.probabilities[i], reason: '$reason [$i]');
    }
  }

  group('DrClassificationResult.fromProbabilities (shared derivation)', () {
    test('matches the classifier derivation bit-for-bit on real vectors', () {
      const vectors = <List<double>>[
        // Already-normalised confident vector.
        [0.90, 0.05, 0.03, 0.01, 0.01],
        // Raw unnormalised model scores (the classifier's real input shape).
        [10.0, 5.0, 1.0, 0.5, 0.1],
        // Ambiguous distribution (margin below the 0.15 gate).
        [0.40, 0.30, 0.20, 0.06, 0.04],
        // Confident referable grade.
        [0.02, 0.03, 0.85, 0.07, 0.03],
        // High-risk grade.
        [0.01, 0.02, 0.04, 0.90, 0.03],
        // All-equal tie: argmax stays at index 0.
        [0.2, 0.2, 0.2, 0.2, 0.2],
        // Descending start (top-1 in first slot, quirk-preserving case).
        [0.5, 0.3, 0.2, 0.0, 0.0],
        // Ascending: top-1 lands on the last index.
        [0.0, 0.0, 0.2, 0.3, 0.5],
        // Very small but positive scores still normalise.
        [1e-300, 2e-300, 3e-300, 4e-300, 5e-300],
      ];
      for (final v in vectors) {
        expectBitIdentical(
          DrClassificationResult.fromProbabilities(v),
          referenceBuildResult(v),
          'vector $v',
        );
      }
    });

    test('computes normalised scores from an unnormalised vector', () {
      final res = DrClassificationResult.fromProbabilities(const [
        10.0,
        5.0,
        1.0,
        0.5,
        0.1,
      ]);
      // Floating-point sums of normalised doubles land on 1.0 within 1 ulp.
      expect(
        res.probabilities.fold<double>(0.0, (a, b) => a + b),
        closeTo(1.0, 1e-12),
      );
      expect(res.predictedGrade, DrGrade.noDr);
      expect(res.confidence, res.probabilities[0]);
    });

    test('confidence is exactly max(normalised probabilities)', () {
      final res = DrClassificationResult.fromProbabilities(const [
        0.01,
        0.02,
        0.04,
        0.90,
        0.03,
      ]);
      final maxProb = res.probabilities.reduce((a, b) => a > b ? a : b);
      expect(res.confidence, maxProb);
    });

    test('margin is exactly top-1 minus top-2', () {
      final res = DrClassificationResult.fromProbabilities(const [
        0.02,
        0.03,
        0.85,
        0.07,
        0.03,
      ]);
      // Select top-1 and top-2 from the produced normalised scores.
      var top1Idx = 0;
      for (var i = 1; i < 5; i++) {
        if (res.probabilities[i] > res.probabilities[top1Idx]) top1Idx = i;
      }
      var top2Idx = -1;
      for (var i = 0; i < 5; i++) {
        if (i != top1Idx &&
            (top2Idx == -1 ||
                res.probabilities[i] > res.probabilities[top2Idx])) {
          top2Idx = i;
        }
      }
      expect(top1Idx, 2); // 0.85
      expect(top2Idx, 3); // 0.07 is the second-largest, not 0.03
      // Exact double equality: margin is measured from the same doubles.
      expect(res.confidence, res.probabilities[top1Idx]);
      expect(
        res.top2Margin,
        res.probabilities[top1Idx] - res.probabilities[top2Idx],
      );
      expect(res.top2Margin, lessThan(res.confidence));
      expect(res.top2Margin, greaterThanOrEqualTo(0.0));
    });

    test('argmax grade and referable flag follow the normalised vector', () {
      final severe = DrClassificationResult.fromProbabilities(const [
        0.01,
        0.02,
        0.04,
        0.90,
        0.03,
      ]);
      expect(severe.predictedGrade, DrGrade.severeNpdr);
      expect(severe.isReferable, isTrue);

      final none = DrClassificationResult.fromProbabilities(const [
        0.90,
        0.05,
        0.03,
        0.01,
        0.01,
      ]);
      expect(none.predictedGrade, DrGrade.noDr);
      expect(none.isReferable, isFalse);
    });

    test('result satisfies the Rule 0 validate() invariant', () {
      final res = DrClassificationResult.fromProbabilities(const [
        0.40,
        0.30,
        0.20,
        0.06,
        0.04,
      ]);
      expect(res.validate(), isNull);
    });

    test('rejects malformed vectors instead of fabricating a result', () {
      // Wrong length — never pad or truncate into a valid shape.
      expect(
        () => DrClassificationResult.fromProbabilities(const [0.5, 0.5]),
        throwsArgumentError,
      );
      expect(
        () => DrClassificationResult.fromProbabilities(const [
          0.2,
          0.2,
          0.2,
          0.2,
          0.2,
          0.0,
        ]),
        throwsArgumentError,
      );
      // Zero-sum vector — no normalisation possible, no invented values.
      expect(
        () => DrClassificationResult.fromProbabilities(const [
          0.0,
          0.0,
          0.0,
          0.0,
          0.0,
        ]),
        throwsArgumentError,
      );
      // NaN element poisons the sum — rejected, not laundered.
      expect(
        () => DrClassificationResult.fromProbabilities(const [
          double.nan,
          0.1,
          0.1,
          0.1,
          0.1,
        ]),
        throwsArgumentError,
      );
      // Infinite element poisons the sum — rejected, not laundered.
      expect(
        () => DrClassificationResult.fromProbabilities(const [
          double.infinity,
          0.0,
          0.0,
          0.0,
          0.0,
        ]),
        throwsArgumentError,
      );
    });
  });
}
