from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class DiabetesStatus(str, Enum):
    UNKNOWN = "UNKNOWN"
    NO_DIABETES = "NO_DIABETES"
    PRE_DIABETES = "PRE_DIABETES"
    CONFIRMED_DIABETES = "CONFIRMED_DIABETES"


class RiskLevel(str, Enum):
    LOW = "LOW"
    MODERATE = "MODERATE"
    HIGH = "HIGH"


class ScreeningPathway(str, Enum):
    LIFESTYLE_PREVENTION = "LIFESTYLE_PREVENTION"
    CLINICAL_TESTING_REQUIRED = "CLINICAL_TESTING_REQUIRED"
    RETINAL_SCREENING_INDICATED = "RETINAL_SCREENING_INDICATED"


@dataclass
class PatientClinicalProfile:
    patient_id: str
    age: int
    gender: str                           # "Male", "Female", "Other"
    bmi: float                            # kg/m^2
    family_history_diabetes: bool         # Parents/siblings with diabetes
    physical_activity: str                # "Sedentary", "Moderate", "Vigorous"
    symptoms: list[str] = field(default_factory=list) # e.g. ["Polyuria", "Polydipsia", "Blurry Vision"]
    
    # Clinical Biomarkers (if available at camp / clinic)
    fasting_glucose_mg_dl: float | None = None
    random_glucose_mg_dl: float | None = None
    hba1c_pct: float | None = None
    known_diabetes_years: float | None = None


@dataclass
class DiabetesRiskAssessment:
    risk_level: RiskLevel
    risk_score: float                     # 0 - 100 standardized risk index
    diabetes_status: DiabetesStatus
    pathway: ScreeningPathway
    clinical_rationale: list[str] = field(default_factory=list)
    action_recommendation: str = ""
    risk_source: str = "heuristic"           # clinical_rule, ml, or heuristic

    def summary_text(self) -> str:
        s = (
            f"Diabetes Risk Level:  {self.risk_level.value} (Score: {self.risk_score:.0f}/100)\n"
            f"Diabetes Status:      {self.diabetes_status.value}\n"
            f"Recommended Pathway:  {self.pathway.value}\n"
            f"Clinical Action:      {self.action_recommendation}"
        )
        return s
