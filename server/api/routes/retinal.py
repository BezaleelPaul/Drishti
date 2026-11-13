from __future__ import annotations

import json
import sqlite3

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, UploadFile
from fastapi.concurrency import run_in_threadpool

from api.auth import ApiPrincipal, audit_action, require_auth
from api.database import get_db, save_screening_record
from api.schemas import (
    DashboardScreeningsResponse,
    DashboardStats,
    RecentScreeningItem,
    RetinalAnalysisResponse,
    RetinalQualityResponse,
)
from api.services.ai_bridge import AIBridge
from src.classification.classifier import ClinicalModelUnavailableError

router = APIRouter(tags=["Retinal Screening"])

_UPLOAD_MAX_BYTES = 10 * 1024 * 1024
_UPLOAD_CHUNK = 256 * 1024


async def _read_upload_capped(file: UploadFile, what: str = "image") -> bytes:
    """Read an upload in chunks with an early abort: a lying or missing
    Content-Length (e.g. chunked encoding) must not OOM the worker before
    the size check runs."""
    parts = []
    total = 0
    while True:
        chunk = await file.read(_UPLOAD_CHUNK)
        if not chunk:
            break
        total += len(chunk)
        if total > _UPLOAD_MAX_BYTES:
            raise HTTPException(
                status_code=413, detail=f"{what.capitalize()} too large (max 10MB)."
            )
        parts.append(chunk)
    data = b"".join(parts)
    if not data:
        raise HTTPException(status_code=400, detail=f"Empty {what} file uploaded.")
    return data


def _safe_json_list(value) -> list:
    """Parse a JSON list column; return [] on NULL/garbage instead of 500."""
    if not value:
        return []
    if isinstance(value, list):
        return value
    try:
        parsed = json.loads(value)
        return parsed if isinstance(parsed, list) else []
    except (json.JSONDecodeError, TypeError):
        return []


def _safe_probabilities(value) -> list[float] | None:
    """Return only a valid five-class probability vector from legacy storage."""
    values = _safe_json_list(value)
    if len(values) != 5:
        return None
    try:
        probabilities = [float(item) for item in values]
    except (TypeError, ValueError):
        return None
    if any(not 0.0 <= item <= 1.0 for item in probabilities):
        return None
    return probabilities


@router.post("/retinal/quality", response_model=RetinalQualityResponse)
async def check_image_quality(
    _principal: ApiPrincipal = Depends(require_auth),
    file: UploadFile = File(..., description="Fundus image (JPG/PNG)"),
    camera_profile: str = Form("Generic Fundus Camera"),
):
    """
    Model 1: Real-Time Retinal Image Quality Gate.
    Evaluates blur, illumination, contrast, FOV, and deep ensemble gradability in <100ms.
    Returns immediate ASHA guidance and Hindi voice tip if image fails.
    """
    if file.content_type not in ("image/jpeg", "image/png", "application/octet-stream"):
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported content type: {file.content_type}. Upload JPG/PNG.",
        )
    image_bytes = await _read_upload_capped(file)

    bridge = AIBridge.get_instance()
    try:
        # Blocking TF/OpenCV inference must not run on the event loop:
        # concurrent uploads would stall every other request behind it.
        quality_result = await run_in_threadpool(bridge.assess_quality, image_bytes, camera_profile)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return RetinalQualityResponse(**quality_result)


