import unittest

from src.pipeline.schema import QualityGrade, QualityReason
from src.quality.checker import ImageQualityChecker
from src.synthetic_fixtures import create_synthetic_fundus_image


class TestImageQualityChecker(unittest.TestCase):

    def setUp(self):
        self.checker = ImageQualityChecker()

    def test_sharp_fundus_grades_good(self):
        img = create_synthetic_fundus_image()
        result = self.checker.assess_image(img)
        self.assertEqual(result.grade, QualityGrade.GOOD)
        self.assertGreater(result.metrics.sharpness_score, 0.0)

    def test_severely_underexposed_image_grades_bad(self):
        img = create_synthetic_fundus_image(brightness_shift=-180.0)
        result = self.checker.assess_image(img)
        self.assertEqual(result.grade, QualityGrade.BAD)
        self.assertIn(QualityReason.INADEQUATE_ILLUMINATION, result.reasons)

    def test_non_fundus_image_grades_bad(self):
        img = create_synthetic_fundus_image(is_non_fundus=True)
        result = self.checker.assess_image(img)
        self.assertEqual(result.grade, QualityGrade.BAD)
        self.assertIn(QualityReason.NON_FUNDUS_OR_CORRUPT, result.reasons)

    def test_strict_mode_increases_scrutiny(self):
        img = create_synthetic_fundus_image(brightness_shift=-40.0)
        res_normal = self.checker.assess_image(img, strict_mode=False)
        res_strict = self.checker.assess_image(img, strict_mode=True)
        # Strict mode should be equal or stricter
        severity_rank = {QualityGrade.GOOD: 1, QualityGrade.BORDERLINE: 2, QualityGrade.BAD: 3}
        self.assertGreaterEqual(severity_rank[res_strict.grade], severity_rank[res_normal.grade])


if __name__ == "__main__":
    unittest.main()
