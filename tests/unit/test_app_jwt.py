"""Unit tests: app session tokens and dual-credential principals (T1, T3)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import jwt
import pytest
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from api import app_jwt
from api.app_jwt import (
    JWT_AUDIENCE,
    JWT_ISSUER,
    InvalidAppTokenError,
    decode_app_token,
    issue_app_token,
)
from api.auth import ApiPrincipal, authenticate, resolve_privileged_role

SECRET = "unit-test-secret-that-is-long-enough-0123456789"


@pytest.fixture(autouse=True)
def _secret(monkeypatch, tmp_path):
    monkeypatch.setenv("DRISHTI_JWT_SECRET", SECRET)
    monkeypatch.delenv("ENV", raising=False)
    # Failed-auth audit writes must never land in the tracked demo DB.
    import api.database as database

    monkeypatch.setattr(database, "DB_PATH", str(tmp_path / "unit_auth.db"))


class TestAppToken:
    def test_issue_and_decode_roundtrip(self) -> None:
        token, expires_in = issue_app_token("doctor@example.org", "doctor", "approved")
        assert expires_in <= 3600
        claims = decode_app_token(token)
        assert claims.email == "doctor@example.org"
        assert claims.role == "doctor"
        assert claims.specialist_status == "approved"

    def test_ttl_is_capped_at_one_hour(self) -> None:
        _, expires_in = issue_app_token("a@b.org", "operator", ttl_minutes=10_000)
        assert expires_in == 3600

    def test_ttl_has_a_floor(self) -> None:
        _, expires_in = issue_app_token("a@b.org", "operator", ttl_minutes=0)
        assert expires_in == 60

    def test_expired_token_rejected(self) -> None:
        now = datetime.now(timezone.utc)
        expired = jwt.encode(
            {
                "iss": JWT_ISSUER,
                "aud": JWT_AUDIENCE,
                "sub": "user:a@b.org",
                "email": "a@b.org",
                "role": "doctor",
                "iat": int((now - timedelta(hours=2)).timestamp()),
                "exp": int((now - timedelta(hours=1)).timestamp()),
            },
            SECRET,
            algorithm="HS256",
        )
        with pytest.raises(InvalidAppTokenError):
            decode_app_token(expired)

    def test_wrong_audience_rejected(self) -> None:
        now = datetime.now(timezone.utc)
        forged = jwt.encode(
            {
                "iss": JWT_ISSUER,
                "aud": "some-other-app",
                "sub": "user:a@b.org",
                "email": "a@b.org",
                "role": "admin",
                "iat": int(now.timestamp()),
                "exp": int((now + timedelta(minutes=30)).timestamp()),
            },
            SECRET,
            algorithm="HS256",
        )
        with pytest.raises(InvalidAppTokenError):
            decode_app_token(forged)

    def test_signed_with_other_secret_rejected(self) -> None:
        now = datetime.now(timezone.utc)
        forged = jwt.encode(
            {
                "iss": JWT_ISSUER,
                "aud": JWT_AUDIENCE,
                "sub": "user:a@b.org",
                "email": "a@b.org",
                "role": "admin",
                "iat": int(now.timestamp()),
                "exp": int((now + timedelta(minutes=30)).timestamp()),
            },
            "another-secret-another-secret-0123456789",
            algorithm="HS256",
        )
        with pytest.raises(InvalidAppTokenError):
            decode_app_token(forged)

    def test_garbage_rejected(self) -> None:
        with pytest.raises(InvalidAppTokenError):
            decode_app_token("not.a.jwt")
        with pytest.raises(InvalidAppTokenError):
            decode_app_token("")

    def test_prod_without_secret_refuses_to_issue(self, monkeypatch) -> None:
        monkeypatch.delenv("DRISHTI_JWT_SECRET", raising=False)
        monkeypatch.setenv("ENV", "prod")
        with pytest.raises(RuntimeError):
            issue_app_token("a@b.org", "operator")

    def test_short_secret_rejected(self, monkeypatch) -> None:
        monkeypatch.setenv("DRISHTI_JWT_SECRET", "too-short")
        with pytest.raises(RuntimeError):
            issue_app_token("a@b.org", "operator")


class TestPrincipalResolution:
    def test_api_key_path_still_works(self) -> None:
        app = FastAPI()

        @app.get("/who")
        def who(principal: ApiPrincipal = Depends(authenticate)):
            return {"role": principal.role, "method": principal.method}

        client = TestClient(app)
        response = client.get("/who", headers={"X-API-Key": "dev-doctor-key"})
        assert response.status_code == 200
        assert response.json() == {"role": "doctor", "method": "api_key"}

    def test_bearer_token_yields_jwt_principal(self) -> None:
        app = FastAPI()

        @app.get("/who")
        def who(principal: ApiPrincipal = Depends(authenticate)):
            return {
                "role": principal.role,
                "method": principal.method,
                "email": principal.email,
                "status": principal.specialist_status,
            }

        token, _ = issue_app_token("doc@example.org", "doctor", "approved")
        client = TestClient(app)
        response = client.get("/who", headers={"Authorization": f"Bearer {token}"})
        assert response.status_code == 200
        body = response.json()
        assert body == {
            "role": "doctor",
            "method": "app_jwt",
            "email": "doc@example.org",
            "status": "approved",
        }

    def test_no_credentials_is_401(self) -> None:
        app = FastAPI()

        @app.get("/who")
        def who(principal: ApiPrincipal = Depends(authenticate)):
            return {"role": principal.role}

        assert TestClient(app).get("/who").status_code == 401

    def test_invalid_bearer_is_401(self) -> None:
        app = FastAPI()

        @app.get("/who")
        def who(principal: ApiPrincipal = Depends(authenticate)):
            return {"role": principal.role}

        response = TestClient(app).get("/who", headers={"Authorization": "Bearer garbage"})
        assert response.status_code == 401

    def test_api_key_wins_when_both_present(self) -> None:
        app = FastAPI()

        @app.get("/who")
        def who(principal: ApiPrincipal = Depends(authenticate)):
            return {"role": principal.role, "method": principal.method}

        token, _ = issue_app_token("doc@example.org", "admin", "approved")
        response = TestClient(app).get(
            "/who",
            headers={"X-API-Key": "dev-operator-key", "Authorization": f"Bearer {token}"},
        )
        assert response.status_code == 200
        assert response.json() == {"role": "operator", "method": "api_key"}


class TestRoleMapping:
    def test_admin_allowlist_is_case_insensitive(self, monkeypatch) -> None:
        monkeypatch.setenv("DRISHTI_ADMIN_EMAILS", "Chief@Hospital.org")
        assert resolve_privileged_role("chief@hospital.ORG", None) == ("admin", "approved")

    def test_approved_specialist_becomes_doctor(self) -> None:
        assert resolve_privileged_role("doc@example.org", "approved") == ("doctor", "approved")

    def test_pending_specialist_stays_operator(self) -> None:
        assert resolve_privileged_role("doc@example.org", "pending") == ("operator", "pending")

    def test_rejected_specialist_stays_operator(self) -> None:
        assert resolve_privileged_role("doc@example.org", "rejected") == ("operator", "rejected")

    def test_unknown_email_is_operator(self) -> None:
        assert resolve_privileged_role("stranger@example.org", None) == ("operator", None)

    def test_admin_allowlist_does_not_grant_on_prefix(self, monkeypatch) -> None:
        monkeypatch.setenv("DRISHTI_ADMIN_EMAILS", "admin@hospital.org")
        assert resolve_privileged_role("admin@hospital.org.evil.example", None) == ("operator", None)
