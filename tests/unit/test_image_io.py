"""Tests for the shared image-loading contract (src/image_io.py).

Every pipeline stage funnels input through ``to_rgb_uint8``; these tests
pin the scale/clip/fail-closed/copy semantics that make stage results
consistent.
"""

import unittest

import numpy as np

from src.image_io import (
    MAX_IMAGE_DIM,
    RETINAL_BG_THRESHOLD,
    retinal_mask,
    rgb_to_gray,
    to_rgb_uint8,
)


class TestToRgbUint8(unittest.TestCase):
    def test_float_01_scale_saturates_not_truncates(self):
        img = np.full((4, 4, 3), 0.5, dtype=np.float32)
        out = to_rgb_uint8(img)
        self.assertEqual(out.dtype, np.uint8)
        self.assertEqual(int(out[0, 0, 0]), 127)

    def test_float_255_range_passes_through_clipped(self):
        img = np.full((4, 4, 3), 300.0, dtype=np.float32)
        out = to_rgb_uint8(img)
        self.assertEqual(int(out[0, 0, 0]), 255)

    def test_float_hot_pixel_outliers_saturate(self):
        img = np.zeros((8, 8, 3), dtype=np.float32)
        img[0, 0] = 1.0  # 1/192 pixels above 1.0 -> outlier path
        out = to_rgb_uint8(img)
        self.assertEqual(int(out[0, 0, 0]), 255)
        self.assertEqual(int(out[1, 1, 1]), 0)

    def test_nan_fails_closed(self):
        img = np.zeros((4, 4, 3), dtype=np.float32)
        img[2, 2, 1] = np.nan
        with self.assertRaisesRegex(ValueError, "NaN"):
            to_rgb_uint8(img)

    def test_integer_clip_not_wrap(self):
        img = np.full((4, 4, 3), 2**40, dtype=np.int64)
        out = to_rgb_uint8(img)
        self.assertEqual(int(out[0, 0, 0]), 255)

    def test_bool_mask_becomes_binary_white(self):
        mask = np.zeros((4, 4), dtype=bool)
        mask[0, 0] = True
        out = to_rgb_uint8(mask)
        self.assertEqual(int(out[0, 0, 0]), 255)
        self.assertEqual(int(out[1, 1, 2]), 0)

    def test_grayscale_expands_to_3_channels(self):
        img = np.full((4, 4), 90, dtype=np.uint8)
        out = to_rgb_uint8(img)
        self.assertEqual(out.shape, (4, 4, 3))
        self.assertTrue((out[:, :, 0] == out[:, :, 2]).all())

    def test_rgba_drops_alpha(self):
        img = np.zeros((4, 4, 4), dtype=np.uint8)
        img[:, :, 3] = 200  # alpha must be discarded, not blended
        out = to_rgb_uint8(img)
        self.assertEqual(out.shape, (4, 4, 3))

    def test_unsupported_shapes_fail_closed(self):
        for bad in (np.zeros(5), np.zeros((2, 2, 5)), np.zeros((2, 2, 2, 2))):
            with self.subTest(shape=bad.shape), self.assertRaises(ValueError):
                to_rgb_uint8(bad)

    def test_empty_and_oversize_fail_closed(self):
        with self.assertRaises(ValueError):
            to_rgb_uint8(np.zeros((0, 0, 3)))
        with self.assertRaisesRegex(ValueError, "dimensions"):
            to_rgb_uint8(np.zeros((MAX_IMAGE_DIM + 1, 10, 3), dtype=np.uint8))

    def test_non_array_type_rejected(self):
        with self.assertRaises(TypeError):
            to_rgb_uint8("not-an-image")

    def test_canonical_input_is_copied_not_aliased(self):
        img = np.full((4, 4, 3), 100, dtype=np.uint8)
        out = to_rgb_uint8(img)
        self.assertFalse(np.shares_memory(out, img))
        out[:] = 0
        self.assertEqual(int(img[0, 0, 0]), 100)


class TestSharedMasks(unittest.TestCase):
    def test_retinal_mask_threshold(self):
        gray = np.array([RETINAL_BG_THRESHOLD, RETINAL_BG_THRESHOLD + 1])
        mask = retinal_mask(gray)
        self.assertEqual(mask.tolist(), [False, True])

    def test_rgb_to_gray_matches_luma_weights(self):
        px = np.array([[[100, 150, 200]]], dtype=np.float32)
        luma = rgb_to_gray(px)
        self.assertAlmostEqual(float(luma[0, 0]), 0.299 * 100 + 0.587 * 150 + 0.114 * 200, places=4)


if __name__ == "__main__":
    unittest.main()
