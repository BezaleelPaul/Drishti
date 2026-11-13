"""On-demand marker computation for clinician review cases.

Advisory data path for the tele-ophthalmologist review viewer: resolves the
review case's stored fundus image (``screenings.original_image_path``), runs
the retinal-structure segmenter on demand — regardless of the screening's
quality grade — and maps its coordinates into the marker payload.

Every failure degrades to ``available=False`` with a short honest reason.
Markers are advisory: never fabricated, never partial, and never raised past
this service (a marker failure must not block the sign-off decision path).
"""

from __future__ import annotations

import logging
import os
import sqlite3
import threading
from typing import TYPE_CHECKING

import numpy as np

from api.database import get_db
from api.schemas import MarkerCircle, MarkerPoint, ReviewMarkersResponse
from src.image_io import MAX_IMAGE_DIM

if TYPE_CHECKING:
    from src.segmentation.structure_segmenter import (
        RetinalStructureSegmenter,
        RetinalStructuresResult,
    )

logger = logging.getLogger(__name__)

_segmenter: RetinalStructureSegmenter | None = None
_segmenter_lock = threading.Lock()


def _get_segmenter() -> RetinalStructureSegmenter:
    """Thread-safe lazy singleton for :class:`RetinalStructureSegmenter`.

    Reusing one warm instance across requests avoids reloading the optional
    DL toolbox model on every marker request (mirrors the router's warm
    singleton). The segmenter normalizes input internally via
    ``src.image_io.to_rgb_uint8``, so a raw decoded array is passed through.
    """
    global _segmenter
    if _segmenter is None:
        with _segmenter_lock:
            if _segmenter is None:
                from src.segmentation.structure_segmenter import RetinalStructureSegmenter

                _segmenter = RetinalStructureSegmenter()
    return _segmenter


def _unavailable(review_id: str, reason: str) -> ReviewMarkersResponse:
    """Fail-closed payload: zero coordinates, honest reason."""
    return ReviewMarkersResponse(review_id=review_id, available=False, reason=reason)


def _resolve_image_path(conn: sqlite3.Connection, review_id: str) -> tuple[str | None, str]:
    """Resolve ``review_id`` -> ``screenings.original_image_path``.

    Returns ``(path, "")`` on success, or ``(None, reason)`` when the review
    case or its screening row is unretrievable or stores no image path.
    """
    review_row = conn.execute(
        "SELECT screening_id FROM doctor_reviews WHERE review_id = ?",
        (review_id,),
    ).fetchone()
    if review_row is None:
        return None, "review case not found"
    screening_row = conn.execute(
        "SELECT original_image_path FROM screenings WHERE screening_id = ?",
        (review_row["screening_id"],),
    ).fetchone()
    if screening_row is None:
        return None, "review screening record not found"
    path = screening_row["original_image_path"]
    if not path:
        return None, "stored fundus image path is missing"
    return str(path), ""


def _fetch_cnn_grade(conn: sqlite3.Connection, review_id: str) -> tuple[int | None, str | None]:
    """Stored CNN grade for the review case (None when absent/ungraded).

    Absence is NOT negative evidence: quality-rejected screenings never
    stored a grade, and the payload must not fabricate one.
    """
    row = conn.execute(
        "SELECT screenings.dr_grade_num "
        "FROM doctor_reviews JOIN screenings "
        "ON screenings.screening_id = doctor_reviews.screening_id "
        "WHERE doctor_reviews.review_id = ?",
        (review_id,),
    ).fetchone()
    if row is None or row["dr_grade_num"] is None:
        return None, None
    return int(row["dr_grade_num"]), None


def _decode_image_capped(path: str) -> np.ndarray:
    """Capped decode mirroring the pipeline's image guard.

    PIL opens lazily, so the early header dimension check rejects degenerate
    or >4K images before any pixel buffer exists. Returns the decoded
    HxWx3 RGB uint8 array in the SOURCE image's pixel space.
    """
    from PIL import Image, UnidentifiedImageError

    pil_img = None
    try:
        try:
            pil_img = Image.open(path)
        except (UnidentifiedImageError, OSError) as exc:
            raise ValueError(f"Invalid image file: {exc}") from exc
        w, h = pil_img.size
        if w <= 0 or h <= 0 or w > MAX_IMAGE_DIM or h > MAX_IMAGE_DIM:
            raise ValueError(
                f"Image dimensions {w}x{h} outside decodable range (max {MAX_IMAGE_DIM})."
            )
        return np.array(pil_img.convert("RGB"))
    finally:
        if pil_img is not None:
            pil_img.close()


