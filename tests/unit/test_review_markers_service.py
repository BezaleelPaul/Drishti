"""Unit tests for the on-demand review marker service (compute_review_markers).

Consistency strategy: the service's payload is asserted against a DIRECT
RetinalStructureSegmenter call on the same decoded image — coordinates are
real algorithm output, so the tests prove faithful mapping (types, bounds,
counts, identity of coordinates) instead of hardcoding coordinate values.
"""

import os
import sqlite3
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import cv2
import numpy as np
import pytest
from PIL import Image

from api.schemas import ReviewMarkersResponse
from src.services.marker_service import _get_segmenter, compute_review_markers

W, H = 640, 480
REVIEW_ID = "REV-TEST1"
SCREENING_ID = "SCR-TEST1"
REPO_ROOT = Path(__file__).resolve().parents[2]
REAL_FUNDUS_JPG = REPO_ROOT / "demo" / "sample_images" / "scenario_1_good.jpg"
MA_DOTS = (
    (430, 310),
    (350, 340),
    (440, 160),
    (300, 150),
    (500, 260),
    (260, 350),
    (390, 120),
)


def _synthetic_fundus_rgb() -> np.ndarray:
    """Black background, bright red fundus disc, darker vessel strokes,
    small dark-red MA-like dots — synthetic pixels exercising REAL segmenter
    code (never a stub)."""
    img = np.zeros((H, W, 3), dtype=np.uint8)  # channel order R,G,B
    cv2.circle(img, (320, 240), 200, (60, 30, 35), -1)
    cv2.circle(img, (240, 240), 28, (240, 210, 170), -1)
    cv2.line(img, (240, 240), (400, 180), (25, 14, 18), 2, cv2.LINE_AA)
    cv2.line(img, (240, 240), (180, 340), (25, 14, 18), 2, cv2.LINE_AA)
    for x, y in MA_DOTS:
        cv2.circle(img, (x, y), 2, (45, 10, 25), -1)
    return img


def _write_fundus_file(root: str, screening_id: str = SCREENING_ID) -> str:
    folder = os.path.join(root, "results", "api_screenings", screening_id)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{screening_id}_orig.jpg")
    Image.fromarray(_synthetic_fundus_rgb()).save(path, quality=98)
    return path


def _seed_review_case(
    image_path: str | None,
    *,
    dangling_screening: bool = False,
    review_id: str = REVIEW_ID,
    patient_id: str = "PT-TEST1",
    screening_id: str = SCREENING_ID,
) -> None:
    """Insert patient + screening + PENDING doctor_review rows into the
    fixture DB (raw SQL, mirroring test_retention's seeding style).
    review_id/patient_id/screening_id parametrized ONLY so multiple seedings
    can coexist in one module (task 4.1 multi-case tests); existing calls
    are unchanged (defaults preserve the original ids)."""
    from api import database

    now = datetime.now(timezone.utc).isoformat()
    conn = sqlite3.connect(database.DB_PATH)
    try:
        conn.execute(
            "INSERT INTO patients (patient_id, name, age, gender, created_at) "
            "VALUES (?, 'Marker Probe', 50, 'Male', ?)",
            (patient_id, now),
        )
        if not dangling_screening:
            conn.execute(
                "INSERT INTO screenings (screening_id, patient_id, eye_side, "
                "quality_grade, created_at, original_image_path) "
                "VALUES (?, ?, 'Right', 'GOOD', ?, ?)",
                (screening_id, patient_id, now, image_path),
            )
        conn.execute(
            "INSERT INTO doctor_reviews (review_id, screening_id, patient_id, "
            "status, created_at) VALUES (?, ?, ?, 'PENDING', ?)",
            (review_id, screening_id, patient_id, now),
        )
        conn.commit()
    finally:
        conn.close()


@pytest.fixture()
def review_env(monkeypatch):
    """Temp SQLite DB + temp image root; DB globals restored afterwards."""
    from api import database

    orig_path = database.DB_PATH
    orig_done = database._init_done
    monkeypatch.setenv("SEED_DEMO_DATA", "0")
    with tempfile.TemporaryDirectory(prefix="marker-svc-") as td:
        database.DB_PATH = os.path.join(td, "test.db")
        database._init_done = False
        database.init_db()
        yield td
    database.DB_PATH = orig_path
    database._init_done = orig_done


def _assert_unavailable(response: ReviewMarkersResponse) -> None:
    """Fail-closed shape: no coordinate values anywhere in the payload."""
    assert response.available is False
    assert isinstance(response.reason, str) and response.reason
    assert response.optic_disc is None
    assert response.fovea is None
    assert response.ma_candidates == []
    assert response.width == 0
    assert response.height == 0
    assert response.source == "classical_cv_segmentation"


