"""Tests for the shared DRDetect contract module and strict-weights mode."""

import unittest

import numpy as np
from PIL import Image

try:
    import cv2  # noqa: F401 - availability check for preprocessing tests

    CV2_AVAILABLE = True
except ImportError:  # pragma: no cover - minimal CI environments
    CV2_AVAILABLE = False

from src.classification.classifier import (
    ClinicalModelUnavailableError,
    DRClassifier,
)
from src.classification.drdetect_contract import (
    INPUT_SIZE,
    REFERABLE_SCORE_CUT,
    THRESHOLDS,
    preprocess_fundus_to_nchw,
)


class TestContractConstants(unittest.TestCase):
    def test_thresholds_are_frozen_contract(self):
        self.assertEqual((0.5, 1.5, 2.5, 3.5), THRESHOLDS)

    def test_referable_cut_matches_thresholds(self):
        self.assertEqual(REFERABLE_SCORE_CUT, THRESHOLDS[1])

    def test_input_size(self):
        self.assertEqual(INPUT_SIZE, 512)


@unittest.skipUnless(CV2_AVAILABLE, "opencv not installed")
class TestContractPreprocess(unittest.TestCase):
    def test_output_shape_dtype_contiguity(self):
        img = np.full((96, 96, 3), 90, dtype=np.uint8)
        img[:, :, 0] += 40  # fundus-like R>G>B ordering
        result = preprocess_fundus_to_nchw(Image.fromarray(img))
        self.assertEqual(result.shape, (1, 3, INPUT_SIZE, INPUT_SIZE))
        self.assertEqual(result.dtype, np.float32)
        self.assertTrue(result.flags["C_CONTIGUOUS"])

    def test_classifier_delegates_to_contract(self):
        img = np.zeros((128, 128, 3), dtype=np.uint8)
        img[:, :, 0] = 180
        img[:, :, 1] = 90
        img[:, :, 2] = 30
        pil_img = Image.fromarray(img)
        classifier = DRClassifier()
        from_classifier = classifier._preprocess_for_drdetect(pil_img)
        from_contract = preprocess_fundus_to_nchw(pil_img)
        np.testing.assert_array_equal(from_classifier, from_contract)


class TestStrictRealWeights(unittest.TestCase):
    _MISSING = "Z:/definitely/not/a/real/model"
    _MISSING_KERAS = _MISSING + ".keras"
    _MISSING_TORCH = _MISSING + ".pt"

    def _classifier(self, strict: bool) -> DRClassifier:
        return DRClassifier(
            onnx_model_path=self._MISSING,
            keras_model_path=self._MISSING_KERAS,
            pytorch_model_path=self._MISSING_TORCH,
            strict_real_weights=strict,
        )

    def test_strict_raises_when_no_weights_load(self):
        with self.assertRaisesRegex(ClinicalModelUnavailableError, "No real DR model weights"):
            self._classifier(strict=True)

    def test_lenient_still_falls_back_to_simulated(self):
        classifier = self._classifier(strict=False)
        self.assertEqual(classifier.model_backend, "simulated")


if __name__ == "__main__":
    unittest.main()