def _build_payload(
    review_id: str,
    np_img: np.ndarray,
    result: RetinalStructuresResult,
    cnn_grade: int | None = None,
) -> ReviewMarkersResponse:
    """Map a segmenter result into the marker payload (source-pixel space).

    Honesty mapping: optic disc / fovea are ``None`` when the segmenter
    reported a zero centre (or zero radius); ``ma_candidates`` is ALWAYS a
    list — an explicitly empty list means "computed, none found" (healthy),
    which is a different state from ``available=False`` (not computed).

    The evidence-linked extension (schema_version 1.0) attaches typed lesion
    evidence, the versioned ICDRS criteria evaluation, and the CNN-vs-
    evidence reconciliation. All extension fields are advisory and never
    block the sign-off path; detector failure degrades to explicit
    not-evaluated bookkeeping, never fabricated evidence.
    """
    od_x, od_y = int(result.optic_disc_center[0]), int(result.optic_disc_center[1])
    od_radius = int(result.optic_disc_radius)
    optic_disc = (
        MarkerCircle(x=od_x, y=od_y, r=od_radius)
        if od_radius > 0 and (od_x != 0 or od_y != 0)
        else None
    )

    fv_x, fv_y = int(result.fovea_center[0]), int(result.fovea_center[1])
    fovea = MarkerPoint(x=fv_x, y=fv_y) if (fv_x != 0 or fv_y != 0) else None

    ma_candidates = [
        MarkerCircle(x=int(cx), y=int(cy), r=max(int(cr), 0))
        for cx, cy, cr in result.microaneurysm_candidates
    ]

    reason = "No microaneurysm candidates found" if not ma_candidates else None

    # ---- Evidence-linked extension (fail-closed: errors drop to legacy shape)
    from src.services.evidence_service import build_evidence_payload

    extension = build_evidence_payload(np_img, result, cnn_grade=cnn_grade)
    if extension is not None:
        return ReviewMarkersResponse(
            review_id=review_id,
            available=True,
            reason=reason,
            width=int(np_img.shape[1]),
            height=int(np_img.shape[0]),
            optic_disc=optic_disc,
            fovea=fovea,
            ma_candidates=ma_candidates,
            schema_version="1.0",
            lesion_evidence=extension["lesion_evidence"],
            criteria_evaluation=extension["criteria_evaluation"],
            grading_policy=extension["grading_policy"],
            disagreement=extension["disagreement"],
        )
    logger.warning(
        "Evidence extension failed for review %s (degrading to legacy markers)", review_id
    )
    return ReviewMarkersResponse(
        review_id=review_id,
        available=True,
        reason=reason,
        width=int(np_img.shape[1]),
        height=int(np_img.shape[0]),
        optic_disc=optic_disc,
        fovea=fovea,
        ma_candidates=ma_candidates,
    )


def compute_review_markers(review_id: str) -> ReviewMarkersResponse:
    """Compute anatomical/lesion markers on demand for a review case.

    Advisory and fail-closed: an unknown review, missing image, decode
    failure, DB error, or segmentation error returns ``available=False``
    with a short honest reason. Never raises, never fabricates coordinates,
    never returns partial markers, and never carries mask pixel data.
    """
    try:
        with get_db() as conn:
            image_path, resolve_error = _resolve_image_path(conn, review_id)
            cnn_grade, _ = _fetch_cnn_grade(conn, review_id)
        if resolve_error:
            return _unavailable(review_id, resolve_error)
        if not os.path.isfile(image_path):
            return _unavailable(review_id, "stored fundus image not found")
        try:
            np_img = _decode_image_capped(image_path)
        except ValueError as exc:
            logger.warning("Marker decode failed for review %s: %s", review_id, exc)
            return _unavailable(review_id, "fundus image could not be decoded")
        result = _get_segmenter().segment_structures(np_img)
        return _build_payload(review_id, np_img, result, cnn_grade=cnn_grade)
    except Exception as exc:  # noqa: BLE001 - advisory path must fail closed
        logger.warning("Marker computation failed for review %s: %s", review_id, exc)
        return _unavailable(review_id, "marker computation failed")
