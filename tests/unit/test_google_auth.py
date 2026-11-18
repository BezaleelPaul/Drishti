"""Unit tests: Google ID-token trust rules (T2)."""

from __future__ import annotations

import pytest

from api import google_auth
from api.google_auth import GoogleIdentity, GoogleTokenError, verify_google_id_token


def _claims(**overrides):
    base = {
        "iss": "https://accounts.google.com",
        "aud": "client-id.apps.googleusercontent.com",
        "sub": "1234567890",
        "email": "Doctor@Example.org",
        "email_verified": True,
    }
    base.update(overrides)
    return base


@pytest.fixture(autouse=True)
def _audiences(monkeypatch):
    monkeypatch.setenv("DRISHTI_GOOGLE_CLIENT_IDS", "client-id.apps.googleusercontent.com")


class TestGoogleTokenVerification:
    def test_valid_token_returns_lowercased_identity(self, monkeypatch) -> None:
        monkeypatch.setattr(google_auth, "_verify_with_google", lambda token, aud: _claims())
        identity = verify_google_id_token("a" * 40)
        assert identity == GoogleIdentity(subject="1234567890", email="doctor@example.org")

    def test_both_google_issuers_accepted(self, monkeypatch) -> None:
        monkeypatch.setattr(
            google_auth, "_verify_with_google", lambda token, aud: _claims(iss="accounts.google.com")
        )
        assert verify_google_id_token("a" * 40).email == "doctor@example.org"

    def test_unexpected_issuer_rejected(self, monkeypatch) -> None:
        monkeypatch.setattr(
            google_auth, "_verify_with_google", lambda token, aud: _claims(iss="https://evil.example")
        )
        with pytest.raises(GoogleTokenError):
            verify_google_id_token("a" * 40)

    def test_verifier_exception_becomes_token_error(self, monkeypatch) -> None:
        def _boom(token, aud):
            raise ValueError("bad signature / expired / wrong audience")

        monkeypatch.setattr(google_auth, "_verify_with_google", _boom)
        with pytest.raises(GoogleTokenError):
            verify_google_id_token("a" * 40)

    def test_unverified_email_rejected(self, monkeypatch) -> None:
        monkeypatch.setattr(
            google_auth, "_verify_with_google", lambda token, aud: _claims(email_verified=False)
        )
        with pytest.raises(GoogleTokenError):
            verify_google_id_token("a" * 40)

    def test_missing_email_rejected(self, monkeypatch) -> None:
        claims = _claims()
        claims.pop("email")
        monkeypatch.setattr(google_auth, "_verify_with_google", lambda token, aud: claims)
        with pytest.raises(GoogleTokenError):
            verify_google_id_token("a" * 40)

    def test_missing_subject_rejected(self, monkeypatch) -> None:
        monkeypatch.setattr(google_auth, "_verify_with_google", lambda token, aud: _claims(sub=""))
        with pytest.raises(GoogleTokenError):
            verify_google_id_token("a" * 40)

    def test_no_configured_client_ids_fails_closed(self, monkeypatch) -> None:
        monkeypatch.delenv("DRISHTI_GOOGLE_CLIENT_IDS", raising=False)
        monkeypatch.setattr(google_auth, "configured_client_ids", lambda: [])
        with pytest.raises(GoogleTokenError):
            verify_google_id_token("a" * 40)

    def test_empty_token_rejected_without_calling_google(self, monkeypatch) -> None:
        called = False

        def _spy(token, aud):
            nonlocal called
            called = True
            return _claims()

        monkeypatch.setattr(google_auth, "_verify_with_google", _spy)
        with pytest.raises(GoogleTokenError):
            verify_google_id_token("")
        assert called is False
