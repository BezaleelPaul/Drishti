import unittest

from src.pipeline.confidence import ConfidenceConfig, ConfidenceEvaluator
from src.pipeline.schema import DRClassificationResult, DRGrade


class TestConfidenceEvaluator(unittest.TestCase):
    def setUp(self):
        self.evaluator = ConfidenceEvaluator(
            ConfidenceConfig(
                min_confidence_threshold=0.60,
                min_ambiguity_margin=0.15,
                always_flag_high_risk=True,
            )
        )

    def test_confident_low_risk_clears_without_human_review(self):
        # Grade 0 (No DR) with 85% confidence and high margin
        res = DRClassificationResult(
            predicted_grade=DRGrade.NO_DR,
            probabilities=[0.85, 0.08, 0.04, 0.02, 0.01],
            confidence=0.85,
            top2_margin=0.77,
            is_referable=False,
        )
        assessment = self.evaluator.evaluate(res)
        self.assertTrue(assessment.is_confident)
        self.assertFalse(assessment.is_ambiguous)
        self.assertFalse(assessment.is_high_risk)
        self.assertFalse(assessment.requires_human_review)

    def test_low_confidence_flags_human_review(self):
        # Grade 1 with only 45% confidence
        res = DRClassificationResult(
            predicted_grade=DRGrade.MILD_NPDR,
            probabilities=[0.30, 0.45, 0.15, 0.05, 0.05],
            confidence=0.45,
            top2_margin=0.15,
            is_referable=False,
        )
        assessment = self.evaluator.evaluate(res)
        self.assertFalse(assessment.is_confident)
        self.assertTrue(assessment.requires_human_review)

    def test_ambiguous_margin_flags_human_review(self):
        # Top 1 = 0.50, Top 2 = 0.45 -> margin 0.05 (< 0.15)
        res = DRClassificationResult(
            predicted_grade=DRGrade.MODERATE_NPDR,
            probabilities=[0.02, 0.45, 0.50, 0.02, 0.01],
            confidence=0.50,
            top2_margin=0.05,
            is_referable=True,
        )
        assessment = self.evaluator.evaluate(res)
        self.assertTrue(assessment.is_ambiguous)
        self.assertTrue(assessment.requires_human_review)

    def test_high_risk_grade_always_flagged_even_at_99_percent_confidence(self):
        # Section 7: "A high-risk grade is flagged even if the model is confident"
        res = DRClassificationResult(
            predicted_grade=DRGrade.SEVERE_NPDR,
            probabilities=[0.001, 0.002, 0.007, 0.98, 0.01],
            confidence=0.98,
            top2_margin=0.97,
            is_referable=True,
        )
        assessment = self.evaluator.evaluate(res)
        self.assertTrue(assessment.is_high_risk)
        self.assertTrue(assessment.requires_human_review)
        self.assertTrue(any("mandatory ophthalmologist" in f for f in assessment.flags))

    def test_default_threshold_is_70_percent(self):
        # Shipped default (split-half validated, docs/EVALUATION_RESULTS.md 5):
        # confidence 0.65 releases under the legacy 0.60 gate but must now flag.
        default_eval = ConfidenceEvaluator()
        self.assertEqual(default_eval.config.min_confidence_threshold, 0.70)
        res = DRClassificationResult(
            predicted_grade=DRGrade.MILD_NPDR,
            probabilities=[0.20, 0.65, 0.08, 0.04, 0.03],
            confidence=0.65,
            top2_margin=0.45,
            is_referable=False,
        )
        assessment = default_eval.evaluate(res)
        self.assertFalse(assessment.is_confident)
        self.assertTrue(assessment.requires_human_review)
        self.assertTrue(any("70%" in f for f in assessment.flags))


if __name__ == "__main__":
    unittest.main()
