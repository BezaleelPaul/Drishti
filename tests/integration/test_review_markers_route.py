"""Integration tests for GET /review/{review_id}/markers (task 2.2).

Covers the MarkerRoute API contract (design.md: 200 marker payload, 404
unknown review, 401/403 auth, 200-unavailable on segmentation failure) and
the audit-trail behaviour for reads and misses.

Design decision (documented per spec): the route PRE-CHECKS the review case
(Option A) — a strict review-id format check plus a `SELECT 1 FROM
doctor_reviews` lookup — and raises 404 itself. The marker service stays
fail-closed for any TOCTOU race (row deleted between pre-check and compute),
so no typed exception had to be added to marker_service.
"""

import os
import shutil
import sqlite3
import tempfile
from datetime import datetime, timezone

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from api import database
from api.main import app

client = TestClient(app, raise_server_exceptions=False)
DOCTOR_HEADERS = {"X-API-Key": "dev-doctor-key"}
OPERATOR_HEADERS = {"X-API-Key": "dev-operator-key"}
ADMIN_HEADERS = {"X-API-Key": "dev-admin-key"}

_DEMO_GOOD_IMAGE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..",
    "..",
    "demo",
    "sample_images",
    "scenario_1_good.jpg",
)

W, H = 640, 480
REVIEW_ID = "REV-ROUTE1"
SCREENING_ID = "SCR-ROUTE1"
MA_DOTS = (
    (430, 310),
    (350, 340),
    (440, 160),
    (300, 150),
    (500, 260),
    (260, 350),
    (390, 120),
)

EXPECTED_KEYS = {
    "review_id",
    "available",
    "reason",
    "source",
    "width",
    "height",
    "optic_disc",
    "fovea",
    "ma_candidates",
    # Evidence-linked extension (schema_version 1.0): optional fields that are
    # always emitted on available payloads (legacy fallback emits the legacy
    # key set only).
    "schema_version",
    "lesion_evidence",
    "criteria_evaluation",
    "grading_policy",
    "disagreement",
}


def _synthetic_fundus_rgb() -> np.ndarray:
    """Black background, bright red fundus disc, darker vessel strokes,
    small dark-red MA-like dots — the same REAL segmenter exercise used by
    tests/unit/test_review_markers_service.py."""
    img = np.zeros((H, W, 3), dtype=np.uint8)
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


def _seed_review_case(image_path: str | None, quality_grade: str = "GOOD") -> None:
    """Seed a patient + screening (with the GIVEN quality grade — the marker
    route must be grade-blind) + a pending doctor review for it."""
    now = datetime.now(timezone.utc).isoformat()
    conn = sqlite3.connect(database.DB_PATH)
    try:
        conn.execute(
            "INSERT INTO patients (patient_id, name, age, gender, created_at) "
            "VALUES ('PT-ROUTE1', 'Marker Route Probe', 50, 'Male', ?)",
            (now,),
        )
        conn.execute(
            "INSERT INTO screenings (screening_id, patient_id, eye_side, "
            "quality_grade, created_at, original_image_path) "
            "VALUES (?, 'PT-ROUTE1', 'Right', ?, ?, ?)",
            (SCREENING_ID, quality_grade, now, image_path),
        )
        conn.execute(
            "INSERT INTO doctor_reviews (review_id, screening_id, patient_id, "
            "status, created_at) VALUES (?, ?, 'PT-ROUTE1', 'PENDING', ?)",
            (REVIEW_ID, SCREENING_ID, now),
        )
        conn.commit()
    finally:
        conn.close()


@pytest.fixture()
def review_env(monkeypatch):
    """Temp SQLite DB + temp image root; DB globals restored afterwards."""
    orig_path = database.DB_PATH
    orig_done = database._init_done
    monkeypatch.setenv("SEED_DEMO_DATA", "0")
    with tempfile.TemporaryDirectory(prefix="marker-route-") as td:
        database.DB_PATH = os.path.join(td, "test.db")
        database._init_done = False
        database.init_db()
        yield td
    database.DB_PATH = orig_path
    database._init_done = orig_done


