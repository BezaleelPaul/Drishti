"""Bayesian Prior Coupling: Combines Upstream Clinical Risk with Retinal DR Triage.

Integrates systemic risk factors (Duration of Diabetes, HbA1c, Blood Pressure, BMI)
with the local ocular DR score to prevent under-referral in high-risk patients.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from src.clinical_risk.schema import PatientClinicalProfile, RiskLevel

# Alias for backward and forward clinical compatibility
DiabetesRiskLevel = RiskLevel
from src.pipeline.schema import DRClassificationResult, DRGrade


class CombinedCarePath(str, Enum):
    ROUTINE_ANNUAL = "ROUTINE_ANNUAL"
    ACCELERATED_PRIMARY_CARE = "ACCELERATED_PRIMARY_CARE"
    OPHTHALMOLOGY_REFERRAL = "OPHTHALMOLOGY_REFERRAL"
    URGENT_TELE_REVIEW = "URGENT_TELE_REVIEW"


@dataclass
class CoupledAssessmentResult:
    retinal_grade: DRGrade
    retinal_score: float | None
    systemic_risk_level: DiabetesRiskLevel
    adjusted_referral_threshold: float
    is_referable_coupled: bool
    recommended_pathway: CombinedCarePath
    recommended_screening_interval_months: int
    clinical_narrative: str


class BayesianRiskCouplingService:
    """Couples upstream systemic diabetes indicators with ocular classification."""

    DEFAULT_REFERABLE_CUTOFF = 1.50

    def couple(
        self,
        retinal_result: DRClassificationResult,
        clinical_profile: PatientClinicalProfile | None = None,
        upstream_risk_level: DiabetesRiskLevel | None = None,
    ) -> CoupledAssessmentResult:
        # Determine systemic risk tier
        if clinical_profile is not None:
            sys_risk = self._compute_profile_risk(clinical_profile)
        elif upstream_risk_level is not None:
            sys_risk = upstream_risk_level
        else:
            sys_risk = DiabetesRiskLevel.MODERATE

        # Compute dynamic threshold adjustment (Bayesian prior)
        # High systemic risk lowers the threshold to trigger early referral
        threshold_delta = 0.0
        if sys_risk == RiskLevel.HIGH:
            threshold_delta = 0.20  # Lowers cutoff from 1.50 -> 1.30
        elif sys_risk == RiskLevel.MODERATE:
            threshold_delta = 0.05  # Slight adjustment 1.50 -> 1.45

        adj_cutoff = self.DEFAULT_REFERABLE_CUTOFF - threshold_delta
        score = retinal_result.raw_score if retinal_result.raw_score is not None else float(retinal_result.predicted_grade.value)
        coupled_referable = score >= adj_cutoff or retinal_result.predicted_grade.value >= 2

        # Care pathway derivation
        grade_val = retinal_result.predicted_grade.value
        if coupled_referable:
            care_path = CombinedCarePath.OPHTHALMOLOGY_REFERRAL
            interval = 1  # 1 month for specialist review
            narrative = (
                f"Referable retinopathy indicated (Score: {score:.2f} >= Adjusted Cutoff: {adj_cutoff:.2f}). "
                f"Patient systemic risk is {sys_risk.value}. Fast-track ophthalmic referral advised."
            )
        elif grade_val == 1:
            if sys_risk == RiskLevel.HIGH:
                care_path = CombinedCarePath.ACCELERATED_PRIMARY_CARE
                interval = 3  # Accelerated 3-month follow-up due to high glycemic/duration burden
                narrative = (
                    f"Mild NPDR detected with elevated systemic metabolic risk ({sys_risk.value}). "
                    "Accelerated 3-month rescreening and intensive glycemic/BP control recommended."
                )
            else:
                care_path = CombinedCarePath.ACCELERATED_PRIMARY_CARE
                interval = 6
                narrative = (
                    f"Mild NPDR detected with manageable systemic risk ({sys_risk.value}). "
                    "6-month follow-up recommended."
                )
        else:
            if sys_risk == RiskLevel.HIGH:
                care_path = CombinedCarePath.ACCELERATED_PRIMARY_CARE
                interval = 6  # High risk patient rescreens in 6 months even with clear retina
                narrative = (
                    f"No retinopathy apparent today, but high systemic risk profile ({sys_risk.value}) "
                    "warrants shorter 6-month screening cycle."
                )
            else:
                care_path = CombinedCarePath.ROUTINE_ANNUAL
                interval = 12
                narrative = "No DR detected. Routine annual screening recommended."

        return CoupledAssessmentResult(
            retinal_grade=retinal_result.predicted_grade,
            retinal_score=score,
            systemic_risk_level=sys_risk,
            adjusted_referral_threshold=adj_cutoff,
            is_referable_coupled=coupled_referable,
            recommended_pathway=care_path,
            recommended_screening_interval_months=interval,
            clinical_narrative=narrative,
        )

    def _compute_profile_risk(self, profile: PatientClinicalProfile) -> RiskLevel:
        high_burden = 0
        known_yrs = getattr(profile, "known_diabetes_years", None) or getattr(profile, "years_with_diabetes", None)
        if known_yrs is not None and known_yrs >= 10:
            high_burden += 2
        hba1c = getattr(profile, "hba1c_pct", None) or getattr(profile, "hba1c_percent", None)
        if hba1c is not None and hba1c >= 8.5:
            high_burden += 2
        bp = getattr(profile, "systolic_bp_mmhg", None)
        if bp is not None and bp >= 140:
            high_burden += 1
        bmi = getattr(profile, "bmi", None)
        if bmi is not None and bmi >= 27.5:  # Asian-Indian obese cutoff
            high_burden += 1

        if high_burden >= 2:
            return RiskLevel.HIGH
        if high_burden >= 1:
            return RiskLevel.MODERATE
        return RiskLevel.LOW
