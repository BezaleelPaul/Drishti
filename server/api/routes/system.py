from __future__ import annotations

import logging
import os
import shutil
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends

from api.auth import ApiPrincipal, require_auth
from api.database import get_db
from api.schemas import SystemStatusResponse

router = APIRouter(tags=["System Status"])

logger = logging.getLogger(__name__)

_PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# NOTE: no liveness shortcut without auth — /status reports aggregate
# patient/screening counts, which must not be an unauthenticated polling
# oracle. The Flutter badge and test suite both send X-API-Key.
@router.get("/status", response_model=SystemStatusResponse)
def get_system_status(_principal: ApiPrincipal = Depends(require_auth)):
    """Real-time status probed from the database, disk, and model artifacts —
    never hardcoded. A missing artifact degrades (not silently 'Ready')."""
    db_ok = True
    total_patients = total_screenings = pending_reviews = 0
    try:
        with get_db() as conn:
            cursor = conn.cursor()
            cursor.execute("SELECT COUNT(*) as count FROM patients")
            total_patients = cursor.fetchone()["count"]

            cursor.execute("SELECT COUNT(*) as count FROM screenings")
            total_screenings = cursor.fetchone()["count"]

            cursor.execute("SELECT COUNT(*) as count FROM doctor_reviews WHERE status = 'PENDING'")
            pending_reviews = cursor.fetchone()["count"]
    except Exception as e:  # noqa: BLE001 - status endpoint reports degraded state
        db_ok = False
        logger.warning("health DB probe failed: %s", e)

    try:
        disk_free_mb = shutil.disk_usage(_PROJECT_ROOT).free // (1024 * 1024)
    except OSError:
        disk_free_mb = -1

    artifacts = {
        "Model 2 (DR Classifier)": os.path.join(_PROJECT_ROOT, "final_model.keras"),
        "Upstream Risk Engine": os.path.join(
            _PROJECT_ROOT, "src", "clinical_risk", "diabetes_ml_model.joblib"
        ),
    }
    missing = [name for name, path in artifacts.items() if not os.path.isfile(path)]
    runtime_issues = []
    try:
        from api.services.ai_bridge import AIBridge

        classifier_backend = AIBridge.loaded_classifier_backend()
        if classifier_backend is not None and classifier_backend not in ("keras", "pytorch"):
            runtime_issues.append(
                f"Model 2 runtime backend is {classifier_backend}; clinical weights are unavailable"
            )
    except Exception as exc:  # noqa: BLE001 - optional camera probe is best effort
        logger.warning("Model runtime probe failed: %s", exc)
        runtime_issues.append("Model 2 runtime probe failed")

    known_paths = {
        "Model 1 (Quality Gate)": "Deep Ensemble (berenslab/fundus_image_toolbox) + MultiScale Fusion",
        "Model 2 (DR Classifier)": "EfficientNetB0 (APTOS 2019 fine-tuned, 5-class severity)",
        "Explainability Engine": "Grad-CAM++ (Higher-order gradient backpropagation)",
        "Upstream Risk Engine": "Random Forest (Google-Aravind / Indian ICMR guideline calibration)",
    }
    models_info = {
        name: (desc + (" [ARTIFACT MISSING]" if name in missing else ""))
        for name, desc in known_paths.items()
    }
    if runtime_issues:
        models_info["Model 2 (DR Classifier)"] += " [UNAVAILABLE: clinical backend not loaded]"

    if db_ok and not missing and not runtime_issues and disk_free_mb != 0:
        engine = "Ready (Model 1 Quality + Model 2 DR + Grad-CAM++)"
    else:
        causes = []
        if not db_ok:
            causes.append("database unreachable")
        if missing:
            causes.append("missing artifacts: " + ", ".join(missing))
        causes.extend(runtime_issues)
        if disk_free_mb == 0:
            causes.append("disk full")
        engine = "Degraded (" + "; ".join(causes) + ")"

    return SystemStatusResponse(
        ai_engine=engine,
        camera_input="Ready (Generic Fundus Camera / JPG / PNG)",
        network_connectivity=f"Local (offline-first, disk free: {disk_free_mb} MB)",
        pending_doctor_reviews=pending_reviews,
        total_patients_registered=total_patients,
        total_screenings_completed=total_screenings,
        offline_queue_ready=db_ok and disk_free_mb != 0,
        models_loaded=models_info,
        last_sync_time=datetime.now(timezone.utc).strftime("%d %b %Y, %H:%M UTC"),
    )


