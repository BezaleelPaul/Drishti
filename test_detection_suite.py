"""
Comprehensive Detection & Clinical Safety Test Suite for Drishti-AI / DRISHTI.
Tests:
1. Certified Clean Fundus: Detection of DR, vessels, optic disc, fovea, and Grad-CAM
2. Quality Defects: Motion blur and severe underexposure fail-closed rejections
3. Adversarial Out-of-Domain: Face portrait, receipt document, and blank surfaces rejected
4. CSME Geometric Engine: ETDRS foveal proximity rings (<0.5 DD vs >1.5 DD)
5. Bayesian Risk Coupling: Upstream systemic risk modulating referral thresholds
6. Bilateral Session Aggregator: Worst-eye rule and inter-ocular asymmetry detection
7. Live FastAPI Bridge: Real HTTP inference on running backend
"""
import json
import os
import sys
import time

import numpy as np
import requests
from PIL import Image

# Ensure project root in sys.path
PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from src.clinical_risk import DiabetesRiskModel, PatientClinicalProfile, RiskLevel
from src.pipeline.patient_session import (
    EyeCapture,
    EyeLaterality,
    PatientScreeningSession,
    PatientSessionResult,
    RetinalField,
)
from src.pipeline.router import ScreeningPipelineRouter
from src.pipeline.schema import DRGrade, QualityGrade
from src.quality.checker import ImageQualityChecker
from src.services.bayesian_risk_coupling import BayesianRiskCouplingService
from src.services.csme_engine import (
    CSMEGeometricEngine,
    CSMERiskLevel,
    ExudateCluster,
)


