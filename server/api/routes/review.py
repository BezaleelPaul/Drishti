from __future__ import annotations

import re
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query

from api.auth import ApiPrincipal, audit_action, require_doctor
from api.database import get_db
from api.schemas import (
    DoctorDecisionRequest,
    DoctorDecisionResponse,
    DoctorReviewItem,
    DoctorReviewListResponse,
    ReviewMarkersResponse,
)
from src.services.marker_service import compute_review_markers

router = APIRouter(prefix="/review", tags=["Doctor Review"])

# review_id format check: identical style to results.py's screening-id
# allowlist. Anything outside the format "never exists" -> uniform 404
# without leaking the expected format.
_REVIEW_ID_RE = re.compile(r"^REV-[A-Z0-9]{6,}$")

DR_LABELS = {
    0: "No DR",
    1: "Mild NPDR",
    2: "Moderate NPDR",
    3: "Severe NPDR",
    4: "Proliferative DR",
}


# Allowlisted doctor decisions -> internal review statuses.
DECISION_STATUS_MAP = {
    "CONFIRM": "CONFIRMED",
    "CONFIRM_AND_REFER": "REFERRED",
    "OVERRIDE_GRADE": "OVERRIDDEN",
    "REQUEST_RECAPTURE": "RECAPTURE_REQUESTED",
    "ROUTINE_FOLLOW_UP": "ROUTINE_FOLLOW_UP",
}


@router.get("/pending", response_model=DoctorReviewListResponse)
def get_pending_reviews(
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0, le=100000),
    _principal: ApiPrincipal = Depends(require_doctor),
):
    """
    Retrieves all screenings flagged for clinical review:
    - Ambiguous or low-confidence predictions (<70%)
    - High-risk cases (Severe NPDR, Proliferative DR)
    - Borderline quality scans requiring specialist over-read
    """
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute("SELECT COUNT(*) as total FROM doctor_reviews WHERE status = 'PENDING'")
        total_pending = cursor.fetchone()["total"]
        cursor.execute(
            """
        SELECT 
            r.review_id, r.screening_id, r.patient_id, r.status, r.doctor_name,
            r.doctor_decision, r.clinical_notes, r.referral_urgency, r.follow_up_days,
            r.created_at, r.reviewed_at,
            p.name as patient_name, p.age as patient_age, p.gender as patient_gender, p.village, p.abha_id,
            s.eye_side, s.quality_grade, s.dr_grade_num, s.dr_grade_label, s.dr_confidence,
            s.is_referable, s.requires_human_review, s.human_review_type, s.human_review_reason,
            s.original_image_path, s.gradcam_overlay_path
        FROM doctor_reviews r
        JOIN patients p ON r.patient_id = p.patient_id
        JOIN screenings s ON r.screening_id = s.screening_id
        WHERE r.status = 'PENDING'
        ORDER BY r.created_at ASC
        LIMIT ? OFFSET ?
        """,
            (limit, offset),
        )
        rows = cursor.fetchall()

    items = []
    for r in rows:
        items.append(
            DoctorReviewItem(
                review_id=r["review_id"],
                screening_id=r["screening_id"],
                patient_id=r["patient_id"],
                patient_name=r["patient_name"],
                patient_age=r["patient_age"],
                patient_gender=r["patient_gender"],
                village=r["village"],
                abha_id=r["abha_id"],
                eye_side=r["eye_side"],
                quality_grade=r["quality_grade"],
                dr_grade_num=r["dr_grade_num"],
                dr_grade_label=r["dr_grade_label"],
                dr_confidence=r["dr_confidence"],
                is_referable=None if r["is_referable"] is None else bool(r["is_referable"]),
                requires_human_review=bool(r["requires_human_review"]),
                human_review_type=r["human_review_type"] or "NONE",
                human_review_reason=r["human_review_reason"],
                original_image_url=r["original_image_path"],
                gradcam_overlay_url=r["gradcam_overlay_path"],
                status=r["status"],
                doctor_name=r["doctor_name"],
                doctor_decision=r["doctor_decision"],
                clinical_notes=r["clinical_notes"],
                referral_urgency=r["referral_urgency"],
                follow_up_days=r["follow_up_days"],
                created_at=r["created_at"],
                reviewed_at=r["reviewed_at"],
            )
        )

    return DoctorReviewListResponse(total_pending=total_pending, items=items)


