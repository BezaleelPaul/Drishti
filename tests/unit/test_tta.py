"""Tests for TTA ensemble + honest ordinal uncertainty in the DRDetect path."""

import os
import unittest
import unittest.mock
from types import SimpleNamespace

import numpy as np

try:
    import cv2  # noqa: F401 - availability check for the fake-session path

    CV2_AVAILABLE = True
except ImportError:  # pragma: no cover - minimal CI environments
    CV2_AVAILABLE = False

from src.classification.classifier import DRClassifier
from src.classification.ordinal import (
    BASE_SIGMA,
    decode_grade,
    probabilities_from_score,
    uncertainty_from_scores,
    widened_sigma,
)
from src.classification.tta import (
    DEFAULT_VIEW_COUNT,
    aggregate_scores,
    build_views,
    resolve_view_count,
)

THRESHOLDS = [0.5, 1.5, 2.5, 3.5]


class _FakeSession:
    """Minimal onnxruntime.InferenceSession stand-in with per-view scoring."""

    def __init__(self, score_fn):
        self._score_fn = score_fn
        self.input = SimpleNamespace(name="input")
        self.calls: list[np.ndarray] = []

    def get_inputs(self):
        return [self.input]

    def run(self, _outputs, feeds):
        tensor = feeds[self.input.name]
        self.calls.append(tensor)
        return [np.array([self._score_fn(tensor)], dtype=np.float32)]


class TestResolveViewCount(unittest.TestCase):
    def test_default_is_full_ensemble(self):
        self.assertEqual(resolve_view_count(None), DEFAULT_VIEW_COUNT)

    def test_one_disables_tta(self):
        for raw in (1, "1", "0", -3):
            with self.subTest(raw=raw):
                self.assertEqual(resolve_view_count(raw), 1)

    def test_four_builds_ensemble(self):
        self.assertEqual(resolve_view_count(4), 4)

    def test_invalid_values_fall_back_to_ensemble(self):
        for raw in ("abc", "4x"):
            with self.subTest(raw=raw):
                self.assertEqual(resolve_view_count(raw), DEFAULT_VIEW_COUNT)


class TestBuildViews(unittest.TestCase):
    def setUp(self):
        self.tensor = np.arange(48, dtype=np.float32).reshape(1, 3, 4, 4)
        self.original = self.tensor.copy()

    def test_single_view_is_passthrough(self):
        views = build_views(self.tensor, 1)
        self.assertEqual(len(views), 1)
        np.testing.assert_array_equal(views[0], self.original)

    def test_ensemble_preserves_shape_and_input(self):
        views = build_views(self.tensor, 4)
        self.assertEqual(len(views), 4)
        for view in views:
            self.assertEqual(view.shape, self.original.shape)
        self.assertTrue(all(v.flags["C_CONTIGUOUS"] for v in views))
        np.testing.assert_array_equal(self.tensor, self.original)

    def test_flips_match_numpy_semantics(self):
        views = build_views(self.tensor, 4)
        np.testing.assert_array_equal(views[1], np.flip(self.original, axis=3))
        np.testing.assert_array_equal(views[2], np.flip(self.original, axis=2))
        np.testing.assert_array_equal(views[3], np.flip(np.flip(self.original, axis=2), axis=3))

    def test_rejects_bad_shape_and_unknown_count(self):
        for bad_shape, count, expected in (
            ((3, 4, 4), 4, "4 dims"),
            ((1, 3, 4, 4), 3, "Unsupported TTA view count"),
        ):
            with (
                self.subTest(shape=bad_shape, count=count),
                self.assertRaisesRegex(ValueError, expected),
            ):
                build_views(np.zeros(bad_shape), count)


class TestAggregateScores(unittest.TestCase):
    def test_pairwise_statistics(self):
        report = aggregate_scores([2.0, 2.4])
        self.assertAlmostEqual(report.mean_score, 2.2)
        self.assertAlmostEqual(report.spread, 0.2, places=5)
        self.assertEqual(report.n_views, 2)
        self.assertEqual(report.scores, (2.0, 2.4))

    def test_single_view_has_zero_spread(self):
        report = aggregate_scores([1.9])
        self.assertEqual(report.n_views, 1)
        self.assertEqual(report.spread, 0.0)
        self.assertEqual(report.mean_score, 1.9)

    def test_rejects_empty_and_nonfinite(self):
        with self.assertRaises(ValueError):
            aggregate_scores([])
        with self.assertRaises(ValueError):
            aggregate_scores([1.0, float("nan")])


