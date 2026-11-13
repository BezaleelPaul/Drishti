"""Integration tests for /sync/v2 â€” the de-identified sync contract (C-4).

Contract guarantees under test:
  1. clean pseudonymized payloads are stored (and idempotently replayed),
  2. ANY PHI field (name/phone/ABHA/village) rejects the WHOLE batch with
     422 PHI_REJECTED and persists nothing,
  3. unknown fields reject (pydantic extra=forbid + linter),
  4. value-level regex tripwires catch PHI hidden inside allowed fields,
  5. batch cap (>3 items) rejects,
  6. no PHI column exists in the deid_screenings store,
  7. rejections are audit-logged without echoing the offending values.
"""

from __future__ import annotations

import base64
import sqlite3

import pytest
from fastapi.testclient import TestClient

from api.main import app

client = TestClient(app, raise_server_exceptions=False)
OPERATOR_HEADERS = {"X-API-Key": "dev-operator-key"}
DOCTOR_HEADERS = {"X-API-Key": "dev-doctor-key"}


@pytest.fixture(autouse=True)
def _reset_rate_limiter():
    """This module makes ~30 requests against two keys; the sliding-window
    limiter (correctly) trips at 120/min per identity across the whole
    pytest session. Clear the buckets per-test so assertions exercise the
    contract, not the rate budget."""
    from api.main import app as _app
    from api.ratelimit import RateLimiter

    if _app.middleware_stack is None:
        _app.middleware_stack = _app.build_middleware_stack()
    mw = _app.middleware_stack
    while mw is not None:
        if isinstance(mw, RateLimiter):
            mw._hits.clear()
            break
        mw = getattr(mw, "app", None)
    yield


def _item(pseudo_id: str = "SCR-AAAA0001", **overrides) -> dict:
    base = {
        "pseudo_screening_id": pseudo_id,
        "pseudonym": "RSV-AB12CD34",
        "age_band": "40-49",
        "gender": "F",
        "eye_side": "Right",
        "dr_grade": 2,
        "dr_label": "Moderate NPDR",
        "probabilities": [0.05, 0.1, 0.6, 0.15, 0.1],
        "confidence": 0.6,
        "requires_human_review": True,
        "image_base64": None,
        "consent_version": "v1-2026-09",
        "captured_at": "2026-09-28T08:00:00Z",
    }
    base.update(overrides)
    return base


def _db_row_count(pseudo_id: str) -> int:
    from api.database import DB_PATH

    conn = sqlite3.connect(DB_PATH)
    try:
        cur = conn.execute(
            "SELECT COUNT(*) FROM deid_screenings WHERE pseudo_screening_id = ?",
            (pseudo_id,),
        )
        return int(cur.fetchone()[0])
    finally:
        conn.close()


def _jpeg_b64(size_hint: int = 64) -> str:
    from PIL import Image
    import io

    img = Image.new("RGB", (size_hint, size_hint), (150, 40, 40))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    return base64.b64encode(buf.getvalue()).decode()


def test_clean_payload_is_stored_and_replayed_idempotently():
    item = _item("SCR-INTEG0001", image_base64=_jpeg_b64())
    r1 = client.post("/sync/v2", headers=OPERATOR_HEADERS, json={"screenings": [item]})
    assert r1.status_code == 200, r1.text
    body = r1.json()
    assert body["total_synced"] == 1
    assert body["synced_pseudo_ids"] == ["SCR-INTEG0001"]
    assert _db_row_count("SCR-INTEG0001") == 1

    # Retry the exact same item: replay, still exactly one row.
    r2 = client.post("/sync/v2", headers=OPERATOR_HEADERS, json={"screenings": [item]})
    assert r2.status_code == 200
    assert r2.json()["total_synced"] == 1
    assert _db_row_count("SCR-INTEG0001") == 1


def _assert_rejected_with_field(r, field_hint: str) -> None:
    """422 either from pydantic extra=forbid (detail = error list with the
    field in loc) or from the PHI linter (detail.error == PHI_REJECTED).
    Either way the field must be named and the VALUE never echoed."""
    assert r.status_code == 422, r.text
    detail = r.json()["detail"]
    if isinstance(detail, list):
        # Pydantic path: loc ends with the offending field name.
        assert any(field_hint in str(err.get("loc", [])) for err in detail), (
            f"field {field_hint} not named in {detail}"
        )
    else:
        assert detail["error"] == "PHI_REJECTED"
        assert any(field_hint in v for v in detail["violations"])


def test_name_field_rejects_whole_batch_with_persisted_nothing():
    items = [
        _item("SCR-INTEG0002"),
        _item("SCR-INTEG0003", name="Sunita Bai"),  # PHI smuggled in
    ]
    r = client.post("/sync/v2", headers=OPERATOR_HEADERS, json={"screenings": items})
    _assert_rejected_with_field(r, "name")
    # Whole batch dropped: even the clean item is NOT stored.
    assert _db_row_count("SCR-INTEG0002") == 0
    assert _db_row_count("SCR-INTEG0003") == 0


def test_unknown_field_rejects_fail_closed():
    r = client.post(
        "/sync/v2",
        headers=OPERATOR_HEADERS,
        json={"screenings": [_item("SCR-INTEG0004", notes="free text")]},
    )
    assert r.status_code == 422
    # Pydantic extra=forbid fires before the route; either way: rejected.
    assert _db_row_count("SCR-INTEG0004") == 0


def test_phone_inside_pseudonym_is_caught_by_regex_tripwire():
    r = client.post(
        "/sync/v2",
        headers=OPERATOR_HEADERS,
        json={
            "screenings": [
                _item("SCR-INTEG0005", pseudonym="RSV-9876543210"),
            ]
        },
    )
    assert r.status_code == 422
    detail = r.json()["detail"]
    assert detail["error"] == "PHI_REJECTED"
    assert any("MOBILE" in v for v in detail["violations"])
    assert _db_row_count("SCR-INTEG0005") == 0


