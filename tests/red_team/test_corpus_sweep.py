"""
Corpus sweep: EVERY scan test case in the repo must fail closed.

Invariant under test (the Phase-1 promise):

    An input that is not a retinal photograph never produces a DR
    (diabetic-retinopathy) prediction anywhere in the pipeline — no grade,
    no referral flag, no "AI detected" text — and a retinal photograph is
    never mislabelled as non-retinal.

Sources swept:
  * ``test_samples/**`` — tracked corpus, present in every checkout/CI.
  * optional local inputs when present (API upload history, demo app
    images, vendored toolbox samples) — skipped silently when absent.
"""

import glob
import os
import unittest

import numpy as np
from PIL import Image

from src.pipeline.schema import PipelineErrorCode, QualityGrade
from src.pipeline.router import ScreeningPipelineRouter
from src.quality.fundus_gate import build_fundus_gate

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_SAMPLES = os.path.join(_ROOT, "test_samples")
_ADVERSARIAL = os.path.join(_SAMPLES, "03_adversarial_non_fundus")

_OPTIONAL_PATTERNS = (
    "results/api_screenings/**/*_orig.jpg",
    "results/pdf_cache/*.jpg",
    "flutter_app/assets/images/*.*",
    "external/fundus_image_toolbox/**/*.jpg",
    "external/fundus_image_toolbox/**/*.png",
)
_IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def _is_image(path: str) -> bool:
    return (
        os.path.splitext(path)[1].lower() in _IMG_EXT
        and "__MACOSX" not in path
        and os.path.isfile(path)
    )


def scan_test_cases() -> list[str]:
    """All scan inputs visible in this checkout, tracked corpus first."""
    found = glob.glob(os.path.join(_SAMPLES, "**", "*"), recursive=True)
    for pattern in _OPTIONAL_PATTERNS:
        found += glob.glob(os.path.join(_ROOT, pattern), recursive=True)
    return sorted({os.path.normpath(p) for p in found if _is_image(p)})


class TestCorpusNeverYieldsPredictionForNonRetina(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gate = build_fundus_gate()
        cls.router = ScreeningPipelineRouter()
        cls.images = scan_test_cases()
        cls.verdicts = {}
        for path in cls.images:
            arr = np.asarray(Image.open(path).convert("RGB"))
            cls.verdicts[path] = cls.gate.evaluate(arr)

    def test_corpus_is_not_empty(self):
        self.assertTrue(self.images, "no scan test cases discovered")
        self.assertGreaterEqual(
            len([p for p in self.images if _ADVERSARIAL in p]),
            10,
            "adversarial folder is missing fixtures",
        )

    def test_adversarial_folder_contains_only_non_fundus_inputs(self):
        files = sorted(p for p in glob.glob(os.path.join(_ADVERSARIAL, "*")) if _is_image(p))
        self.assertTrue(files, "no fixtures in 03_adversarial_non_fundus")
        for path in files:
            with self.subTest(image=os.path.basename(path)):
                decision = self.verdicts.get(os.path.normpath(path))
                if decision is None:
                    arr = np.asarray(Image.open(path).convert("RGB"))
                    decision = self.gate.evaluate(arr)
                self.assertEqual(
                    decision.verdict.value,
                    "NOT_FUNDUS",
                    f"'{os.path.basename(path)}' is not rejected: {decision.reason}",
                )

    def test_every_non_retinal_input_is_blocked_without_a_dr_prediction(self):
        checked = 0
        for path, decision in self.verdicts.items():
            if decision.verdict.value != "NOT_FUNDUS":
                continue
            with self.subTest(image=os.path.basename(path)):
                checked += 1
                record = self.router.process_image(path)
                self.assertIsNone(
                    record.dr_prediction,
                    f"non-retinal input '{path}' produced a DR prediction",
                )
                self.assertIs(record.error_code, PipelineErrorCode.IMG_NOT_FUNDUS, path)
                self.assertEqual(record.quality_grade, QualityGrade.BAD, path)
                self.assertFalse(record.human_review_required, path)
        self.assertGreater(checked, 0, "no non-retinal inputs found to verify")

    def test_retinal_inputs_are_never_rejected_by_the_domain_gate(self):
        # Full pipeline runs only on the tracked corpus; optional local dirs
        # (vendored toolbox, API upload history) are gate-checked above.
        retinal = [
            p for p, d in self.verdicts.items() if d.verdict.value == "FUNDUS" and _SAMPLES in p
        ]
        self.assertTrue(retinal, "no fundus images discovered")
        for path in retinal:
            with self.subTest(image=os.path.basename(path)):
                record = self.router.process_image(path)
                self.assertIsNot(
                    record.error_code,
                    PipelineErrorCode.IMG_NOT_FUNDUS,
                    f"retinal image '{path}' was called non-fundus",
                )


if __name__ == "__main__":
    unittest.main()