@router.post("/retinal/analyze", response_model=RetinalAnalysisResponse)
async def analyze_retinal_image(
    _principal: ApiPrincipal = Depends(require_auth),
    file: UploadFile = File(..., description="Fundus image (JPG/PNG)"),
    patient_id: str = Form(..., description="Target patient identifier"),
    eye_side: str = Form("Right", description="'Right' or 'Left'"),
    camera_profile: str = Form("Generic Fundus Camera"),
):
    """
    End-to-End AI Retinal Screening Analysis:
    1. Model 1 Quality Gate (rejection gate / zero diagnostic leakage)
    2. Model 2 DR Severity Classification (Grades 0 to 4)
    3. True Grad-CAM++ Explainability visualization
    4. Softmax Confidence margin evaluation & Clinical human review flagging
    5. Automatic enrollment into Doctor Review queue if flagged
    """
    if eye_side not in ("Right", "Left"):
        raise HTTPException(status_code=422, detail="eye_side must be 'Right' or 'Left'.")
    if file.content_type not in ("image/jpeg", "image/png", "application/octet-stream"):
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported content type: {file.content_type}. Upload JPG/PNG.",
        )
    image_bytes = await _read_upload_capped(file)

    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT patient_id FROM patients WHERE patient_id = ?", (patient_id,))
        if not cursor.fetchone():
            raise HTTPException(status_code=404, detail=f"Patient {patient_id} not registered.")

    bridge = AIBridge.get_instance()
    try:
        analysis = await run_in_threadpool(
            bridge.analyze_retina,
            image_bytes,
            patient_id,
            eye_side,
            camera_profile,
        )
    except ClinicalModelUnavailableError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    try:
        with get_db() as conn:
            save_screening_record(conn, analysis)
    except sqlite3.IntegrityError:
        # Patient deleted between the existence check and the save (FK).
        raise HTTPException(
            status_code=409,
            detail=f"Patient {patient_id} no longer registered; re-register and retry.",
        )
    except ValueError:
        raise HTTPException(status_code=500, detail="Screening completed but persistence failed.")

    return RetinalAnalysisResponse(**analysis)


_DASHBOARD_REJECTION_TEXT = {
    "IMG_NOT_FUNDUS": "Not a fundus image",
    "IMG_UNGRADABLE": "Ungradable image",
}


def _dashboard_row_item(r: sqlite3.Row) -> RecentScreeningItem:
    error_code = r["error_code"] if "error_code" in r.keys() else None
    ref = r["is_referable"]
    grade_label = r["dr_grade_label"]
    rejected = r["quality_grade"] == "BAD" or error_code in (
        "IMG_NOT_FUNDUS",
        "IMG_UNGRADABLE",
    )
    if rejected:
        status = "rejected"
    elif ref:
        status = "referral"
    elif r["requires_human_review"]:
        status = "awaiting_specialist"
    else:
        status = "verified"
    if grade_label:
        result_text = grade_label
    elif error_code in _DASHBOARD_REJECTION_TEXT:
        result_text = _DASHBOARD_REJECTION_TEXT[error_code]
    elif rejected:
        result_text = "Quality rejected"
    else:
        result_text = "Pending"
    return RecentScreeningItem(
        screening_id=r["screening_id"],
        patient_id=r["patient_id"],
        patient_name=r["patient_name"],
        created_at=r["created_at"],
        dr_grade_num=r["dr_grade_num"],
        dr_grade_label=grade_label,
        result_text=result_text,
        is_referable=None if ref is None else bool(ref),
        requires_human_review=bool(r["requires_human_review"]),
        status=status,
    )


