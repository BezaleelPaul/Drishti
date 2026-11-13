import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/services/ml/confidence_evaluator.dart';
import 'package:netra_ai_mobile/services/ml/pipeline_schema.dart';

void main() {
  group('ConfidenceEvaluatorDart (parity with src/pipeline/confidence.py)', () {
    const evaluator = ConfidenceEvaluatorDart();

    DrClassificationResult resultOf(
      List<double> probs, {
      double? confidence,
      double? margin,
    }) {
      final sorted = List<double>.from(probs)..sort();
      final top1 = probs.indexOf(sorted.last);
      final grade = DrGrade.fromValue(top1);
      return DrClassificationResult(
        predictedGrade: grade,
        probabilities: probs,
        confidence: confidence ?? sorted.last,
        top2Margin: margin ?? sorted.last - sorted[sorted.length - 2],
        isReferable: grade.isReferable,
      );
    }

    test('confident non-referable prediction needs no review', () {
      final r = resultOf([0.85, 0.05, 0.04, 0.03, 0.03]);
      final a = evaluator.evaluate(r);
      expect(a.isConfident, isTrue);
      expect(a.isAmbiguous, isFalse);
      expect(a.isHighRisk, isFalse);
      expect(a.requiresHumanReview, isFalse);
      expect(a.flags, isEmpty);
    });

    test('low confidence (<0.70) flags review with exact flag string', () {
      final r = resultOf([0.45, 0.30, 0.10, 0.10, 0.05]);
      final a = evaluator.evaluate(r);
      expect(a.isConfident, isFalse);
      expect(a.requiresHumanReview, isTrue);
      expect(a.flags, contains('Low confidence (45.0% < 70%)'));
    });

    test('ambiguous margin (<0.15) flags ambiguity', () {
      final r = resultOf([0.40, 0.35, 0.15, 0.07, 0.03]);
      final a = evaluator.evaluate(r);
      expect(a.isAmbiguous, isTrue);
      expect(a.requiresHumanReview, isTrue);
      expect(
        a.flags,
        contains('Class ambiguity (Top-1/Top-2 margin 0.05 < 0.15)'),
      );
    });

    test('high-risk grade 3 is mandatory-review even at confidence 1.0', () {
      final r = resultOf([0.0, 0.0, 0.0, 1.0, 0.0]);
      final a = evaluator.evaluate(r);
      expect(a.isHighRisk, isTrue);
      expect(a.requiresHumanReview, isTrue);
      expect(
        a.flags,
        contains(
          'High-risk clinical grade (Severe NPDR): mandatory ophthalmologist over-read',
        ),
      );
    });

    test('high-risk grade 4 is mandatory-review even at confidence 1.0', () {
      final r = resultOf([0.0, 0.0, 0.0, 0.0, 1.0]);
      final a = evaluator.evaluate(r);
      expect(a.isHighRisk, isTrue);
      expect(a.requiresHumanReview, isTrue);
    });

    test('confidence mismatch with max(probs) fails closed', () {
      final r = resultOf([0.85, 0.05, 0.04, 0.03, 0.03], confidence: 0.50);
      final a = evaluator.evaluate(r);
      expect(a.isConfident, isFalse);
      expect(a.requiresHumanReview, isTrue);
      expect(a.flags.first, startsWith('Confidence mismatch'));
    });

    test('NaN confidence fails closed with the Python-validation message', () {
      final r = resultOf([
        0.85,
        0.05,
        0.04,
        0.03,
        0.03,
      ], confidence: double.nan);
      final a = evaluator.evaluate(r);
      expect(a.isConfident, isFalse);
      expect(a.requiresHumanReview, isTrue);
      expect(
        a.flags,
        contains(
          'Invalid confidence inputs (NaN/inf or missing values detected): mandatory human review',
        ),
      );
    });

    test('NaN in probabilities fails closed', () {
      // Build directly: sorting a list containing NaN is unspecified, so the
      // helper's argmax is not meaningful here.
      final r = DrClassificationResult(
        predictedGrade: DrGrade.noDr,
        probabilities: [0.85, 0.05, 0.04, 0.03, double.nan],
        confidence: 0.85,
        top2Margin: 0.8,
        isReferable: false,
      );
      final a = evaluator.evaluate(r);
      expect(a.requiresHumanReview, isTrue);
      expect(a.flags.first, startsWith('Invalid confidence inputs'));
    });

    test('grade 2 (referable, low confidence) flags review via Rule 1', () {
      final r = resultOf([0.10, 0.15, 0.55, 0.12, 0.08]);
      final a = evaluator.evaluate(r);
      expect(a.isConfident, isFalse); // 0.55 < 0.70
      expect(a.requiresHumanReview, isTrue);
      expect(a.flags, contains('Low confidence (55.0% < 70%)'));
    });
  });
}
