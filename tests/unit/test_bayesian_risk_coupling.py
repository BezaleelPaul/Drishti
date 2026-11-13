"""Unit tests for Bayesian Prior Coupling Service."""
import pytest

from src.clinical_risk.schema import PatientClinicalProfile, RiskLevel
from src.pipeline.schema import DRClassificationResult, DRGrade
from src.services.bayesian_risk_coupling import (
    BayesianRiskCouplingService,
    CombinedCarePath,
    CoupledAssessmentResult,
)


@pytest.fixture
def bayesian_service():
    return BayesianRiskCouplingService()


def make_retinal_result(grade: DRGrade, score: float | None = None) -> DRClassificationResult:
    return DRClassificationResult(
        predicted_grade=grade,
        probabilities=[0.2] * 5,
        confidence=0.85,
        top2_margin=0.30,
        is_referable=grade.is_referable,
        raw_score=score if score is not None else float(grade.value),
    )


def test_clean_retina_low_systemic_risk_recommends_routine_annual(bayesian_service):
    """Grade 0 with low systemic risk keeps routine 12-month rescreening."""
    profile = PatientClinicalProfile(
        patient_id="P_LOW",
        age=35,
        gender="Female",
        bmi=22.0,
        family_history_diabetes=False,
        physical_activity="Vigorous",
        fasting_glucose_mg_dl=90.0,
        known_diabetes_years=1.0,
        hba1c_pct=5.4,
    )
    ret_res = make_retinal_result(DRGrade.NO_DR, score=0.1)
    coupled = bayesian_service.couple(ret_res, clinical_profile=profile)

    assert isinstance(coupled, CoupledAssessmentResult)
    assert coupled.systemic_risk_level == RiskLevel.LOW
    assert not coupled.is_referable_coupled
    assert coupled.recommended_pathway == CombinedCarePath.ROUTINE_ANNUAL
    assert coupled.recommended_screening_interval_months == 12


def test_clean_retina_high_systemic_risk_accelerates_primary_care(bayesian_service):
    """Grade 0 with high glycemic/duration burden shortens interval to 6 months."""
    profile = PatientClinicalProfile(
        patient_id="P_HIGH",
        age=62,
        gender="Male",
        bmi=29.0,
        family_history_diabetes=True,
        physical_activity="Sedentary",
        known_diabetes_years=14.0,
        hba1c_pct=9.5,
    )
    ret_res = make_retinal_result(DRGrade.NO_DR, score=0.2)
    coupled = bayesian_service.couple(ret_res, clinical_profile=profile)

    assert coupled.systemic_risk_level == RiskLevel.HIGH
    assert not coupled.is_referable_coupled
    assert coupled.recommended_pathway == CombinedCarePath.ACCELERATED_PRIMARY_CARE
    assert coupled.recommended_screening_interval_months == 6


def test_mild_npdr_high_systemic_risk_accelerates_to_three_months(bayesian_service):
    """Grade 1 with high systemic risk requires tight 3-month monitoring."""
    profile = PatientClinicalProfile(
        patient_id="P_MILD_HIGH",
        age=58,
        gender="Female",
        bmi=28.5,
        family_history_diabetes=True,
        physical_activity="Sedentary",
        known_diabetes_years=11.0,
        hba1c_pct=8.8,
    )
    ret_res = make_retinal_result(DRGrade.MILD_NPDR, score=1.1)
    coupled = bayesian_service.couple(ret_res, clinical_profile=profile)

    assert coupled.systemic_risk_level == RiskLevel.HIGH
    assert coupled.recommended_pathway == CombinedCarePath.ACCELERATED_PRIMARY_CARE
    assert coupled.recommended_screening_interval_months == 3
    assert "Accelerated 3-month rescreening" in coupled.clinical_narrative


def test_borderline_retinal_score_escalated_by_high_systemic_burden(bayesian_service):
    """Continuous retinal score 1.35 is below standard 1.50 cutoff, but high systemic burden lowers threshold to 1.30 and triggers referral."""
    profile = PatientClinicalProfile(
        patient_id="P_BORDERLINE",
        age=65,
        gender="Male",
        bmi=30.0,
        family_history_diabetes=True,
        physical_activity="Sedentary",
        known_diabetes_years=15.0,
        hba1c_pct=9.8,
    )
    # Model scored 1.38 (classified as Grade 1 under standard 1.5 cutoff)
    ret_res = make_retinal_result(DRGrade.MILD_NPDR, score=1.38)
    coupled = bayesian_service.couple(ret_res, clinical_profile=profile)

    assert coupled.systemic_risk_level == RiskLevel.HIGH
    assert coupled.adjusted_referral_threshold <= 1.30
    assert coupled.is_referable_coupled
    assert coupled.recommended_pathway == CombinedCarePath.OPHTHALMOLOGY_REFERRAL
    assert coupled.recommended_screening_interval_months == 1


def test_severe_dr_triggers_referral_regardless_of_profile(bayesian_service):
    """Grade 3 (Severe NPDR) always triggers urgent ophthalmology referral."""
    ret_res = make_retinal_result(DRGrade.SEVERE_NPDR, score=3.0)
    coupled = bayesian_service.couple(ret_res, upstream_risk_level=RiskLevel.LOW)

    assert coupled.is_referable_coupled
    assert coupled.recommended_pathway == CombinedCarePath.OPHTHALMOLOGY_REFERRAL
    assert coupled.recommended_screening_interval_months == 1