def _audit_rows(action: str) -> list[sqlite3.Row]:
    conn = sqlite3.connect(database.DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute(
            "SELECT actor, action, resource, detail FROM audit_log WHERE action = ?",
            (action,),
        ).fetchall()
    finally:
        conn.close()


def test_doctor_key_gets_marker_payload_for_seeded_case(review_env):
    """Req 1.1/6.3: doctor key -> 200 payload with dimensions, coordinates
    only (no mask keys), provenance pinned, and a read audit row."""
    image_path = _write_fundus_file(review_env)
    _seed_review_case(image_path)

    response = client.get(f"/review/{REVIEW_ID}/markers", headers=DOCTOR_HEADERS)

    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body.keys()) == EXPECTED_KEYS
    assert body["review_id"] == REVIEW_ID
    assert body["available"] is True
    assert body["source"] == "classical_cv_segmentation"
    assert (body["width"], body["height"]) == (W, H)
    for marker in body["ma_candidates"]:
        assert isinstance(marker["x"], int) and isinstance(marker["y"], int)
        assert isinstance(marker["r"], int) and marker["r"] >= 0
        assert 0 <= marker["x"] < W
        assert 0 <= marker["y"] < H
    assert len(body["ma_candidates"]) == len(MA_DOTS)

    reads = _audit_rows("review_markers_read")
    assert len(reads) == 1
    assert reads[0]["resource"] == REVIEW_ID
    assert SCREENING_ID in reads[0]["detail"]
    assert reads[0]["actor"].startswith("doctor:")


def test_unknown_review_returns_404(review_env):
    _seed_review_case(None)

    response = client.get("/review/REV-NOEXIST/markers", headers=DOCTOR_HEADERS)

    assert response.status_code == 404, response.text
    assert "not found" in response.json()["detail"].lower()
    assert len(_audit_rows("review_markers_read_404")) == 1


def test_missing_auth_header_returns_401(review_env):
    response = client.get(f"/review/{REVIEW_ID}/markers")

    assert response.status_code == 401, response.text


def test_operator_key_returns_403(review_env):
    image_path = _write_fundus_file(review_env)
    _seed_review_case(image_path)

    response = client.get(f"/review/{REVIEW_ID}/markers", headers=OPERATOR_HEADERS)

    assert response.status_code == 403, response.text
    assert _audit_rows("review_markers_read") == []


def test_invalid_review_id_format_returns_404(review_env):
    """Invalid format NEVER exists -> uniform 404 without leaking the
    expected format in the message."""
    for junk in ("REV-SHORT", "garbage123", "%20%2e%2e"):
        response = client.get(f"/review/{junk}/markers", headers=DOCTOR_HEADERS)
        assert response.status_code == 404, (junk, response.text)
        assert response.json()["detail"] == "Review case not found."


def test_path_traversal_attempts_return_404_and_audit(review_env):
    """Traversal that survives client-side URL normalisation lands in the
    path param, fails the format check, is audited, and never touches the
    filesystem or DB. A %2F form decodes to a slash and is rejected one
    layer earlier by routing itself — still a 404, but no handler audit."""
    for injected in ("%2e%2e", "%20%2e%2e"):
        response = client.get(f"/review/{injected}/markers", headers=DOCTOR_HEADERS)
        assert response.status_code == 404, (injected, response.text)
    assert len(_audit_rows("review_markers_read_404")) == 2
    response = client.get("/review/..%2Fetc%2Fpasswd/markers", headers=DOCTOR_HEADERS)
    assert response.status_code == 404, response.text


def test_segmentation_failure_is_200_unavailable_not_5xx(review_env, monkeypatch):
    """Design contract: a segmentation failure is a SUCCESSFUL response
    carrying an unavailable payload, never a server error."""
    from src.segmentation.structure_segmenter import RetinalStructureSegmenter

    image_path = _write_fundus_file(review_env)
    _seed_review_case(image_path)

    def _boom(self, np_img):
        raise RuntimeError("segmenter exploded")

    monkeypatch.setattr(RetinalStructureSegmenter, "segment_structures", _boom)
    response = client.get(f"/review/{REVIEW_ID}/markers", headers=DOCTOR_HEADERS)

    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body.keys()) == EXPECTED_KEYS
    assert body["available"] is False
    assert isinstance(body["reason"], str) and body["reason"]
    assert body["source"] == "classical_cv_segmentation"
    assert body["width"] == 0 and body["height"] == 0
    assert body["optic_disc"] is None and body["fovea"] is None
    assert body["ma_candidates"] == []


