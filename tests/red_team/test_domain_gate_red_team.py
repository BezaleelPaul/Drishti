"""
Red-team: the fundus/domain gate must reject non-retinal photographs.

Every probe here is a photograph a real ASHA worker could plausibly upload
(skin, document, wood, wall, screen) or a corrupted file. The invariant under
test: NONE of them may reach DR classification or emit a headline grade.
"""

import os
import unittest

import numpy as np
from PIL import Image

from src.pipeline.schema import PipelineErrorCode, QualityGrade, QualityReason
from src.quality.checker import ImageQualityChecker
from src.quality.fundus_gate import (
    FundusVerdict,
    HeuristicFundusGate,
    LegacyColorFundusGate,
    build_fundus_gate,
)
from src.synthetic_fixtures import create_synthetic_fundus_image

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_REAL_FUNDUS_DIR = os.path.join(_REPO_ROOT, "test_samples", "01_real_clinical_fundus")
_NON_FUNDUS_DIR = os.path.join(_REPO_ROOT, "test_samples", "03_adversarial_non_fundus")


def _noise(shape, mean, spread, seed):
    rng = np.random.RandomState(seed)
    base = np.full(shape, mean, dtype=np.float32)
    return np.clip(base + rng.normal(0.0, spread, shape), 0, 255).astype(np.uint8)


def _flat(shape, rgb):
    img = np.zeros(shape, dtype=np.uint8)
    img[:] = rgb
    return img