def run_detection_suite():
    print("=" * 80)
    print("      DRISHTI-AI / DRISHTI: COMPREHENSIVE CLINICAL DETECTION SUITE")
    print("=" * 80)
    router = ScreeningPipelineRouter()
    checker = ImageQualityChecker()
    csme_engine = CSMEGeometricEngine()
    bayesian_service = BayesianRiskCouplingService()
    session_engine = PatientScreeningSession(router=router, bayesian_service=bayesian_service, csme_engine=csme_engine)

    results_matrix = []

    # -------------------------------------------------------------------------
    # TEST 1: Certified Clean Fundus
    # -------------------------------------------------------------------------
    clean_sample = os.path.join(PROJECT_ROOT, "test_samples", "04_section24_demo_scenarios", "scenario_1_good.jpg")
    t0 = time.time()
    rec_clean = router.process_image(clean_sample, enable_csme=True)
    t_clean = time.time() - t0

    t1_pass = (
        rec_clean.quality_grade == QualityGrade.GOOD
        and rec_clean.quality_status.startswith("Reliable")
        and rec_clean.dr_prediction is not None
        and rec_clean.gradcam_result is not None
        and rec_clean.gradcam_result.heatmap_generated is True
    )
    grade_label = rec_clean.dr_prediction.predicted_grade.label if rec_clean.dr_prediction else "None"
    conf_pct = rec_clean.dr_prediction.confidence * 100 if rec_clean.dr_prediction else 0.0

    results_matrix.append({
        "Category": "Fundus Detection",
        "Test Case": "Certified Clean Fundus (scenario_1_good.jpg)",
        "Expected": "Quality Reliable, DR Graded, GradCAM generated",
        "Actual": f"Reliable, {grade_label} (Conf {conf_pct:.1f}%), Heatmap OK",
        "Latency": f"{t_clean*1000:.1f} ms",
        "Passed": t1_pass,
    })
    print(f"[{'PASS' if t1_pass else 'FAIL'}] Test 1 - Clean Fundus: Grade={grade_label}, Quality={rec_clean.quality_grade.value}")

    # -------------------------------------------------------------------------
    # TEST 2: Quality Defect Rejection - Motion Blur
    # -------------------------------------------------------------------------
    blur_sample = os.path.join(PROJECT_ROOT, "test_samples", "02_quality_failures_and_edge_cases", "real_fundus_with_extreme_motion_blur.jpg")
    t0 = time.time()
    rec_blur = router.process_image(blur_sample)
    t_blur = time.time() - t0

    t2_pass = (
        rec_blur.quality_grade in (QualityGrade.BAD, QualityGrade.BORDERLINE)
        and rec_blur.dr_prediction is None
        and any("blur" in str(r).lower() or "sharpness" in str(r).lower() or "focus" in str(r).lower() for r in rec_blur.rejection_reasons)
    )
    results_matrix.append({
        "Category": "Quality Gate",
        "Test Case": "Motion Blur (real_fundus_with_extreme_motion_blur.jpg)",
        "Expected": "Rejected, Zero DR Prediction, Blur Reason Flagged",
        "Actual": f"Grade={rec_blur.quality_grade.value}, DR={rec_blur.dr_prediction}, Reasons={rec_blur.rejection_reasons[:2]}",
        "Latency": f"{t_blur*1000:.1f} ms",
        "Passed": t2_pass,
    })
    print(f"[{'PASS' if t2_pass else 'FAIL'}] Test 2 - Motion Blur: Suppressed DR={rec_blur.dr_prediction is None}, Reasons={rec_blur.rejection_reasons[:1]}")

    # -------------------------------------------------------------------------
    # TEST 3: Quality Defect Rejection - Severe Underexposure
    # -------------------------------------------------------------------------
    dark_sample = os.path.join(PROJECT_ROOT, "test_samples", "02_quality_failures_and_edge_cases", "severely_underexposed_dark.jpg")
    t0 = time.time()
    rec_dark = router.process_image(dark_sample)
    t_dark = time.time() - t0

    t3_pass = (
        rec_dark.quality_grade in (QualityGrade.BAD, QualityGrade.BORDERLINE)
        and rec_dark.dr_prediction is None
        and any("dark" in str(r).lower() or "underexposed" in str(r).lower() or "illumination" in str(r).lower() for r in rec_dark.rejection_reasons)
    )
    results_matrix.append({
        "Category": "Quality Gate",
        "Test Case": "Severely Underexposed (severely_underexposed_dark.jpg)",
        "Expected": "Rejected, Zero DR Prediction, Dark/Illumination Reason Flagged",
        "Actual": f"Grade={rec_dark.quality_grade.value}, DR={rec_dark.dr_prediction}, Reasons={rec_dark.rejection_reasons[:2]}",
        "Latency": f"{t_dark*1000:.1f} ms",
        "Passed": t3_pass,
    })
    print(f"[{'PASS' if t3_pass else 'FAIL'}] Test 3 - Underexposed: Suppressed DR={rec_dark.dr_prediction is None}, Reasons={rec_dark.rejection_reasons[:1]}")

    # -------------------------------------------------------------------------
    # TEST 4: Adversarial Non-Fundus Rejection - Face Portrait
    # -------------------------------------------------------------------------
    face_sample = os.path.join(PROJECT_ROOT, "test_samples", "03_adversarial_non_fundus", "external_face_portrait.jpg")
    t0 = time.time()
    rec_face = router.process_image(face_sample)
    t_face = time.time() - t0

    t4_pass = (
        rec_face.quality_grade == QualityGrade.BAD
        and rec_face.dr_prediction is None
    )
    results_matrix.append({
        "Category": "Adversarial OOD",
        "Test Case": "Human Face Portrait (external_face_portrait.jpg)",
        "Expected": "Fail-closed Quality Rejection, Zero DR Leakage",
        "Actual": f"Quality={rec_face.quality_grade.value}, DR={rec_face.dr_prediction}",
        "Latency": f"{t_face*1000:.1f} ms",
        "Passed": t4_pass,
    })
    print(f"[{'PASS' if t4_pass else 'FAIL'}] Test 4 - Face Portrait Rejection: Quality={rec_face.quality_grade.value}, DR={rec_face.dr_prediction}")

    # -------------------------------------------------------------------------
    # TEST 5: Adversarial Non-Fundus Rejection - Document / Receipt
    # -------------------------------------------------------------------------
    receipt_sample = os.path.join(PROJECT_ROOT, "test_samples", "03_adversarial_non_fundus", "external_receipt_document.jpg")
    t0 = time.time()
    rec_receipt = router.process_image(receipt_sample)
    t_receipt = time.time() - t0

    t5_pass = (
        rec_receipt.quality_grade == QualityGrade.BAD
        and rec_receipt.dr_prediction is None
    )
    results_matrix.append({
        "Category": "Adversarial OOD",
        "Test Case": "Document/Receipt (external_receipt_document.jpg)",
        "Expected": "Fail-closed Quality Rejection, Zero DR Leakage",
        "Actual": f"Quality={rec_receipt.quality_grade.value}, DR={rec_receipt.dr_prediction}",
        "Latency": f"{t_receipt*1000:.1f} ms",
        "Passed": t5_pass,
    })
    print(f"[{'PASS' if t5_pass else 'FAIL'}] Test 5 - Receipt Rejection: Quality={rec_receipt.quality_grade.value}, DR={rec_receipt.dr_prediction}")

    # -------------------------------------------------------------------------
    # TEST 6: CSME Geometric Macular Edema Engine
    # -------------------------------------------------------------------------
    t0 = time.time()
    from src.segmentation.structure_segmenter import RetinalStructuresResult

    # Test high risk: exudates at ~0.16 DD from fovea (< 0.5 DD)
    mask_high = np.zeros((512, 512), dtype=np.uint8)
    mask_high[254:258, 268:272] = 255
    landmarks_high = RetinalStructuresResult(
        optic_disc_center=(100, 256),
        optic_disc_radius=40,
        fovea_center=(256, 256),
        vessel_mask=np.zeros((512, 512), dtype=np.uint8),
        exudate_mask=mask_high,
    )
    res_high_csme = csme_engine.evaluate(np.zeros((512, 512, 3), dtype=np.uint8), landmarks=landmarks_high)

    # Test safe: exudates at ~2.41 DD from fovea (> 1.5 DD)
    mask_safe = np.zeros((512, 512), dtype=np.uint8)
    mask_safe[254:258, 448:452] = 255
    landmarks_safe = RetinalStructuresResult(
        optic_disc_center=(100, 256),
        optic_disc_radius=40,
        fovea_center=(256, 256),
        vessel_mask=np.zeros((512, 512), dtype=np.uint8),
        exudate_mask=mask_safe,
    )
    res_safe_csme = csme_engine.evaluate(np.zeros((512, 512, 3), dtype=np.uint8), landmarks=landmarks_safe)
    t_csme = time.time() - t0

    t6_pass = (
        res_high_csme.risk_level == CSMERiskLevel.HIGH_RISK_URGENT
        and res_high_csme.urgent_referral is True
        and res_safe_csme.risk_level == CSMERiskLevel.MACULAR_SAFE
        and res_safe_csme.urgent_referral is False
    )
    results_matrix.append({
        "Category": "CSME Engine",
        "Test Case": "ETDRS Foveal Rings (0.16 DD vs 2.41 DD)",
        "Expected": "High Risk Urgent (<0.5 DD) & Macular Safe (>1.5 DD)",
        "Actual": f"Near: {res_high_csme.risk_level.value} (Urgent={res_high_csme.urgent_referral}), Distant: {res_safe_csme.risk_level.value}",
        "Latency": f"{t_csme*1000:.1f} ms",
        "Passed": t6_pass,
    })
    print(f"[{'PASS' if t6_pass else 'FAIL'}] Test 6 - CSME ETDRS Geometric Engine: High={res_high_csme.risk_level.value}, Safe={res_safe_csme.risk_level.value}")

    # -------------------------------------------------------------------------
    # TEST 7: Bayesian Prior Systemic Risk Coupling
    # -------------------------------------------------------------------------
    t0 = time.time()
    normal_profile = PatientClinicalProfile(
        patient_id="PT-NORMAL",
        age=32,
        gender="Female",
        bmi=21.5,
        family_history_diabetes=False,
        physical_activity="Moderate",
        hba1c_pct=5.4,
        symptoms=[],
    )
    uncontrolled_profile = PatientClinicalProfile(
        patient_id="PT-UNCONTROLLED",
        age=62,
        gender="Male",
        bmi=34.2,
        family_history_diabetes=True,
        physical_activity="Sedentary",
        hba1c_pct=10.2,
        fasting_glucose_mg_dl=230.0,
        known_diabetes_years=14.0,
        symptoms=["Blurry vision", "Neuropathy"],
    )

    coupled_normal = bayesian_service.couple(rec_clean.dr_prediction, clinical_profile=normal_profile)
    coupled_uncontrolled = bayesian_service.couple(rec_clean.dr_prediction, clinical_profile=uncontrolled_profile)
    t_bayes = time.time() - t0

    t7_pass = (
        coupled_normal.systemic_risk_level == RiskLevel.LOW
        and coupled_uncontrolled.systemic_risk_level == RiskLevel.HIGH
        and coupled_uncontrolled.adjusted_referral_threshold < coupled_normal.adjusted_referral_threshold
    )
    results_matrix.append({
        "Category": "Bayesian Coupling",
        "Test Case": "HbA1c 5.4% (Normal) vs 10.2% (Uncontrolled)",
        "Expected": "Lower referral cutoff on uncontrolled diabetes (1.30 vs 1.50)",
        "Actual": f"Normal cutoff: {coupled_normal.adjusted_referral_threshold:.2f}, Uncontrolled cutoff: {coupled_uncontrolled.adjusted_referral_threshold:.2f}",
        "Latency": f"{t_bayes*1000:.1f} ms",
        "Passed": t7_pass,
    })
    print(f"[{'PASS' if t7_pass else 'FAIL'}] Test 7 - Bayesian Coupling: Cutoff drops from {coupled_normal.adjusted_referral_threshold:.2f} to {coupled_uncontrolled.adjusted_referral_threshold:.2f}")

    # -------------------------------------------------------------------------
    # TEST 8: Bilateral Inter-Ocular Asymmetry Alert & Worst-Eye Rule
    # -------------------------------------------------------------------------
    t0 = time.time()
    normal_od_sample = os.path.join(PROJECT_ROOT, "test_samples", "01_real_clinical_fundus", "external_fundus_right_eye.jpg")
    mod_os_sample = os.path.join(PROJECT_ROOT, "test_samples", "04_section24_demo_scenarios", "scenario_4_uncertain.jpg")

    session_asym = session_engine.process_bilateral_session(
        patient_id="PT-ASYM-002",
        od_image=normal_od_sample,
        os_image=mod_os_sample,
        clinical_profile=normal_profile,
    )
    t_bilateral = time.time() - t0

    t8_pass = (
        session_asym.patient_id == "PT-ASYM-002"
        and session_asym.interocular_asymmetry_detected is True
        and session_asym.patient_dr_grade == DRGrade.MODERATE_NPDR
        and session_asym.human_review_required is True
    )
    results_matrix.append({
        "Category": "Bilateral Session",
        "Test Case": "Inter-Ocular Asymmetry (OD Grade 0 vs OS Grade 2)",
        "Expected": "Asymmetry Flagged, Worst-Eye (Grade 2), Review Required",
        "Actual": f"Asymmetry={session_asym.interocular_asymmetry_detected}, Patient={session_asym.patient_dr_grade.label}, Review={session_asym.human_review_required}",
        "Latency": f"{t_bilateral*1000:.1f} ms",
        "Passed": t8_pass,
    })
    print(f"[{'PASS' if t8_pass else 'FAIL'}] Test 8 - Bilateral Asymmetry: Asymmetry={session_asym.interocular_asymmetry_detected}, PatientGrade={session_asym.patient_dr_grade.label}")

    # -------------------------------------------------------------------------
    # TEST 9: Live FastAPI Endpoint Detection
    # -------------------------------------------------------------------------
    t0 = time.time()
    api_url = "http://127.0.0.1:8000"
    headers = {"X-API-Key": "dev-operator-key"}

    # 9a. Retinal Quality Check
    with open(clean_sample, "rb") as f:
        resp_q = requests.post(f"{api_url}/retinal/quality", files={"file": ("scenario_1_good.jpg", f, "image/jpeg")}, headers=headers, timeout=10)
    q_data = resp_q.json() if resp_q.status_code == 200 else {}

    # 9b. Register test patient
    p_payload = {
        "name": "Validation Patient",
        "age": 58,
        "gender": "Female",
        "phone": "+91 98765 43210",
        "village": "Saswad",
        "screening_centre": "Community Vision Clinic",
        "known_diabetes": "Yes",
    }
    resp_p = requests.post(f"{api_url}/patients", json=p_payload, headers=headers, timeout=10)
    created_pid = resp_p.json()["patient_id"] if resp_p.status_code == 201 else None

    # 9c. Retinal Screening Analysis
    with open(clean_sample, "rb") as f:
        resp_a = requests.post(
            f"{api_url}/retinal/analyze",
            data={"patient_id": created_pid, "eye_side": "Right", "camera_profile": "Generic Fundus Camera"},
            files={"file": ("scenario_1_good.jpg", f, "image/jpeg")},
            headers=headers,
            timeout=15,
        )
    a_data = resp_a.json() if resp_a.status_code == 200 else {}
    t_api = time.time() - t0

    t9_pass = (
        resp_q.status_code == 200
        and q_data.get("quality_grade") == "GOOD"
        and resp_p.status_code == 201
        and resp_a.status_code == 200
        and a_data.get("dr_grade") == 1
        and a_data.get("gradcam_target_layer") is not None
    )

    api_actual = f"Quality: {q_data.get('quality_grade')} (Score {q_data.get('quality_score', 0):.2f}) | DR: Grade {a_data.get('dr_grade')} ({a_data.get('dr_label')}) | CAM: {a_data.get('gradcam_target_layer')}"
    results_matrix.append({
        "Category": "FastAPI Bridge",
        "Test Case": "End-to-End Live Screening (/retinal/quality + /retinal/analyze)",
        "Expected": "Quality 200 (GOOD) + Patient 201 + Analyze 200 (DR Grade 1 & Saliency)",
        "Actual": api_actual,
        "Latency": f"{t_api*1000:.1f} ms",
        "Passed": t9_pass,
    })
    print(f"[{'PASS' if t9_pass else 'FAIL'}] Test 9 - Live FastAPI Screening: {api_actual}")

    print("\n" + "=" * 80)
    all_passed = all(r["Passed"] for r in results_matrix)
    print(f"OVERALL STATUS: {'ALL TESTS PASSED (100% OPERATIONAL)' if all_passed else 'SOME TESTS FAILED'}")
    print("=" * 80)

    print("\n### Markdown Verification Matrix\n")
    print("| # | Subsystem / Category | Test Fixture / Scenario | Detection Expected | Verified Clinical Output | Latency | Status |")
    print("|---|---|---|---|---|---|:---:|")
    for i, r in enumerate(results_matrix, 1):
        status = "PASSED" if r["Passed"] else "FAILED"
        print(f"| {i} | {r['Category']} | {r['Test Case']} | {r['Expected']} | {r['Actual']} | {r['Latency']} | {status} |")
    print("")

    return results_matrix, all_passed


if __name__ == "__main__":
    matrix, ok = run_detection_suite()
    if not ok:
        sys.exit(1)