def test_abha_pattern_inside_captured_at_is_caught():
    r = client.post(
        "/sync/v2",
        headers=OPERATOR_HEADERS,
        json={
            "screenings": [
                _item("SCR-INTEG0006", captured_at="12-3456-7890-1234"),
            ]
        },
    )
    assert r.status_code == 422
    assert any("ABHA" in v for v in r.json()["detail"]["violations"])


def test_salutation_name_pattern_is_caught():
    r = client.post(
        "/sync/v2",
        headers=OPERATOR_HEADERS,
        json={
            "screenings": [
                _item("SCR-INTEG0007", dr_label="Severe NPDR - see Dr. Raman"),
            ]
        },
    )
    assert r.status_code == 422
    assert any("SALUTATION" in v for v in r.json()["detail"]["violations"])


def test_batch_cap_three_items():
    items = [_item(f"SCR-INTEGCAP{i}") for i in range(4)]
    r = client.post("/sync/v2", headers=OPERATOR_HEADERS, json={"screenings": items})
    assert r.status_code == 422


def test_violation_echoes_codes_never_values():
    r = client.post(
        "/sync/v2",
        headers=OPERATOR_HEADERS,
        json={"screenings": [_item("SCR-INTEG0008", name="Secret Patient Name")]},
    )
    _assert_rejected_with_field(r, "name")
    # The offending VALUE must never appear in the response body — this
    # holds for the linter path AND the pydantic extra=forbid path (whose
    # default body echoes `input`; the app redacts it globally, C-4).
    assert "Secret Patient Name" not in r.text


def test_deid_store_has_no_phi_columns():
    from api.database import DB_PATH

    conn = sqlite3.connect(DB_PATH)
    try:
        cur = conn.execute("PRAGMA table_info(deid_screenings)")
        columns = {row[1] for row in cur.fetchall()}
    finally:
        conn.close()
    forbidden = {"name", "phone", "abha_id", "village", "patient_id", "address"}
    assert columns.isdisjoint(forbidden), f"PHI columns present: {columns & forbidden}"


def test_rejection_is_audit_logged_without_values():
    from api.database import DB_PATH

    client.post(
        "/sync/v2",
        headers=OPERATOR_HEADERS,
        json={"screenings": [_item("SCR-INTEG0009", name="Very Secret Name")]},
    )
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        cur = conn.execute(
            "SELECT detail FROM audit_log WHERE action = 'deid_sync_rejected' "
            "ORDER BY id DESC LIMIT 1"
        )
        row = cur.fetchone()
    finally:
        conn.close()
    assert row is not None
    assert "Very Secret Name" not in (row["detail"] or "")


@pytest.mark.parametrize(
    "field",
    ["name", "phone", "abha_id", "village", "patient_id", "operator_name"],
)
def test_every_known_phi_field_is_rejected(field: str):
    pseudo = f"SCR-INTEGPHI{field[:4].upper()}"
    r = client.post(
        "/sync/v2",
        headers=OPERATOR_HEADERS,
        json={"screenings": [_item(pseudo, **{field: "PHI-VALUE"})]},
    )
    assert r.status_code == 422, f"{field} was not rejected: {r.text}"
    assert _db_row_count(pseudo) == 0


# -----------------------------------------------------------------------------
# Doctor visibility (D-2 close-out): the referral queue is reachable by the
# ophthalmologist console and by NOBODY else.
# -----------------------------------------------------------------------------

DOCTOR_HEADERS = {"X-API-Key": "dev-doctor-key"}


def test_doctor_sees_uploaded_referral_in_pending_queue():
    item = _item("SCR-INTEGDR01", image_base64=_jpeg_b64())
    r_post = client.post("/sync/v2", headers=OPERATOR_HEADERS, json={"screenings": [item]})
    assert r_post.status_code == 200, r_post.text

    r = client.get("/sync/v2/pending", headers=DOCTOR_HEADERS)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["count"] >= 1
    match = [i for i in body["items"] if i["pseudo_screening_id"] == "SCR-INTEGDR01"]
    assert match, "uploaded referral not visible to the doctor"
    row = match[0]
    # The doctor sees pseudonymized context, never identity.
    assert row["pseudonym"] == "RSV-AB12CD34"
    assert row["dr_grade"] == 2
    assert row["requires_human_review"] is True
    assert row["has_image"] is True
    forbidden = {"name", "phone", "abha_id", "village", "patient_id"}
    assert row.keys().isdisjoint(forbidden)


def test_operator_cannot_enumerate_the_referral_queue():
    r = client.get("/sync/v2/pending", headers=OPERATOR_HEADERS)
    assert r.status_code == 403


def test_doctor_fetches_the_deidentified_image_roundtrip():
    jpeg_b64 = _jpeg_b64(48)
    item = _item("SCR-INTEGDR02", image_base64=jpeg_b64)
    r_post = client.post("/sync/v2", headers=OPERATOR_HEADERS, json={"screenings": [item]})
    assert r_post.status_code == 200

    r = client.get("/sync/v2/image/SCR-INTEGDR02", headers=DOCTOR_HEADERS)
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("image/jpeg")
    # Bytes must round-trip exactly: the doctor grades what the phone sent.
    assert base64.b64decode(jpeg_b64) == r.content


def test_missing_image_returns_404_for_doctor():
    r = client.get("/sync/v2/image/SCR-DOESNOTEXIST", headers=DOCTOR_HEADERS)
    assert r.status_code == 404
