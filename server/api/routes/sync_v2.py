"""De-identified sync endpoint (/sync/v2, Ticket C-4).

Contract (docs/PRIVACY.md + docs/TEAM_PLAN_NEXT_UPDATE.md §5):
  - carries ONLY pseudonymized data; the server stores NO PHI columns
    (name/phone/ABHA/village do not exist in deid_screenings),
  - batch-level fail-closed PHI linter: any violation => HTTP 422, the
    ENTIRE batch is dropped, nothing is persisted or quarantined,
  - NO server-side inference: the AI already ran on the phone; v2 removes
    the multi-second in-request analysis of v1 (/sync),
  - idempotent: the row PK (pseudo_screening_id) doubles as the receipt —
    INSERT OR IGNORE + fetch replays retries without duplicate rows,
  - every accept/reject is audit-logged with pseudonyms only, never values.
"""

from __future__ import annotations

import base64
import logging
import os
from datetime import datetime, timezone

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from fastapi.responses import FileResponse

from api.auth import ApiPrincipal, require_auth, require_doctor
from api.database import get_db
from api.schemas import DeidentifiedSyncRequest, DeidentifiedSyncResponse
from api.services.deid_linter import PHIRejectionError, assert_clean
from api.services.sms_gateway import is_configured as sms_is_configured
from api.services.sms_gateway import send_doctor_sms
from api.services.whatsapp_notify import is_configured, notify_doctor_referral

router = APIRouter(prefix="/sync/v2", tags=["De-identified Synchronization"])

logger = logging.getLogger(__name__)

#: De-identified images arrive as ~<=1.1MB decoded 512px JPEGs. Anything
#: bigger is not a v2 payload (misrouted v1 client) and is rejected.
_MAX_DECODED_IMAGE = 1_500_000

_JPEG_MAGIC = (b"\xff\xd8",)


def _results_dir() -> str:
    from api.services.ai_bridge import _RESULTS_DIR

    return os.path.join(_RESULTS_DIR, "deid_screenings")


def _audit(cursor, action: str, resource: str, detail: str) -> None:
    cursor.execute(
        "INSERT INTO audit_log (actor, action, resource, detail, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (
            "deid-sync",
            action,
            resource,
            detail,
            datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        ),
    )


@router.post("", response_model=DeidentifiedSyncResponse)
def sync_deidentified_batch(
    payload: DeidentifiedSyncRequest,
    background_tasks: BackgroundTasks,
    _principal: ApiPrincipal = Depends(require_auth),
) -> DeidentifiedSyncResponse:
    """Receives consent-gated, pseudonymized screening results.

    Fail-closed order of operations:
      1. Parse-time rejection of unknown fields (pydantic extra=forbid),
      2. Batch-level PHI lint — ONE violation rejects the whole batch
         (HTTP 422 PHI_REJECTED) BEFORE any persistence,
      3. Per-item save with idempotent replay on the pseudo id.
    """
    # ---- Layer 2: batch-level linter (whole batch fails together) ----
    for index, item in enumerate(payload.screenings):
        try:
            assert_clean(item.model_dump())
        except PHIRejectionError as exc:
            with get_db() as conn:
                _audit(
                    conn.cursor(),
                    "deid_sync_rejected",
                    f"batch-item-{index}",
                    ",".join(exc.violations)[:400],
                )
                conn.commit()
            logger.warning(
                "De-identified sync batch rejected at item %d: %s",
                index,
                ",".join(exc.violations),
            )
            raise HTTPException(
                status_code=422,
                detail={
                    "error": "PHI_REJECTED",
                    "item_index": index,
                    "violations": exc.violations,
                },
            ) from None

    synced_ids: list[str] = []
    failed_items: list[dict[str, str]] = []
    seen_in_batch: set[str] = set()

    for item in payload.screenings:
        pseudo_id = item.pseudo_screening_id
        try:
            if pseudo_id in seen_in_batch:
                failed_items.append(
                    {"pseudo_screening_id": pseudo_id, "error": "DUPLICATE_IN_BATCH"}
                )
                continue
            seen_in_batch.add(pseudo_id)

            image_path: str | None = None
            if item.image_base64:
                try:
                    image_bytes = base64.b64decode(item.image_base64, validate=True)
                except Exception:  # noqa: BLE001 - per-item error contract
                    raise ValueError("Invalid base64 image payload.")
                if not image_bytes or len(image_bytes) > _MAX_DECODED_IMAGE:
                    raise ValueError("Decoded image empty or exceeds the v2 cap.")
                if not image_bytes.startswith(_JPEG_MAGIC):
                    raise ValueError("Only JPEG images are accepted on /sync/v2.")
                os.makedirs(_results_dir(), exist_ok=True)
                # File keyed by the pseudo id: no PHI in the filename either.
                image_path = os.path.join(_results_dir(), f"{pseudo_id}.jpg")
                with open(image_path, "wb") as fh:
                    fh.write(image_bytes)

            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
            with get_db() as conn:
                cursor = conn.cursor()
                cursor.execute(
                    "INSERT OR IGNORE INTO deid_screenings "
                    "(pseudo_screening_id, pseudonym, age_band, gender, eye_side, "
                    " dr_grade_num, dr_label, prob_vector, confidence, "
                    " requires_human_review, consent_version, image_path, "
                    " captured_at, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        pseudo_id,
                        item.pseudonym,
                        item.age_band,
                        item.gender,
                        item.eye_side,
                        item.dr_grade,
                        item.dr_label,
                        (
                            ",".join(f"{p:.6f}" for p in item.probabilities)
                            if item.probabilities is not None
                            else None
                        ),
                        item.confidence,
                        1 if item.requires_human_review else 0,
                        item.consent_version,
                        image_path,
                        (item.captured_at or "").strip() or None,
                        now,
                    ),
                )
                if cursor.rowcount == 0:
                    # Idempotent replay: this pseudo id is already durably
                    # stored — success, no duplicate row, no re-write.
                    synced_ids.append(pseudo_id)
                    _audit(cursor, "deid_sync_replayed", pseudo_id, "")
                    conn.commit()
                    continue

                _audit(
                    cursor,
                    "deid_sync_stored",
                    pseudo_id,
                    f"grade={item.dr_grade if item.dr_grade is not None else 'none'} "
                    f"review={1 if item.requires_human_review else 0}",
                )
                conn.commit()
                synced_ids.append(pseudo_id)
                if is_configured():
                    # Free doctor notification via the WhatsApp Cloud API
                    # sandbox (pseudonym + grade only — see
                    # api/services/whatsapp_notify.py). Background task:
                    # storage never waits on the network.
                    background_tasks.add_task(
                        notify_doctor_referral,
                        {
                            "pseudo_screening_id": pseudo_id,
                            "pseudonym": item.pseudonym,
                            "dr_grade": item.dr_grade,
                            "dr_label": item.dr_label,
                            "requires_human_review": item.requires_human_review,
                        },
                    )
                if sms_is_configured():
                    # DLT-legal SMS channel (production, TRAI-registered
                    # gateway + approved template). Same background + fail-
                    # safe discipline; disabled until env keys exist.
                    background_tasks.add_task(
                        send_doctor_sms,
                        {
                            "pseudo_screening_id": pseudo_id,
                            "pseudonym": item.pseudonym,
                            "dr_grade": item.dr_grade,
                            "dr_label": item.dr_label,
                            "requires_human_review": item.requires_human_review,
                        },
                    )
        except ValueError as e:
            failed_items.append({"pseudo_screening_id": pseudo_id, "error": str(e)[:200]})
        except Exception as e:  # noqa: BLE001 - stable per-item error code
            logger.warning("De-identified sync item %s failed: %s", pseudo_id, e)
            failed_items.append(
                {"pseudo_screening_id": pseudo_id, "error": "INTERNAL_PROCESSING_FAILED"}
            )

    return DeidentifiedSyncResponse(
        total_received=len(payload.screenings),
        total_synced=len(synced_ids),
        synced_pseudo_ids=synced_ids,
        failed_items=failed_items,
    )