class TestOrdinalHelpers(unittest.TestCase):
    def test_decode_grade_strict_thresholds(self):
        cases = [(1.499, 1), (1.5, 1), (1.501, 2), (2.6, 3), (-1.0, 0), (99.0, 4)]
        for score, expected in cases:
            with self.subTest(score=score):
                self.assertEqual(decode_grade(score, THRESHOLDS), expected)

    def test_probabilities_normalization_and_ordering(self):
        probs = probabilities_from_score(2.4, BASE_SIGMA)
        self.assertAlmostEqual(sum(probs), 1.0, places=9)
        self.assertGreater(probs[2], 0)
        self.assertTrue(all(p >= 0 for p in probs))

    def test_widened_sigma_reduces_top1_confidence(self):
        center = 2.4
        legacy = probabilities_from_score(center, BASE_SIGMA)
        widened = probabilities_from_score(center, widened_sigma(0.5))
        self.assertEqual(widened_sigma(0.0), BASE_SIGMA)
        self.assertGreater(max(legacy), max(widened))

    def test_widened_sigma_rejects_invalid_spread(self):
        for bad in (-0.1, float("nan")):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                widened_sigma(bad)

    def test_uncertainty_matches_legacy_when_spread_zero(self):
        score = 2.4
        dist = min(abs(score - th) for th in THRESHOLDS)
        self.assertAlmostEqual(
            uncertainty_from_scores(score, THRESHOLDS, spread=0.0),
            float(np.exp(-dist)),
        )

    def test_uncertainty_grows_with_disagreement(self):
        score = 2.0  # far from boundaries: boundary signal (exp(-0.5) ~ 0.61)
        low = uncertainty_from_scores(score, THRESHOLDS, spread=0.05)
        high = uncertainty_from_scores(score, THRESHOLDS, spread=0.5)
        self.assertGreater(high, low)
        self.assertLessEqual(high, 1.0)

    def test_uncertainty_takes_max_of_signals(self):
        # At the boundary, spread=0.5 cannot exceed the boundary signal.
        self.assertAlmostEqual(uncertainty_from_scores(2.4, THRESHOLDS, spread=0.5), np.exp(-0.1))


@unittest.skipUnless(CV2_AVAILABLE, "opencv not installed")
class TestDRDetectTTAPath(unittest.TestCase):
    def setUp(self):
        os.environ["DRISHTI_TTA_VIEWS"] = "4"
        self.addCleanup(os.environ.pop, "DRISHTI_TTA_VIEWS", None)

    def _make_classifier(self, score_fn) -> DRClassifier:
        classifier = DRClassifier()
        classifier.model_backend = "onnx_drdetect"
        classifier._onnx_session = _FakeSession(score_fn)
        return classifier

    @staticmethod
    def _img(left_value: float, right_value: float) -> np.ndarray:
        img = np.zeros((64, 64, 3), dtype=np.uint8)
        img[:, :32, :] = int(left_value)
        img[:, 32:, :] = int(right_value)
        # Beta R>G>B fundus ordering preserved on both halves
        img[:, :, 0] += 30
        return img

    def test_symmetric_image_runs_all_views_with_zero_spread(self):
        counter = {"n": 0}

        def score_fn(tensor):
            counter["n"] += 1
            return 2.6

        classifier = self._make_classifier(score_fn)
        result = classifier.predict(self._img(150, 150))
        self.assertEqual(counter["n"], 4)
        self.assertEqual(len(classifier._onnx_session.calls), 4)
        self.assertEqual(result.predicted_grade.value, 3)
        self.assertAlmostEqual(result.raw_score, 2.6, places=6)
        # Zero spread -> sigma must equal the legacy fixed kernel width
        self.assertAlmostEqual(result.confidence, max(probabilities_from_score(2.6, BASE_SIGMA)))
        self.assertAlmostEqual(result.uncertainty, float(np.exp(-abs(2.6 - 2.5))), places=6)

    def test_asymmetric_views_raise_uncertainty_and_widen_probs(self):
        def score_fn(tensor):
            direction = float(np.mean(tensor))
            return 2.0 + 3.0 * (direction + 1.0)  # per-view variation

        classifier = self._make_classifier(score_fn)
        result = classifier.predict(self._img(200, 60))
        self.assertGreater(result.uncertainty, 0.0)
        self.assertTrue(0.0 <= result.uncertainty <= 1.0)
        self.assertAlmostEqual(sum(result.probabilities), 1.0, places=6)
        self.assertTrue(0.0 <= result.confidence <= 1.0)
        self.assertGreaterEqual(result.top2_margin, 0.0)

    def test_tta_disabled_runs_single_view_with_legacy_decoding(self):
        os.environ["DRISHTI_TTA_VIEWS"] = "1"
        counter = {"n": 0}

        def score_fn(_tensor):
            counter["n"] += 1
            return 2.6

        classifier = self._make_classifier(score_fn)
        self.assertEqual(classifier.tta_views, 1)
        result = classifier.predict(self._img(120, 120))
        self.assertEqual(counter["n"], 1)
        self.assertAlmostEqual(result.raw_score, 2.6, places=6)
        self.assertEqual(result.predicted_grade.value, 3)
        self.assertAlmostEqual(result.confidence, max(probabilities_from_score(2.6)), places=6)


if __name__ == "__main__":
    unittest.main()
