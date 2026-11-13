import os
import tempfile
import unittest

from src.pipeline.router import ScreeningPipelineRouter
from src.pipeline.schema import DRGrade, HumanReviewType, QualityGrade, QualityReason
from tests.unit.test_quality import create_synthetic_fundus_image


class TestEdgeCases(unittest.TestCase):
    """
    Directly tests the explicit Section 18 edge case criteria.
    """

    def setUp(self):
        self.router = ScreeningPipelineRouter()

    def test_corrupt_or_unreadable_file_upload(self):
        """
        Section 18: Corrupt/unreadable file upload -> fails gracefully
        with a clear error, not a silent crash or default grade.
        """
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf:
            tf.write(b"NOT AN IMAGE FILE RANDOM GARBAGE DATA")
            temp_path = tf.name

        try:
            record = self.router.process_image(temp_path)
            self.assertEqual(record.quality_grade, QualityGrade.BAD)
            self.assertIsNone(record.dr_prediction)
            self.assertTrue(any("non-fundus or corrupt" in r.lower() for r in record.rejection_reasons))
            self.assertIn("non-fundus or corrupt", record.format_report_text().lower())
        finally:
            if os.path.exists(temp_path):
                os.remove(temp_path)

    def test_non_fundus_image_rejection(self):
        """
        Section 18: Non-fundus image (e.g. an unrelated photo) submitted ->
        confirm Model 1 routes it toward Bad/rejection rather than Model 2
        attempting a grade on nonsense input.
        """
        non_fundus = create_synthetic_fundus_image(is_non_fundus=True)
        record = self.router.process_image(non_fundus)
        self.assertEqual(record.quality_grade, QualityGrade.BAD)
        self.assertIsNone(record.dr_prediction)
        self.assertIn(QualityReason.NON_FUNDUS_OR_CORRUPT.value, record.rejection_reasons)

    def test_high_risk_grade_at_high_confidence_is_still_flagged(self):
        """
        Section 18: High-risk grade (Severe/Proliferative) at high confidence ->
        confirm it is still flagged (confidence is not allowed to suppress high-severity flag).
        """
        # Mock class prediction to return Grade 4 with 99% confidence
        class MockHighRiskClassifier:
            def predict(self, _):
                from src.pipeline.schema import DRClassificationResult
                return DRClassificationResult(
                    predicted_grade=DRGrade.PROLIFERATIVE_DR,
                    probabilities=[0.0, 0.0, 0.0, 0.01, 0.99],
                    confidence=0.99,
                    top2_margin=0.98,
                    is_referable=True,
                )

            def get_backend(self):
                return "keras"

        router = ScreeningPipelineRouter(dr_classifier=MockHighRiskClassifier())
        good_img = create_synthetic_fundus_image()
        record = router.process_image(good_img)

        self.assertIsNotNone(record.dr_prediction)
        self.assertEqual(record.dr_prediction.predicted_grade, DRGrade.PROLIFERATIVE_DR)
        # MUST BE FLAGGED despite 99% confidence
        self.assertTrue(record.human_review_required)
        self.assertEqual(record.human_review_type, HumanReviewType.CLINICAL_LEVEL)
        self.assertTrue(record.confidence_assessment.is_high_risk)


if __name__ == "__main__":
    unittest.main()
