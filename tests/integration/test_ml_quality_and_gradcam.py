import unittest

import numpy as np

from src.classification.classifier import DRClassifier
from src.classification.gradcam import GradCAMExplainer
from src.pipeline.router import ScreeningPipelineRouter
from src.pipeline.schema import QualityGrade
from src.quality.checker import ImageQualityChecker
from src.quality.enhancer import AdaptiveQualityEnhancer
from src.synthetic_fixtures import create_synthetic_fundus_image


class TestMLQualityAndGradCAM(unittest.TestCase):
    """
    Integration test verifying the ML-driven quality engine,
    adaptive CIELAB enhancer, and true gradient Grad-CAM++ pipeline.
    """

    def setUp(self):
        self.checker = ImageQualityChecker()
        self.enhancer = AdaptiveQualityEnhancer()
        self.classifier = DRClassifier()
        self.explainer = GradCAMExplainer(classifier_backend=self.classifier, use_gradcam_plus_plus=True)

        # Synthetic circular fundus test image with vessel-like detail
        # so contrast and sharpness metrics pass the reliability gate.
        self.test_img = create_synthetic_fundus_image()

    def test_ml_quality_scoring(self):
        res = self.checker.assess_image(self.test_img)
        self.assertIn(res.grade, (QualityGrade.GOOD, QualityGrade.BORDERLINE))
        self.assertIn("ml_quality_score", res.metrics.raw_scores)
        ml_score = res.metrics.raw_scores["ml_quality_score"]
        self.assertGreaterEqual(ml_score, 0.0)
        self.assertLessEqual(ml_score, 1.0)

    def test_dynamic_crop_and_clahe(self):
        cropped = self.enhancer.dynamic_circle_crop(self.test_img, size=256)
        enhanced = self.enhancer.enhance_borderline_image(cropped)
        self.assertEqual(enhanced.shape, (256, 256, 3))
        self.assertEqual(enhanced.dtype, np.uint8)

    def test_dr_classifier_and_gradcam_binding(self):
        pred = self.classifier.predict(self.test_img)
        self.assertEqual(len(pred.probabilities), 5)
        self.assertIn(pred.predicted_grade.value, range(5))

        gradcam_res = self.explainer.generate_heatmap(
            self.test_img, pred.predicted_grade, classifier=self.classifier
        )
        self.assertTrue(gradcam_res.heatmap_generated)
        self.assertIsNotNone(gradcam_res.target_layer)
        self.assertEqual(gradcam_res.heatmap_array.shape[:2], self.test_img.shape[:2])
        self.assertEqual(gradcam_res.heatmap_array.shape[2], 3)

    def test_router_integration_with_ml_components(self):
        router = ScreeningPipelineRouter(
            quality_checker=self.checker,
            dr_classifier=self.classifier,
            gradcam_explainer=self.explainer,
        )
        record = router.process_image(self.test_img)
        self.assertIsNotNone(record.quality_metrics)
        self.assertIn("ml_quality_score", record.quality_metrics.raw_scores)
        # This fixture grades GOOD, so Model 2 + Grad-CAM must have run.
        self.assertIsNotNone(record.dr_prediction)
        self.assertIsNotNone(record.gradcam_result)
        self.assertTrue(record.gradcam_result.heatmap_generated)


if __name__ == "__main__":
    unittest.main()