def test_available_path_matches_direct_segmenter_output(review_env):
    """Req 1.1/1.2 + 2.1: on-demand segmentation maps the segmenter's real
    output faithfully (count + coordinate identity), never hardcoded."""
    image_path = _write_fundus_file(review_env)
    _seed_review_case(image_path)

    np_img = np.array(Image.open(image_path).convert("RGB"))
    direct = _get_segmenter().segment_structures(np_img)
    response = compute_review_markers(REVIEW_ID)

    assert response.available is True
    assert response.review_id == REVIEW_ID
    assert (response.width, response.height) == (np_img.shape[1], np_img.shape[0])
    assert response.source == "classical_cv_segmentation"

    od_x, od_y = direct.optic_disc_center
    if direct.optic_disc_radius > 0 and (od_x != 0 or od_y != 0):
        assert response.optic_disc is not None
        assert (response.optic_disc.x, response.optic_disc.y, response.optic_disc.r) == (
            int(od_x),
            int(od_y),
            int(direct.optic_disc_radius),
        )
    else:
        assert response.optic_disc is None

    fv_x, fv_y = direct.fovea_center
    if fv_x != 0 or fv_y != 0:
        assert response.fovea is not None
        assert (response.fovea.x, response.fovea.y) == (int(fv_x), int(fv_y))
    else:
        assert response.fovea is None

    assert len(response.ma_candidates) == len(direct.microaneurysm_candidates)
    for marker, (cx, cy, cr) in zip(response.ma_candidates, direct.microaneurysm_candidates):
        assert isinstance(marker.x, int) and isinstance(marker.y, int)
        assert isinstance(marker.r, int)
        assert (marker.x, marker.y, marker.r) == (int(cx), int(cy), int(cr))
        assert 0 <= marker.x < response.width
        assert 0 <= marker.y < response.height
        assert marker.r >= 0

    if not direct.microaneurysm_candidates:
        assert response.reason == "No microaneurysm candidates found"


def test_unknown_review_fails_closed(review_env):
    _assert_unavailable(compute_review_markers("REV-DOESNOTEXIST"))
    response = compute_review_markers("REV-DOESNOTEXIST")
    assert response.reason == "review case not found"


def test_review_with_missing_screening_row_fails_closed(review_env):
    _seed_review_case(None, dangling_screening=True)
    _assert_unavailable(compute_review_markers(REVIEW_ID))


def test_review_with_empty_image_path_fails_closed(review_env):
    _seed_review_case("")
    _assert_unavailable(compute_review_markers(REVIEW_ID))


def test_review_with_missing_image_file_fails_closed(review_env):
    _seed_review_case(os.path.join(review_env, "no_such_dir", "gone.jpg"))
    _assert_unavailable(compute_review_markers(REVIEW_ID))


def test_garbage_image_fails_closed(review_env):
    path = os.path.join(review_env, "garbage.jpg")
    with open(path, "wb") as fh:
        fh.write(b"this is not an image at all")
    _seed_review_case(path)
    _assert_unavailable(compute_review_markers(REVIEW_ID))


def test_oversize_header_fails_closed_before_pixel_decode(review_env):
    """Header dimension cap: a >4096px image is rejected before decode."""
    huge = np.zeros((10, 4097, 3), dtype=np.uint8)
    path = os.path.join(review_env, "wide.jpg")
    Image.fromarray(huge).save(path, quality=95)
    _seed_review_case(path)
    _assert_unavailable(compute_review_markers(REVIEW_ID))


def test_segmenter_exception_fails_closed(review_env, monkeypatch):
    from src.segmentation.structure_segmenter import RetinalStructureSegmenter

    image_path = _write_fundus_file(review_env)
    _seed_review_case(image_path)

    def _boom(self, np_img):
        raise RuntimeError("segmenter exploded")

    monkeypatch.setattr(RetinalStructureSegmenter, "segment_structures", _boom)
    _assert_unavailable(compute_review_markers(REVIEW_ID))


def test_payload_never_carries_mask_data(review_env):
    """Req 2.4: coordinates only — no mask/overlay/attention fields."""
    image_path = _write_fundus_file(review_env)
    _seed_review_case(image_path)
    dumped = compute_review_markers(REVIEW_ID).model_dump()
    for forbidden in (
        "vessel_mask",
        "exudate_mask",
        "annotated_overlay",
        "vessel_density_pct",
        "vessel_density_raw",
        "gradcam",
        "mask",
    ):
        assert forbidden not in dumped


# ---------------------------------------------------------------------------
# Task 4.1 additions: fabricated-marker guard, real-image smoke, determinism,
# provenance (Req 1.3, 1.4, 2.2, 7.1)
# ---------------------------------------------------------------------------


