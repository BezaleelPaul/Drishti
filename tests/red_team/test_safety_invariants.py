"""
Red-team: no forced predictions.

Terminal invariants asserted for every screening attempt:
  * a failure state always carries a machine-readable ``error_code``
  * a failed/ungradable image NEVER carries a DR grade
  * a graded image is either confident (no code) or explicitly
    AI_LOW_CONFIDENCE - never an image-domain code
"""

import os
import tempfile
import unittest

from src.pipeline.router import ScreeningPipelineRouter
from src.pipeline.schema import (
    PipelineErrorCode,
    QualityGrade,
    QualityReason,
    ScreeningRecord,
)
from src.synthetic_fixtures import create_synthetic_fundus_image
from tests.red_team.test_domain_gate_red_team import non_fundus_probes


class TestNoForcedPrediction(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.router = ScreeningPipelineRouter()

    def test_non_fundus_upload_never_produces_a_grade(self):
        for name, img in non_fundus_probes().items():
            with self.subTest(probe=name):
                record = self.router.process_image(img)
                self.assertIsNone(
                    record.dr_prediction,
                    f"'{name}' produced a DR grade: {record.dr_prediction}",
                )
                self.assertIsNone(record.confidence_assessment)
                self.assertIs(record.error_code, PipelineErrorCode.IMG_NOT_FUNDUS)
                self.assertEqual(record.quality_grade, QualityGrade.BAD)

    def test_corrupt_file_fails_with_invalid_code_not_a_default_grade(self):
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf:
            tf.write(b"NOT AN IMAGE FILE RANDOM GARBAGE DATA")
            path = tf.name
        try:
            record = self.router.process_image(path)
        finally:
            os.unlink(path)

        self.assertEqual(record.quality_grade, QualityGrade.BAD)
        self.assertIsNone(record.dr_prediction)
        self.assertIs(record.error_code, PipelineErrorCode.IMG_INVALID)
        self.assertIn(QualityReason.NON_FUNDUS_OR_CORRUPT.value, record.rejection_reasons)

    def test_retry_cap_escalation_still_carries_its_error_code(self):
        record = self.router.process_image(
            non_fundus_probes()["face_selfie"],
            recapture_attempt_count=self.router.MAX_RECAPTURE_CAP,
        )
        self.assertIs(record.error_code, PipelineErrorCode.IMG_NOT_FUNDUS)
        self.assertTrue(record.human_review_required)
        self.assertIsNone(record.dr_prediction)

    def test_every_ungraded_record_has_a_code_and_every_confident_record_does_not(self):
        probes = {
            "good": create_synthetic_fundus_image(),
            "blurred": create_synthetic_fundus_image(blur_level=6.0),
            "underexposed": create_synthetic_fundus_image(brightness_shift=-180.0),
            "non_fundus": non_fundus_probes()["paper_document"],
        }
        for name, img in probes.items():
            with self.subTest(probe=name):
                record = self.router.process_image(img)
                if record.dr_prediction is None:
                    self.assertIsNotNone(
                        record.error_code,
                        f"'{name}' failed with no machine-readable error_code",
                    )
                    continue

                conf = record.confidence_assessment
                uncertain = conf is not None and (not conf.is_confident or conf.is_ambiguous)
                if uncertain:
                    self.assertIs(
                        record.error_code,
                        PipelineErrorCode.AI_LOW_CONFIDENCE,
                        f"'{name}' was uncertain but coded {record.error_code}",
                    )
                else:
                    self.assertIsNone(
                        record.error_code,
                        f"'{name}' was confident yet coded {record.error_code}",
                    )

    def test_uncertain_non_referable_result_never_reads_as_a_final_no_dr_answer(self):
        """Low confidence must not ship 'Routine screening: No DR detected'."""
        record = self.router.process_image(create_synthetic_fundus_image())
        self.assertIsNotNone(record.dr_prediction)
        if record.error_code is PipelineErrorCode.AI_LOW_CONFIDENCE:
            self.assertNotIn("No DR detected", record.action)
            self.assertTrue(record.human_review_required)
            self.assertIn(record.human_review_type.value, ("CLINICAL_LEVEL", "OPERATOR_LEVEL"))

    def test_confident_gradable_fundus_can_state_a_result(self):
        """A confident prediction carries no error code and is not suppressed."""
        record = self.router.process_image(create_synthetic_fundus_image())
        pred = record.dr_prediction
        if pred is None:
            self.fail("gradable synthetic fundus produced no prediction")
        self.assertGreater(float(pred.confidence), 0.0)
        self.assertIn(record.quality_grade, (QualityGrade.GOOD, QualityGrade.BORDERLINE))
        if record.error_code is None:
            self.assertNotIn("AI confidence below the reliability threshold", record.action)

    def test_reassessment_cleared_borderline_is_not_an_error_state(self):
        record = self.router.process_image(create_synthetic_fundus_image(brightness_shift=-40.0))
        if record.reassessment_outcome.value == "CLEARED":
            if record.error_code is not None:
                self.assertIs(record.error_code, PipelineErrorCode.AI_LOW_CONFIDENCE)
            if record.dr_prediction is None:
                self.fail("cleared borderline must carry its prediction")


class TestErrorCodeContract(unittest.TestCase):
    def test_error_codes_are_stable_and_client_branchable(self):
        self.assertEqual(
            [c.value for c in PipelineErrorCode],
            [
                "IMG_INVALID",
                "IMG_NOT_FUNDUS",
                "IMG_UNGRADABLE",
                "AI_LOW_CONFIDENCE",
                "AI_UNAVAILABLE",
                "AI_TIMEOUT",
            ],
        )

    def test_screening_record_serialises_the_code_into_the_report(self):
        record = ScreeningRecord(
            image_path="x.jpg",
            quality_grade=QualityGrade.BAD,
            quality_status="Unreliable",
            rejection_reasons=["Non-fundus or corrupt image file"],
            error_code=PipelineErrorCode.IMG_NOT_FUNDUS,
            action="Recapture image.",
        )
        report = record.format_report_text()
        self.assertIn("IMG_NOT_FUNDUS", report)
        self.assertIn("Not generated", report)

    def test_api_response_model_exposes_error_code(self):
        from api.schemas import RetinalAnalysisResponse, RetinalQualityResponse

        for model in (RetinalAnalysisResponse, RetinalQualityResponse):
            self.assertIn("error_code", model.model_fields)


if __name__ == "__main__":
    unittest.main()
