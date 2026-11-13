"""Unit tests for Bilateral and Multi-Field Patient Screening Session Aggregator."""
import cv2
import numpy as np
import pytest

from src.clinical_risk.schema import PatientClinicalProfile
from src.pipeline.patient_session import (
    EyeCapture,
    EyeLaterality,
    PatientScreeningSession,
    PatientSessionResult,
    RetinalField,
)
from src.pipeline.schema import DRGrade, HumanReviewType, QualityGrade
from src.synthetic_fixtures import create_synthetic_fundus_image


@pytest.fixture
def session_runner():
    return PatientScreeningSession()


def test_bilateral_clean_session(session_runner):
    """Bilateral images with clean retinas yield Grade 0 patient triage."""
    od = create_synthetic_fundus_image()
    os_img = create_synthetic_fundus_image()

    res = session_runner.process_bilateral_session(
        patient_id="P_CLEAN",
        od_image=od,
        os_image=os_img,
    )

    assert isinstance(res, PatientSessionResult)
    assert res.patient_id == "P_CLEAN"
    assert res.od_record is not None
    assert res.os_record is not None
    assert not res.interocular_asymmetry_detected
    assert not res.csme_detected_any_eye


def test_worst_eye_max_pooling_triage(session_runner):
    """Patient triage reflects the worst eye across bilateral captures."""
    od = create_synthetic_fundus_image()
    os_img = create_synthetic_fundus_image()

    # Router processes both. We verify worst eye logic by testing session calculation
    res = session_runner.process_bilateral_session(
        patient_id="P_MAX_POOL",
        od_image=od,
        os_image=os_img,
    )

    # Patient triage grade should match the maximum of OD and OS
    od_grade = res.od_record.dr_prediction.predicted_grade.value if res.od_record.dr_prediction else 0
    os_grade = res.os_record.dr_prediction.predicted_grade.value if res.os_record.dr_prediction else 0
    expected_val = max(od_grade, os_grade)

    assert res.patient_dr_grade.value == expected_val


def test_interocular_asymmetry_alert():
    """Simulated discordance between eyes (OD Grade 0 vs OS Grade 3) triggers asymmetry alert."""
    from unittest.mock import MagicMock
    from src.pipeline.schema import DRClassificationResult, ScreeningRecord

    session = PatientScreeningSession()

    def mock_record(grade_val: int) -> ScreeningRecord:
        pred = DRClassificationResult(
            predicted_grade=DRGrade(grade_val),
            probabilities=[0.2] * 5,
            confidence=0.88,
            top2_margin=0.40,
            is_referable=grade_val >= 2,
            raw_score=float(grade_val),
        )
        return ScreeningRecord(
            image_path="test.jpg",
            quality_grade=QualityGrade.GOOD,
            quality_status="Reliable",
            dr_prediction=pred,
            reassessment_outcome=None,
        )

    # Directly mock router outputs to test asymmetry logic isolatedly
    session.router.process_image = MagicMock(side_effect=[mock_record(0), mock_record(3)])

    res = session.process_bilateral_session(
        patient_id="P_ASYMMETRY",
        od_image=np.zeros((100, 100, 3), dtype=np.uint8),
        os_image=np.zeros((100, 100, 3), dtype=np.uint8),
    )

    assert res.interocular_asymmetry_detected
    assert res.asymmetry_narrative is not None
    assert "Significant inter-ocular asymmetry detected" in res.asymmetry_narrative
    assert res.human_review_required
    assert res.human_review_type == HumanReviewType.CLINICAL_LEVEL


def test_bilateral_csme_escalation(session_runner):
    """Presence of CSME in either eye forces urgent patient-level referral."""
    od = create_synthetic_fundus_image()
    os_img = create_synthetic_fundus_image()

    # Introduce hard exudate near fovea in Left Eye (OS)
    structs = session_runner.csme_engine.segmenter.segment_structures(os_img)
    fx, fy = structs.fovea_center
    dd_px = 2.0 * structs.optic_disc_radius
    cv2.circle(os_img, (int(fx + 0.3 * dd_px), fy), 6, (255, 255, 120), -1)

    res = session_runner.process_bilateral_session(
        patient_id="P_CSME",
        od_image=od,
        os_image=os_img,
    )

    assert res.csme_detected_any_eye
    assert res.is_referable
    assert "URGENT OPHTHALMOLOGY REFERRAL" in res.overall_action_plan


def test_bayesian_prior_coupling_in_session(session_runner):
    """Providing high systemic metabolic burden couples with patient session."""
    od = create_synthetic_fundus_image()
    os_img = create_synthetic_fundus_image()

    high_risk_profile = PatientClinicalProfile(
        patient_id="P_SYS",
        age=67,
        gender="Male",
        bmi=31.0,
        family_history_diabetes=True,
        physical_activity="Sedentary",
        known_diabetes_years=16.0,
        hba1c_pct=9.6,
    )

    res = session_runner.process_bilateral_session(
        patient_id="P_SYS",
        od_image=od,
        os_image=os_img,
        clinical_profile=high_risk_profile,
    )

    assert res.coupled_risk is not None
    summary_text = res.format_session_summary()
    assert "Systemic Prior" in summary_text
    assert "HIGH" in summary_text
