"""Unit tests for the advisory OOD detector (src/quality/ood.py)."""

import unittest

from src.quality.ood import OOD_FLAG_THRESHOLD, ood_score


class TestOODDetector(unittest.TestCase):
    def test_confident_one_hot_is_not_suspect(self):
        r = ood_score([0.97, 0.01, 0.01, 0.005, 0.005])
        self.assertFalse(r.is_suspect)
        self.assertLess(r.ood_score, 0.2)
        self.assertEqual(r.signals, [])

    def test_uniform_distribution_is_suspect(self):
        r = ood_score([0.2, 0.2, 0.2, 0.2, 0.2])
        self.assertTrue(r.is_suspect)
        self.assertGreaterEqual(r.ood_score, OOD_FLAG_THRESHOLD)
        self.assertTrue(any("entropy" in s for s in r.signals))

    def test_score_monotonic_in_flatness(self):
        peaked = ood_score([0.9, 0.04, 0.03, 0.02, 0.01]).ood_score
        flat = ood_score([0.3, 0.25, 0.2, 0.15, 0.1]).ood_score
        self.assertLess(peaked, flat)

    def test_out_of_envelope_brightness_adds_signal(self):
        ok = ood_score([0.9, 0.04, 0.03, 0.02, 0.01], brightness=120.0)
        dark = ood_score([0.9, 0.04, 0.03, 0.02, 0.01], brightness=3.0)
        self.assertGreater(dark.ood_score, ok.ood_score)
        self.assertTrue(any("brightness" in s for s in dark.signals))

    def test_out_of_envelope_contrast_adds_signal(self):
        flat_img = ood_score([0.9, 0.04, 0.03, 0.02, 0.01], contrast=0.5)
        self.assertTrue(any("contrast" in s for s in flat_img.signals))

    def test_renormalizes_unnormalized_input(self):
        r = ood_score([97.0, 1.0, 1.0, 0.5, 0.5])
        self.assertFalse(r.is_suspect)

    def test_rejects_wrong_length(self):
        with self.assertRaises(ValueError):
            ood_score([0.5, 0.5])

    def test_rejects_zero_sum(self):
        with self.assertRaises(ValueError):
            ood_score([0.0, 0.0, 0.0, 0.0, 0.0])

    def test_rejects_nan(self):
        with self.assertRaises(ValueError):
            ood_score([0.5, 0.5, float("nan"), 0.0, 0.0])

    def test_rejects_negative(self):
        with self.assertRaises(ValueError):
            ood_score([1.2, -0.2, 0.0, 0.0, 0.0])

    def test_rejects_nonfinite_stat(self):
        with self.assertRaises(ValueError):
            ood_score([0.9, 0.04, 0.03, 0.02, 0.01], brightness=float("inf"))


if __name__ == "__main__":
    unittest.main()
