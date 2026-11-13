import unittest

from src.pipeline.router import ScreeningPipelineRouter
from src.pipeline.schema import (
    HumanReviewType,
    QualityAssessmentResult,
    QualityGrade,
    QualityReason,
    ReassessmentOutcome,
)
from tests.unit.test_quality import create_synthetic_fundus_image


class TestPipelineFlowIntegration(unittest.TestCase):
    """
    End-to-end integration tests verifying every branch of Section 3's flow.
    """

    def setUp(self):
        self.router = ScreeningPipelineRouter()

    def test_good_image_flow(self):
        """
        Good image -> reaches Model 2 without touching Reassessment/Recapture.
        """
        img = create_synthetic_fundus_image()
        record = self.router.process_image(img, recapture_attempt_count=0)

        # Must clear quality gate
        self.assertEqual(record.quality_grade, QualityGrade.GOOD)
        self.assertEqual(record.reassessment_outcome, ReassessmentOutcome.NOT_APPLICABLE)
        # Must reach Model 2
        self.assertIsNotNone(record.dr_prediction)
        self.assertIsNotNone(record.gradcam_result)

    def test_bad_image_flow_prevents_dr_classification(self):
        """
        Bad image -> routes to Recapture, NEVER touches Model 2 directly.
        """
        img = create_synthetic_fundus_image(brightness_shift=-180.0)  # severely underexposed
        record = self.router.process_image(img, recapture_attempt_count=0)

        self.assertEqual(record.quality_grade, QualityGrade.BAD)
        # CRITICAL RULE: dr_prediction must be None
        self.assertIsNone(record.dr_prediction)
        self.assertIsNone(record.gradcam_result)
        self.assertIn("Recapture image", record.action)
        self.assertEqual(record.recapture_attempt_count, 1)

    def test_retry_cap_enforcement(self):
        """
        Section 5/7: Retry limit hard cap of 2 recaptures per patient session.
        When attempts == 2, next bad image must force-escalate to human review.
        """
        img = create_synthetic_fundus_image(brightness_shift=-180.0)
        # 2 prior recaptures exhausted
        record = self.router.process_image(img, recapture_attempt_count=2)

        self.assertEqual(record.quality_grade, QualityGrade.BAD)
        self.assertIsNone(record.dr_prediction)
        self.assertTrue(record.human_review_required)
        self.assertEqual(record.human_review_type, HumanReviewType.OPERATOR_LEVEL)
        self.assertIn("Recapture cap", record.action)

    def test_borderline_image_reassessment_flow(self):
        """
        Borderline image -> enters reassessment (Node 4).
        If reassessment fails -> does NOT reach Model 2.
        """
        # Force the BORDERLINE branch deterministically: brightness shifts alone
        # grade GOOD in this environment, which previously let this test pass
        # vacuously without ever entering reassessment.
        img = create_synthetic_fundus_image(brightness_shift=-35.0)
        borderline = QualityAssessmentResult(
            grade=QualityGrade.BORDERLINE,
            is_reliable=False,
            reasons=[QualityReason.BORDERLINE_MARGINAL],
            details="Forced borderline for reassessment-path coverage.",
        )
        self.router.quality_checker.assess_image = lambda *a, **k: borderline
        record = self.router.process_image(img, recapture_attempt_count=0)

        # Must have entered reassessment (Node 4).
        self.assertEqual(record.quality_grade, QualityGrade.BORDERLINE)
        self.assertIn(record.reassessment_outcome, (ReassessmentOutcome.FAILED, ReassessmentOutcome.CLEARED))
        if record.reassessment_outcome == ReassessmentOutcome.FAILED:
            self.assertIsNone(record.dr_prediction)
            self.assertTrue(record.human_review_required)
        else:
            self.assertIsNotNone(record.dr_prediction)


if __name__ == "__main__":
    unittest.main()
