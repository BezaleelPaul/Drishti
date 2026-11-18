"""Integration tests: POST /auth/google and role assignment (T3).

The Google verifier is monkeypatched — no network, no real tokens. These
tests assert the *Drishti* trust rules (allowlist, specialist status,
feature flag, session shape), not Google's cryptography.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import api.database as database
from api.app_jwt import decode_app_token
from api.google_auth import GoogleIdentity, GoogleTokenError
from api.main import app
from api.routes import auth as auth_routes

client = TestClient(app)

SECRET = "integration-secret-that-is-long-enough-0123456789"


@pytest.fixture(autouse=True)
def _isolated(tmp_path, monkeypatch):
    monkeypatch.setattr(database, "DB_PATH", str(tmp_path / "auth_test.db"))
    monkeypatch.setenv("DRISHTI_JWT_SECRET", SECRET)
    monkeypatch.setenv("DRISHTI_HUMAN_AUTH", "1")
    monkeypatch.setenv("DRISHTI_GOOGLE_CLIENT_IDS", "test-client.apps.googleusercontent.com")
    monkeypatch.setenv("DRISHTI_ADMIN_EMAILS", "Chief@Hospital.org")
    monkeypatch.delenv("ENV", raising=False)
    yield


def _sign_in_as(email: str, monkeypatch, *, verified: bool = True) -> dict:
    def _verify(token: str):
        if not verified:
            raise GoogleTokenError("token verification failed")
        return GoogleIdentity(subject="google-sub", email=email)

    monkeypatch.setattr(auth_routes, "verify_google_id_token", _verify)
    response = client.post("/auth/google", json={"id_token": "x" * 40})
    return response


def _insert_application(email: str, status: str) -> None:
    from api.database import get_connection

    conn = get_connection()
    try:
        from api.specialists import ensure_schema

        ensure_schema(conn)
        conn.execute(
            "INSERT INTO specialist_applications "
            "(email, full_name, council_reg_no, specialty, status, submitted_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (email.lower(), "Test Doctor", "KMC-12345", "Ophthalmology", status, "2026-11-18T00:00:00Z"),
        )
        conn.commit()
    finally:
        conn.close()


class TestFeatureFlag:
    def test_disabled_by_default(self, monkeypatch) -> None:
        monkeypatch.delenv("DRISHTI_HUMAN_AUTH", raising=False)
        response = client.post("/auth/google", json={"id_token": "x" * 40})
        assert response.status_code == 404

    def test_auth_me_also_disabled(self, monkeypatch) -> None:
        monkeypatch.delenv("DRISHTI_HUMAN_AUTH", raising=False)
        assert client.get("/auth/me", headers={"X-API-Key": "dev-operator-key"}).status_code == 404


class TestRoleAssignment:
    def test_admin_allowlist_grants_admin(self, monkeypatch) -> None:
        response = _sign_in_as("chief@hospital.org", monkeypatch)
        assert response.status_code == 200
        body = response.json()
        assert body["role"] == "admin"
        assert body["email"] == "chief@hospital.org"
        assert body["specialist_status"] == "approved"

    def test_approved_specialist_gets_doctor(self, monkeypatch) -> None:
        _insert_application("doc@example.org", "approved")
        body = _sign_in_as("doc@example.org", monkeypatch).json()
        assert body["role"] == "doctor"
        assert body["specialist_status"] == "approved"

    def test_pending_specialist_stays_operator(self, monkeypatch) -> None:
        _insert_application("pending@example.org", "pending")
        body = _sign_in_as("pending@example.org", monkeypatch).json()
        assert body["role"] == "operator"
        assert body["specialist_status"] == "pending"

    def test_unknown_user_becomes_operator(self, monkeypatch) -> None:
        body = _sign_in_as("stranger@example.org", monkeypatch).json()
        assert body["role"] == "operator"
        assert body["specialist_status"] is None

    def test_rejected_specialist_stays_operator(self, monkeypatch) -> None:
        _insert_application("rejected@example.org", "rejected")
        body = _sign_in_as("rejected@example.org", monkeypatch).json()
        assert body["role"] == "operator"
        assert body["specialist_status"] == "rejected"


class TestTokenShape:
    def test_session_token_decodes_and_carries_role(self, monkeypatch) -> None:
        body = _sign_in_as("doc@example.org", monkeypatch).json()
        claims = decode_app_token(body["access_token"])
        assert claims.role == "operator"  # no application: honest default
        assert body["token_type"] == "bearer"
        assert 0 < body["expires_in"] <= 3600

    def test_invalid_google_token_is_401(self, monkeypatch) -> None:
        response = _sign_in_as("x@example.org", monkeypatch, verified=False)
        assert response.status_code == 401
        assert "access_token" not in response.json()

    def test_malformed_request_is_422(self) -> None:
        assert client.post("/auth/google", json={"id_token": "short"}).status_code == 422
        assert client.post("/auth/google", json={}).status_code == 422

    def test_audit_records_identity_issuance(self, monkeypatch) -> None:
        _sign_in_as("audit@example.org", monkeypatch)
        from api.database import get_connection

        conn = get_connection()
        try:
            rows = conn.execute(
                "SELECT action, actor FROM audit_log WHERE action = 'auth.issue'"
            ).fetchall()
        finally:
            conn.close()
        assert rows, "auth.issue must be audited"
        assert rows[-1]["actor"] == "user:audit@example.org"


class TestWhoAmI:
    def test_bearer_session_identifies_caller(self, monkeypatch) -> None:
        token = _sign_in_as("chief@hospital.org", monkeypatch).json()["access_token"]
        response = client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 200
        assert response.json()["role"] == "admin"

    def test_api_key_is_not_a_human_session(self) -> None:
        response = client.get("/auth/me", headers={"X-API-Key": "dev-admin-key"})
        assert response.status_code == 403

    def test_no_credentials_is_401(self) -> None:
        assert client.get("/auth/me").status_code == 401
