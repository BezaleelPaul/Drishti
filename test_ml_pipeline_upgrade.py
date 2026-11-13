"""
Verification script for ML-driven Quality Assessment & True Grad-CAM Engine.
"""
import os
import sys

import numpy as np

# Ensure project root in sys.path
PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from src.classification.classifier import DRClassifier
from src.classification.gradcam import GradCAMExplainer
from src.pipeline.router import ScreeningPipelineRouter
from src.quality.checker import ImageQualityChecker
from src.quality.enhancer import AdaptiveQualityEnhancer


def run_tests():
    print("Testing ML Quality Checker...")
    checker = ImageQualityChecker()
    test_img = np.zeros((256, 256, 3), dtype=np.uint8)
    # Synthetic fundus circle
    y, x = np.ogrid[:256, :256]
    mask = (x - 128)**2 + (y - 128)**2 <= 100**2
    test_img[mask, 0] = 200 # Red
    test_img[mask, 1] = 100 # Green
    test_img[mask, 2] = 40  # Blue

    res = checker.assess_image(test_img)
    print(f"Quality Grade: {res.grade}, Is Reliable: {res.is_reliable}")
    print(f"Metrics: Sharpness={res.metrics.sharpness_score:.1f}, ML Quality Score={res.metrics.raw_scores.get('ml_quality_score', 'N/A')}")
    print(f"Engine: {res.metrics.raw_scores.get('quality_engine', 'N/A')}")
    assert res.metrics.raw_scores.get('ml_quality_score') is not None
    print("[PASS] Quality Checker OK")

    print("\nTesting Adaptive CLAHE & Dynamic ROI Enhancer...")
    enhancer = AdaptiveQualityEnhancer()
    cropped = enhancer.dynamic_circle_crop(test_img, size=256)
    enhanced = enhancer.enhance_borderline_image(cropped)
    assert enhanced.shape == (256, 256, 3)
    print("[PASS] Enhancer OK")

    print("\nTesting DR Classifier...")
    classifier = DRClassifier()
    print(f"Classifier backend: {classifier.get_backend()}")
    pred = classifier.predict(test_img)
    print(f"Predicted Grade: {pred.predicted_grade.value} ({pred.predicted_grade.label}), Conf: {pred.confidence:.2f}")
    assert len(pred.probabilities) == 5
    print("[PASS] Classifier OK")

    print("\nTesting Grad-CAM Explainer with True Gradient Engine...")
    explainer = GradCAMExplainer(classifier_backend=classifier, use_gradcam_plus_plus=True)
    gradcam_res = explainer.generate_heatmap(test_img, pred.predicted_grade)
    print(f"Heatmap Generated: {gradcam_res.heatmap_generated}, Target Layer: {gradcam_res.target_layer}")
    assert gradcam_res.heatmap_generated is True
    print("[PASS] Grad-CAM Explainer OK")

    print("\nTesting Screening Pipeline Router End-to-End...")
    router = ScreeningPipelineRouter(
        quality_checker=checker,
        dr_classifier=classifier,
        gradcam_explainer=explainer,
    )
    record = router.process_image(test_img)
    print(f"Pipeline Result: Quality={record.quality_grade}, DR={record.dr_prediction.predicted_grade.label if record.dr_prediction else 'Suppressed'}")
    print(f"GradCAM Layer in Record: {record.gradcam_result.target_layer if record.gradcam_result else 'None'}")
    print("[PASS] Pipeline Router OK")

    print("\nALL UPGRADE TESTS PASSED SUCCESSFULLY!")

if __name__ == "__main__":
    run_tests()
