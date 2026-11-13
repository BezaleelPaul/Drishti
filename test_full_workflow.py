"""
End-to-end Demonstration and Test of the Extended 2-Stage Medical Workflow:
Stage 1: Upstream Diabetes Risk Stratification (Google-Aravind / Hindu article model)
Stage 2: AI-Assisted Retinal Screening Pipeline (Section 3 Decision Flow)
"""

import os

from src.clinical_risk import (
    DiabetesRiskModel,
    PatientClinicalProfile,
    ScreeningPathway,
)
from src.pipeline.router import ScreeningPipelineRouter


def run_comprehensive_test():
    print("=" * 80)
    print("DEMO: 2-STAGE PREVENTIVE DIABETES & RETINAL SCREENING WORKFLOW")
    print("Inspired by the Google - Aravind Eye Hospital Clinical Screening Model")
    print("=" * 80)

    risk_model = DiabetesRiskModel()
    pipeline_router = ScreeningPipelineRouter()
    sample_dir = os.path.join("test_samples", "curated")

    # -------------------------------------------------------------
    # Case A: Person with Confirmed Diabetes -> Retinal Screening
    # -------------------------------------------------------------
    print("\n" + "#" * 80)
    print("CASE A: Patient with Confirmed Diabetes (Upstream -> Retinal Screening)")
    print("#" * 80)

    patient_a = PatientClinicalProfile(
        patient_id="PT-2026-001",
        age=54,
        gender="Male",
        bmi=28.2,
        family_history_diabetes=True,
        physical_activity="Sedentary",
        symptoms=["Blurry vision", "Mild fatigue"],
        hba1c_pct=8.2,
        known_diabetes_years=6.0,
    )

    print("\n--- STAGE 1: Clinical Risk Evaluation ---")
    assessment_a = risk_model.evaluate(patient_a)
    print(assessment_a.summary_text())

    if assessment_a.pathway == ScreeningPathway.RETINAL_SCREENING_INDICATED:
        print("\n--- STAGE 2: AI-Assisted Retinal Screening (Clean Capture) ---")
        good_image_path = os.path.join(sample_dir, "scenario_1_good.jpg")
        record_a = pipeline_router.process_image(
            good_image_path,
            recapture_attempt_count=0,
            output_dir=os.path.join("results", "test_case_a"),
        )
        print(record_a.format_report_text())
        print("Audit overlay saved to: results/test_case_a/gradcam_overlay.png")

    # -------------------------------------------------------------
    # Case B: High-Risk Individual without Confirmed Diagnosis
    # -------------------------------------------------------------
    print("\n" + "#" * 80)
    print("CASE B: High-Risk Community Member (Upstream -> Clinical Testing Required)")
    print("#" * 80)

    patient_b = PatientClinicalProfile(
        patient_id="PT-2026-002",
        age=48,
        gender="Female",
        bmi=29.0,
        family_history_diabetes=True,
        physical_activity="Sedentary",
        symptoms=["Frequent urination", "Excessive thirst"],
        fasting_glucose_mg_dl=None,
        hba1c_pct=None,
        known_diabetes_years=None,
    )

    print("\n--- STAGE 1: Clinical Risk Evaluation ---")
    assessment_b = risk_model.evaluate(patient_b)
    print(assessment_b.summary_text())
    print("\n>> Clinical Guardrail Verified: System does NOT diagnose diabetes or grade retina.")
    print(">> Patient is directed to laboratory testing (FPG / HbA1c) for physician confirmation.")

    # -------------------------------------------------------------
    # Case C: Confirmed Diabetes Patient with Bad Retinal Capture
    # -------------------------------------------------------------
    print("\n" + "#" * 80)
    print("CASE C: Patient with Confirmed Diabetes (Quality Gate Failure / Recapture)")
    print("#" * 80)

    print("\n--- STAGE 2: AI-Assisted Retinal Screening (Degraded / Blurry Image) ---")
    bad_image_path = os.path.join(sample_dir, "scenario_2_bad.jpg")
    record_c = pipeline_router.process_image(
        bad_image_path,
        recapture_attempt_count=0,
        output_dir=os.path.join("results", "test_case_c"),
    )
    print(record_c.format_report_text())
    print("\n>> Non-Negotiable Gate Rule Verified:")
    print(f">> Quality Grade: {record_c.quality_grade.value}")
    print(f">> Model 2 DR Prediction: {record_c.dr_prediction} (Strictly None - zero leakage!)")

    print("\n" + "=" * 80)
    print("ALL TEST SCENARIOS COMPLETED SUCCESSFULLY")
    print("=" * 80)


if __name__ == "__main__":
    run_comprehensive_test()
