import unittest

import numpy as np

from src.classification.classifier import DRClassifier
from src.pipeline.schema import DRGrade


class TestDRClassifier(unittest.TestCase):

    def setUp(self):
        self.classifier = DRClassifier()

    def test_classifier_predicts_valid_distribution(self):
        # 224x224 synthetic fundus
        img = np.zeros((224, 224, 3), dtype=np.uint8)
        img[:, :, 0] = 180
        img[:, :, 1] = 90
        img[:, :, 2] = 30

        result = self.classifier.predict(img)
        self.assertEqual(len(result.probabilities), 5)
        self.assertAlmostEqual(sum(result.probabilities), 1.0, places=3)
        self.assertIn(result.predicted_grade.value, range(5))
        self.assertGreaterEqual(result.confidence, 0.0)
        self.assertLessEqual(result.confidence, 1.0)
        self.assertGreaterEqual(result.top2_margin, 0.0)

    def test_referable_dr_flag(self):
        # Test property behavior
        self.assertFalse(DRGrade.NO_DR.is_referable)
        self.assertFalse(DRGrade.MILD_NPDR.is_referable)
        self.assertTrue(DRGrade.MODERATE_NPDR.is_referable)
        self.assertTrue(DRGrade.SEVERE_NPDR.is_referable)
        self.assertTrue(DRGrade.PROLIFERATIVE_DR.is_referable)


if __name__ == "__main__":
    unittest.main()
