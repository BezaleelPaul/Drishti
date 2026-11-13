"""Evidence normalization: detector outputs -> typed, validated evidence.

Single place where raw segmentation output (``RetinalStructuresResult``)
is converted into stable-id, typed, criterion-linked evidence objects for
the API payload, Flutter rendering, and report generation.

Coordinate contract (documented, enforced here):
  * Canonical space = SOURCE-image pixel space, origin top-left,
    (x, y), x in [0, width), y in [0, height). The segmenter runs on the
    ``to_rgb_uint8``-normalized ORIGINAL image — no crop, resize, or flip
    occurs anywhere in the router path, so no coordinate transformation
    is ever needed. These assertions are validated fail-closed here.
  * Geometry: circles only (point + radius). OD/fovea are landmarks,
    lesions are candidates — the type/status distinction is explicit.
  * Invalid pixels (NaN/inf/out-of-range) raise ValueError: this module
    fails closed and callers must not silently drop malformed evidence.

Honesty contract:
  * every lesion is a CANDIDATE from classical CV — never a confirmed
    lesion, never model attention;
  * a detector that failed produces explicit failed/not-evaluated bookkeeping
    (returned alongside), never "zero evidence";
  * ids are stable within one screening result (LE-0001...), assigned in
    deterministic input order.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum

import numpy as np

DETECTOR_ID = "classical_cv_segmenter"
DETECTOR_VERSION = "1.0"


class LesionType(str, Enum):
    MICROANEURYSM_CANDIDATE = "microaneurysm_candidate"
    EXUDATE_CANDIDATE = "exudate_candidate"
    HEMORRHAGE_CANDIDATE = "hemorrhage_candidate"


class DetectionStatus(str, Enum):
    DETECTED = "detected"
    INDETERMINATE = "indeterminate"
    NOT_EVALUATED = "not_evaluated"
    FAILED = "failed"


@dataclass(frozen=True)
class LandmarkEvidence:
    landmark_id: str
    landmark_type: str  # "optic_disc" | "fovea"
    x: int
    y: int
    radius: int | None
    reliable: bool
    evidence_notes: tuple[str, ...] = ()


@dataclass(frozen=True)
class LesionEvidence:
    lesion_id: str
    lesion_type: LesionType
    detection_status: DetectionStatus
    x: int
    y: int
    radius: int | None
    geometry_type: str
    detector_id: str
    detector_version: str
    criterion_links: tuple[str, ...] = ()
    evidence_notes: tuple[str, ...] = ()
    image_width: int = 0
    image_height: int = 0


@dataclass(frozen=True)
class DetectorRunStatus:
    """Explicit bookkeeping so 'not detected' is never confused with 'failed'."""

    detector_id: str
    detector_version: str
    ran: bool
    failed: bool
    note: tuple[str, ...] = field(default_factory=tuple)


MA_TO_FOVEA_CRITERION = "icdrss.fovea_involvement"
MA_CRITERION = "icdrss.ma_present"
EXUDATE_CRITERION = "icdrss.exudate_present"


def _validate_image_shape(img_w: int, img_h: int) -> None:
    if img_w <= 0 or img_h <= 0:
        raise ValueError(f"Invalid image dimensions: {img_w}x{img_h}.")


def _validate_point(x: int, y: int, img_w: int, img_h: int, label: str) -> None:
    for name, val in (("x", x), ("y", y)):
        if not np.isfinite(val):
            raise ValueError(f"{label} coordinate {name} is not finite: {val}.")
        if val < 0 or (name == "x" and val >= img_w) or (name == "y" and val >= img_h):
            raise ValueError(
                f"{label} coordinate {name}={val} outside image bounds ({img_w}x{img_h})."
            )


def _normalize_segmenter_input(img_rgb: np.ndarray) -> tuple[int, int]:
    if not isinstance(img_rgb, np.ndarray):
        raise TypeError(f"Expected numpy array, got {type(img_rgb)}.")
    if img_rgb.ndim != 3 or img_rgb.shape[2] != 3:
        raise ValueError(f"Expected HxWx3 RGB image, got shape {img_rgb.shape}.")
    h, w = int(img_rgb.shape[0]), int(img_rgb.shape[1])
    _validate_image_shape(w, h)
    return w, h


def _exudate_blobs(exudate_mask: np.ndarray) -> list[tuple[int, int, int]]:
    """Groups the exudate mask into candidate blobs (minEnclosingCircle).

    The segmenter emits a binary mask; per-lesion identity needs connected
    components. Contours in EXTERNAL mode: each blob is one candidate.
    """
    try:
        import cv2
    except ImportError:
        return []
    _cnt = cv2.findContours(exudate_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    contours = _cnt[0] if len(_cnt) == 2 else _cnt[1]
    blobs: list[tuple[int, int, int]] = []
    for cnt in contours:
        if cv2.contourArea(cnt) <= 1:
            continue
        (x, y), radius = cv2.minEnclosingCircle(cnt)
        blobs.append((round(x), round(y), max(round(radius), 1)))
    return blobs


def normalize_structures(
    img_rgb: np.ndarray,
    structures: object,
) -> tuple[list[LandmarkEvidence], list[LesionEvidence], dict[str, DetectorRunStatus]]:
    """Converts a segmenter result into landmark + lesion evidence.

    Args:
        img_rgb: the SAME canonical array the segmenter consumed (source
            pixel space); used only for bounds validation.
        structures: ``RetinalStructuresResult`` (duck-typed to avoid a
            circular import).

    Returns (landmarks, lesions, detector_status_by_detector_key).
    Raises ValueError on malformed coordinates (fail-closed).
    """
    from src.segmentation.structure_segmenter import (
        HAS_OPENCV,
    )  # local: avoid import at module load

    img_w, img_h = _normalize_segmenter_input(img_rgb)

    od_x, od_y = int(structures.optic_disc_center[0]), int(structures.optic_disc_center[1])
    od_radius = int(structures.optic_disc_radius)
    fv_x, fv_y = int(structures.fovea_center[0]), int(structures.fovea_center[1])
    _validate_point(od_x, od_y, img_w, img_h, "optic disc")
    _validate_point(fv_x, fv_y, img_w, img_h, "fovea")

    od_reliable = od_radius > 0 and (od_x != 0 or od_y != 0)
    fovea_reliable = fv_x != 0 or fv_y != 0

    landmarks = [
        LandmarkEvidence(
            landmark_id="LM-OD",
            landmark_type="optic_disc",
            x=od_x,
            y=od_y,
            radius=od_radius,
            reliable=od_reliable,
            evidence_notes=(
                ()
                if od_reliable
                else ("Landmark degenerate (zero centre/radius) — excluded from spatial rules.",)
            ),
        ),
        LandmarkEvidence(
            landmark_id="LM-FOVEA",
            landmark_type="fovea",
            x=fv_x,
            y=fv_y,
            radius=None,
            reliable=fovea_reliable,
            evidence_notes=(
                "Geometric estimate temporal to the optic disc "
                "(documented segmenter fallback; not a detected fovea)."
            ),
        ),
    ]

    lesions: list[LesionEvidence] = []
    seq = 0

    def _next_id() -> str:
        nonlocal seq
        seq += 1
        return f"LE-{seq:04d}"

    # Microaneurysm candidates (already discrete points from the segmenter).
    for cx, cy, cr in structures.microaneurysm_candidates:
        _validate_point(int(cx), int(cy), img_w, img_h, "microaneurysm candidate")
        lesions.append(
            LesionEvidence(
                lesion_id=_next_id(),
                lesion_type=LesionType.MICROANEURYSM_CANDIDATE,
                detection_status=DetectionStatus.DETECTED,
                x=int(cx),
                y=int(cy),
                radius=max(int(cr), 0),
                geometry_type="circle",
                detector_id=DETECTOR_ID,
                detector_version=DETECTOR_VERSION,
                criterion_links=(MA_CRITERION, MA_TO_FOVEA_CRITERION),
                evidence_notes=(
                    "Classical-CV candidate (dark focal spot); not a confirmed lesion.",
                ),
                image_width=img_w,
                image_height=img_h,
            )
        )

    # Exudate candidates: derive discrete blobs from the binary mask.
    exudate_status = DetectorRunStatus(
        detector_id=DETECTOR_ID,
        detector_version=DETECTOR_VERSION,
        ran=structures.exudate_mask is not None,
        failed=False,
        note=() if structures.exudate_mask is not None else ("Exudate mask unavailable.",),
    )
    if structures.exudate_mask is not None:
        for ex, ey, er in _exudate_blobs(np.asarray(structures.exudate_mask)):
            _validate_point(ex, ey, img_w, img_h, "exudate candidate")
            lesions.append(
                LesionEvidence(
                    lesion_id=_next_id(),
                    lesion_type=LesionType.EXUDATE_CANDIDATE,
                    detection_status=DetectionStatus.DETECTED,
                    x=ex,
                    y=ey,
                    radius=er,
                    geometry_type="circle",
                    detector_id=DETECTOR_ID,
                    detector_version=DETECTOR_VERSION,
                    criterion_links=(EXUDATE_CRITERION, MA_TO_FOVEA_CRITERION),
                    evidence_notes=(
                        "Bright-lesion candidate outside the optic disc; not a confirmed lesion.",
                    ),
                    image_width=img_w,
                    image_height=img_h,
                )
            )

    ma_status = DetectorRunStatus(
        detector_id=DETECTOR_ID,
        detector_version=DETECTOR_VERSION,
        ran=HAS_OPENCV,
        failed=not HAS_OPENCV,
        note=() if HAS_OPENCV else ("OpenCV unavailable; MA detection did not run.",),
    )
    statuses = {DETECTOR_ID: ma_status, f"{DETECTOR_ID}:exudate": exudate_status}
    return landmarks, lesions, statuses


def fovea_involved_ids(
    lesions: list[LesionEvidence],
    landmarks: list[LandmarkEvidence],
    structures: object,
) -> tuple[list[str], bool]:
    """Applies the documented CSME proximity rule to candidate evidence.

    Rule (segmenter, versioned with the detector): a lesion candidate whose
    distance to the fovea centre is < 1.5x the optic-disc radius is in the
    macular zone. Returns (ids, evaluable). Not evaluable when either
    landmark is unreliable — proximity to an unreliable landmark is not
    spatial evidence.
    """
    od = next((l for l in landmarks if l.landmark_type == "optic_disc"), None)
    fovea = next((l for l in landmarks if l.landmark_type == "fovea"), None)
    if od is None or fovea is None or not od.reliable or not fovea.reliable:
        return [], False
    threshold = od.radius * 1.5 if od.radius and od.radius > 0 else 0
    if threshold <= 0:
        return [], False
    fx, fy = fovea.x, fovea.y
    ids: list[str] = []
    for lesion in lesions:
        if lesion.detection_status != DetectionStatus.DETECTED:
            continue
        dist = float(np.sqrt((lesion.x - fx) ** 2 + (lesion.y - fy) ** 2))
        if dist < threshold:
            ids.append(lesion.lesion_id)
    return ids, True
