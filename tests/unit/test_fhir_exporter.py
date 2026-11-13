"""Tests for the FHIR R4 exporter's clinical-safety semantics.

Covers the ungradable-capture rules: no false disease coding, absent
biomarker observations, and LOINC/SNOMED structure for gradable captures.
"""

import unittest

from src.pipeline.schema import (
    DRClassificationResult,
    DRGrade,
    QualityGrade,
    ScreeningRecord,
)
from src.reporting.fhir_exporter import (
    _safe_float,
    _safe_int,
    export_abdm_fhir_diagnostic_report,
)


def _gradable_record(grade: DRGrade = DRGrade.MODERATE_NPDR) -> ScreeningRecord:
    pred = DRClassificationResult(
        predicted_grade=grade,
        probabilities=[0.05, 0.10, 0.60, 0.15, 0.10],
        confidence=0.60,
        top2_margin=0.45,
        is_referable=grade.is_referable,
    )
    return ScreeningRecord(
        image_path="test.jpg",
        quality_grade=QualityGrade.GOOD,
        quality_status="Reliable",
        dr_prediction=pred,
    )


def _biomarkers() -> dict:
    return {
        "microaneurysm_count": 7,
        "vessel_density_pct": 41.5,
        "csme_risk": "MODERATE",
        "min_fovea_distance_px": 1200,
    }


class TestFhirExporter(unittest.TestCase):
    def test_gradable_report_structure_and_codes(self):
        report = export_abdm_fhir_diagnostic_report(
            patient_data={"patient_id": "ARV-2026-0842", "age": 54},
            screening_record=_gradable_record(),
            biomarkers=_biomarkers(),
        )
        self.assertEqual(report["resourceType"], "DiagnosticReport")
        self.assertEqual(report["status"], "final")
        loinc = [c["code"] for c in report["code"]["coding"]]
        self.assertIn("81219-8", loinc)
        conclusion = report["conclusion"]
        self.assertIn("Moderate NPDR", conclusion)
        self.assertIn("Referable DR: Yes", conclusion)
        contained_ids = {obs["id"] for obs in report["contained"]}
        self.assertEqual(
            contained_ids,
            {
                "obs-dr-grade",
                "obs-ai-confidence",
                "obs-microaneurysms",
                "obs-vessel-density",
                "obs-csme-risk",
            },
        )
        conf_obs = next(o for o in report["contained"] if o["id"] == "obs-ai-confidence")
        self.assertAlmostEqual(conf_obs["valueQuantity"]["value"], 60.0)
        ma_obs = next(o for o in report["contained"] if o["id"] == "obs-microaneurysms")
        self.assertEqual(ma_obs["valueInteger"], 7)

    def test_ungradable_never_asserts_disease(self):
        # Screening record without a DR prediction must produce NullFlavor UNK
        # coding, empty conclusionCode, and dataAbsentReason biomarkers —
        # never a false "no DR" certification.
        record = ScreeningRecord(
            image_path="bad.jpg",
            quality_grade=QualityGrade.BAD,
            quality_status="Unreliable",
        )
        report = export_abdm_fhir_diagnostic_report(
            patient_data={"patient_id": "X"},
            screening_record=record,
            biomarkers={"csme_risk": "UNGRADABLE"},
        )
        self.assertEqual(report["conclusionCode"], [])
        dr_obs = next(o for o in report["contained"] if o["id"] == "obs-dr-grade")
        self.assertIn("v3-NullFlavor", dr_obs["valueCodeableConcept"]["coding"][0]["system"])
        self.assertEqual(dr_obs["valueCodeableConcept"]["coding"][0]["code"], "UNK")
        for obs_id in ("obs-microaneurysms", "obs-vessel-density", "obs-csme-risk"):
            obs = next(o for o in report["contained"] if o["id"] == obs_id)
            self.assertIn("dataAbsentReason", obs)
        self.assertIn("not assessed", report["conclusion"])

    def test_patient_id_sanitized_for_fhir_id(self):
        report = export_abdm_fhir_diagnostic_report(
            patient_data={"patient_id": "bad id/with*chars!"},
            screening_record=_gradable_record(),
            biomarkers=_biomarkers(),
        )
        reference = report["subject"]["reference"]
        self.assertTrue(reference.startswith("Patient/"))
        tail = reference.split("/", 1)[1]
        for ch in tail:
            self.assertRegex(ch, r"[A-Za-z0-9\-\.]")

    def test_unsafe_ids_fall_back_to_generated(self):
        report = export_abdm_fhir_diagnostic_report(
            patient_data={"patient_id": "***"},
            screening_record=_gradable_record(),
            biomarkers=_biomarkers(),
        )
        self.assertTrue(report["subject"]["reference"].startswith("Patient/patient-"))

    def test_safe_coercion_helpers(self):
        self.assertEqual(_safe_int("12"), 12)
        self.assertEqual(_safe_int(None, 3), 3)
        self.assertEqual(_safe_int("abc", 5), 5)
        self.assertAlmostEqual(_safe_float("1.5"), 1.5)
        self.assertAlmostEqual(_safe_float(None, 0.5), 0.5)
        self.assertAlmostEqual(_safe_float("nope", 0.25), 0.25)


if __name__ == "__main__":
    unittest.main()