@router.get("/cameras")
def get_camera_profiles() -> list[dict[str, Any]]:
    """Conceptual camera profiles demonstrating manufacturer-agnostic image compatibility."""
    return [
        {
            "id": "generic",
            "name": "Generic Fundus Camera",
            "manufacturer": "Any Compatible Fundus Device",
            "format": "JPG / PNG",
            "description": "Standard circular fundus photography from any medical device",
            "fov": "30° to 50°",
        },
        {
            "id": "forus_3nethra",
            "name": "Forus 3nethra Classic",
            "manufacturer": "Forus Health (India)",
            "format": "2048 x 1536 JPG",
            "description": "Non-mydriatic portable tabletop camera for Indian rural PHCs",
            "fov": "45° field of view",
        },
        {
            "id": "remidio_fop",
            "name": "Remidio Fundus-on-Phone (FOP)",
            "manufacturer": "Remidio Innovative Solutions",
            "format": "Smartphone CMOS RGB",
            "description": "Handheld portable smartphone fundus camera for mobile screening vans",
            "fov": "45° field of view",
        },
        {
            "id": "volk_inview",
            "name": "Volk iNview",
            "manufacturer": "Volk Optical",
            "format": "Smartphone 20D Lens Aperture",
            "description": "Smartphone-mounted indirect ophthalmoscopy condensing lens",
            "fov": "50° circular aperture",
        },
    ]


@router.get("/samples")
def get_sample_test_cases() -> list[dict[str, Any]]:
    """Curated field test pack demonstrating multi-camera and multi-condition compatibility."""
    return [
        {
            "id": "case_1_clean",
            "name": "Case 1: Clean Diagnostic Quality",
            "patient_name": "Ramesh Kumar (Age: 54)",
            "camera": "Hospital-grade desktop fundus camera",
            "expected_quality": "GOOD",
            "expected_dr": "Grade 0 / Mild",
        },
        {
            "id": "case_2_blur",
            "name": "Case 2: Camera Defocus & Motion Blur",
            "patient_name": "Test Subject (Defocus artifact)",
            "camera": "Handheld smartphone camera with motion",
            "expected_quality": "REJECT (Severe Blur)",
            "expected_dr": "SUPPRESSED (Safe abstention)",
        },
        {
            "id": "case_3_borderline",
            "name": "Case 3: Marginal Low Illumination",
            "patient_name": "Test Subject (Small pupil / under-dilation)",
            "camera": "Non-mydriatic camera with small pupil",
            "expected_quality": "BORDERLINE (Reassessment)",
            "expected_dr": "Conditional triage under review",
        },
        {
            "id": "case_4_severe",
            "name": "Case 4: High-Risk Proliferative Signs",
            "patient_name": "Anand Patil (Age: 62)",
            "camera": "Clinical fundus camera",
            "expected_quality": "GOOD",
            "expected_dr": "Grade 3 / 4 (High Risk — Mandatory Over-read)",
        },
        {
            "id": "case_5_non_fundus",
            "name": "Case 5: Adversarial Non-Fundus Input",
            "patient_name": "Negative Control Test",
            "camera": "External photo / non-retinal image",
            "expected_quality": "REJECT (Non-Fundus or Corrupt)",
            "expected_dr": "SUPPRESSED",
        },
    ]
