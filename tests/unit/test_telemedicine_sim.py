"""Tests for the district telemedicine simulation engine.

Verifies bandwidth savings math, staffing invariants, queue-stability
semantics, and the physical-validation fail-closed rules.
"""

import unittest

import pytest

from src.simulation.telemedicine_sim import (
    DistrictSimulationParams,
    TelemedicineSimulinkEngine,
)


def _default_params() -> DistrictSimulationParams:
    return DistrictSimulationParams(annual_target_patients=100_000)


class TestDistrictSimulation(unittest.TestCase):
    def test_default_run_shape_and_invariants(self):
        report = TelemedicineSimulinkEngine(_default_params()).run_simulation()
        self.assertEqual(report.daily_patient_intake, 385)  # ceil(100000/260)
        self.assertEqual(report.daily_flagged_for_review, 62)  # ceil(385 * 0.16)
        self.assertGreater(report.cloud_total_data_uploaded_gb_annual, 0)
        self.assertLess(
            report.edge_total_data_uploaded_gb_annual,
            report.cloud_total_data_uploaded_gb_annual,
        )
        self.assertGreater(report.bandwidth_saved_pct, 95.0)
        self.assertLess(
            report.doctors_needed_with_our_system,
            report.doctors_needed_without_our_system,
        )
        self.assertLess(
            report.avg_turnaround_time_edge_sec,
            report.avg_turnaround_time_cloud_min * 60,
        )
        self.assertEqual(
            report.annual_patients_successfully_screened,
            _default_params().annual_target_patients,
        )

    def test_queue_stable_when_capacity_exceeds_intake(self):
        params = _default_params()
        params.num_tele_ophthalmologists = 10
        params.assisted_review_time_sec = 10.0
        report = TelemedicineSimulinkEngine(params).run_simulation()
        self.assertTrue(report.queue_stable)

    def test_queue_unstable_when_capacity_below_intake(self):
        params = _default_params()
        params.num_tele_ophthalmologists = 1
        params.doctor_work_hours_per_day = 1.0  # cap: 3600s/60s = 60 < 62 flagged/day
        params.assisted_review_time_sec = 60.0
        report = TelemedicineSimulinkEngine(params).run_simulation()
        self.assertFalse(report.queue_stable)

    def test_edge_upload_scales_with_flagged_rate(self):
        params = _default_params()
        params.referable_or_flagged_rate = 0.32
        report = TelemedicineSimulinkEngine(params).run_simulation()
        base = TelemedicineSimulinkEngine(_default_params()).run_simulation()
        self.assertAlmostEqual(
            report.edge_total_data_uploaded_gb_annual,
            base.edge_total_data_uploaded_gb_annual * 2,
            delta=0.3,
        )

    def test_insights_are_generated(self):
        report = TelemedicineSimulinkEngine(_default_params()).run_simulation()
        self.assertTrue(report.summary_insights)
        self.assertTrue(all(isinstance(s, str) for s in report.summary_insights))


@pytest.mark.parametrize(
    "field, value",
    [
        ("working_days_per_year", 0),
        ("annual_target_patients", -5),
        ("assisted_review_time_sec", 0.0),
        ("unassisted_review_time_sec", -1.0),
        ("doctor_work_hours_per_day", 0.0),
        ("num_tele_ophthalmologists", 0),
        ("rural_bandwidth_kbps", 0.0),
        ("quality_rejection_rate", 1.0),
        ("referable_or_flagged_rate", -0.1),
        ("raw_image_size_mb", 0.0),
        ("compressed_dossier_kb", -2.0),
        ("edge_dr_inference_sec", -0.5),
        ("num_phcs", 0),
        ("num_mobile_vans", -1),
    ],
)
def test_unphysical_params_fail_closed(field, value):
    params = DistrictSimulationParams(annual_target_patients=100_000)
    setattr(params, field, value)
    with pytest.raises(ValueError):
        TelemedicineSimulinkEngine(params).run_simulation()
