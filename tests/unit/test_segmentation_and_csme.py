import os
import sys
import unittest

import numpy as np

# Ensure project root in sys.path
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from src.pipeline.router import ScreeningPipelineRouter
from src.quality.checker import ImageQualityChecker
from src.segmentation.structure_segmenter import RetinalStructureSegmenter


class TestSegmentationAndCSME(unittest.TestCase):
    def setUp(self):
        self.segmenter = RetinalStructureSegmenter(use_dl_toolbox=False)
        self.checker = ImageQualityChecker()
        self.router = ScreeningPipelineRouter()

    def test_csme_exudate_without_microaneurysms(self):
        """ETDRS compliance: Exudates near fovea with 0 MAs MUST trigger HIGH CSME risk.

        Injects a near-fovea exudate mask at the detector boundary so the
        assertion exercises the real CSME decision rule in segment_structures.
        """
        img = np.zeros((512, 512, 3), dtype=np.uint8)
        img[50:460, 50:460] = [180, 70, 30]
        probe = self.segmenter.segment_structures(img)
        fx, fy = int(probe.fovea_center[0]), int(probe.fovea_center[1])

        exudate_mask = np.zeros((512, 512), dtype=np.uint8)
        exudate_mask[max(0, fy - 3):fy + 4, max(0, fx - 3):fx + 4] = 255

        original = self.segmenter._segment_exudates
        self.segmenter._segment_exudates = lambda *a, **k: exudate_mask
        try:
            res = self.segmenter.segment_structures(img)
        finally:
            self.segmenter._segment_exudates = original

        self.assertEqual(len(res.microaneurysm_candidates), 0)
        self.assertTrue(res.csme_risk.startswith("HIGH"), res.csme_risk)
        self.assertIsNotNone(res.min_fovea_distance_px)
        self.assertLess(res.min_fovea_distance_px, 10.0)

    def test_dynamic_contour_mask_nonzero(self):
        """Verifies in-place mutation bug fix in _extract_dynamic_retinal_mask."""
        img = np.zeros((400, 400, 3), dtype=np.uint8)
        y, x = np.ogrid[:400, :400]
        circle = ((x - 200)**2 + (y - 200)**2) <= 150**2
        img[circle] = [180, 80, 20]
        
        mask, fov_ratio = self.checker._extract_dynamic_retinal_mask(img)
        self.assertTrue(np.any(mask))
        self.assertGreater(fov_ratio, 0.10)

if __name__ == '__main__':
    unittest.main()
