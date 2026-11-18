"""Integration tests: specialist application + admin approval workflow
(T5-T8) and its effect on issued roles.

The Google verifier is monkeypatched; no network or real tokens involved.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

import api.database as database
from api.app_jwt import decode_app_token
from api.google_auth import GoogleIdentity
from api.main import app
from api.routes import auth as auth_routes

client = TestClient(app)

SECRET = "workflow-secret-that-is-long-enough-0123456789"

VALID_APPLICATION = {
    "full_name": "Dr Asha Rao",
    "council_reg_no": "KMC/12345",
    "specialty": "Ophthalmology",
}


@pytest.fixture(autouse=True)
def _isolated(tmp_path, monkeypatch):
    monkeypatch.setattr(database, "DB_PATH", str(tmp_path / "specialists_test.db"))
    monkeypatch.setenv("DRISHTI_JWT_SECRET", SECRET)
    monkeypatch.setenv("DRISHTI_HUMAN_AUTH", "1")
    monkeypatch.setenv("DRISHTI_GOOGLE_CLIENT_IDS", "test-client.apps.googleusercontent.com")
    monkeypatch.setenv("DRISHTI_ADMIN_EMAILS", "chief@hospital.org")
    monkeypatch.delenv("ENV", raising=False)
    yield


def _session(email: str, monkeypatch) -> str:
    monkeypatch.setattr(
        auth_routes,
        "verify_google_id_token",
        lambda token: GoogleIdentity(subject="sub", email=email),
    )
    response = client.post("/auth/google", json={"id_token": "x" * 40})
    assert response.status_code == 200, response.text
    return response.json()["access_token"]


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _apply(token: str, payload: dict | None = None):
    return client.post("/specialists/apply", json=payload or VALID_APPLICATION, headers=_auth(token))


class TestApplicationSubmission:
    def test_application_creates_pending_record(self, monkeypatch) -> None:
        token = _session("newdoc@example.org", monkeypatch)
        response = _apply(token)
        assert response.status_code == 201, response.text
        body = response.json()
        assert body["status"] == "pending"
        assert body["email"] == "newdoc@example.org"
        assert body["council_reg_no"] == "KMC/12345"
        assert body["decided_at"] is None

    def test_duplicate_open_application_conflicts(self, monkeypatch) -> None:
        token = _session("dupe@example.org", monkeypatch)
        assert _apply(token).status_code == 201
        second = _apply(token)
        assert second.status_code == 409
        assert "awaiting review" in second.json()["detail"]

    def test_approved_specialist_cannot_reapply(self, monkeypatch) -> None:
        token = _session("approved@example.org", monkeypatch)
        assert _apply(token).status_code == 201
        admin = _session("chief@hospital.org", monkeypatch)
        listing = client.get("/admin/specialists?status=pending", headers=_auth(admin)).json()
        application_id = next(a["id"] for a in listing if a["email"] == "approved@example.org")
        assert (
            client.post(
                f"/admin/specialists/{application_id}/decide",
                json={"decision": "approve"},
                headers=_auth(admin),
            ).status_code
            == 200
        )
        again = _apply(token)
        assert again.status_code == 409
        assert "already" in again.json()["detail"].lower()

    def test_validation_rejects_bad_payloads(self, monkeypatch) -> None:
        token = _session("validator@example.org", monkeypatch)
        cases = [
            {"full_name": "A", "council_reg_no": "KMC/1", "specialty": "Ophthalmology"},
            {"full_name": "Dr X", "council_reg_no": "!", "specialty": "Ophthalmology"},
            {"full_name": "Dr X", "council_reg_no": "KMC/123", "specialty": " "},
            {"council_reg_no": "KMC/123", "specialty": "Ophthalmology"},
        ]
        for payload in cases:
            assert _apply(token, payload).status_code == 422, payload

    def test_api_key_cannot_apply(self) -> None:
        response = client.post(
            "/specialists/apply",
            json=VALID_APPLICATION,
            headers={"X-API-Key": "dev-operator-key"},
        )
        assert response.status_code == 403
        assert "human session" in response.json()["detail"]

    def test_feature_off_hides_workflow(self, monkeypatch) -> None:
        monkeypatch.delenv("DRISHTI_HUMAN_AUTH", raising=False)
        assert client.post("/specialists/apply", json=VALID_APPLICATION).status_code == 404
        assert client.get("/admin/specialists").status_code == 404


class TestMyApplication:
    def test_reports_none_before_applying(self, monkeypatch) -> None:
        token = _session("fresh@example.org", monkeypatch)
        body = client.get("/specialists/me", headers=_auth(token)).json()
        assert body == {"application": None, "can_reapply_at": None}

    def test_reports_pending_state(self, monkeypatch) -> None:
        token = _session("pending@example.org", monkeypatch)
        _apply(token)
        body = client.get("/specialists/me", headers=_auth(token)).json()
        assert body["application"]["status"] == "pending"


class TestAdminDecisions:
    def test_admin_lists_pending_by_default_filter(self, monkeypatch) -> None:
        user = _session("candidate@example.org", monkeypatch)
        _apply(user)
        admin = _session("chief@hospital.org", monkeypatch)
        listing = client.get("/admin/specialists?status=pending", headers=_auth(admin))
        assert listing.status_code == 200
        emails = [row["email"] for row in listing.json()]
        assert "candidate@example.org" in emails

    def test_non_admin_cannot_list_or_decide(self, monkeypatch) -> None:
        user = _session("notadmin@example.org", monkeypatch)
        _apply(user)
        listing = client.get("/admin/specialists", headers=_auth(user))
        assert listing.status_code == 403
        decision = client.post(
            "/admin/specialists/1/decide", json={"decision": "approve"}, headers=_auth(user)
        )
        assert decision.status_code == 403

    def test_approval_upgrades_next_session_to_doctor(self, monkeypatch) -> None:
        applicant = _session("future-doctor@example.org", monkeypatch)
        before = decode_app_token(applicant)
        assert before.role == "operator"
        _apply(applicant)

        admin = _session("chief@hospital.org", monkeypatch)
        listing = client.get("/admin/specialists?status=pending", headers=_auth(admin)).json()
        application_id = next(a["id"] for a in listing if a["email"] == "future-doctor@example.org")
        decided = client.post(
            f"/admin/specialists/{application_id}/decide",
            json={"decision": "approve", "note": "Verified registration"},
            headers=_auth(admin),
        )
        assert decided.status_code == 200
        assert decided.json()["status"] == "approved"
        assert decided.json()["decided_by"].startswith("user:chief@hospital.org")

        refreshed = _session("future-doctor@example.org", monkeypatch)
        claims = decode_app_token(refreshed)
        assert claims.role == "doctor"
        assert claims.specialist_status == "approved"

    def test_rejection_blocks_resubmission_during_cooldown(self, monkeypatch) -> None:
        applicant = _session("rejected@example.org", monkeypatch)
        _apply(applicant)
        admin = _session("chief@hospital.org", monkeypatch)
        listing = client.get("/admin/specialists?status=pending", headers=_auth(admin)).json()
        application_id = next(a["id"] for a in listing if a["email"] == "rejected@example.org")
        client.post(
            f"/admin/specialists/{application_id}/decide",
            json={"decision": "reject", "note": "License unreadable"},
            headers=_auth(admin),
        )

        retry = _apply(applicant)
        assert retry.status_code == 429
        assert "Re-application is available after" in retry.json()["detail"]

        me = client.get("/specialists/me", headers=_auth(applicant)).json()
        assert me["application"]["status"] == "rejected"
        assert me["can_reapply_at"] is not None

    def test_cannot_decide_closed_application_twice(self, monkeypatch) -> None:
        applicant = _session("twice@example.org", monkeypatch)
        _apply(applicant)
        admin = _session("chief@hospital.org", monkeypatch)
        listing = client.get("/admin/specialists?status=pending", headers=_auth(admin)).json()
        application_id = next(a["id"] for a in listing if a["email"] == "twice@example.org")
        first = client.post(
            f"/admin/specialists/{application_id}/decide",
            json={"decision": "approve"},
            headers=_auth(admin),
        )
        assert first.status_code == 200
        second = client.post(
            f"/admin/specialists/{application_id}/decide",
            json={"decision": "reject"},
            headers=_auth(admin),
        )
        assert second.status_code == 409

    def test_unknown_application_is_404(self, monkeypatch) -> None:
        admin = _session("chief@hospital.org", monkeypatch)
        response = client.post(
            "/admin/specialists/99999/decide",
            json={"decision": "approve"},
            headers=_auth(admin),
        )
        assert response.status_code == 404

    def test_api_key_admin_can_review(self, monkeypatch) -> None:
        """Machine admins keep working (existing deployment path)."""
        applicant = _session("via-key@example.org", monkeypatch)
        _apply(applicant)
        listing = client.get(
            "/admin/specialists?status=pending", headers={"X-API-Key": "dev-admin-key"}
        )
        assert listing.status_code == 200


class TestAuditTrail:
    def test_apply_and_decide_are_audited(self, monkeypatch) -> None:
        applicant = _session("audited@example.org", monkeypatch)
        _apply(applicant)
        admin = _session("chief@hospital.org", monkeypatch)
        listing = client.get("/admin/specialists?status=pending", headers=_auth(admin)).json()
        application_id = next(a["id"] for a in listing if a["email"] == "audited@example.org")
        client.post(
            f"/admin/specialists/{application_id}/decide",
            json={"decision": "approve"},
            headers=_auth(admin),
        )

        from api.database import get_connection

        conn = get_connection()
        try:
            actions = [
                row["action"]
                for row in conn.execute("SELECT action FROM audit_log ORDER BY id").fetchall()
            ]
        finally:
            conn.close()
        assert "specialist.apply" in actions
        assert "specialist.decide" in actions