@router.get("/pending")
def list_deid_screenings(
    limit: int = 100,
    _principal: ApiPrincipal = Depends(require_doctor),
) -> dict:
    """Doctor console feed: pseudonymized referrals awaiting over-read.

    Doctor/admin role only — operators cannot enumerate the referral queue.
    Every field is pseudonym-keyed; the image is fetched separately via
    /sync/v2/image/{pseudo_id} (also doctor-only). No PHI columns exist to
    return.
    """
    limit = max(1, min(limit, 200))
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT pseudo_screening_id, pseudonym, age_band, gender, eye_side, "
            "dr_grade_num, dr_label, prob_vector, confidence, "
            "requires_human_review, consent_version, image_path, captured_at, "
            "created_at "
            "FROM deid_screenings ORDER BY created_at DESC LIMIT ?",
            (limit,),
        )
        rows = cursor.fetchall()
    items = []
    for row in rows:
        items.append(
            {
                "pseudo_screening_id": row["pseudo_screening_id"],
                "pseudonym": row["pseudonym"],
                "age_band": row["age_band"],
                "gender": row["gender"],
                "eye_side": row["eye_side"],
                "dr_grade": row["dr_grade_num"],
                "dr_label": row["dr_label"],
                "probabilities": [float(p) for p in row["prob_vector"].split(",")]
                if row["prob_vector"]
                else None,
                "confidence": row["confidence"],
                "requires_human_review": bool(row["requires_human_review"]),
                "consent_version": row["consent_version"],
                "captured_at": row["captured_at"],
                "created_at": row["created_at"],
                "has_image": bool(row["image_path"]) and os.path.exists(row["image_path"]),
            }
        )
    return {"count": len(items), "items": items}


@router.get("/image/{pseudo_screening_id}")
def get_deid_image(
    pseudo_screening_id: str,
    _principal: ApiPrincipal = Depends(require_doctor),
) -> FileResponse:
    """Serves the stored DE-IDENTIFIED image (downscaled, EXIF-stripped by
    the client) to doctor/admin sessions only."""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT image_path FROM deid_screenings WHERE pseudo_screening_id = ?",
            (pseudo_screening_id,),
        )
        row = cursor.fetchone()
    path = row["image_path"] if row else None
    if not path or not os.path.exists(path):
        raise HTTPException(status_code=404, detail="image_not_found")
    # Path traversal hardening: the stored path must live inside the
    # de-identified results directory.
    base = os.path.abspath(_results_dir())
    if not os.path.abspath(path).startswith(base):
        raise HTTPException(status_code=404, detail="image_not_found")
    return FileResponse(path, media_type="image/jpeg")