@router.post("/{review_id}", response_model=DoctorDecisionResponse)
def submit_doctor_decision(
    review_id: str,
    payload: DoctorDecisionRequest,
    _principal: ApiPrincipal = Depends(require_doctor),
):
    """
    Records an ophthalmologist's clinical verdict.
    Updates doctor_reviews and synchronizes with primary screenings record.
    """
    with get_db() as conn:
        cursor = conn.cursor()

        cursor.execute(
            "SELECT review_id, screening_id, status FROM doctor_reviews WHERE review_id = ?",
            (review_id,),
        )
        row = cursor.fetchone()
        if not row:
            raise HTTPException(status_code=404, detail=f"Review case {review_id} not found.")

        if row["status"] != "PENDING":
            raise HTTPException(
                status_code=409,
                detail=f"Review {review_id} already decided (status={row['status']}).",
            )
        decision_key = (payload.decision or "").strip().upper()
        if decision_key not in DECISION_STATUS_MAP:
            raise HTTPException(
                status_code=422,
                detail=f"Unknown decision '{payload.decision}'. Allowed: {sorted(DECISION_STATUS_MAP)}.",
            )
        now = datetime.now(timezone.utc).isoformat()
        new_status = DECISION_STATUS_MAP[decision_key]
        # Decision/override coupling: an OVERRIDE without a grade would mark
        # the case OVERRIDDEN while changing nothing; a stray override with
        # CONFIRM would silently rewrite the grade under a CONFIRMED status.
        if decision_key == "OVERRIDE_GRADE" and payload.grade_override is None:
            raise HTTPException(
                status_code=422,
                detail="decision 'OVERRIDE_GRADE' requires grade_override (0-4).",
            )
        if decision_key != "OVERRIDE_GRADE" and payload.grade_override is not None:
            raise HTTPException(
                status_code=422,
                detail=f"grade_override is only valid with decision 'OVERRIDE_GRADE', not '{payload.decision}'.",
            )
        screening_id = row["screening_id"]

        # 1. Update doctor_reviews table. The WHERE status='PENDING' makes
        # this atomic: two concurrent verdicts cannot both win — the loser
        # sees rowcount 0 and gets a 409 instead of double-appending notes.
        cursor.execute(
            """
        UPDATE doctor_reviews
        SET status = ?,
            doctor_name = ?,
            doctor_decision = ?,
            doctor_grade_override = ?,
            clinical_notes = ?,
            referral_urgency = ?,
            follow_up_days = ?,
            reviewed_at = ?
        WHERE review_id = ? AND status = 'PENDING'
        """,
            (
                new_status,
                payload.doctor_name,
                payload.decision,
                payload.grade_override,
                payload.clinical_notes,
                payload.referral_urgency,
                payload.follow_up_days,
                now,
                review_id,
            ),
        )
        if cursor.rowcount == 0:
            # Lost the race (or row vanished): distinguish 404 from 409.
            cursor.execute("SELECT status FROM doctor_reviews WHERE review_id = ?", (review_id,))
            race_row = cursor.fetchone()
            if race_row is None:
                raise HTTPException(status_code=404, detail=f"Review case {review_id} not found.")
            raise HTTPException(
                status_code=409,
                detail=f"Review {review_id} already decided (status={race_row['status']}).",
            )

        # 2. Synchronize clinical verdict into primary screenings table
        notes_suffix = f" [Doctor Verdict ({payload.doctor_name}): {payload.decision}. Notes: {payload.clinical_notes or 'None'}]"
        if payload.grade_override is not None:
            new_label = DR_LABELS.get(payload.grade_override, f"Grade {payload.grade_override}")
            is_ref = 1 if payload.grade_override >= 2 else 0
            cursor.execute(
                """
            UPDATE screenings
            SET dr_grade_num = ?,
                dr_grade_label = ?,
                is_referable = ?,
                requires_human_review = 0,
                human_review_type = 'NONE',
                screening_status = ?,
                action_recommendation = COALESCE(action_recommendation, '') || ?
            WHERE screening_id = ?
            """,
                (
                    payload.grade_override,
                    new_label,
                    is_ref,
                    f"Reviewed: {new_status}",
                    notes_suffix,
                    screening_id,
                ),
            )
        else:
            cursor.execute(
                """
            UPDATE screenings
            SET requires_human_review = 0,
                human_review_type = 'NONE',
                screening_status = ?,
                action_recommendation = COALESCE(action_recommendation, '') || ?
            WHERE screening_id = ?
            """,
                (
                    f"Reviewed: {new_status}",
                    notes_suffix,
                    screening_id,
                ),
            )

        # 3. Verdict audit INSIDE the same transaction: a verdict is never
        # committed without its audit row (crash between commit and a
        # post-commit audit used to allow exactly that).
        cursor.execute(
            "INSERT INTO audit_log (actor, action, resource, detail, created_at)"
            " VALUES (?, ?, ?, ?, ?)",
            (
                f"{_principal.role}:{_principal.key_fingerprint}",
                "doctor_verdict",
                review_id,
                f"decision={payload.decision} status={new_status} screening={screening_id} doctor={payload.doctor_name}"[
                    :500
                ],
                now,
            ),
        )

        conn.commit()

    return DoctorDecisionResponse(
        success=True,
        message=f"Clinical decision recorded by {payload.doctor_name}. Screening record synchronized.",
        review_id=review_id,
        updated_status=new_status,
    )


@router.get("/{review_id}/markers", response_model=ReviewMarkersResponse)
def get_review_markers(review_id: str, _principal: ApiPrincipal = Depends(require_doctor)):
    """
    On-demand marker payload for one review case (advisory read-only data
    path; image bytes stay on the existing GET /results route):

    - 200 with coordinates + dimensions when markers could be computed
      (provenance always `classical_cv_segmentation`).
    - 200 with `available: false` when computation fails (fail-closed
      service), never a 5xx: markers must not block the sign-off path.
    - 404 when the review case does not exist or the id format is invalid
      (uniform "not found", no format oracle).
    - 401/403 through the existing doctor authorization.

    Unknown-review handling (design decision, Option A): this route
    PRE-CHECKS the review row and raises 404 itself; `compute_review_markers`
    stays unchanged and keeps failing closed, which also covers the TOCTOU
    case of a row deleted between pre-check and computation.
    """
    if not _REVIEW_ID_RE.match(review_id):
        audit_action(_principal, "review_markers_read_404", review_id)
        raise HTTPException(status_code=404, detail="Review case not found.")

    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT screening_id FROM doctor_reviews WHERE review_id = ?",
            (review_id,),
        )
        row = cursor.fetchone()
    if row is None:
        # Audit misses too: only logging successes would let a key
        # enumerate review ids without leaving a trace.
        audit_action(_principal, "review_markers_read_404", review_id)
        raise HTTPException(status_code=404, detail=f"Review case {review_id} not found.")

    response = compute_review_markers(review_id)
    audit_action(
        _principal,
        "review_markers_read",
        review_id,
        f"screening={row['screening_id']} available={response.available}",
    )
    return response
