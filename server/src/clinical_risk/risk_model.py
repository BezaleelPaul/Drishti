from __future__ import annotations

import logging
import math
import os

logger = logging.getLogger(__name__)

from src.clinical_risk.schema import (
    DiabetesRiskAssessment,
    DiabetesStatus,
    PatientClinicalProfile,
    RiskLevel,
    ScreeningPathway,
)

try:
    import joblib
    HAS_JOBLIB = True
except ImportError:
    HAS_JOBLIB = False


class DiabetesRiskModel:
    """
    Upstream Diabetes Risk Assessment Engine (Layer 1 & 2).
    Evaluates clinical and lifestyle parameters using a trained Random Forest ML model
    calibrated to population epidemiological surveys, with clinical biomarker checks.
    
    Clinical Guardrail:
    'AI does not diagnose diabetes from symptoms alone. High-risk patients are
     directed toward laboratory testing (HbA1c/FPG) for physician confirmation.'
    """

    def __init__(self, model_path: str | None = None):
        self.model_path = model_path or os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "diabetes_ml_model.joblib"
        )
        self.ml_model = None
        self.feature_cols = []
        self.importances = {}
        self._load_ml_model()

    def _load_ml_model(self):
        if HAS_JOBLIB and os.path.exists(self.model_path):
            try:
                payload = joblib.load(self.model_path)
                self.ml_model = payload["model"]
                self.feature_cols = payload.get("feature_cols", [])
                self.importances = payload.get("importances", {})
            except Exception:  # noqa: BLE001 - heuristic risk fallback is intentional
                self.ml_model = None

    def evaluate(self, profile: PatientClinicalProfile) -> DiabetesRiskAssessment:
        rationale: list[str] = []
        # Work on a copy: clamping below must never mutate the caller's object
        # (keeps evaluate() idempotent and side-effect free).
        import dataclasses as _dc
        profile = _dc.replace(profile)

        # 0. Input validation / clamping (defensive: never crash on negative inputs).
        # Non-numeric values are treated as missing (scored 0 with rationale),
        # never TypeError. Missing numerics score 0 but say so explicitly.
        def _num(name: str, val):
            if val is None:
                rationale.append(f"{name} not provided; scored as 0 (missing data).")
                return 0
            try:
                v = float(val)
            except (TypeError, ValueError):
                rationale.append(f"Invalid {name} ({val!r}); scored as 0 (missing data).")
                return 0
            if not math.isfinite(v):
                rationale.append(f"Invalid {name} ({val!r}); scored as 0 (missing data).")
                return 0
            if v < 0:
                rationale.append(f"Invalid negative {name} ({v}) clamped to 0 for risk estimation.")
                return 0.0
            return v

        def _num_or_none(name: str, val):
            """Like _num but preserves None (for optional biomarkers / duration)."""
            if val is None:
                return None
            try:
                v = float(val)
            except (TypeError, ValueError):
                rationale.append(f"Invalid {name} ({val!r}); ignored (missing data).")
                return None
            if not math.isfinite(v):
                rationale.append(f"Invalid {name} ({val!r}); ignored (missing data).")
                return None
            return v

        profile.age = _num("Age", profile.age)
        profile.bmi = _num("BMI", profile.bmi)
        profile.hba1c_pct = _num_or_none("HbA1c", profile.hba1c_pct)
        if profile.hba1c_pct is not None and profile.hba1c_pct > 20.0:
            rationale.append(f"HbA1c {profile.hba1c_pct:.1f}% outside physiological range (>20%); clamped to 20%.")
            profile.hba1c_pct = 20.0
        profile.fasting_glucose_mg_dl = _num_or_none("Fasting glucose", profile.fasting_glucose_mg_dl)
        if profile.fasting_glucose_mg_dl is not None and profile.fasting_glucose_mg_dl > 600.0:
            rationale.append(
                f"Fasting glucose {profile.fasting_glucose_mg_dl:.0f} mg/dL outside physiological range (>600); clamped."
            )
            profile.fasting_glucose_mg_dl = 600.0
        profile.random_glucose_mg_dl = _num_or_none("Random glucose", profile.random_glucose_mg_dl)
        if profile.random_glucose_mg_dl is not None and profile.random_glucose_mg_dl > 800.0:
            rationale.append(
                f"Random glucose {profile.random_glucose_mg_dl:.0f} mg/dL outside physiological range (>800); clamped."
            )
            profile.random_glucose_mg_dl = 800.0
        profile.known_diabetes_years = _num_or_none("Diabetes duration", profile.known_diabetes_years)
        if profile.known_diabetes_years is not None and profile.known_diabetes_years < 0:
            rationale.append(
                f"Invalid negative diabetes duration ({profile.known_diabetes_years}) ignored; "
                "treating as no confirmed history."
            )
            profile.known_diabetes_years = None

        # 1. Check for already confirmed diabetes diagnosis
        # Note: 0 years means no confirmed history (falls through to risk estimation);
        # negative values are invalid and treated as None path (handled above).
        if profile.known_diabetes_years is not None and profile.known_diabetes_years > 0:
            rationale.append(f"Confirmed history of diabetes ({profile.known_diabetes_years:.1f} years duration).")
            return DiabetesRiskAssessment(
                risk_level=RiskLevel.HIGH,
                risk_score=100.0,
                diabetes_status=DiabetesStatus.CONFIRMED_DIABETES,
                pathway=ScreeningPathway.RETINAL_SCREENING_INDICATED,
                clinical_rationale=rationale,
                action_recommendation=(
                    "Proceed immediately to AI-assisted retinal screening for diabetic retinopathy triage."
                ),
                risk_source="clinical_rule",
            )

        # 2. Laboratory Biomarker Verification (Physician Diagnostic Criteria)
        if profile.hba1c_pct is not None and profile.hba1c_pct >= 6.5:
            rationale.append(f"Diagnostic HbA1c level: {profile.hba1c_pct:.1f}% (>= 6.5% diagnostic of diabetes).")
            return DiabetesRiskAssessment(
                risk_level=RiskLevel.HIGH,
                risk_score=98.0,
                diabetes_status=DiabetesStatus.CONFIRMED_DIABETES,
                pathway=ScreeningPathway.RETINAL_SCREENING_INDICATED,
                clinical_rationale=rationale,
                action_recommendation=(
                    "HbA1c indicates diabetes. Proceed to retinal fundus screening and physician consult."
                ),
                risk_source="clinical_rule",
            )

        if profile.fasting_glucose_mg_dl is not None and profile.fasting_glucose_mg_dl >= 126.0:
            rationale.append(f"Fasting glucose: {profile.fasting_glucose_mg_dl:.0f} mg/dL (>= 126 mg/dL).")
            return DiabetesRiskAssessment(
                risk_level=RiskLevel.HIGH,
                risk_score=98.0,
                diabetes_status=DiabetesStatus.CONFIRMED_DIABETES,
                pathway=ScreeningPathway.RETINAL_SCREENING_INDICATED,
                clinical_rationale=rationale,
                action_recommendation=(
                    "Fasting blood glucose diagnostic of diabetes. Proceed to retinal screening and physician consult."
                ),
                risk_source="clinical_rule",
            )

        if profile.random_glucose_mg_dl is not None and profile.random_glucose_mg_dl >= 200.0:
            rationale.append(
                f"Random glucose: {profile.random_glucose_mg_dl:.0f} mg/dL (>= 200 mg/dL diagnostic of diabetes)."
            )
            return DiabetesRiskAssessment(
                risk_level=RiskLevel.HIGH,
                risk_score=98.0,
                diabetes_status=DiabetesStatus.CONFIRMED_DIABETES,
                pathway=ScreeningPathway.RETINAL_SCREENING_INDICATED,
                clinical_rationale=rationale,
                action_recommendation=(
                    "Random blood glucose diagnostic of diabetes. Proceed to retinal screening and physician consult."
                ),
                risk_source="clinical_rule",
            )

        # 3. Machine Learning Risk Prediction (Random Forest)
        # None-safe, whitespace/case-insensitive activity check.
        is_sedentary = 1 if (profile.physical_activity or "").strip().lower() == "sedentary" else 0
        # None-safe, case-insensitive symptoms normalization ("none"/"" entries ignored).
        syms = profile.symptoms or []
        syms_norm = [str(s).strip().lower() for s in syms]
        symptom_cnt = len([s for s in syms_norm if s and s != "none"])

        # None-safe numeric defaults for scoring (clamped above; None -> 0).
        age_val = profile.age if profile.age is not None else 0
        bmi_val = profile.bmi if profile.bmi is not None else 0

        def _heuristic_score() -> float:
            s = 0.0
            if age_val >= 50:
                s += 28
            elif age_val >= 35:
                s += 18
            if bmi_val >= 27.5:
                s += 25
            elif bmi_val >= 23.0:
                s += 15
            if profile.family_history_diabetes:
                s += 20
            if is_sedentary:
                s += 15
            s += min(symptom_cnt * 6.0, 18.0)
            return min(s, 100.0)

        risk_source = 'ml'
        if self.ml_model is not None:
            try:
                import pandas as pd
            except ImportError:
                logger.warning("pandas not available; falling back to heuristic diabetes risk estimate.")
                rationale.append("ML library (pandas) unavailable; using heuristic fallback risk estimate.")
                score = _heuristic_score()
                risk_source = 'heuristic'
            else:
                try:
                    features = pd.DataFrame([[
                        age_val,
                        bmi_val,
                        1 if profile.family_history_diabetes else 0,
                        is_sedentary,
                        symptom_cnt,
                    ]], columns=self.feature_cols)

                    # Validate feature count against the trained model's expectation.
                    expected_n = getattr(self.ml_model, "n_features_in_", None)
                    if expected_n is not None and features.shape[1] != expected_n:
                        raise ValueError(
                            f"Feature count mismatch: model expects {expected_n} features "
                            f"(configured columns: {self.feature_cols}), "
                            f"but got {features.shape[1]} columns from profile data."
                        )

                    # Get calibrated probability of diabetes risk from ML model
                    ml_prob = float(self.ml_model.predict_proba(features)[0, 1])
                    score = round(ml_prob * 100.0, 1)
                    rationale.append(f"Random Forest ML risk probability: {ml_prob:.1%}")
                except Exception as exc:  # noqa: BLE001 - invalid ML output uses rules
                    logger.warning("ML prediction failed (%s); falling back to heuristic estimate.", exc)
                    rationale.append(
                        "ML prediction unavailable; using heuristic fallback risk estimate."
                    )
                    score = _heuristic_score()
                    risk_source = 'heuristic'
        else:
            logger.warning("ML model not loaded; using heuristic diabetes risk estimate.")
            # Fallback heuristic calculation if model file not available
            score = _heuristic_score()
            risk_source = 'heuristic'

        # Explain top patient contributors
        if age_val >= 45:
            rationale.append(f"Age {age_val} (elevated age-related vulnerability)")
        if bmi_val >= 25.0:
            rationale.append(f"BMI {bmi_val:.1f} kg/m² (metabolic adiposity factor)")
        if profile.family_history_diabetes:
            rationale.append("Genetic/family predisposition reported")
        if symptom_cnt > 0:
            rationale.append(f"{symptom_cnt} symptom(s) identified ({', '.join(str(s) for s in syms)})")

        # Biomarker adjustments for impaired glycemia. Independent (not elif):
        # a patient with BOTH impaired HbA1c and impaired fasting glucose must
        # never score LOWER than a patient with only one of them.
        # Pre-diabetes HbA1c (5.7-6.4%) elevates to MODERATE tier, not HIGH.
        if profile.hba1c_pct is not None and profile.hba1c_pct >= 5.7:
            score = max(score, 35.0)
            rationale.append(
                f"Impaired HbA1c ({profile.hba1c_pct:.1f}%) in pre-diabetes range; "
                "elevated risk to moderate tier."
            )
        # Fasting glucose is tiered like HbA1c: impaired (100-125) -> MODERATE.
        # (Diabetes-range values already returned as CONFIRMED above.)
        if profile.fasting_glucose_mg_dl is not None and profile.fasting_glucose_mg_dl >= 100.0:
            score = max(score, 35.0)
            rationale.append(
                f"Impaired fasting glucose ({profile.fasting_glucose_mg_dl:.0f} mg/dL) "
                "in pre-diabetes range; elevated risk to moderate tier."
            )

        # Clinical Triage Boundaries
        if score >= 55.0:
            return DiabetesRiskAssessment(
                risk_level=RiskLevel.HIGH,
                risk_score=score,
                diabetes_status=DiabetesStatus.UNKNOWN,
                pathway=ScreeningPathway.CLINICAL_TESTING_REQUIRED,
                clinical_rationale=rationale,
                action_recommendation=(
                    "Elevated diabetes risk. Recommend formal clinical laboratory testing "
                    "(Fasting Plasma Glucose and HbA1c) for physician diagnosis. "
                    "If confirmed, patient must enroll in annual retinal screening."
                ),
                risk_source=risk_source,
            )
        elif score >= 30.0:
            return DiabetesRiskAssessment(
                risk_level=RiskLevel.MODERATE,
                risk_score=score,
                diabetes_status=DiabetesStatus.UNKNOWN,
                pathway=ScreeningPathway.CLINICAL_TESTING_REQUIRED,
                clinical_rationale=rationale,
                action_recommendation=(
                    "Moderate diabetes risk. Recommend routine screening glucose check "
                    "and lifestyle counseling at primary healthcare centre."
                ),
                risk_source=risk_source,
            )
        else:
            return DiabetesRiskAssessment(
                risk_level=RiskLevel.LOW,
                risk_score=score,
                diabetes_status=DiabetesStatus.NO_DIABETES,
                pathway=ScreeningPathway.LIFESTYLE_PREVENTION,
                clinical_rationale=rationale,
                action_recommendation=(
                    "Low risk. Encourage healthy diet, active lifestyle, and routine re-evaluation every 3 years."
                ),
                risk_source=risk_source,
            )