def test_every_fail_closed_case_carries_no_fabricated_marker(review_env):
    """Req 1.3/1.4: EVERY fail-closed mode — including paths only reachable
    with specific image content — produces no coordinate value at all.
    A single fabricated OD/fovea/candidate or non-zero dimension anywhere
    makes this fail; empty reasons make it fail."""
    unavailable = []
    for idx, (review_id, path) in enumerate(
        (
            ("REV-FAB-UNKNOWN", None),
            ("REV-FAB-DANGLING", "DANGLING"),
            ("REV-FAB-EMPTY", ""),
            ("REV-FAB-MISSING", "GONE"),
            ("REV-FAB-GARBAGE", "garbage"),
            ("REV-FAB-OVERSIZE", "oversize"),
            ("REV-FAB-TRUNCATED", "truncated"),
        ),
        start=1,
    ):
        patient_id = f"PT-FAB{idx}"
        screening_id = f"SCR-FAB{idx}"
        if path is None:
            _seed_review_case(
                None,
                dangling_screening=True,
                review_id=review_id,
                patient_id=patient_id,
                screening_id=screening_id,
            )
        elif path == "":
            _seed_review_case(
                "", review_id=review_id, patient_id=patient_id, screening_id=screening_id
            )
        elif path == "GONE":
            _seed_review_case(
                os.path.join(review_env, "no_dir", "gone.jpg"),
                review_id=review_id,
                patient_id=patient_id,
                screening_id=screening_id,
            )
        elif path == "garbage":
            p = os.path.join(review_env, "garbage.jpg")
            with open(p, "wb") as fh:
                fh.write(b"this is not an image at all")
            _seed_review_case(
                p, review_id=review_id, patient_id=patient_id, screening_id=screening_id
            )
        elif path == "oversize":
            p = os.path.join(review_env, "wide.jpg")
            Image.fromarray(np.zeros((10, 4097, 3), dtype=np.uint8)).save(p, quality=95)
            _seed_review_case(
                p, review_id=review_id, patient_id=patient_id, screening_id=screening_id
            )
        else:  # truncated: valid header, truncated pixel stream
            p = os.path.join(review_env, "truncated.jpg")
            full = os.path.join(tempfile.gettempdir(), "_full_probe.jpg")
            Image.fromarray(_synthetic_fundus_rgb()).save(full, quality=95)
            raw = Path(full).read_bytes()
            Path(p).write_bytes(raw[: len(raw) // 2])
            _seed_review_case(
                p, review_id=review_id, patient_id=patient_id, screening_id=screening_id
            )
        response = compute_review_markers(review_id)
        unavailable.append(response)
        _assert_unavailable(response)
        assert response.review_id == review_id
    assert len(unavailable) == 7

    # Distinct honest reasons, no "available but empty" conflation and no
    # misleading success reason leaking into a failed payload:
    reasons = {r.reason for r in unavailable}
    assert len(reasons) >= 4  # each mode states its own cause
    assert "No microaneurysm candidates found" not in reasons  # healthy-reason confusion


def test_truncated_pixel_data_fails_closed(review_env):
    """Decode-failure variant: valid JPEG header survives the pre-decode
    cap (=== passes the header check that 4097px fails), but the pixel
    stream is cut mid-file. Proves the decode step itself — not just the
    header sniff — fails closed."""
    full_path = os.path.join(tempfile.gettempdir(), "_marker_trunc_src.jpg")
    Image.fromarray(_synthetic_fundus_rgb()).save(full_path, quality=95)
    raw = Path(full_path).read_bytes()
    for idx, cut in enumerate((0.5, 0.01), start=1):
        path = os.path.join(review_env, f"trunc_{cut}.jpg")
        Path(path).write_bytes(raw[: int(len(raw) * cut)])
        _seed_review_case(
            path,
            review_id=f"REV-TRUNC{idx}",
            patient_id=f"PT-TRUNC{idx}",
            screening_id=f"SCR-TRUNC{idx}",
        )
        resp = compute_review_markers(f"REV-TRUNC{idx}")
        _assert_unavailable(resp)
        # Honest reason set: decode-tier reason OR the catch-all (both
        # true, non-empty, and never the healthy "no candidates" reason).
        assert resp.reason in (
            "fundus image could not be decoded",
            "marker computation failed",
        )


def test_available_payload_real_fundus_image_smoke(review_env):
    """Req 7.1: real production fundus image — segmentation succeeds and the
    payload structure is honest. Structure asserted, no coordinate values
    hardcoded; 0 MA candidates is a legitimate outcome on this image.
    Coordinates may sit up to min(W,H)//4 outside the canvas: the service
    passes segmenter output through (the painter owns OOB drop), so the
    honest bound is 'plausible CV output', not strict canvas clipping."""
    assert REAL_FUNDUS_JPG.is_file(), "repo real fundus demo image is missing"
    _seed_review_case(str(REAL_FUNDUS_JPG))

    response = compute_review_markers(REVIEW_ID)
    assert response.available is True, f"real-image degrade happened: {response.reason}"
    assert response.review_id == REVIEW_ID
    assert response.source == "classical_cv_segmentation"
    assert (response.width, response.height) == (512, 512)
    assert response.width > 0 and response.height > 0

    threshold = min(response.width, response.height) // 4
    if response.optic_disc is not None:
        od = response.optic_disc
        assert isinstance(od.x, int) and isinstance(od.y, int) and isinstance(od.r, int)
        assert od.r > 0
        assert -threshold <= od.x < response.width + threshold
        assert -threshold <= od.y < response.height + threshold
    if response.fovea is not None:
        fv = response.fovea
        assert isinstance(fv.x, int) and isinstance(fv.y, int)
        assert -threshold <= fv.x < response.width + threshold
        assert -threshold <= fv.y < response.height + threshold
    assert isinstance(response.ma_candidates, list)
    for cand in response.ma_candidates:
        assert isinstance(cand.x, int) and isinstance(cand.y, int) and isinstance(cand.r, int)
        assert cand.r >= 0
        assert -threshold <= cand.x < response.width + threshold
        assert -threshold <= cand.y < response.height + threshold


def test_two_consecutive_calls_are_identical(review_env):
    """Req 2.2 determinism: stable markers for the clinician — two calls on
    the same review give byte-identical payloads (proves no drift between
    calls, regression, or time/random dependence). Uses the REAL demo image
    so stability is proven on production-like pixels."""
    _seed_review_case(str(REAL_FUNDUS_JPG))
    second = compute_review_markers(REVIEW_ID)
    first = compute_review_markers(REVIEW_ID)
    assert first.model_dump() == second.model_dump()

    _seed_review_case(
        _write_fundus_file(review_env),
        review_id="REV-DET2",
        patient_id="PT-DET2",
        screening_id="SCR-DET2",
    )
    third = compute_review_markers("REV-DET2")
    fourth = compute_review_markers("REV-DET2")
    assert third.model_dump() == fourth.model_dump()
    # Independent review case on the synthetic file: available with the
    # decoded file's dimensions (640x480), proving stability is not an
    # artifact of the real image's warm caches.
    assert (third.width, third.height) == (W, H)
    assert third.available is True


@pytest.mark.parametrize(
    "label",
    [
        "available_path",
        "dangling_screening",
        "empty_path",
        "missing_file",
        "garbage",
        "oversize_header",
        "truncated_pixels",
        "segmenter_exception",
        "unavailable_helper_never_raises",
    ],
)
def test_source_provenance_pinned_in_available_and_unavailable(review_env, monkeypatch, label):
    """Req 2.2: provenance literal is pinned in BOTH payload shapes —
    available with real coordinates AND every unavailable reason."""
    if label == "available_path":
        _seed_review_case(_write_fundus_file(review_env))
        response = compute_review_markers(REVIEW_ID)
        assert response.available is True, f"synthetic fundus must be gradable: {response.reason}"
        assert response.source == "classical_cv_segmentation"
        return

    from src.segmentation.structure_segmenter import RetinalStructureSegmenter

    if label == "dangling_screening":
        _seed_review_case(None, dangling_screening=True)
    elif label == "empty_path":
        _seed_review_case("")
    elif label == "missing_file":
        _seed_review_case(os.path.join(review_env, "no_dir", "gone.jpg"))
    elif label == "garbage":
        p = os.path.join(review_env, "garbage.jpg")
        with open(p, "wb") as fh:
            fh.write(b"this is not an image at all")
        _seed_review_case(p)
    elif label == "oversize_header":
        p = os.path.join(review_env, "wide.jpg")
        Image.fromarray(np.zeros((10, 4097, 3), dtype=np.uint8)).save(p, quality=95)
        _seed_review_case(p)
    elif label == "truncated_pixels":
        p = os.path.join(review_env, "trunc.jpg")
        full = os.path.join(tempfile.gettempdir(), "prov_src.jpg")
        Image.fromarray(_synthetic_fundus_rgb()).save(full, quality=95)
        raw = Path(full).read_bytes()
        Path(p).write_bytes(raw[: len(raw) // 2])
        _seed_review_case(p)
    elif label == "segmenter_exception":
        _seed_review_case(_write_fundus_file(review_env))
        monkeypatch.setattr(
            RetinalStructureSegmenter,
            "segment_structures",
            lambda self, np_img: (_ for _ in ()).throw(RuntimeError("boom")),
        )
    elif label == "unavailable_helper_never_raises":
        response = compute_review_markers("REV-NOT-SEEDED")
        _assert_unavailable(response)
        assert response.source == "classical_cv_segmentation"
        return

    response = compute_review_markers(REVIEW_ID)
    _assert_unavailable(response)
    assert response.source == "classical_cv_segmentation"