def _copy_demo_good_image(root: str, screening_id: str = SCREENING_ID) -> str:
    """Copy the REAL demo fundus photo into the temp image root so the test
    exercises an actual photograph (not the synthetic segmenter exercise)."""
    folder = os.path.join(root, "results", "api_screenings", screening_id)
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{screening_id}_orig.jpg")
    shutil.copyfile(_DEMO_GOOD_IMAGE, path)
    return path


def _assert_grade_blind_available(body: dict) -> None:
    """Shared honesty assertions for the Req 1.2 grade-independence proof.

    The segmenter on the real demo photo finds the optic disc and fovea but
    ZERO microaneurysm candidates; per the service's honesty mapping an
    empty `ma_candidates` list with available=True means "computed, none
    found" — a different state from available=False (not computed).
    """
    assert body["available"] is True
    assert (body["width"], body["height"]) == (512, 512)
    assert body["optic_disc"] is not None and body["optic_disc"]["r"] > 0
    assert body["fovea"] is not None
    assert body["ma_candidates"] == []
    assert body["reason"] == "No microaneurysm candidates found"


# Code-change falsifier: if compute_review_markers ever becomes
# BORDERLINE-only again (e.g. a grade gate or a precomputed-caches-only
# path is reintroduced, like the historical router gap at
# src/pipeline/router.py:163), both of these tests
# swing to available=False with a "path/decode" style reason and FAIL.


def test_good_quality_case_gets_markers_on_demand(review_env):
    """Req 1.2 proof: a quality-passed (GOOD, NOT BORDERLINE) review case
    still gets markers computed on demand from the stored image. Passing
    proves the route does NOT depend on the BORDERLINE-only reassessment
    branch (the historical gap this feature closes)."""
    image_path = _copy_demo_good_image(review_env)
    _seed_review_case(image_path, quality_grade="GOOD")

    first = client.get(f"/review/{REVIEW_ID}/markers", headers=DOCTOR_HEADERS)
    assert first.status_code == 200, first.text
    body = first.json()
    assert set(body.keys()) == EXPECTED_KEYS
    assert first.json() == body
    _assert_grade_blind_available(body)

    # Idempotent read: the same case yields an identical payload on a
    # second GET (design MarkerRoute contract: advisory deterministic read).
    second = client.get(f"/review/{REVIEW_ID}/markers", headers=DOCTOR_HEADERS)
    assert second.status_code == 200, second.text
    assert second.json() == body

    reads = _audit_rows("review_markers_read")
    assert len(reads) == 2
    assert all(r["actor"].startswith("doctor:") for r in reads)


def test_borderline_quality_case_also_gets_markers(review_env):
    """Completes the grade-independence proof: the BORDERLINE grade produces
    markers too — segment() quality grade does not change the marker route
    (Req 1.2). Any grade difference in outcome would falsify this test."""
    image_path = _copy_demo_good_image(review_env)
    _seed_review_case(image_path, quality_grade="BORDERLINE")

    response = client.get(f"/review/{REVIEW_ID}/markers", headers=DOCTOR_HEADERS)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["available"] is True
    _assert_grade_blind_available(body)


def test_admin_key_is_accepted_by_require_doctor(review_env):
    """Auth matrix (honest to require_doctor semantics): the role hierarchy
    ranks admin >= doctor, so require_role('doctor','admin') ACCEPTS an
    admin key. Read audit proves the real handler ran (not just auth)."""
    image_path = _write_fundus_file(review_env)
    _seed_review_case(image_path)

    response = client.get(f"/review/{REVIEW_ID}/markers", headers=ADMIN_HEADERS)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["available"] is True
    reads = _audit_rows("review_markers_read")
    assert len(reads) == 1
    assert reads[0]["actor"].startswith("admin:")


def test_absurdly_long_format_valid_review_id_is_clean_404(review_env):
    """Abuse surface (read-only sanity): 'REV-' + 200 A's is format-VALID
    (regex allows {6,}) so it reaches the DB pre-check — but nothing has
    that id. Current behavior: clean uniform 404, handler miss audited,
    and no crash. A future length cap would turn this into a
    format-reject 404 BEFORE the DB lookup — still 404, still audited,
    so this test must stay green either way."""
    long_id = "REV-" + "A" * 200
    _seed_review_case(None)

    response = client.get(f"/review/{long_id}/markers", headers=DOCTOR_HEADERS)

    assert response.status_code == 404, response.text
    assert "not found" in response.json()["detail"].lower()
    assert len(_audit_rows("review_markers_read_404")) == 1