@router.get("/screenings", response_model=DashboardScreeningsResponse)
def get_dashboard_screenings(
    limit: int = Query(6, ge=1, le=50),
    _principal: ApiPrincipal = Depends(require_auth),
):
    """Live PHC dashboard feed: recent screenings (patient names joined)
    plus the tile counters, all computed from the database at request time."""
    audit_action(_principal, "screening_list_read", "global")
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
        SELECT s.screening_id, s.patient_id, p.name AS patient_name,
               s.created_at, s.dr_grade_num, s.dr_grade_label,
               s.is_referable, s.requires_human_review, s.quality_grade,
               s.error_code
        FROM screenings s
        LEFT JOIN patients p ON p.patient_id = s.patient_id
        ORDER BY s.created_at DESC
        LIMIT ?
        """,
            (limit,),
        )
        rows = cursor.fetchall()

        cursor.execute(
            """
        SELECT COUNT(*) AS n FROM screenings
        WHERE date(created_at, 'localtime') = date('now', 'localtime')
        """
        )
        today_screenings = cursor.fetchone()["n"]

        cursor.execute("SELECT COUNT(*) AS n FROM doctor_reviews WHERE status = 'PENDING'")
        awaiting_specialist = cursor.fetchone()["n"]

        cursor.execute("SELECT COUNT(*) AS n FROM screenings WHERE is_referable = 1")
        urgent_referrals = cursor.fetchone()["n"]

        cursor.execute("SELECT COUNT(*) AS n FROM screenings")
        total_screenings = cursor.fetchone()["n"]

    return DashboardScreeningsResponse(
        items=[_dashboard_row_item(r) for r in rows],
        stats=DashboardStats(
            today_screenings=today_screenings,
            awaiting_specialist=awaiting_specialist,
            urgent_referrals=urgent_referrals,
            total_screenings=total_screenings,
        ),
    )


@router.get("/screenings/{patient_id}", response_model=list[RetinalAnalysisResponse])
def get_patient_screenings(
    patient_id: str,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    _principal: ApiPrincipal = Depends(require_auth),
):
    """Retrieves past retinal screening records for a specific patient (paginated)."""
    audit_action(_principal, "screening_list_read", patient_id)
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
        SELECT * FROM screenings
        WHERE patient_id = ?
        ORDER BY created_at DESC
        LIMIT ? OFFSET ?
        """,
            (patient_id, limit, offset),
        )
        rows = cursor.fetchall()

    results = []
    for r in rows:
        ref = r["is_referable"]
        # sqlite3.Row iterates over VALUES, so `key in row` is always False.
        # Membership must be checked against row.keys() (column names).
        stored_summary = r["patient_summary"] if "patient_summary" in r.keys() else None
        results.append(
            RetinalAnalysisResponse(
                screening_id=r["screening_id"],
                patient_id=r["patient_id"],
                eye_side=r["eye_side"],
                camera_profile=r["camera_profile"],
                quality_grade=r["quality_grade"],
                quality_score=r["quality_score"] if r["quality_score"] is not None else 0.0,
                # BORDERLINE with a stored DR grade was cleared by reassessment
                # (failed borderlines store no grade) — counts as passed.
                quality_passed=(r["quality_grade"] == "GOOD" or r["dr_grade_num"] is not None),
                rejection_reasons=_safe_json_list(r["rejection_reasons"]),
                suspected_clinical_cause=r["suspected_clinical_cause"],
                error_code=r["error_code"] if "error_code" in r.keys() else None,
                dr_grade=r["dr_grade_num"],
                dr_label=r["dr_grade_label"],
                prediction_score=r["dr_confidence"],
                probabilities=_safe_probabilities(r["probabilities"]),
                # Backend that produced this grade: 'keras' | 'pytorch' | 'simulated' |
                # None (unknown, e.g. history rows written before this field existed).
                # Clients MUST treat 'simulated' as non-diagnostic.
                model_backend=r["model_backend"] if "model_backend" in r.keys() else None,
                # NULL in DB = ungradable: must stay None, never False (healthy).
                is_referable=None if ref is None else bool(ref),
                vessel_density_pct=r["vessel_density_pct"],
                microaneurysm_count=r["microaneurysm_count"],
                csme_risk=r["csme_risk"],
                min_fovea_distance_px=r["min_fovea_distance_px"],
                requires_human_review=bool(r["requires_human_review"]),
                human_review_type=r["human_review_type"] or "NONE",
                human_review_reason=r["human_review_reason"],
                confidence_flags=_safe_json_list(r["confidence_flags"]),
                original_image_url=r["original_image_path"],
                gradcam_overlay_url=r["gradcam_overlay_path"],
                gradcam_target_layer=r["target_layer"],
                action_recommendation=r["action_recommendation"] or "",
                # Stored verbatim: never re-fabricate a "Grade X detected"
                # summary for rows that have no grade.
                patient_plain_language_summary=(
                    stored_summary
                    or (
                        "Screening completed. No gradable result; recapture advised."
                        if r["dr_grade_num"] is None
                        else "Screening completed."
                    )
                ),
                created_at=r["created_at"],
                captured_at=r["captured_at"] if "captured_at" in r.keys() else None,
                inference_time_ms=(
                    r["inference_time_ms"] if "inference_time_ms" in r.keys() else None
                ),
            )
        )

    return results