def _document(shape, seed):
    img = _noise(shape, 245.0, 6.0, seed)
    h, w, _ = img.shape
    for i in range(int(h * 0.15), int(h * 0.9), max(6, h // 16)):
        img[i : i + max(2, h // 64), int(w * 0.12) : int(w * 0.88)] = (20, 20, 20)
    return img


def non_fundus_probes(size=(240, 240)) -> dict[str, np.ndarray]:
    """Deterministic stand-ins for the non-retinal images the gate must reject."""
    h, w = size
    return {
        "face_selfie": _noise((h, w, 3), (190.0, 140.0, 110.0), 10.0, 1),
        "face_low_light": _noise((h, w, 3), (110.0, 80.0, 65.0), 8.0, 2),
        "paper_document": _document((h, w, 3), 3),
        "wood_desk": _noise((h, w, 3), (160.0, 110.0, 60.0), 14.0, 4),
        "paint_wall": _noise((h, w, 3), (150.0, 155.0, 150.0), 9.0, 5),
        "phone_screen": _noise((h, w, 3), (40.0, 60.0, 160.0), 12.0, 6),
        "blank_white": _flat((h, w, 3), (255, 255, 255)),
        "blank_black": _flat((h, w, 3), (0, 0, 0)),
        "blank_blue": _flat((h, w, 3), (10, 40, 220)),
        "corrupt_no_variance": np.tile(np.array([[[128, 128, 128]]], dtype=np.uint8), (h, w, 1)),
    }


class TestDomainGateRejectsNonFundus(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.checker = ImageQualityChecker()
        cls.gate = cls.checker.fundus_gate
        cls.probes = non_fundus_probes()

    def test_default_provider_is_the_heuristic_gate(self):
        self.assertIsInstance(self.gate, HeuristicFundusGate)

    def test_every_non_fundus_probe_is_rejected_by_the_gate(self):
        for name, img in self.probes.items():
            with self.subTest(probe=name):
                decision = self.gate.evaluate(img)
                self.assertIs(
                    decision.verdict,
                    FundusVerdict.NOT_FUNDUS,
                    f"gate accepted non-fundus probe '{name}': {decision.reason}",
                )

    def test_every_non_fundus_probe_fails_quality_with_not_fundus_code(self):
        for name, img in self.probes.items():
            with self.subTest(probe=name):
                result = self.checker.assess_image(img)
                self.assertEqual(result.grade, QualityGrade.BAD)
                self.assertIs(result.error_code, PipelineErrorCode.IMG_NOT_FUNDUS)
                self.assertIn(QualityReason.NON_FUNDUS_OR_CORRUPT, result.reasons)

    def test_face_photo_that_once_scored_good_now_leaks_nothing(self):
        """Regression: a selfie previously graded GOOD / No DR with conf 0.74."""
        result = self.checker.assess_image(self.probes["face_selfie"])
        self.assertIsNotNone(result.error_code)
        self.assertEqual(result.grade, QualityGrade.BAD)


class TestDomainGateNeverBlocksRealFundus(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.checker = ImageQualityChecker()
        cls.gate = cls.checker.fundus_gate

    def test_synthetic_fundus_passes_the_gate(self):
        img = create_synthetic_fundus_image()
        decision = self.gate.evaluate(img)
        self.assertIsNot(
            decision.verdict,
            FundusVerdict.NOT_FUNDUS,
            f"synthetic fundus rejected: {decision.reason} signals={decision.signals}",
        )

    def test_synthetic_fundus_still_grades_good(self):
        result = self.checker.assess_image(create_synthetic_fundus_image())
        self.assertEqual(result.grade, QualityGrade.GOOD)
        self.assertIsNone(result.error_code)

    @unittest.skipUnless(
        os.path.isdir(_REAL_FUNDUS_DIR) and os.listdir(_REAL_FUNDUS_DIR),
        "real clinical corpus not present in this checkout",
    )
    def test_real_clinical_corpus_is_never_classified_as_non_fundus(self):
        for name in sorted(os.listdir(_REAL_FUNDUS_DIR)):
            if os.path.splitext(name)[1].lower() not in {".jpg", ".jpeg", ".png"}:
                continue
            with self.subTest(image=name):
                path = os.path.join(_REAL_FUNDUS_DIR, name)
                arr = np.asarray(Image.open(path).convert("RGB"))
                decision = self.gate.evaluate(arr)
                self.assertIsNot(
                    decision.verdict,
                    FundusVerdict.NOT_FUNDUS,
                    f"real fundus image '{name}' was rejected: {decision.reason}",
                )

    def test_dark_fundus_defers_instead_of_being_called_non_fundus(self):
        """Near-black retinal capture must fail on illumination, not domain."""
        dark = create_synthetic_fundus_image(brightness_shift=-250.0)
        decision = self.gate.evaluate(dark)
        self.assertIsNot(decision.verdict, FundusVerdict.NOT_FUNDUS)

        result = self.checker.assess_image(dark)
        self.assertEqual(result.grade, QualityGrade.BAD)
        self.assertIn(QualityReason.INADEQUATE_ILLUMINATION, result.reasons)
        self.assertNotIn(
            QualityReason.NON_FUNDUS_OR_CORRUPT,
            result.reasons,
            "dark fundus was mislabelled as non-fundus",
        )


class TestRealWorldPhotographs(unittest.TestCase):
    """Real photographs downloaded into the corpus (see ATTRIBUTION.md):
    faces, a receipt, a desk, a landscape, a desktop screenshot."""

    @classmethod
    def setUpClass(cls):
        cls.checker = ImageQualityChecker()
        cls.gate = cls.checker.fundus_gate
        cls.photos = (
            sorted(
                name
                for name in os.listdir(_NON_FUNDUS_DIR)
                if name.startswith("external_")
                and os.path.splitext(name)[1].lower() in {".jpg", ".jpeg", ".png"}
            )
            if os.path.isdir(_NON_FUNDUS_DIR)
            else []
        )

    @unittest.skipUnless(os.path.isdir(_NON_FUNDUS_DIR), "external corpus not present")
    def test_external_non_fundus_photos_are_rejected(self):
        self.assertTrue(self.photos, "no external_* photos in corpus")
        for name in self.photos:
            with self.subTest(image=name):
                path = os.path.join(_NON_FUNDUS_DIR, name)
                arr = np.asarray(Image.open(path).convert("RGB"))
                decision = self.gate.evaluate(arr)
                self.assertIs(
                    decision.verdict,
                    FundusVerdict.NOT_FUNDUS,
                    f"'{name}' passed the domain gate: {decision.reason}",
                )

    @unittest.skipUnless(os.path.isdir(_NON_FUNDUS_DIR), "external corpus not present")
    def test_external_non_fundus_photos_never_reach_the_classifier(self):
        self.assertTrue(self.photos, "no external_* photos in corpus")
        for name in self.photos:
            with self.subTest(image=name):
                path = os.path.join(_NON_FUNDUS_DIR, name)
                arr = np.asarray(Image.open(path).convert("RGB"))
                result = self.checker.assess_image(arr)
                self.assertEqual(result.grade, QualityGrade.BAD, name)
                self.assertIs(result.error_code, PipelineErrorCode.IMG_NOT_FUNDUS, name)

    @unittest.skipUnless(os.path.isdir(_REAL_FUNDUS_DIR), "real corpus not present")
    def test_external_fundus_photos_are_never_domain_rejected(self):
        """Regression: a real clinical fundus was rejected on hue-band mismatch."""
        names = [n for n in sorted(os.listdir(_REAL_FUNDUS_DIR)) if n.startswith("external_")]
        self.assertTrue(names, "no external_* fundus images in corpus")
        for name in names:
            with self.subTest(image=name):
                path = os.path.join(_REAL_FUNDUS_DIR, name)
                arr = np.asarray(Image.open(path).convert("RGB"))
                result = self.checker.assess_image(arr)
                self.assertIsNot(
                    result.error_code,
                    PipelineErrorCode.IMG_NOT_FUNDUS,
                    f"'{name}' mislabelled as non-fundus: {result.reasons}",
                )


class TestFundusGateProviders(unittest.TestCase):
    def test_registry_builds_every_documented_provider(self):
        self.assertIsInstance(build_fundus_gate("heuristic"), HeuristicFundusGate)
        self.assertIsInstance(build_fundus_gate("legacy"), LegacyColorFundusGate)
        off = build_fundus_gate("off")
        self.assertIs(off.evaluate(np.zeros((8, 8, 3))).verdict, FundusVerdict.FUNDUS)

    def test_unknown_provider_fails_loudly(self):
        with self.assertRaises(ValueError):
            build_fundus_gate("deep-learning-v9")

    def test_legacy_provider_keeps_original_blank_and_color_rejection(self):
        legacy = build_fundus_gate("legacy")
        self.assertIs(
            legacy.evaluate(non_fundus_probes()["blank_blue"]).verdict,
            FundusVerdict.NOT_FUNDUS,
        )
        self.assertIs(
            legacy.evaluate(non_fundus_probes()["blank_white"]).verdict,
            FundusVerdict.NOT_FUNDUS,
        )

    def test_gate_signals_are_exported_for_client_debugging(self):
        decision = build_fundus_gate().evaluate(create_synthetic_fundus_image())
        for key in ("ring_dark_frac", "orange_band_frac", "red_blue_ratio"):
            self.assertIn(key, decision.signals)


if __name__ == "__main__":
    unittest.main()
